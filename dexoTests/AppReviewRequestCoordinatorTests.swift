import XCTest

@testable import dexo

@MainActor
final class AppReviewRequestCoordinatorTests: XCTestCase {
    func testSuccessfulLikeRequestsReviewOnlyOnceForVersion() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var requestCount = 0
        let coordinator = AppReviewRequestCoordinator(
            defaults: defaults,
            marketingVersion: { "1.2.3" },
            requestReview: {
                requestCount += 1
                return true
            }
        )

        XCTAssertTrue(coordinator.requestAfterLikeChange(liked: true))
        XCTAssertFalse(coordinator.requestAfterLikeChange(liked: true))
        XCTAssertEqual(requestCount, 1)
    }

    func testUnlikeDoesNotRequestReview() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var requestCount = 0
        let coordinator = AppReviewRequestCoordinator(
            defaults: defaults,
            marketingVersion: { "1.2.3" },
            requestReview: {
                requestCount += 1
                return true
            }
        )

        XCTAssertFalse(coordinator.requestAfterLikeChange(liked: false))
        XCTAssertEqual(requestCount, 0)
    }

    func testMissingForegroundSceneDoesNotConsumeEligibility() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let unavailableCoordinator = AppReviewRequestCoordinator(
            defaults: defaults,
            marketingVersion: { "1.2.3" },
            requestReview: { false }
        )

        XCTAssertFalse(unavailableCoordinator.requestAfterLikeChange(liked: true))

        var requestCount = 0
        let availableCoordinator = AppReviewRequestCoordinator(
            defaults: defaults,
            marketingVersion: { "1.2.3" },
            requestReview: {
                requestCount += 1
                return true
            }
        )
        XCTAssertTrue(availableCoordinator.requestAfterLikeChange(liked: true))
        XCTAssertEqual(requestCount, 1)
    }

    func testNewMarketingVersionCanRequestAgain() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var requestCount = 0
        let requester = {
            requestCount += 1
            return true
        }

        let firstVersion = AppReviewRequestCoordinator(
            defaults: defaults,
            marketingVersion: { "1.2.3" },
            requestReview: requester
        )
        let nextVersion = AppReviewRequestCoordinator(
            defaults: defaults,
            marketingVersion: { "1.2.4" },
            requestReview: requester
        )

        XCTAssertTrue(firstVersion.requestAfterLikeChange(liked: true))
        XCTAssertTrue(nextVersion.requestAfterLikeChange(liked: true))
        XCTAssertEqual(requestCount, 2)
    }

    func testRequestedVersionPersistsAcrossCoordinatorInstances() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var requestCount = 0
        let requester = {
            requestCount += 1
            return true
        }

        let first = AppReviewRequestCoordinator(
            defaults: defaults,
            marketingVersion: { "1.2.3" },
            requestReview: requester
        )
        XCTAssertTrue(first.requestAfterLikeChange(liked: true))

        let restored = AppReviewRequestCoordinator(
            defaults: defaults,
            marketingVersion: { "1.2.3" },
            requestReview: requester
        )
        XCTAssertFalse(restored.requestAfterLikeChange(liked: true))
        XCTAssertEqual(requestCount, 1)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "dexo-app-review-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
