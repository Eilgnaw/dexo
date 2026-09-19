import UIKit

/// Draggable circular reply button used in tree mode. Replaces the centered
/// bottom-bar reply button so the user can move it out of the way and have it
/// snap back to whichever screen edge is nearest.
final class FloatingReplyButton: UIButton {
    /// Size of the round affordance. Slightly larger than the bottom-bar
    /// buttons so it reads as a primary FAB.
    private static let buttonSize: CGFloat = 52
    /// Distance from the safe-area edges when snapped.
    private static let edgeInset: CGFloat = 16
    /// Vertical inset above the safe-area bottom when placed at default position.
    private static let defaultBottomInset: CGFloat = 24

    /// Captured during pan so a finger-relative drag works even when the
    /// gesture's `translation` is read against a non-stationary anchor.
    private var dragAnchor: CGPoint = .zero

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.buttonSize, height: Self.buttonSize))
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        let size = Self.buttonSize
        layer.cornerRadius = size / 2
        clipsToBounds = false

        var config: UIButton.Configuration
        if #available(iOS 26.0, *) {
            config = .glass()
        } else {
            config = .plain()
        }
        config.image = UIImage(systemName: "arrowshape.turn.up.left")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        config.baseForegroundColor = .label
        config.background.backgroundColor = .clear
        configuration = config
        accessibilityLabel = String(localized: "reply.title")

        if #unavailable(iOS 26.0) {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.16
            layer.shadowOffset = CGSize(width: 0, height: 3)
            layer.shadowRadius = 6
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            blur.layer.cornerRadius = size / 2
            blur.clipsToBounds = true
            blur.isUserInteractionEnabled = false
            blur.frame = bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            insertSubview(blur, at: 0)
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.cancelsTouchesInView = false
        addGestureRecognizer(pan)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        switch gesture.state {
        case .began:
            dragAnchor = center
        case .changed:
            let t = gesture.translation(in: parent)
            center = clampedCenter(CGPoint(x: dragAnchor.x + t.x, y: dragAnchor.y + t.y), in: parent)
        case .ended, .cancelled, .failed:
            snapToEdge(in: parent)
        default:
            break
        }
    }

    private func clampedCenter(_ p: CGPoint, in parent: UIView) -> CGPoint {
        let safe = parent.safeAreaLayoutGuide.layoutFrame
        let half = Self.buttonSize / 2
        let inset = Self.edgeInset
        let minX = min(safe.minX + inset + half, safe.midX)
        let maxX = max(safe.maxX - inset - half, safe.midX)
        let minY = min(safe.minY + inset + half, safe.midY)
        let maxY = max(safe.maxY - inset - half, safe.midY)
        return CGPoint(
            x: min(max(p.x, minX), maxX),
            y: min(max(p.y, minY), maxY)
        )
    }

    private func snapToEdge(in parent: UIView) {
        let safe = parent.safeAreaLayoutGuide.layoutFrame
        let half = Self.buttonSize / 2
        let inset = Self.edgeInset
        let leftEdge = min(safe.minX + inset + half, safe.midX)
        let rightEdge = max(safe.maxX - inset - half, safe.midX)
        let snapX: CGFloat = center.x < safe.midX ? leftEdge : rightEdge
        let target = CGPoint(x: snapX, y: center.y)
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            usingSpringWithDamping: 0.78,
            initialSpringVelocity: 0.6,
            options: [.allowUserInteraction],
            animations: { self.center = target }
        )
    }

    /// Place the button at its default position — bottom-right, just above the
    /// safe-area bottom. Idempotent; safe to call after rotation.
    func placeAtDefaultPosition() {
        guard let parent = superview else { return }
        let safe = parent.safeAreaLayoutGuide.layoutFrame
        let half = Self.buttonSize / 2
        let x = safe.maxX - Self.edgeInset - half
        let y = safe.maxY - Self.defaultBottomInset - half
        center = CGPoint(x: x, y: y)
    }

    /// Re-clamp to the current parent bounds — used on rotation so the button
    /// doesn't end up off-screen if the parent shrank along its current axis.
    func reclampToParent() {
        guard let parent = superview else { return }
        center = clampedCenter(center, in: parent)
    }
}
