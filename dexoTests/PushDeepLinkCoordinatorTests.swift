import Foundation
import XCTest
@testable import dexo

final class PushDeepLinkCoordinatorTests: XCTestCase {
    private func destination(id: String, delivery: TimeInterval = 100) -> PushDeepLinkCoordinator.Destination {
        .init(
            forumBaseURL: "https://example.com",
            relativeURL: "/t/example/123",
            notificationIdentifier: id,
            threadIdentifier: "topic-123",
            responseIdentity: .init(
                notificationIdentifier: id,
                deliveryDate: Date(timeIntervalSince1970: delivery),
                actionIdentifier: "default"
            )
        )
    }

    func testDuplicateSceneAndDelegateResponseCannotReplaceNewerDestination() {
        let coordinator = PushDeepLinkCoordinator()
        let first = destination(id: "first")
        let second = destination(id: "second")
        coordinator.enqueue(first)
        coordinator.enqueue(second)
        coordinator.enqueue(first)
        XCTAssertEqual(coordinator.pendingDestination?.responseIdentity, second.responseIdentity)
    }

    func testReusedNotificationIdentifierWithNewDeliveryIsAccepted() {
        let coordinator = PushDeepLinkCoordinator()
        coordinator.enqueue(destination(id: "same", delivery: 100))
        let replacement = destination(id: "same", delivery: 200)
        coordinator.enqueue(replacement)
        XCTAssertEqual(coordinator.pendingDestination?.responseIdentity, replacement.responseIdentity)
    }
}
