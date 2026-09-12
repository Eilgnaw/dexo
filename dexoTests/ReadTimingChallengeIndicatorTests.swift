import UIKit
import WebKit
import XCTest
@testable import dexo

@MainActor
final class ReadTimingSettingsTests: XCTestCase {
    func testTogglingReportingKeepsTheActiveSwitchInItsCell() throws {
        let settings = AppSettings.shared
        let wasEnabled = settings.linuxDoReadTimingsEnabled
        let challengeCoordinator = CloudflareChallengeCoordinator.shared
        let originalReasons = challengeCoordinator.reasons(for: "https://linux.do")
        defer {
            challengeCoordinator.clearAll(for: "https://linux.do")
            challengeCoordinator.report(originalReasons, for: "https://linux.do")
            settings.linuxDoReadTimingsEnabled = wasEnabled
        }
        challengeCoordinator.clearAll(for: "https://linux.do")
        settings.linuxDoReadTimingsEnabled = false

        let controller = LinuxDoReadTimingSettingsViewController(baseURL: "https://linux.do")
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
        challengeCoordinator.report(.readTiming, for: "https://linux.do")
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
        XCTAssertFalse(challengeCoordinator.requiresVerification(for: "https://linux.do"))
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
final class CloudflareChallengeIndicatorTests: XCTestCase {
    func testDefaultPlacementClampsAndSnapsToEitherSafeEdge() {
        let indicator = CloudflareChallengeIndicatorView { _ in }
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

    func testMenuReflectsMergedReasonsAndRoutesSelections() throws {
        var selections: [CloudflareChallengeIndicatorView.Action] = []
        let indicator = CloudflareChallengeIndicatorView { selections.append($0) }
        indicator.configure(reasons: [.readTiming, .generalRequest])
        let menu = try XCTUnwrap(indicator.menu)

        XCTAssertEqual(menu.title, String(localized: "cloudflare.challenge.title"))
        XCTAssertEqual(
            menu.children.map(\.title),
            [
                String(localized: "cloudflare.challenge.open"),
                String(localized: "cloudflare.challenge.disable_read_timing"),
                String(localized: "cloudflare.challenge.ignore"),
            ]
        )
        XCTAssertEqual(
            indicator.accessibilityValue,
            String(localized: "settings.read_timings.status.verification_required")
        )

        indicator.perform(.openChallenge)
        indicator.perform(.disableReporting)
        indicator.perform(.ignoreGeneralRequest)
        XCTAssertEqual(
            selections,
            [.openChallenge, .disableReporting, .ignoreGeneralRequest]
        )

        indicator.configure(reasons: .generalRequest)
        XCTAssertEqual(
            indicator.menu?.children.map(\.title),
            [
                String(localized: "cloudflare.challenge.open"),
                String(localized: "cloudflare.challenge.ignore"),
            ]
        )
    }

    func testBreathingSurvivesPresentationUpdatesAndRestartsAfterVisibilityChanges() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let indicator = CloudflareChallengeIndicatorView { _ in }
        window.addSubview(indicator)
        indicator.updatePlacement(in: window.bounds)
        indicator.layoutIfNeeded()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let glow = try XCTUnwrap(indicator.layer.sublayers?.first { $0.name == "cloudflareChallenge.glow" })

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

    func testSharedHostClearsOnlyTheReasonSelectedByTheUser() throws {
        let suiteName = "dexo-cloudflare-host-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = CloudflareChallengeCoordinator(
            defaults: defaults,
            migrateLegacyState: false
        )
        coordinator.report([.readTiming, .generalRequest], for: "https://linux.do")
        let settings = AppSettings.shared
        let wasEnabled = settings.linuxDoReadTimingsEnabled
        defer { settings.linuxDoReadTimingsEnabled = wasEnabled }
        settings.linuxDoReadTimingsEnabled = true

        let presenter = UIViewController()
        let host = CloudflareChallengeIndicatorHost(
            coordinator: coordinator,
            baseURLProvider: { "https://linux.do" },
            presenterProvider: { presenter }
        )
        host.install(in: presenter.view)

        host.indicator.perform(.ignoreGeneralRequest)
        XCTAssertEqual(coordinator.reasons(for: "https://linux.do"), .readTiming)
        XCTAssertFalse(host.indicator.isHidden)

        host.indicator.perform(.disableReporting)
        XCTAssertTrue(coordinator.reasons(for: "https://linux.do").isEmpty)
        XCTAssertFalse(settings.linuxDoReadTimingsEnabled)
        XCTAssertTrue(host.indicator.isHidden)
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

    func testChallengeConfigurationUsesDefaultStoreAndClearsProxyWhenDoHIsOff() async throws {
        guard #available(iOS 17.0, *) else { return }
        let settings = AppSettings.shared
        let wasEnabled = settings.dohEnabled
        defer { settings.dohEnabled = wasEnabled }
        settings.dohEnabled = false

        let (configuration, lease) = try await ChallengeViewController.makeWebViewConfiguration()

        XCTAssertTrue(configuration.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertTrue(configuration.websiteDataStore.proxyConfigurations.isEmpty)
        XCTAssertNil(lease)
    }

    func testChallengeConfigurationDoesNotFallBackWhenEnabledDoHIsInvalid() async {
        guard #available(iOS 17.0, *) else { return }
        let settings = AppSettings.shared
        let wasEnabled = settings.dohEnabled
        let previousServers = settings.dohServers
        let previousDefaultID = settings.defaultDoHServerID
        defer {
            settings.dohServers = previousServers
            settings.defaultDoHServerID = previousDefaultID
            settings.dohEnabled = wasEnabled
        }
        settings.dohServers = []
        settings.dohEnabled = true

        do {
            _ = try await ChallengeViewController.makeWebViewConfiguration()
            XCTFail("An invalid enabled DoH configuration must not silently use direct networking")
        } catch {
            XCTAssertTrue(WKWebsiteDataStore.default().proxyConfigurations.isEmpty)
        }
    }
}
