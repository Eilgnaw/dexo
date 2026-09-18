import XCTest

@testable import dexo

@MainActor
final class AuthenticationExpiryCoordinatorTests: XCTestCase {
    func testReminderIsPersistentAndForumScoped() throws {
        let suiteName = "dexo-auth-expiry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = AuthenticationExpiryCoordinator(defaults: defaults)

        XCTAssertFalse(coordinator.isPending(for: "https://one.example"))
        XCTAssertTrue(coordinator.report(for: "https://one.example/community/"))
        XCTAssertFalse(coordinator.report(for: "https://one.example/community"))
        XCTAssertFalse(coordinator.isPending(for: "https://one.example/other"))
        XCTAssertFalse(coordinator.isPending(for: "https://two.example/community"))
        XCTAssertTrue(
            AuthenticationExpiryCoordinator(defaults: defaults)
                .isPending(for: "https://one.example/community")
        )

        coordinator.clear(for: "https://one.example/community")
        XCTAssertFalse(coordinator.isPending(for: "https://one.example/community"))
    }

    func testOnlyCurrentCredentialCanBeExpired() throws {
        let baseURL = "https://auth-expiry-\(UUID().uuidString).example"
        let auth = AuthManager.shared
        defer {
            auth.clearLocalAuthentication(for: baseURL)
            AuthenticationExpiryCoordinator.shared.clear(for: baseURL)
        }
        try KeychainHelper.saveUserApiKey("old-key", for: baseURL)
        let oldRevision = auth.authenticationRevision(for: baseURL)

        auth.clearLocalAuthentication(for: baseURL)
        try KeychainHelper.saveUserApiKey("new-key", for: baseURL)
        auth.invalidateExpiredAuthentication(for: baseURL, expectedRevision: oldRevision)
        XCTAssertEqual(KeychainHelper.getUserApiKey(for: baseURL), "new-key")
        XCTAssertFalse(AuthenticationExpiryCoordinator.shared.isPending(for: baseURL))

        auth.invalidateExpiredAuthentication(
            for: baseURL,
            expectedRevision: auth.authenticationRevision(for: baseURL)
        )
        XCTAssertFalse(auth.isAuthenticated(for: baseURL))
        XCTAssertTrue(AuthenticationExpiryCoordinator.shared.isPending(for: baseURL))
    }

    func testMissingWebCookieExpiresSavedWebLogin() async throws {
        let baseURL = "https://expired-web-\(UUID().uuidString).example"
        let auth = AuthManager.shared
        defer {
            auth.clearLocalAuthentication(for: baseURL)
            AuthenticationExpiryCoordinator.shared.clear(for: baseURL)
        }
        try KeychainHelper.saveUserApiKey(AuthManager.webAuthSentinel, for: baseURL)

        await DiscourseAPI(baseURL: baseURL).verifyAuthentication()

        XCTAssertFalse(auth.isAuthenticated(for: baseURL))
        XCTAssertTrue(AuthenticationExpiryCoordinator.shared.isPending(for: baseURL))
    }

    func testLocalCredentialRemovalClearsReminder() {
        let baseURL = "https://logout-\(UUID().uuidString).example"
        let coordinator = AuthenticationExpiryCoordinator.shared
        coordinator.report(for: baseURL)

        AuthManager.shared.clearLocalAuthentication(for: baseURL)

        XCTAssertFalse(coordinator.isPending(for: baseURL))
    }

    func testLoginAndChallengeShareOneIndicatorMenu() {
        let indicator = CloudflareChallengeIndicatorView(onAction: { _ in })
        indicator.configure(
            reasons: [.generalRequest],
            authenticationExpired: true
        )

        let titles = indicator.menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
        XCTAssertEqual(indicator.accessibilityIdentifier, "authentication.expiry.indicator")
        XCTAssertTrue(titles.contains(String(localized: "auth.expired.relogin")))
        XCTAssertTrue(titles.contains(String(localized: "cloudflare.challenge.open")))
        XCTAssertTrue(titles.contains(String(localized: "auth.expired.ignore")))
    }
}
