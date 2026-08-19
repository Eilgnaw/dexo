import XCTest
@testable import dexo

@MainActor
final class HomeViewModelTests: XCTestCase {
    func testOlderFeedRequestCannotOverwriteNewMode() async throws {
        let api = MockHomeFeedAPI()
        api.delayActivityPageZero = true
        api.responses[api.key(.created, 0)] = try topicList(ids: [2])
        let viewModel = HomeViewModel(api: api)

        let oldRequest = Task { await viewModel.loadTopics() }
        for _ in 0 ..< 50 where api.delayedContinuation == nil {
            await Task.yield()
        }
        let delayed = try XCTUnwrap(api.delayedContinuation)
        api.delayedContinuation = nil

        XCTAssertTrue(viewModel.selectFeedMode(.created))
        await viewModel.loadTopics()
        XCTAssertEqual(viewModel.topics.map(\.id), [2])

        delayed.resume(returning: try topicList(ids: [1]))
        await oldRequest.value
        XCTAssertEqual(viewModel.feedMode, .created)
        XCTAssertEqual(viewModel.topics.map(\.id), [2])
    }

    func testFailedModeSwitchNeverDisplaysOldFeedWithNewTimestampSemantics() async throws {
        let api = MockHomeFeedAPI()
        api.responses[api.key(.activity, 0)] = try topicList(ids: [1])
        api.failures.insert(api.key(.created, 0))
        let viewModel = HomeViewModel(api: api)

        await viewModel.loadTopics()
        XCTAssertEqual(viewModel.topics.map(\.id), [1])

        XCTAssertTrue(viewModel.selectFeedMode(.created))
        XCTAssertTrue(viewModel.topics.isEmpty)
        await viewModel.loadTopics()

        XCTAssertEqual(viewModel.feedMode, .created)
        XCTAssertTrue(viewModel.topics.isEmpty)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testCreatedFeedKeepsTheSameModeForFirstPageAndLoadMore() async throws {
        let api = MockHomeFeedAPI()
        api.responses[api.key(.created, 0)] = try topicList(ids: [2], hasMore: true)
        api.responses[api.key(.created, 1)] = try topicList(ids: [3])
        let viewModel = HomeViewModel(api: api)

        XCTAssertTrue(viewModel.selectFeedMode(.created))
        await viewModel.loadTopics()
        await viewModel.loadMoreTopics()

        XCTAssertEqual(viewModel.topics.map(\.id), [2, 3])
        XCTAssertEqual(api.topicFeedCalls, [
            .init(mode: .created, page: 0),
            .init(mode: .created, page: 1),
        ])
    }

    func testCloudflareChallengeIsExposedToHomepage() async {
        let api = MockHomeFeedAPI()
        api.challengeFailures.insert(api.key(.activity, 0))
        let viewModel = HomeViewModel(api: api)

        await viewModel.loadTopics()

        XCTAssertTrue(viewModel.requiresChallenge)
        XCTAssertFalse(viewModel.requiresLogin)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    private func topicList(ids: [Int], hasMore: Bool = false) throws -> DiscourseTopicList {
        let topics = ids.map { id in
            """
            {
              "id": \(id),
              "fancy_title": "Topic \(id)",
              "title": "Topic \(id)",
              "posts_count": 1,
              "reply_count": 0,
              "views": 1,
              "created_at": "2026-07-10T00:00:00.000Z"
            }
            """
        }.joined(separator: ",")
        let more = hasMore ? #", "more_topics_url": "/latest?page=1""# : ""
        let json = #"{"users":[],"topic_list":{"topics":["# + topics + "]" + more + "}}"
        return try JSONDecoder().decode(DiscourseTopicList.self, from: Data(json.utf8))
    }
}

@MainActor
private final class MockHomeFeedAPI: HomeFeedAPIClient {
    struct Call: Equatable {
        let mode: TopicFeedMode
        let page: Int
    }

    enum Failure: LocalizedError {
        case requested

        var errorDescription: String? { "Requested test failure" }
    }

    var responses: [String: DiscourseTopicList] = [:]
    var failures = Set<String>()
    var challengeFailures = Set<String>()
    var topicFeedCalls: [Call] = []
    var delayActivityPageZero = false
    var delayedContinuation: CheckedContinuation<DiscourseTopicList, any Error>?

    func key(_ mode: TopicFeedMode, _ page: Int) -> String {
        "\(mode.rawValue):\(page)"
    }

    func fetchTopicFeed(mode: TopicFeedMode, page: Int) async throws -> DiscourseTopicList {
        topicFeedCalls.append(.init(mode: mode, page: page))
        if delayActivityPageZero, mode == .activity, page == 0 {
            return try await withCheckedThrowingContinuation { continuation in
                delayedContinuation = continuation
            }
        }
        let requestKey = key(mode, page)
        if challengeFailures.contains(requestKey) {
            throw DiscourseAPIError(
                messages: ["Cloudflare challenge required"],
                errorType: "challenge_required"
            )
        }
        if failures.contains(requestKey) { throw Failure.requested }
        return try XCTUnwrap(responses[requestKey])
    }

    func fetchCategoryTopics(
        slug: String,
        id: Int,
        feedMode: TopicFeedMode?,
        page: Int
    ) async throws -> DiscourseTopicList {
        throw Failure.requested
    }

    func fetchAllCategories(forceRefresh: Bool) async throws -> DiscourseCategoryList {
        DiscourseCategoryList(categoryList: .init(categories: []))
    }

    func invalidateCategoryCache() {}
}
