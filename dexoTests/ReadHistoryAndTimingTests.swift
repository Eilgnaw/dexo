import Foundation
import XCTest
@testable import dexo

final class ReadHistoryDatabaseTests: XCTestCase {
    func testMigrationUpsertAccountIsolationAndForumCascade() throws {
        try withDatabase { database in
            var forum = ForumInstance.new(title: "Forum", baseURL: "https://forum.example.com")
            try database.saveForum(&forum)
            let forumID = try XCTUnwrap(forum.id)
            let alice = ReadHistoryScope(forumId: forumID, accountKey: "user:alice", accountName: "Alice")
            let bob = ReadHistoryScope(forumId: forumID, accountKey: "user:bob", accountName: "Bob")

            let firstViewedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let latestViewedAt = Date(timeIntervalSince1970: 1_700_000_100)
            let first = try makeTopic(
                id: 42,
                title: "First title",
                fancyTitle: "Fancy title",
                avatarTemplate: "/avatar/{size}.png",
                tags: [["id": 7, "name": "Swift", "slug": "swift"]]
            )
            try database.recordLocalRead(topic: first, scope: alice, viewedAt: firstViewedAt)

            let updated = try makeTopic(id: 42, title: "Updated title")
            try database.recordLocalRead(topic: updated, scope: alice, viewedAt: latestViewedAt)

            let aliceRows = try database.fetchLocalReads(scope: alice)
            XCTAssertEqual(aliceRows.count, 1)
            XCTAssertEqual(aliceRows[0].title, "Updated title")
            XCTAssertEqual(aliceRows[0].fancyTitle, "Fancy title")
            XCTAssertEqual(aliceRows[0].avatarTemplate, "/avatar/{size}.png")
            XCTAssertEqual(aliceRows[0].tags, [TopicListTag(id: 7, name: "Swift", slug: "swift")])
            XCTAssertEqual(aliceRows[0].lastViewedAt.timeIntervalSince1970, latestViewedAt.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(try database.fetchLocalReadTopicIDs(scope: alice), [42])
            XCTAssertTrue(try database.fetchLocalReads(scope: bob).isEmpty)

            var secondForum = ForumInstance.new(title: "Second", baseURL: "https://second.example.com")
            try database.saveForum(&secondForum)
            let secondScope = ReadHistoryScope(
                forumId: try XCTUnwrap(secondForum.id),
                accountKey: alice.accountKey,
                accountName: alice.accountName
            )
            try database.recordLocalRead(
                topic: try makeTopic(id: 42, title: "Same ID on another forum"),
                scope: secondScope
            )
            XCTAssertEqual(try database.fetchLocalReads(scope: secondScope).count, 1)

            try database.deleteForum(forum)
            XCTAssertTrue(try database.fetchLocalReads(scope: alice).isEmpty)
            XCTAssertEqual(try database.fetchLocalReads(scope: secondScope).count, 1)
        }
    }

    func testTimingReportsAreGloballyTrimmedToLatestTwoHundredAndCanBeCleared() throws {
        try withDatabase { database in
            var forum = ForumInstance.new(title: "Forum", baseURL: "https://forum.example.com")
            try database.saveForum(&forum)
            let forumID = try XCTUnwrap(forum.id)

            for index in 0 ..< 205 {
                var report = TopicTimingReport(
                    id: nil,
                    forumId: forumID,
                    baseURL: forum.baseURL,
                    accountName: "alice",
                    topicId: index,
                    attemptedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    topicTime: 1_000,
                    postCount: 1,
                    visibleTime: 900,
                    requestDuration: 20,
                    statusCode: index.isMultiple(of: 2) ? 200 : 503,
                    outcome: index.isMultiple(of: 2) ? .success : .failure,
                    consecutiveFailureCount: 0,
                    trippedBreaker: false,
                    errorSummary: nil
                )
                try database.saveTopicTimingReport(&report)
            }

            let reports = try database.fetchTopicTimingReports()
            XCTAssertEqual(reports.count, 200)
            XCTAssertEqual(reports.first?.topicId, 204)
            XCTAssertEqual(reports.last?.topicId, 5)
            XCTAssertEqual(
                try database.fetchTopicTimingReports(filter: .success).count,
                100
            )
            XCTAssertEqual(
                try database.fetchTopicTimingReports(filter: .failure).count,
                100
            )

            try database.clearTopicTimingReports()
            XCTAssertTrue(try database.fetchTopicTimingReports().isEmpty)
        }
    }

    func testTimingReportsCanBeScopedAndClearedForLinuxDoOnly() throws {
        try withDatabase { database in
            var linuxDo = ForumInstance.new(title: "linux.do", baseURL: "https://linux.do")
            var meta = ForumInstance.new(title: "Meta", baseURL: "https://meta.linux.do")
            var other = ForumInstance.new(title: "Other", baseURL: "https://forum.example.com")
            try database.saveForum(&linuxDo)
            try database.saveForum(&meta)
            try database.saveForum(&other)

            let forums = [linuxDo, meta, other]
            for (index, forum) in forums.enumerated() {
                var report = TopicTimingReport(
                    id: nil,
                    forumId: try XCTUnwrap(forum.id),
                    baseURL: forum.baseURL,
                    accountName: "alice",
                    topicId: index + 1,
                    attemptedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    topicTime: 1_000,
                    postCount: 1,
                    visibleTime: 1_000,
                    requestDuration: 20,
                    statusCode: index == 1 ? 503 : 200,
                    outcome: index == 1 ? .failure : .success,
                    consecutiveFailureCount: index == 1 ? 1 : 0,
                    trippedBreaker: false,
                    errorSummary: index == 1 ? "HTTP 503" : nil
                )
                try database.saveTopicTimingReport(&report)
            }

            XCTAssertEqual(
                try database.fetchTopicTimingReports(scope: .linuxDo).map(\.topicId),
                [2, 1]
            )
            XCTAssertEqual(
                try database.fetchTopicTimingReports(filter: .failure, scope: .linuxDo).map(\.topicId),
                [2]
            )

            try database.clearTopicTimingReports(scope: .linuxDo)
            XCTAssertTrue(try database.fetchTopicTimingReports(scope: .linuxDo).isEmpty)
            XCTAssertEqual(
                try database.fetchTopicTimingReports(scope: .allForums).map(\.topicId),
                [3]
            )
        }
    }

    private func withDatabase(_ body: (DatabaseManager) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dexo-read-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let database = try DatabaseManager(testingPath: directory.appendingPathComponent("test.sqlite").path)
            try body(database)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeTopic(
        id: Int,
        title: String,
        fancyTitle: String? = nil,
        avatarTemplate: String? = nil,
        tags: [[String: Any]] = []
    ) throws -> DiscourseTopicDetail {
        var post: [String: Any] = [
            "id": id * 10,
            "username": "alice",
            "post_number": 1,
        ]
        if let avatarTemplate { post["avatar_template"] = avatarTemplate }
        var object: [String: Any] = [
            "id": id,
            "title": title,
            "posts_count": 2,
            "reply_count": 1,
            "created_at": "2026-07-01T00:00:00.000Z",
            "archetype": "regular",
            "tags": tags,
            "post_stream": ["posts": [post], "stream": [id * 10]],
        ]
        if let fancyTitle { object["fancy_title"] = fancyTitle }
        return try JSONDecoder().decode(
            DiscourseTopicDetail.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}

final class ReadTopicMergerTests: XCTestCase {
    func testMergeDeduplicatesUsesCloudMetadataAndTracksBothOrigins() throws {
        let localDate = try XCTUnwrap(ReadTopicRow.parseISODate("2026-07-10T00:00:00.000Z"))
        let local = LocalReadTopic(
            topic: try makeTopic(id: 1, title: "Local snapshot"),
            scope: ReadHistoryScope(forumId: 1, accountKey: "user:alice", accountName: "Alice"),
            viewedAt: localDate
        )
        let cloud = makeCloudTopic(
            id: 1,
            title: "Cloud metadata",
            bumpedAt: "2026-07-09T00:00:00.000Z",
            lastVisitedAt: "2026-07-12T00:00:00.000Z"
        )

        let rows = ReadTopicMerger.merge(localTopics: [local], cloudTopics: [cloud])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].topic.title, "Cloud metadata")
        XCTAssertEqual(rows[0].origins, [.local, .cloud])
        XCTAssertEqual(
            rows[0].mergedSortDate,
            try XCTUnwrap(ReadTopicRow.parseISODate("2026-07-12T00:00:00.000Z"))
        )
    }

    func testMergeSortUsesLocalReadTimeThenCloudActivityFallback() throws {
        let scope = ReadHistoryScope(forumId: 1, accountKey: "anonymous", accountName: nil)
        let newestLocal = LocalReadTopic(
            topic: try makeTopic(id: 3, title: "Local"),
            scope: scope,
            viewedAt: try XCTUnwrap(ReadTopicRow.parseISODate("2026-07-13T00:00:00.000Z"))
        )
        let cloudWithLastPost = makeCloudTopic(
            id: 2,
            title: "Cloud",
            bumpedAt: nil,
            lastPostedAt: "2026-07-11T00:00:00.000Z"
        )
        let cloudWithCreationOnly = makeCloudTopic(
            id: 4,
            title: "Older cloud",
            bumpedAt: nil,
            lastPostedAt: nil,
            createdAt: "2026-07-09T00:00:00.000Z"
        )

        let rows = ReadTopicMerger.merge(
            localTopics: [newestLocal],
            cloudTopics: [cloudWithCreationOnly, cloudWithLastPost]
        )

        XCTAssertEqual(rows.map(\.id), [3, 2, 4])
    }

    private func makeTopic(id: Int, title: String) throws -> DiscourseTopicDetail {
        try JSONDecoder().decode(
            DiscourseTopicDetail.self,
            from: Data("""
            {
              "id": \(id), "title": "\(title)", "posts_count": 1,
              "reply_count": 0, "created_at": "2026-07-01T00:00:00.000Z",
              "archetype": "regular", "post_stream": { "posts": [], "stream": [] }
            }
            """.utf8)
        )
    }

    private func makeCloudTopic(
        id: Int,
        title: String,
        bumpedAt: String?,
        lastPostedAt: String? = nil,
        lastVisitedAt: String? = nil,
        createdAt: String = "2026-07-01T00:00:00.000Z"
    ) -> DiscourseTopicList.Topic {
        DiscourseTopicList.Topic(
            id: id,
            fancyTitle: title,
            title: title,
            postsCount: 1,
            replyCount: 0,
            views: 0,
            categoryId: nil,
            createdAt: createdAt,
            lastPostedAt: lastPostedAt,
            bumpedAt: bumpedAt,
            lastVisitedAt: lastVisitedAt,
            pinned: nil,
            unseen: nil,
            excerpt: nil,
            posters: nil,
            tags: []
        )
    }
}

final class TopicTimingPolicyTests: XCTestCase {
    func testLinuxDoDefaultsOnAndExplicitOffPersists() throws {
        let suiteName = "dexo-topic-timing-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(testingDefaults: defaults)

        XCTAssertTrue(settings.linuxDoReadTimingsEnabled)
        settings.linuxDoReadTimingsEnabled = false
        XCTAssertFalse(AppSettings(testingDefaults: defaults).linuxDoReadTimingsEnabled)
        settings.linuxDoReadTimingsEnabled = true
        XCTAssertTrue(AppSettings(testingDefaults: defaults).linuxDoReadTimingsEnabled)
    }

    func testLinuxDoPolicyRequiresWebSessionAndCoversSubdomains() {
        let settings = AppSettings.shared
        let original = settings.linuxDoReadTimingsEnabled
        defer { settings.linuxDoReadTimingsEnabled = original }

        settings.linuxDoReadTimingsEnabled = false
        XCTAssertFalse(ForumPolicy.tracksReadTimings(baseURL: "https://linux.do", authKind: .webSession))
        settings.linuxDoReadTimingsEnabled = true
        XCTAssertTrue(ForumPolicy.tracksReadTimings(baseURL: "https://linux.do", authKind: .webSession))
        XCTAssertTrue(ForumPolicy.tracksReadTimings(baseURL: "https://meta.linux.do", authKind: .webSession))
        XCTAssertFalse(ForumPolicy.tracksReadTimings(baseURL: "https://linux.do", authKind: .userAPIKey))
        XCTAssertFalse(ForumPolicy.tracksReadTimings(baseURL: "https://linux.do", authKind: .anonymous))
        XCTAssertTrue(ForumPolicy.tracksReadTimings(baseURL: "https://example.com", authKind: .userAPIKey))
        XCTAssertTrue(ForumPolicy.tracksReadTimings(baseURL: "https://example.com", authKind: .webSession))
        XCTAssertFalse(ForumPolicy.tracksReadTimings(baseURL: "https://example.com", authKind: .anonymous))
    }

    func testCloudflareChallengeWinsOverSuccessStatus() {
        for statusCode in [200, 403, 503] {
            let assessment = assessTopicTimingResponse(
                statusCode: statusCode,
                data: Data("<html><title>Just a moment...</title><script>__cf_chl_</script></html>".utf8),
                errorDescription: nil
            )
            XCTAssertEqual(assessment.outcome, .cloudflareChallenge)
            XCTAssertEqual(assessment.statusCode, statusCode)
        }
    }

    func testSuccessAndOrdinaryFailureClassification() {
        XCTAssertEqual(
            assessTopicTimingResponse(statusCode: 204, data: Data(), errorDescription: nil).outcome,
            .success
        )
        let failure = assessTopicTimingResponse(statusCode: 500, data: Data(), errorDescription: nil)
        XCTAssertEqual(failure.outcome, .failure)
        XCTAssertEqual(failure.errorSummary, "HTTP 500")
    }

    func testTimingRouteDoesNotUseImmediateMutatingRetry() {
        XCTAssertFalse(
            allowsImmediateMutatingAuthRetry(
                for: URL(string: "https://linux.do/topics/timings")
            )
        )
        XCTAssertTrue(
            allowsImmediateMutatingAuthRetry(
                for: URL(string: "https://linux.do/posts.json")
            )
        )
    }
}

final class TopicReadTrackerTests: XCTestCase {
    func testEmptySnapshotKeepsTopicTimeForFirstVisiblePostBatch() {
        var currentTime: CFTimeInterval = 0
        let tracker = TopicReadTracker(now: { currentTime })
        tracker.startSession()

        currentTime = 2
        let emptySnapshot = tracker.snapshotDelta()
        XCTAssertEqual(emptySnapshot.topicTime, 0)
        XCTAssertTrue(emptySnapshot.timings.isEmpty)

        tracker.recordVisible(postNumber: 1)
        currentTime = 4
        tracker.recordHidden(postNumber: 1)
        let visibleSnapshot = tracker.snapshotDelta()

        XCTAssertEqual(visibleSnapshot.topicTime, 4_000)
        XCTAssertEqual(visibleSnapshot.timings, [1: 2_000])
    }

    func testSessionStartAlignsPostsRegisteredBeforeViewAppears() {
        var currentTime: CFTimeInterval = 0
        let tracker = TopicReadTracker(now: { currentTime })
        tracker.recordVisible(postNumber: 1)

        currentTime = 2
        tracker.startSession()
        currentTime = 3.25
        let snapshot = tracker.snapshotDelta()

        XCTAssertEqual(snapshot.topicTime, 1_250)
        XCTAssertEqual(snapshot.timings, [1: 1_250])
    }
}
