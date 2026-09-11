import Foundation
import GRDB
import XCTest
import UIKit
@testable import dexo

final class ForumLaunchCoordinatorTests: XCTestCase {
    private var directory: URL!
    private var databasePath: String!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var settings: AppSettings!
    private var database: DatabaseManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databasePath = directory.appendingPathComponent("launch.sqlite").path
        defaultsName = "ForumLaunchTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        settings = AppSettings(testingDefaults: defaults)
        database = try DatabaseManager(testingPath: databasePath)
    }

    override func tearDownWithError() throws {
        database = nil
        settings = nil
        defaults.removePersistentDomain(forName: defaultsName)
        defaults = nil
        try FileManager.default.removeItem(at: directory)
    }

    private var launch: ForumLaunchCoordinator {
        ForumLaunchCoordinator(database: database, settings: settings)
    }

    func testFreshInstallSeedsForumAndOpensItWithoutNetwork() throws {
        XCTAssertTrue(database.wasCreatedOnOpen)
        try launch.initializeDefaultForum()
        let forums = try database.fetchAllForums()
        XCTAssertEqual(forums.count, 1)
        let forum = try XCTUnwrap(forums.first)
        XCTAssertEqual(forum.baseURL, "https://discuss.python.org")
        XCTAssertFalse(forum.title.isEmpty)
        XCTAssertNotNil(forum.iconURL)
        XCTAssertNil(forum.apiKey)
        XCTAssertTrue(settings.autoOpenLastForum)
        XCTAssertTrue(settings.hasShownAutoOpenPrompt)
        XCTAssertEqual(settings.defaultForumInitialization, .completed)
        XCTAssertEqual(try launch.startupForum()?.id, forum.id)
    }

    func testRelaunchDoesNotDuplicateOrResetUserPreference() throws {
        try launch.initializeDefaultForum()
        let id = settings.lastOpenedForumId
        settings.autoOpenLastForum = false
        database = try DatabaseManager(testingPath: databasePath)
        XCTAssertFalse(database.wasCreatedOnOpen)
        try launch.initializeDefaultForum()
        XCTAssertEqual(try database.fetchAllForums().count, 1)
        XCTAssertEqual(settings.lastOpenedForumId, id)
        XCTAssertFalse(settings.autoOpenLastForum)
        XCTAssertNil(try launch.startupForum())
    }

    func testExistingEmptyStoreIsNotSeededAndKeepsSettings() throws {
        database = try DatabaseManager(testingPath: databasePath)
        settings.lastOpenedForumId = 42
        settings.autoOpenLastForum = true
        try launch.initializeDefaultForum()
        XCTAssertTrue(try database.fetchAllForums().isEmpty)
        XCTAssertEqual(settings.lastOpenedForumId, 42)
        XCTAssertTrue(settings.autoOpenLastForum)
        XCTAssertFalse(settings.hasShownAutoOpenPrompt)
        XCTAssertEqual(settings.defaultForumInitialization, .completed)
    }

    func testExistingUserForumAndDisabledSettingArePreserved() throws {
        var forum = ForumInstance.new(title: "Existing", baseURL: "https://example.com")
        try database.saveForum(&forum)
        let original = try database.fetchAllForums()
        settings.lastOpenedForumId = forum.id
        settings.autoOpenLastForum = false
        database = try DatabaseManager(testingPath: databasePath)
        try launch.initializeDefaultForum()
        XCTAssertEqual(try database.fetchAllForums(), original)
        XCTAssertEqual(settings.lastOpenedForumId, forum.id)
        XCTAssertFalse(settings.autoOpenLastForum)
    }

    func testDeletingDefaultForumDoesNotSeedItAgain() throws {
        try launch.initializeDefaultForum()
        let forum = try XCTUnwrap(database.fetchAllForums().first)
        try database.deleteForum(forum)
        database = try DatabaseManager(testingPath: databasePath)
        try launch.initializeDefaultForum()
        XCTAssertTrue(try database.fetchAllForums().isEmpty)
        XCTAssertNil(try launch.startupForum())
    }

    func testFailedInsertRemainsPendingAndRetriesAfterReopeningStore() throws {
        let queue = try DatabaseQueue(path: databasePath)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_seed BEFORE INSERT ON forumInstance
                BEGIN SELECT RAISE(FAIL, 'injected failure'); END
                """)
        }
        XCTAssertThrowsError(try launch.initializeDefaultForum())
        XCTAssertEqual(settings.defaultForumInitialization, .pending)
        XCTAssertNil(settings.lastOpenedForumId)
        XCTAssertFalse(settings.autoOpenLastForum)
        try queue.write { db in try db.execute(sql: "DROP TRIGGER fail_seed") }
        database = try DatabaseManager(testingPath: databasePath)
        try launch.initializeDefaultForum()
        XCTAssertEqual(try database.fetchAllForums().count, 1)
        XCTAssertEqual(settings.defaultForumInitialization, .completed)
        XCTAssertNotNil(try launch.startupForum())
    }

    func testInterruptedPreferenceWriteReusesAlreadySavedDefault() throws {
        settings.defaultForumInitialization = .pending
        var forum = ForumInstance.new(title: "Python", baseURL: ForumLaunchCoordinator.defaultForumBaseURL)
        try database.saveForum(&forum)
        database = try DatabaseManager(testingPath: databasePath)
        try launch.initializeDefaultForum()
        XCTAssertEqual(try database.fetchAllForums().count, 1)
        XCTAssertEqual(settings.lastOpenedForumId, forum.id)
    }

    func testPendingInitializationDoesNotAddAlongsideUserConfiguredForum() throws {
        settings.defaultForumInitialization = .pending
        var forum = ForumInstance.new(title: "Chosen", baseURL: "https://example.com")
        try database.saveForum(&forum)
        let original = try database.fetchAllForums()
        try launch.initializeDefaultForum()
        XCTAssertEqual(try database.fetchAllForums(), original)
        XCTAssertFalse(settings.autoOpenLastForum)
    }

    func testInvalidLastForumFallsBackToList() throws {
        settings.autoOpenLastForum = true
        XCTAssertNil(try launch.startupForum())
        settings.lastOpenedForumId = 999
        XCTAssertNil(try launch.startupForum())
        var forum = ForumInstance.new(title: "Legacy", baseURL: "http://example.com")
        try database.saveForum(&forum)
        settings.lastOpenedForumId = forum.id
        XCTAssertNil(try launch.startupForum())
    }

    func testNotificationTakesPriorityOverLastForum() throws {
        try launch.initializeDefaultForum()
        XCTAssertNotNil(try launch.startupForum())
        XCTAssertNil(try launch.startupForum(hasPendingNotification: true))
    }

    func testOfflineFirstLaunchKeepsDefaultForumAndExposesFeedError() async throws {
        try launch.initializeDefaultForum()
        let forumID = try XCTUnwrap(launch.startupForum()?.id)
        let home = HomeViewModel(api: OfflineHomeFeedAPI())
        await home.loadTopics()
        XCTAssertFalse(home.isLoading)
        XCTAssertTrue(home.topics.isEmpty)
        XCTAssertNotNil(home.errorMessage)
        XCTAssertFalse(home.requiresLogin)
        XCTAssertFalse(home.requiresChallenge)
        XCTAssertEqual(try launch.startupForum()?.id, forumID)
        XCTAssertEqual(try database.fetchAllForums().count, 1)
    }
}

@MainActor
private final class OfflineHomeFeedAPI: HomeFeedAPIClient {
    func fetchTopicFeed(mode: TopicFeedMode, page: Int) async throws -> DiscourseTopicList {
        throw URLError(.notConnectedToInternet)
    }

    func fetchCategoryTopics(slug: String, id: Int, feedMode: TopicFeedMode?, page: Int) async throws -> DiscourseTopicList {
        throw URLError(.notConnectedToInternet)
    }

    func fetchAllCategories(forceRefresh: Bool) async throws -> DiscourseCategoryList {
        throw URLError(.notConnectedToInternet)
    }

    func invalidateCategoryCache() {}
}

@MainActor
final class ForumOverlayGeometryTests: XCTestCase {
    func testManualOpenKeepsForumWindowWithinScreen() throws {
        try assertVisibleWindowGeometry(animated: true)
    }

    func testColdLaunchKeepsForumWindowWithinScreen() throws {
        try assertVisibleWindowGeometry(animated: false)
    }

    private func assertVisibleWindowGeometry(animated: Bool) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let animationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            ForumOverlayManager.shared.dismiss()
            window.isHidden = true
            previousKeyWindow?.makeKeyAndVisible()
            UIView.setAnimationsEnabled(animationsEnabled)
        }
        let forum = ForumInstance.new(title: "Geometry", baseURL: "https://example.com")
        let container = try XCTUnwrap(ForumOverlayManager.shared.present(forum: forum, in: window, animated: animated))
        let overlay = try XCTUnwrap(container.view.window)
        overlay.layoutIfNeeded()
        XCTAssertEqual(overlay.frame, window.frame)
        XCTAssertEqual(overlay.transform, .identity)
        XCTAssertTrue(overlay.isKeyWindow)
        XCTAssertFalse(overlay.isHidden)
    }
}
