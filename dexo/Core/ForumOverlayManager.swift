import SDWebImage
import UIKit

final class ForumOverlayManager {
    static let shared = ForumOverlayManager()

    private enum FloatingEdge { case left, right }
    private static let floatingButtonSize: CGFloat = 56
    private static let floatingEdgeInset: CGFloat = 32

    private(set) var currentContainer: ForumContainerViewController?
    private var floatingButton: UIView?
    private var floatingButtonEdge: FloatingEdge = .right
    private var isMinimized = false
    private weak var mainWindow: UIWindow?
    private var overlayWindow: UIWindow?

    /// Snapshot used during animations
    private var snapshotView: UIView?

    /// Tracks the floating button position for animation target
    private var floatingButtonCenter: CGPoint {
        guard let mainWindow else { return .zero }
        let range = floatingCenterRange(in: mainWindow)
        return CGPoint(x: range.maxX, y: range.maxY)
    }

    private func floatingSafeBounds(in window: UIWindow) -> CGRect {
        let bounds = window.safeAreaLayoutGuide.layoutFrame
        return bounds.width > 0 && bounds.height > 0
            ? bounds : window.bounds.inset(by: window.safeAreaInsets)
    }

    private func floatingCenterRange(in window: UIWindow) -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
        let safe = floatingSafeBounds(in: window)
        let inset = Self.floatingEdgeInset + Self.floatingButtonSize / 2
        return (
            minX: min(safe.minX + inset, safe.midX),
            maxX: max(safe.maxX - inset, safe.midX),
            minY: min(safe.minY + inset, safe.midY),
            maxY: max(safe.maxY - inset, safe.midY)
        )
    }

    private func clampedFloatingCenter(_ center: CGPoint, in window: UIWindow) -> CGPoint {
        let range = floatingCenterRange(in: window)
        return CGPoint(
            x: min(max(center.x, range.minX), range.maxX),
            y: min(max(center.y, range.minY), range.maxY)
        )
    }

    private func snappedFloatingCenter(_ center: CGPoint, in window: UIWindow) -> CGPoint {
        let range = floatingCenterRange(in: window)
        let clamped = clampedFloatingCenter(center, in: window)
        return CGPoint(
            x: floatingButtonEdge == .left ? range.minX : range.maxX,
            y: clamped.y
        )
    }

    private init() {}

    /// A secondary UIWindow does not follow the main window's Stage Manager
    /// size automatically on every iPadOS release.
    func updateGeometry(for scene: UIWindowScene) {
        guard let mainWindow, mainWindow.windowScene === scene else { return }
        mainWindow.layoutIfNeeded()
        let bounds = mainWindow.bounds
        if let overlayWindow, overlayWindow.windowScene === scene,
           overlayWindow.frame != bounds {
            overlayWindow.frame = bounds
            overlayWindow.rootViewController?.view.setNeedsLayout()
        }
        if isMinimized, let floatingButton, floatingButton.superview === mainWindow {
            floatingButton.center = snappedFloatingCenter(floatingButton.center, in: mainWindow)
        }
    }

    // MARK: - Present

    @discardableResult
    func present(forum: ForumInstance, in window: UIWindow, animated: Bool = true) -> ForumContainerViewController? {
        // The forum-list screen offers the user an explicit HTTPS migration.
        // Keep this lower-level entry point fail-closed for every other caller.
        guard ForumURLPolicy.isSecure(forum.baseURL) else { return nil }

        if let currentContainer,
           mainWindow === window,
           isSameForum(currentContainer.forum, forum) {
            if isMinimized {
                restore(animated: animated)
            } else {
                overlayWindow?.isHidden = false
                overlayWindow?.makeKeyAndVisible()
            }
            return currentContainer
        }

        // Clean up any existing instance
        dismissOverlayWindow()
        removeFloatingButton()
        isMinimized = false
        floatingButtonEdge = .right

        mainWindow = window

        guard let scene = window.windowScene else { return nil }

        let containerVC = ForumContainerViewController(forum: forum)
        currentContainer = containerVC

        let overlay = FeedbackWindow(windowScene: scene)
        overlay.rootViewController = containerVC
        overlay.windowLevel = .normal
        overlay.overrideUserInterfaceStyle = window.overrideUserInterfaceStyle
        ThemeManager.shared.apply(to: overlay)
        overlay.backgroundColor = ThemeManager.shared.backgroundColor
        overlay.frame = window.bounds
        overlayWindow = overlay
        overlay.makeKeyAndVisible()

        if animated {
            // UIKit establishes the window geometry when it becomes visible.
            // Applying a transform earlier can shift its final frame offscreen.
            overlay.transform = CGAffineTransform(translationX: 0, y: window.bounds.height)
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
                overlay.transform = .identity
            }
        }
        return containerVC
    }

    private func isSameForum(_ lhs: ForumInstance, _ rhs: ForumInstance) -> Bool {
        if let lhsID = lhs.id, let rhsID = rhs.id {
            return lhsID == rhsID
        }
        return normalizedBaseURL(lhs.baseURL) == normalizedBaseURL(rhs.baseURL)
    }

    private func normalizedBaseURL(_ value: String) -> String? {
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host != nil else { return nil }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string
    }

    // MARK: - Minimize

    func minimize() {
        guard let containerVC = currentContainer,
              let mainWindow,
              let overlayWindow,
              !isMinimized else { return }

        isMinimized = true

        // Take snapshot for animation
        guard let snapshot = overlayWindow.snapshotView(afterScreenUpdates: false) else {
            overlayWindow.isHidden = true
            mainWindow.makeKeyAndVisible()
            showFloatingButton(for: containerVC.forum)
            return
        }

        snapshot.frame = mainWindow.bounds
        snapshot.layer.cornerRadius = 0
        snapshot.clipsToBounds = true
        mainWindow.addSubview(snapshot)
        snapshotView = snapshot

        // Hide overlay window immediately
        overlayWindow.isHidden = true
        mainWindow.makeKeyAndVisible()

        let targetCenter = floatingButtonCenter
        let targetSize: CGFloat = 56

        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: []) {
            let scaleX = targetSize / snapshot.bounds.width
            let scaleY = targetSize / snapshot.bounds.height
            snapshot.transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
            snapshot.center = targetCenter
            snapshot.layer.cornerRadius = targetSize / 2
        } completion: { _ in
            snapshot.removeFromSuperview()
            self.snapshotView = nil
            self.showFloatingButton(for: containerVC.forum)
        }
    }

    // MARK: - Restore

    func restore(animated: Bool = true) {
        guard let _ = currentContainer,
              let mainWindow,
              let overlayWindow,
              isMinimized else { return }

        isMinimized = false

        let targetSize: CGFloat = 56
        let startCenter = floatingButton?.center ?? floatingButtonCenter

        removeFloatingButton()

        if !animated {
            overlayWindow.makeKeyAndVisible()
            return
        }

        // Show overlay briefly to get snapshot, then hide again for animation
        overlayWindow.isHidden = false
        guard let snapshot = overlayWindow.snapshotView(afterScreenUpdates: true) else {
            overlayWindow.makeKeyAndVisible()
            return
        }
        overlayWindow.isHidden = true

        // Start snapshot small at button position
        snapshot.frame = mainWindow.bounds
        let scaleX = targetSize / mainWindow.bounds.width
        let scaleY = targetSize / mainWindow.bounds.height
        snapshot.transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
        snapshot.center = startCenter
        snapshot.layer.cornerRadius = targetSize / 2
        snapshot.clipsToBounds = true
        mainWindow.addSubview(snapshot)
        snapshotView = snapshot

        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: []) {
            snapshot.transform = .identity
            snapshot.center = CGPoint(x: mainWindow.bounds.midX, y: mainWindow.bounds.midY)
            snapshot.layer.cornerRadius = 0
        } completion: { _ in
            snapshot.removeFromSuperview()
            self.snapshotView = nil
            overlayWindow.isHidden = false
            overlayWindow.makeKeyAndVisible()
        }
    }

    // MARK: - Dismiss

    func dismiss() {
        dismissOverlayWindow()
        removeFloatingButton()
        isMinimized = false
        snapshotView?.removeFromSuperview()
        snapshotView = nil
        mainWindow?.makeKeyAndVisible()
    }

    // MARK: - Floating Button

    private func showFloatingButton(for forum: ForumInstance) {
        guard let mainWindow else { return }

        removeFloatingButton()

        let size = Self.floatingButtonSize
        floatingButtonEdge = .right

        // Container view
        let button = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        button.center = floatingButtonCenter
        button.layer.cornerRadius = size / 2
        button.clipsToBounds = false
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowRadius = 8
        button.layer.shadowOpacity = 0.3
        button.layer.shadowOffset = CGSize(width: 0, height: 2)

        // Blur background
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blur.frame = button.bounds
        blur.layer.cornerRadius = size / 2
        blur.clipsToBounds = true
        blur.isUserInteractionEnabled = false
        button.addSubview(blur)

        // Favicon
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 12
        imageView.frame = CGRect(x: 12, y: 12, width: size - 24, height: size - 24)

        if let iconURLString = forum.iconURL, let iconURL = URL(string: iconURLString) {
            imageView.sd_setImage(with: iconURL, placeholderImage: UIImage(systemName: "globe"), options: [], context: ImageCacheManager.shared.avatarContext)
        } else {
            imageView.image = UIImage(systemName: "globe")
            imageView.tintColor = .label
        }
        button.addSubview(imageView)

        // Tap gesture
        let tap = UITapGestureRecognizer(target: self, action: #selector(floatingButtonTapped))
        button.addGestureRecognizer(tap)

        // Pan gesture for dragging
        let pan = UIPanGestureRecognizer(target: self, action: #selector(floatingButtonPanned(_:)))
        button.addGestureRecognizer(pan)

        // Long press to dismiss
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(floatingButtonLongPressed(_:)))
        button.addGestureRecognizer(longPress)

        button.isUserInteractionEnabled = true
        mainWindow.addSubview(button)
        floatingButton = button

        // Appear animation
        button.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
            button.transform = .identity
        }
    }

    private func removeFloatingButton() {
        floatingButton?.removeFromSuperview()
        floatingButton = nil
    }

    // MARK: - Gesture Handlers

    @objc private func floatingButtonTapped() {
        restore()
    }

    @objc private func floatingButtonPanned(_ gesture: UIPanGestureRecognizer) {
        guard let button = floatingButton, let mainWindow else { return }

        let translation = gesture.translation(in: mainWindow)

        switch gesture.state {
        case .changed:
            let proposed = CGPoint(
                x: button.center.x + translation.x,
                y: button.center.y + translation.y
            )
            button.center = clampedFloatingCenter(proposed, in: mainWindow)
            gesture.setTranslation(.zero, in: mainWindow)

        case .ended, .cancelled:
            floatingButtonEdge = button.center.x < floatingSafeBounds(in: mainWindow).midX
                ? .left : .right
            let target = snappedFloatingCenter(button.center, in: mainWindow)

            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                button.center = target
            }

        default:
            break
        }
    }

    @objc private func floatingButtonLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }

        let alert = UIAlertController(
            title: nil,
            message: nil,
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: String(localized: "forum.overlay.close"), style: .destructive) { [weak self] _ in
            self?.dismiss()
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))

        // Present from rootVC of main window
        if let rootVC = mainWindow?.rootViewController {
            if let popover = alert.popoverPresentationController {
                popover.sourceView = floatingButton
                popover.sourceRect = floatingButton?.bounds ?? .zero
            }
            rootVC.present(alert, animated: true)
        }
    }

    // MARK: - Helpers

    private func dismissOverlayWindow() {
        currentContainer?.stopPoller()
        currentContainer = nil
        overlayWindow?.isHidden = true
        overlayWindow?.rootViewController = nil
        overlayWindow = nil
    }
}
