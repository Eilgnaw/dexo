import UIKit

#if DEBUG

/// Floating FPS counter for the top-right of the screen. Debug builds only.
///
/// Install once per `UIWindowScene` from `SceneDelegate`:
///     FPSOverlay.shared.install(on: windowScene)
///
/// Implementation notes:
/// - Lives in its own `UIWindow` above `.statusBar` so it survives navigation and
///   modal presentations without needing per-screen hookup.
/// - The window and its root view pass hit-tests through to the scene below, so
///   the counter never intercepts touches.
/// - Driven by `CADisplayLink`; sampled every 0.5s so the reading is stable.
final class FPSOverlay {
    static let shared = FPSOverlay()

    private var window: UIWindow?
    private let label = UILabel()
    private var displayLink: CADisplayLink?
    private var frameCount = 0
    private var windowStart: CFTimeInterval = 0
    private var targetFPS: Int = 60

    private init() {}

    func install(on scene: UIWindowScene) {
        guard window == nil else { return }

        let w = PassthroughWindow(windowScene: scene)
        w.windowLevel = .statusBar + 1
        w.backgroundColor = .clear

        let root = PassthroughViewController()
        w.rootViewController = root

        label.font = FontManager.shared.monospacedDigitFont(size: 11, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        label.layer.cornerRadius = 4
        label.layer.masksToBounds = true
        label.text = "-- fps"
        label.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
            label.heightAnchor.constraint(equalToConstant: 18),
        ])

        w.isHidden = false
        window = w

        targetFPS = max(60, scene.screen.maximumFramesPerSecond)

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if windowStart == 0 {
            windowStart = link.timestamp
            frameCount = 1
            return
        }
        frameCount += 1
        let elapsed = link.timestamp - windowStart
        guard elapsed >= 0.5 else { return }

        let fps = Double(frameCount) / elapsed
        let displayFPS = Int(round(fps))
        label.text = "\(displayFPS) fps"
        let green = Double(targetFPS) - 2           // within ~2 fps of target
        let yellow = Double(targetFPS) * 0.75       // 75% of target
        if fps >= green {
            label.textColor = .systemGreen
        } else if fps >= yellow {
            label.textColor = .systemYellow
        } else {
            label.textColor = .systemRed
        }

        frameCount = 0
        windowStart = link.timestamp
    }
}

// MARK: - Hit-test passthrough

/// A `UIWindow` that only intercepts touches actually landing on one of its
/// subviews (i.e. the FPS label). Everything else falls through to the window
/// below.
///
/// `UIView.hitTest` on a full-screen window always returns `self` for blank
/// areas (since `pointInside:` is true everywhere), so we explicitly fold
/// both the window itself and its root view back into a `nil` return.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit == nil || hit === self || hit === rootViewController?.view {
            return nil
        }
        return hit
    }
}

private final class PassthroughViewController: UIViewController {}

#endif
