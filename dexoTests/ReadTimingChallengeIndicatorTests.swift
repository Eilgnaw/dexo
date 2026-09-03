import UIKit
import XCTest
@testable import dexo

@MainActor
final class ReadTimingChallengeIndicatorTests: XCTestCase {
    func testDefaultPlacementClampsAndSnapsToEitherSafeEdge() {
        let indicator = ReadTimingChallengeIndicatorView { _ in }
        let availableBounds = CGRect(x: 0, y: 100, width: 390, height: 560)
        indicator.updatePlacement(in: availableBounds)

        XCTAssertGreaterThan(indicator.center.x, availableBounds.midX)
        XCTAssertGreaterThan(indicator.frame.minX, availableBounds.minX)
        XCTAssertLessThan(indicator.frame.maxX, availableBounds.maxX)
        XCTAssertGreaterThan(indicator.frame.minY, availableBounds.minY)
        XCTAssertLessThan(indicator.frame.maxY, availableBounds.maxY)

        let left = indicator.snappedCenter(for: CGPoint(x: -1_000, y: -1_000))
        let right = indicator.snappedCenter(for: CGPoint(x: 1_000, y: 1_000))
        XCTAssertLessThan(left.x, availableBounds.midX)
        XCTAssertGreaterThan(right.x, availableBounds.midX)
        XCTAssertGreaterThan(left.y, availableBounds.minY)
        XCTAssertLessThan(right.y, availableBounds.maxY)
    }

    func testMenuExposesBothLocalizedActionsAndRoutesSelections() throws {
        var selections: [ReadTimingChallengeIndicatorView.Action] = []
        let indicator = ReadTimingChallengeIndicatorView { selections.append($0) }
        let menu = try XCTUnwrap(indicator.menu)

        XCTAssertEqual(menu.title, String(localized: "settings.read_timings.challenge.title"))
        XCTAssertEqual(
            menu.children.map(\.title),
            [
                String(localized: "settings.read_timings.challenge.open"),
                String(localized: "settings.read_timings.challenge.disable"),
            ]
        )
        XCTAssertEqual(
            indicator.accessibilityValue,
            String(localized: "settings.read_timings.status.verification_required")
        )

        indicator.perform(.openChallenge)
        indicator.perform(.disableReporting)
        XCTAssertEqual(selections, [.openChallenge, .disableReporting])
    }

    func testPresentationAnimationRunsAtMostOnceUntilHidden() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let indicator = ReadTimingChallengeIndicatorView { _ in }
        window.addSubview(indicator)
        indicator.updatePlacement(in: window.bounds)

        indicator.setPresented(true, animated: false)
        XCTAssertFalse(indicator.isHidden)
        indicator.setPresented(false, animated: false)
        XCTAssertTrue(indicator.isHidden)
        indicator.setPresented(true, animated: false)
        XCTAssertFalse(indicator.isHidden)
    }
}

@MainActor
final class ChallengeFlowTests: XCTestCase {
    func testInteractiveDismissalReportsCancellationOnlyOnceAfterFinalSync() async throws {
        var results: [ChallengeFlowResult] = []
        let finished = expectation(description: "Challenge flow finished")
        let controller = ChallengeViewController(
            targetURL: try XCTUnwrap(URL(string: "https://linux.do/challenge")),
            userAgent: nil
        ) { result in
            results.append(result)
            finished.fulfill()
        }
        let presentationController = UIPresentationController(
            presentedViewController: controller,
            presenting: nil
        )

        controller.presentationControllerDidDismiss(presentationController)
        controller.presentationControllerDidDismiss(presentationController)
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(results, [.cancelled])
    }
}
