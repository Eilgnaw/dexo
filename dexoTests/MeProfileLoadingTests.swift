import XCTest
@testable import dexo

@MainActor
final class MeProfileLoadingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var cache: ProfileCacheStore!

    override func setUp() {
        super.setUp()
        suiteName = "me-profile-loading-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        cache = ProfileCacheStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        cache = nil
        defaults = nil
        super.tearDown()
    }

    func testSlowSummaryDoesNotHoldBackIdentityAndLoadingEndsOnCompletion() async throws {
        let api = MockMeProfileAPI()
        api.delayProfile = true
        api.delaySummary = true
        let model = makeModel(api)
        let task = Task { await model.reload() }
        await waitUntil { api.profileContinuation != nil && api.summaryContinuation != nil }
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.currentUser)
        let profile = try makeProfile(name: "Fresh profile")
        api.finishProfile(profile)
        await waitUntil { model.currentUser != nil }
        XCTAssertEqual(model.currentUser?.name, "Fresh profile")
        XCTAssertNil(model.summary)
        XCTAssertTrue(model.isLoading)
        api.finishSummary()
        await task.value
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.summary?.topicCount, 32)
        XCTAssertEqual(cache.load(for: api.baseURL)?.profile.name, "Fresh profile")
    }

    func testForcedRefreshShowsMatchingCacheWhileNetworkIsPending() async throws {
        let api = MockMeProfileAPI()
        api.delayProfile = true
        let cached = try makeProfile(name: "Cached profile")
        cache.save(profile: cached, summary: api.summary, for: api.baseURL)
        let model = makeModel(api)
        let task = Task { await model.reload() }
        await waitUntil { api.profileContinuation != nil }
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.currentUser?.name, "Cached profile")
        XCTAssertEqual(model.summary?.topicCount, 32)
        api.finishProfile(try makeProfile(name: "Fresh profile"))
        await task.value
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.currentUser?.name, "Fresh profile")
    }

    func testFreshCacheAvoidsAnInitialNetworkRequest() async throws {
        let api = MockMeProfileAPI()
        cache.save(profile: try makeProfile(name: "Cached profile"), summary: api.summary, for: api.baseURL)
        let model = makeModel(api)
        await model.loadProfile()
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.currentUser?.name, "Cached profile")
        XCTAssertEqual(api.profileCalls, 0)
        XCTAssertEqual(api.summaryCalls, 0)
    }

    func testCacheFromAnotherAccountIsNotShown() async throws {
        let api = MockMeProfileAPI()
        api.delayProfile = true
        cache.save(profile: try makeProfile(name: "Other account", username: "other"), summary: api.summary, for: api.baseURL)
        let model = makeModel(api)
        let task = Task { await model.reload() }
        await waitUntil { api.profileContinuation != nil }
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.currentUser)
        api.finishProfile(try makeProfile(name: "Correct account"))
        await task.value
        XCTAssertEqual(model.currentUser?.username, "lin")
    }

    func testFailureStopsLoadingAndAllowsRetry() async {
        let api = MockMeProfileAPI()
        api.failProfile = true
        let model = makeModel(api)
        await model.reload()
        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.currentUser)
        api.failProfile = false
        await model.reload()
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.currentUser?.username, "lin")
    }

    func testSummaryFailureStillKeepsLoadedIdentity() async {
        let api = MockMeProfileAPI()
        api.failSummary = true
        let model = makeModel(api)
        await model.reload()
        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.currentUser)
        XCTAssertNil(model.summary)
        XCTAssertNil(model.errorMessage)
    }

    func testLogoutPreventsDelayedRequestFromRestoringTheOldAccount() async throws {
        let api = MockMeProfileAPI()
        api.delayProfile = true
        let model = makeModel(api)
        let task = Task { await model.reload() }
        await waitUntil { api.profileContinuation != nil }
        model.clearCachedProfile()
        XCTAssertFalse(model.isLoading)
        api.finishProfile(try makeProfile(name: "Old account"))
        await task.value
        XCTAssertNil(model.currentUser)
        XCTAssertNil(model.userProfile)
        XCTAssertNil(cache.load(for: api.baseURL))
        XCTAssertFalse(model.isLoading)
    }

    private func makeModel(_ api: MockMeProfileAPI) -> MeViewModel {
        MeViewModel(api: api, cacheStore: cache, usernameProvider: { "lin" }, cacheUsername: { _ in })
    }

    private func makeProfile(name: String, username: String = "lin") throws -> DiscourseUserProfile {
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "username": username, "name": name])
        return try JSONDecoder().decode(DiscourseUserProfile.self, from: data)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
        }
        XCTAssertTrue(predicate(), "The controlled request did not reach its expected state.")
    }
}

@MainActor
private final class MockMeProfileAPI: MeProfileAPIClient {
    enum Failure: Error { case requested }
    let baseURL = "https://me-loading-tests.example.com"
    let isLinuxDo = false
    let summary = DiscourseUserSummary(topicCount: 32, postCount: 186, likesGiven: 5, likesReceived: 1024, daysVisited: 128)
    var delayProfile = false
    var delaySummary = false
    var failProfile = false
    var failSummary = false
    var profileCalls = 0
    var summaryCalls = 0
    var profileContinuation: CheckedContinuation<DiscourseUserProfile, Error>?
    var summaryContinuation: CheckedContinuation<DiscourseUserSummary, Error>?

    func fetchCurrentUser() async throws -> DiscourseCurrentUser { throw Failure.requested }
    func fetchNotifications(limit: Int?, filter: String?) async throws -> DiscourseNotificationList { throw Failure.requested }

    func fetchUserProfile(username: String) async throws -> DiscourseUserProfile {
        profileCalls += 1
        if failProfile { throw Failure.requested }
        if delayProfile {
            return try await withCheckedThrowingContinuation { profileContinuation = $0 }
        }
        return try JSONDecoder().decode(DiscourseUserProfile.self, from: Data(#"{"id":1,"username":"lin","name":"Lin"}"#.utf8))
    }

    func fetchUserSummary(username: String) async throws -> DiscourseUserSummary {
        summaryCalls += 1
        if failSummary { throw Failure.requested }
        if delaySummary {
            return try await withCheckedThrowingContinuation { summaryContinuation = $0 }
        }
        return summary
    }

    func finishProfile(_ profile: DiscourseUserProfile) {
        let continuation = profileContinuation
        profileContinuation = nil
        continuation?.resume(returning: profile)
    }

    func finishSummary() {
        let continuation = summaryContinuation
        summaryContinuation = nil
        continuation?.resume(returning: summary)
    }
}
