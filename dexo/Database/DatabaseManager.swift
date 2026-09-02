import Foundation
import GRDB

final class DatabaseManager: Sendable {
    static let shared = DatabaseManager()

    private let dbPool: DatabasePool

    private init() {
        do {
            let fileManager = FileManager.default
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dbURL = appSupport.appendingPathComponent("dexo.sqlite")
            dbPool = try DatabasePool(path: dbURL.path)
            try migrator.migrate(dbPool)
        } catch {
            fatalError("Database initialization failed: \(error)")
        }
    }

    /// Isolated database seam used by unit tests. Production code always uses
    /// `shared`, while tests can validate migrations and retention without
    /// touching the app's real Application Support container.
    init(testingPath path: String) throws {
        dbPool = try DatabasePool(path: path)
        try migrator.migrate(dbPool)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "forumInstance") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("baseURL", .text).notNull()
                t.column("iconURL", .text)
                t.column("apiKey", .text)
                t.column("apiUsername", .text)
                t.column("addedAt", .datetime).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v2") { db in
            try db.alter(table: "forumInstance") { t in
                t.add(column: "username", .text)
            }
        }

        migrator.registerMigration("v3_read_history_and_timing_reports") { db in
            try db.create(table: "localReadTopic") { t in
                t.column("forumId", .integer)
                    .notNull()
                    .references("forumInstance", onDelete: .cascade)
                t.column("accountKey", .text).notNull()
                t.column("topicId", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("fancyTitle", .text)
                t.column("postsCount", .integer).notNull()
                t.column("replyCount", .integer).notNull()
                t.column("categoryId", .integer)
                t.column("createdAt", .text).notNull()
                t.column("avatarTemplate", .text)
                t.column("tagsJSON", .text).notNull().defaults(to: "[]")
                t.column("lastViewedAt", .datetime).notNull()
                t.primaryKey(["forumId", "accountKey", "topicId"])
            }
            try db.create(
                index: "localReadTopic_scope_viewedAt",
                on: "localReadTopic",
                columns: ["forumId", "accountKey", "lastViewedAt"]
            )

            try db.create(table: "topicTimingReport") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("forumId", .integer)
                    .notNull()
                    .references("forumInstance", onDelete: .cascade)
                t.column("baseURL", .text).notNull()
                t.column("accountName", .text)
                t.column("topicId", .integer).notNull()
                t.column("attemptedAt", .datetime).notNull()
                t.column("topicTime", .integer).notNull()
                t.column("postCount", .integer).notNull()
                t.column("visibleTime", .integer).notNull()
                t.column("requestDuration", .integer).notNull()
                t.column("statusCode", .integer)
                t.column("outcome", .text).notNull()
                t.column("consecutiveFailureCount", .integer).notNull()
                t.column("trippedBreaker", .boolean).notNull().defaults(to: false)
                t.column("errorSummary", .text)
            }
            try db.create(
                index: "topicTimingReport_attemptedAt",
                on: "topicTimingReport",
                columns: ["attemptedAt"]
            )
        }

        migrator.registerMigration("v4_push_subscriptions") { db in
            try db.create(table: "pushSubscription") { t in
                t.column("subscriptionID", .text).primaryKey()
                t.column("forumId", .integer)
                    .notNull()
                    .references("forumInstance", onDelete: .cascade)
                t.column("accountName", .text).notNull()
                t.column("endpoint", .text).notNull()
                t.column("previousEndpoint", .text)
                t.column("expiresAt", .datetime).notNull()
                t.column("apnsTokenFingerprint", .text).notNull()
                t.column("state", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["forumId", "accountName"])
            }
        }

        migrator.registerMigration("v5_push_stale_endpoints") { db in
            try db.alter(table: "pushSubscription") { t in
                t.add(
                    column: "staleEndpointsJSON",
                    .text
                ).notNull().defaults(to: "[]")
            }
        }

        return migrator
    }

    // MARK: - Forum CRUD

    func fetchAllForums() throws -> [ForumInstance] {
        try dbPool.read { db in
            try ForumInstance.order(Column("sortOrder").asc, Column("addedAt").asc).fetchAll(db)
        }
    }

    @discardableResult
    func saveForum(_ forum: inout ForumInstance) throws -> ForumInstance {
        try dbPool.write { db in
            try forum.save(db)
            return forum
        }
    }

    func deleteForum(_ forum: ForumInstance) throws {
        try dbPool.write { db in
            _ = try forum.delete(db)
        }
    }

    func nextForumSortOrder() throws -> Int {
        try dbPool.read { db in
            let max = try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM forumInstance") ?? -1
            return max + 1
        }
    }

    func updateForumOrder(_ forums: [ForumInstance]) throws {
        try dbPool.write { db in
            for (index, forum) in forums.enumerated() {
                var updated = forum
                updated.sortOrder = index
                try updated.update(db)
            }
        }
    }

    // MARK: - Local Read History

    func recordLocalRead(
        topic: DiscourseTopicDetail,
        scope: ReadHistoryScope,
        viewedAt: Date = Date()
    ) throws {
        try dbPool.write { db in
            var incoming = LocalReadTopic(topic: topic, scope: scope, viewedAt: viewedAt)
            if let existing = try LocalReadTopic
                .filter(Column("forumId") == scope.forumId)
                .filter(Column("accountKey") == scope.accountKey)
                .filter(Column("topicId") == topic.id)
                .fetchOne(db)
            {
                if incoming.fancyTitle?.isEmpty != false { incoming.fancyTitle = existing.fancyTitle }
                if incoming.avatarTemplate?.isEmpty != false { incoming.avatarTemplate = existing.avatarTemplate }
                if incoming.tagsJSON == "[]" { incoming.tagsJSON = existing.tagsJSON }
                if incoming.createdAt.isEmpty { incoming.createdAt = existing.createdAt }
            }
            try incoming.save(db)
        }
    }

    func fetchLocalReads(scope: ReadHistoryScope) throws -> [LocalReadTopic] {
        try dbPool.read { db in
            try LocalReadTopic
                .filter(Column("forumId") == scope.forumId)
                .filter(Column("accountKey") == scope.accountKey)
                .order(Column("lastViewedAt").desc)
                .fetchAll(db)
        }
    }

    func fetchLocalReadTopicIDs(scope: ReadHistoryScope) throws -> Set<Int> {
        try dbPool.read { db in
            let ids = try Int.fetchAll(
                db,
                sql: """
                SELECT topicId FROM localReadTopic
                WHERE forumId = ? AND accountKey = ?
                """,
                arguments: [scope.forumId, scope.accountKey]
            )
            return Set(ids)
        }
    }

    // MARK: - Topic Timing Reports

    func saveTopicTimingReport(_ report: inout TopicTimingReport) throws {
        try dbPool.write { db in
            try report.insert(db)
            try db.execute(
                sql: """
                DELETE FROM topicTimingReport
                WHERE id NOT IN (
                    SELECT id FROM topicTimingReport
                    ORDER BY attemptedAt DESC, id DESC
                    LIMIT 200
                )
                """
            )
        }
    }

    func fetchTopicTimingReports(
        filter: TopicTimingReportFilter = .all,
        scope: TopicTimingReportScope = .allForums
    ) throws -> [TopicTimingReport] {
        try dbPool.read { db in
            var request = TopicTimingReport.order(Column("attemptedAt").desc, Column("id").desc)
            switch filter {
            case .all:
                break
            case .success:
                request = request.filter(Column("outcome") == TopicTimingOutcome.success.rawValue)
            case .failure:
                request = request.filter(Column("outcome") != TopicTimingOutcome.success.rawValue)
            }
            return try request.fetchAll(db).filter { scope.includes(baseURL: $0.baseURL) }
        }
    }

    func clearTopicTimingReports(scope: TopicTimingReportScope = .allForums) throws {
        try dbPool.write { db in
            switch scope {
            case .allForums:
                _ = try TopicTimingReport.deleteAll(db)
            case .linuxDo:
                let reports = try TopicTimingReport.fetchAll(db)
                for report in reports where scope.includes(baseURL: report.baseURL) {
                    guard let id = report.id else { continue }
                    _ = try TopicTimingReport.deleteOne(db, key: id)
                }
            }
        }
    }

    // MARK: - Push Subscriptions

    func fetchPushSubscription(forumId: Int64, accountName: String) throws -> PushSubscriptionRecord? {
        try dbPool.read { db in
            try PushSubscriptionRecord
                .filter(Column("forumId") == forumId)
                .filter(Column("accountName") == accountName)
                .fetchOne(db)
        }
    }

    func fetchAllPushSubscriptions() throws -> [PushSubscriptionRecord] {
        try dbPool.read { db in
            try PushSubscriptionRecord.fetchAll(db)
        }
    }

    func savePushSubscription(_ subscription: PushSubscriptionRecord) throws {
        try dbPool.write { db in
            try subscription.save(db)
        }
    }

    func replacePushSubscription(
        subscriptionID: String,
        with replacement: PushSubscriptionRecord
    ) throws {
        try dbPool.write { db in
            _ = try PushSubscriptionRecord.deleteOne(db, key: subscriptionID)
            try replacement.save(db)
        }
    }

    func deletePushSubscription(subscriptionID: String) throws {
        try dbPool.write { db in
            _ = try PushSubscriptionRecord.deleteOne(db, key: subscriptionID)
        }
    }
}
