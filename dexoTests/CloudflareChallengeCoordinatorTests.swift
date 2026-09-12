import XCTest
@testable import dexo

@MainActor
final class CloudflareChallengeCoordinatorTests: XCTestCase {
    func testReasonsPersistMergeAndClearIndependently() throws {
        let suiteName = "dexo-cloudflare-state-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = CloudflareChallengeCoordinator(
            defaults: defaults,
            migrateLegacyState: false
        )
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .cloudflareChallengeStateDidChange,
            object: coordinator,
            queue: .main
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertTrue(coordinator.report(.readTiming, for: "https://linux.do/t/1"))
        XCTAssertFalse(coordinator.report(.readTiming, for: "https://linux.do"))
        XCTAssertTrue(coordinator.report(.generalRequest, for: "https://linux.do"))
        XCTAssertEqual(
            coordinator.reasons(for: "https://linux.do/latest"),
            [.readTiming, .generalRequest]
        )
        XCTAssertEqual(notificationCount, 2)

        let restored = CloudflareChallengeCoordinator(
            defaults: defaults,
            migrateLegacyState: false
        )
        XCTAssertEqual(
            restored.reasons(for: "https://linux.do"),
            [.readTiming, .generalRequest]
        )
        restored.clear(.generalRequest, for: "https://linux.do")
        XCTAssertEqual(restored.reasons(for: "https://linux.do"), .readTiming)
        XCTAssertFalse(restored.allowsAutomaticRequests(for: "https://linux.do"))
        restored.clear(.readTiming, for: "https://linux.do")
        XCTAssertTrue(restored.allowsAutomaticRequests(for: "https://linux.do"))
    }

    func testLegacyReadTimingFlagMigratesOnce() throws {
        let suiteName = "dexo-cloudflare-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "linuxDoReadTimingsNeedsVerification")

        let coordinator = CloudflareChallengeCoordinator(defaults: defaults)

        XCTAssertEqual(coordinator.reasons(for: "https://linux.do"), .readTiming)
        XCTAssertNil(defaults.object(forKey: "linuxDoReadTimingsNeedsVerification"))
        XCTAssertEqual(
            CloudflareChallengeCoordinator(defaults: defaults)
                .reasons(for: "https://linux.do"),
            .readTiming
        )
    }

    func testNonLinuxDoChallengesAreNotStored() throws {
        let suiteName = "dexo-cloudflare-scope-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = CloudflareChallengeCoordinator(
            defaults: defaults,
            migrateLegacyState: false
        )

        XCTAssertFalse(coordinator.report(.generalRequest, for: "https://example.com"))
        XCTAssertTrue(coordinator.pendingSiteBaseURLs.isEmpty)
    }

    func testNotificationPollerPausesAndResumesWithSharedChallengeState() throws {
        let suiteName = "dexo-cloudflare-poller-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = CloudflareChallengeCoordinator(
            defaults: defaults,
            migrateLegacyState: false
        )
        let poller = NotificationPoller(
            api: DiscourseAPI(baseURL: "https://linux.do"),
            usernameProvider: { nil },
            challengeCoordinator: coordinator
        )
        defer { poller.stop() }

        coordinator.report(.generalRequest, for: "https://linux.do")
        poller.start()
        XCTAssertFalse(poller.hasScheduledPollForTesting)

        coordinator.clear(.generalRequest, for: "https://linux.do")
        XCTAssertTrue(poller.hasScheduledPollForTesting)

        coordinator.report(.readTiming, for: "https://linux.do")
        XCTAssertFalse(poller.hasScheduledPollForTesting)
    }
}
