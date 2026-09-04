import UIKit

/// A non-modal, draggable affordance shown while linux.do timing uploads are
/// paused for Cloudflare verification. The system menu keeps both choices
/// anchored to the button without interrupting the current reading context.
final class ReadTimingChallengeIndicatorView: UIButton {
    enum Action: Equatable {
        case openChallenge
        case disableReporting
    }

    private static let buttonSize: CGFloat = 48
    private static let edgeInset: CGFloat = 16
    private static let breathingAnimationKey = "readTimingChallenge.breathing"

    private let onAction: (Action) -> Void
    private let glowLayer = CAShapeLayer()
    private var isApplicationActive = UIApplication.shared.applicationState == .active
    private var movementBounds: CGRect = .zero
    private var dragAnchor: CGPoint = .zero
    private var hasBeenPlaced = false
    private var hasAnimatedAppearance = false

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        super.init(frame: CGRect(
            origin: .zero,
            size: CGSize(width: Self.buttonSize, height: Self.buttonSize)
        ))
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.frame = bounds
        let ring = UIBezierPath(ovalIn: bounds.insetBy(dx: -5, dy: -5))
        ring.append(UIBezierPath(ovalIn: bounds.insetBy(dx: -1, dy: -1)))
        glowLayer.path = ring.cgPath
        glowLayer.shadowPath = ring.cgPath
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        configureTheme()
        updateBreathingAnimation()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            configureTheme()
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []
        clipsToBounds = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.shadowRadius = 7
        glowLayer.name = "readTimingChallenge.glow"
        glowLayer.fillRule = .evenOdd
        glowLayer.shadowOpacity = 0.6
        glowLayer.shadowOffset = .zero
        glowLayer.shadowRadius = 5
        glowLayer.opacity = 0.12
        layer.insertSublayer(glowLayer, at: 0)
        accessibilityIdentifier = "read_timings.challenge.indicator"
        accessibilityLabel = String(localized: "settings.read_timings.challenge.title")
        accessibilityHint = String(localized: "settings.read_timings.challenge.indicator.hint")
        accessibilityValue = String(localized: "settings.read_timings.status.verification_required")
        isPointerInteractionEnabled = true
        showsMenuAsPrimaryAction = true

        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.image = UIImage(
            systemName: "exclamationmark.shield.fill",
            withConfiguration: symbolConfiguration
        ) ?? UIImage(systemName: "shield.fill", withConfiguration: symbolConfiguration)
        buttonConfiguration.contentInsets = .zero
        buttonConfiguration.cornerStyle = .capsule
        configuration = buttonConfiguration

        let openChallenge = UIAction(
            title: String(localized: "settings.read_timings.challenge.open"),
            image: UIImage(systemName: "shield.lefthalf.filled")
        ) { [weak self] _ in
            self?.perform(.openChallenge)
        }
        let disableReporting = UIAction(
            title: String(localized: "settings.read_timings.challenge.disable"),
            image: UIImage(systemName: "clock.badge.xmark"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.perform(.disableReporting)
        }
        menu = UIMenu(
            title: String(localized: "settings.read_timings.challenge.title"),
            options: .displayInline,
            children: [openChallenge, disableReporting]
        )

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateBreathingAnimation),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil
        )
        configureTheme()
        isHidden = true
    }

    func configureTheme() {
        let palette = ThemeManager.shared.profileHeaderPalette
        configuration?.baseBackgroundColor = palette.background
        configuration?.baseForegroundColor = palette.foreground
        let glowColor = ThemeManager.shared.accentColor.resolvedColor(with: traitCollection).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.fillColor = glowColor
        glowLayer.shadowColor = glowColor
        CATransaction.commit()
    }

    @objc private func applicationWillResignActive() {
        isApplicationActive = false
        updateBreathingAnimation()
    }

    @objc private func applicationDidBecomeActive() {
        isApplicationActive = true
        updateBreathingAnimation()
    }

    @objc private func updateBreathingAnimation() {
        guard !isHidden, window != nil, isApplicationActive,
              !UIAccessibility.isReduceMotionEnabled
        else {
            glowLayer.removeAnimation(forKey: Self.breathingAnimationKey)
            return
        }
        guard glowLayer.animation(forKey: Self.breathingAnimationKey) == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.12
        animation.toValue = 0.30
        animation.duration = 1.4
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(animation, forKey: Self.breathingAnimationKey)
    }

    func setPresented(_ presented: Bool, animated: Bool) {
        guard presented else {
            layer.removeAllAnimations()
            isHidden = true
            updateBreathingAnimation()
            alpha = 1
            transform = .identity
            hasAnimatedAppearance = false
            return
        }

        isHidden = false
        updateBreathingAnimation()
        guard animated,
              window != nil,
              !hasAnimatedAppearance,
              !UIAccessibility.isReduceMotionEnabled
        else { return }

        hasAnimatedAppearance = true
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            usingSpringWithDamping: 0.78,
            initialSpringVelocity: 0.3,
            options: [.allowUserInteraction]
        ) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    /// Updates the region in which the button may move. The caller excludes
    /// navigation, tab-bar, and bottom-action-button space from this rectangle.
    func updatePlacement(in availableBounds: CGRect) {
        guard availableBounds.width > 0, availableBounds.height > 0 else { return }
        movementBounds = availableBounds
        if hasBeenPlaced {
            center = clampedCenter(for: center)
        } else {
            hasBeenPlaced = true
            let range = centerRange
            center = CGPoint(
                x: range.maxX,
                y: range.minY + ((range.maxY - range.minY) * 0.62)
            )
        }
    }

    func clampedCenter(for proposedCenter: CGPoint) -> CGPoint {
        let range = centerRange
        return CGPoint(
            x: min(max(proposedCenter.x, range.minX), range.maxX),
            y: min(max(proposedCenter.y, range.minY), range.maxY)
        )
    }

    func snappedCenter(for proposedCenter: CGPoint) -> CGPoint {
        let clamped = clampedCenter(for: proposedCenter)
        let range = centerRange
        return CGPoint(
            x: clamped.x < movementBounds.midX ? range.minX : range.maxX,
            y: clamped.y
        )
    }

    func perform(_ action: Action) {
        onAction(action)
    }

    private var centerRange: (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
        let half = Self.buttonSize / 2
        let horizontalInset = Self.edgeInset + half
        let verticalInset = Self.edgeInset + half
        let minimumX = movementBounds.minX + horizontalInset
        let maximumX = movementBounds.maxX - horizontalInset
        let minimumY = movementBounds.minY + verticalInset
        let maximumY = movementBounds.maxY - verticalInset
        return (
            minX: min(minimumX, movementBounds.midX),
            maxX: max(maximumX, movementBounds.midX),
            minY: min(minimumY, movementBounds.midY),
            maxY: max(maximumY, movementBounds.midY)
        )
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard superview != nil else { return }
        switch gesture.state {
        case .began:
            dragAnchor = center
        case .changed:
            let translation = gesture.translation(in: superview)
            center = clampedCenter(for: CGPoint(
                x: dragAnchor.x + translation.x,
                y: dragAnchor.y + translation.y
            ))
        case .ended, .cancelled, .failed:
            let target = snappedCenter(for: center)
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                usingSpringWithDamping: 0.8,
                initialSpringVelocity: 0.4,
                options: [.allowUserInteraction]
            ) {
                self.center = target
            }
        default:
            break
        }
    }
}
