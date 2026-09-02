import Foundation
import GRDB

enum TopicTimingOutcome: String, Codable, CaseIterable, DatabaseValueConvertible, Sendable {
    case success
    case failure
    case cloudflareChallenge

    var isFailure: Bool { self != .success }
}

struct TopicTimingReport: Codable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "topicTimingReport"

    var id: Int64?
    var forumId: Int64
    var baseURL: String
    var accountName: String?
    var topicId: Int
    var attemptedAt: Date
    var topicTime: Int
    var postCount: Int
    var visibleTime: Int
    var requestDuration: Int
    var statusCode: Int?
    var outcome: TopicTimingOutcome
    var consecutiveFailureCount: Int
    var trippedBreaker: Bool
    var errorSummary: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

enum TopicTimingReportFilter: Int, CaseIterable, Sendable {
    case all
    case success
    case failure
}

nonisolated enum TopicTimingReportScope: Equatable, Sendable {
    case allForums
    case linuxDo

    func includes(baseURL: String) -> Bool {
        switch self {
        case .allForums:
            return true
        case .linuxDo:
            return ForumPolicy.isLinuxDoFamily(baseURL: baseURL)
        }
    }
}
