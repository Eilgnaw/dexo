import XCTest

@testable import dexo

@MainActor
final class AppReviewRequestCoordinatorTests: XCTestCase {
    func testSuccessfulLikesAlwaysForwardReviewRequestToSystem() {
        var requestCount = 0
        let coordinator = AppReviewRequestCoordinator(
            requestReview: {
                requestCount += 1
                return true
            }
        )

        XCTAssertTrue(coordinator.requestAfterLikeChange(liked: true))
        XCTAssertTrue(coordinator.requestAfterLikeChange(liked: true))
        XCTAssertEqual(requestCount, 2)
    }

    func testUnlikeDoesNotRequestReview() {
        var requestCount = 0
        let coordinator = AppReviewRequestCoordinator(
            requestReview: {
                requestCount += 1
                return true
            }
        )

        XCTAssertFalse(coordinator.requestAfterLikeChange(liked: false))
        XCTAssertEqual(requestCount, 0)
    }

    func testPublishedReplyAndLoginAlwaysForwardReviewRequestsToSystem() {
        var requestCount = 0
        let coordinator = AppReviewRequestCoordinator(
            requestReview: {
                requestCount += 1
                return true
            }
        )

        XCTAssertTrue(coordinator.requestAfterPublishedReply())
        XCTAssertTrue(coordinator.requestAfterLogin())
        XCTAssertTrue(coordinator.requestAfterPublishedReply())
        XCTAssertTrue(coordinator.requestAfterLogin())
        XCTAssertEqual(requestCount, 4)
    }

    func testUnavailableSystemReviewRequestReturnsFalse() {
        let coordinator = AppReviewRequestCoordinator(requestReview: { false })

        XCTAssertFalse(coordinator.requestAfterLikeChange(liked: true))
        XCTAssertFalse(coordinator.requestAfterPublishedReply())
        XCTAssertFalse(coordinator.requestAfterLogin())
    }
}
