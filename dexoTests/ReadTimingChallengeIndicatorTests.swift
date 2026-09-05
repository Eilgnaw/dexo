import UIKit
import XCTest
@testable import dexo

@MainActor
final class ReadTimingSettingsTests: XCTestCase {
    func testTogglingReportingKeepsTheActiveSwitchInItsCell() throws {
        let settings = AppSettings.shared
        let wasEnabled = settings.linuxDoReadTimingsEnabled
        let neededVerification = settings.linuxDoReadTimingsNeedsVerification
        defer {
            settings.linuxDoReadTimingsEnabled = wasEnabled
            settings.linuxDoReadTimingsNeedsVerification = neededVerification
        }
        settings.linuxDoReadTimingsEnabled = false

        let controller = LinuxDoReadTimingSettingsViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()
        let table = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UITableView }.first)
        let indexPath = IndexPath(row: 0, section: 0)
        let originalCell = try XCTUnwrap(table.cellForRow(at: indexPath))
        let toggle = try XCTUnwrap(originalCell.accessoryView as? UISwitch)

        for enabled in [true, false, true, false] {
            toggle.setOn(enabled, animated: false)
            toggle.sendActions(for: .valueChanged)
            controller.view.layoutIfNeeded()
            XCTAssertEqual(settings.linuxDoReadTimingsEnabled, enabled)
            XCTAssertEqual(toggle.isOn, enabled)
            XCTAssertTrue(table.cellForRow(at: indexPath) === originalCell,
                          "The cell containing the active control must survive its valueChanged callback")
            XCTAssertTrue(toggle.isDescendant(of: originalCell))
        }

        // A background upload can require verification while this page is
        // visible. That notification must update the subtitle in place too.
        settings.linuxDoReadTimingsEnabled = true
        settings.linuxDoReadTimingsNeedsVerification = true
        controller.view.layoutIfNeeded()
        XCTAssertTrue(toggle.isOn)
        XCTAssertTrue(table.cellForRow(at: indexPath) === originalCell)
        XCTAssertEqual(
            originalCell.detailTextLabel?.text,
            String(localized: "settings.read_timings.linux_do.verification_required_subtitle")
        )

        toggle.setOn(false, animated: false)
        toggle.sendActions(for: .valueChanged)
        controller.view.layoutIfNeeded()
        XCTAssertFalse(settings.linuxDoReadTimingsNeedsVerification)
        XCTAssertFalse(settings.linuxDoReadTimingsEnabled)
        XCTAssertTrue(table.cellForRow(at: indexPath) === originalCell)
        XCTAssertTrue(toggle.isDescendant(of: originalCell))
        XCTAssertEqual(
            originalCell.detailTextLabel?.text,
            String(localized: "settings.read_timings.linux_do.subtitle")
        )
    }
}

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

    func testBreathingSurvivesPresentationUpdatesAndRestartsAfterVisibilityChanges() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let indicator = ReadTimingChallengeIndicatorView { _ in }
        window.addSubview(indicator)
        indicator.updatePlacement(in: window.bounds)
        indicator.layoutIfNeeded()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let glow = try XCTUnwrap(indicator.layer.sublayers?.first { $0.name == "readTimingChallenge.glow" })

        indicator.setPresented(true, animated: false)
        XCTAssertFalse(indicator.isHidden)
        XCTAssertEqual(indicator.bounds.size, CGSize(width: 48, height: 48))
        XCTAssertEqual(indicator.configuration?.cornerStyle, .capsule)
        XCTAssertEqual(indicator.layer.cornerRadius, 24)
        if !UIAccessibility.isReduceMotionEnabled {
            let key = try XCTUnwrap(glow.animationKeys()?.first)
            let started = try XCTUnwrap(glow.animation(forKey: key)).beginTime
            indicator.setPresented(true, animated: false)
            indicator.configureTheme()
            indicator.layoutIfNeeded()
            XCTAssertEqual(glow.animationKeys(), [key])
            XCTAssertEqual(glow.animation(forKey: key)?.beginTime, started)
        }
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(glow.animationKeys()?.isEmpty ?? true)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(!(glow.animationKeys()?.isEmpty ?? true), !UIAccessibility.isReduceMotionEnabled)

        indicator.setPresented(false, animated: false)
        XCTAssertTrue(indicator.isHidden)
        XCTAssertTrue(glow.animationKeys()?.isEmpty ?? true)
        indicator.setPresented(true, animated: false)
        XCTAssertFalse(indicator.isHidden)
        XCTAssertEqual(!(glow.animationKeys()?.isEmpty ?? true), !UIAccessibility.isReduceMotionEnabled)
        indicator.removeFromSuperview()
        XCTAssertTrue(glow.animationKeys()?.isEmpty ?? true)
        window.addSubview(indicator)
        XCTAssertEqual(!(glow.animationKeys()?.isEmpty ?? true), !UIAccessibility.isReduceMotionEnabled)
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
