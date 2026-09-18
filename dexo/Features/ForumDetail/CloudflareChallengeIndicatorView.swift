import UIKit

/// A non-modal, draggable affordance for forum attention states. The menu
/// keeps login recovery and Cloudflare actions in one place when both apply.
final class CloudflareChallengeIndicatorView: UIButton {
    enum Action: Equatable {
        case relogin
        case ignoreAuthentication
        case openChallenge
        case disableReporting
        case ignoreGeneralRequest
    }

    private static let buttonSize: CGFloat = 48
    private static let edgeInset: CGFloat = 16
    private static let breathingAnimationKey = "cloudflareChallenge.breathing"

    private let onAction: (Action) -> Void
    private let glowLayer = CAShapeLayer()
    private var isApplicationActive = UIApplication.shared.applicationState == .active
    private var movementBounds: CGRect = .zero
    private var dragAnchor: CGPoint = .zero
    private var hasBeenPlaced = false
    private var hasAnimatedAppearance = false
    private(set) var reasons: CloudflareChallengeReason = []
    private(set) var authenticationExpired = false

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
        glowLayer.name = "cloudflareChallenge.glow"
        glowLayer.fillRule = .evenOdd
        glowLayer.shadowOpacity = 0.6
        glowLayer.shadowOffset = .zero
        glowLayer.shadowRadius = 5
        glowLayer.opacity = 0.12
        layer.insertSublayer(glowLayer, at: 0)
        accessibilityIdentifier = "cloudflare.challenge.indicator"
        accessibilityHint = String(localized: "cloudflare.challenge.indicator.hint")
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

        configure(reasons: [])

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

    func configure(
        reasons: CloudflareChallengeReason,
        authenticationExpired: Bool = false
    ) {
        guard reasons != self.reasons
                || authenticationExpired != self.authenticationExpired
                || menu == nil else { return }
        self.reasons = reasons
        self.authenticationExpired = authenticationExpired
        let hasGeneralRequest = reasons.contains(.generalRequest)
        let title = authenticationExpired
            ? String(localized: "auth.expired.title")
            : hasGeneralRequest
                ? String(localized: "cloudflare.challenge.title")
                : String(localized: "settings.read_timings.challenge.title")
        accessibilityLabel = title
        accessibilityValue = authenticationExpired
            ? String(localized: "auth.expired.title")
            : String(localized: "settings.read_timings.status.verification_required")
        accessibilityHint = authenticationExpired
            ? String(localized: "auth.expired.indicator.hint")
            : String(localized: "cloudflare.challenge.indicator.hint")
        accessibilityIdentifier = authenticationExpired
            ? "authentication.expiry.indicator"
            : "cloudflare.challenge.indicator"

        var buttonConfiguration = configuration
        let symbol = authenticationExpired
            ? "person.crop.circle.badge.exclamationmark"
            : "exclamationmark.shield.fill"
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        buttonConfiguration?.image = UIImage(
            systemName: symbol,
            withConfiguration: symbolConfiguration
        ) ?? UIImage(
            systemName: authenticationExpired ? "person.crop.circle.badge.xmark" : "shield.fill",
            withConfiguration: symbolConfiguration
        )
        configuration = buttonConfiguration

        var actions: [UIMenuElement] = []
        if authenticationExpired {
            actions.append(UIAction(
                title: String(localized: "auth.expired.relogin"),
                image: UIImage(systemName: "person.crop.circle.badge.checkmark")
            ) { [weak self] _ in
                self?.perform(.relogin)
            })
        }
        if !reasons.isEmpty {
            actions.append(UIAction(
                title: String(localized: "cloudflare.challenge.open"),
                image: UIImage(systemName: "shield.lefthalf.filled")
            ) { [weak self] _ in
                self?.perform(.openChallenge)
            })
        }
        if reasons.contains(.readTiming) {
            actions.append(UIAction(
                title: String(localized: "cloudflare.challenge.disable_read_timing"),
                image: UIImage(systemName: "clock.badge.xmark"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.perform(.disableReporting)
            })
        }
        if hasGeneralRequest {
            actions.append(UIAction(
                title: String(localized: "cloudflare.challenge.ignore"),
                image: UIImage(systemName: "eye.slash")
            ) { [weak self] _ in
                self?.perform(.ignoreGeneralRequest)
            })
        }
        if authenticationExpired {
            actions.append(UIAction(
                title: String(localized: "auth.expired.ignore"),
                image: UIImage(systemName: "eye.slash")
            ) { [weak self] _ in
                self?.perform(.ignoreAuthentication)
            })
        }
        menu = UIMenu(title: title, options: .displayInline, children: actions)
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

/// Shared behavior for every screen capable of hosting the challenge shield.
/// View controllers only supply their active base URL and movement bounds.
final class CloudflareChallengeIndicatorHost {
    private let coordinator: CloudflareChallengeCoordinator
    private let authenticationExpiryCoordinator: AuthenticationExpiryCoordinator?
    private let baseURLProvider: () -> String?
    private let presenterProvider: () -> UIViewController?
    private let onRelogin: (() -> Void)?
    private var stateObserver: (any NSObjectProtocol)?
    private var authenticationObserver: (any NSObjectProtocol)?

    private(set) lazy var indicator = CloudflareChallengeIndicatorView {
        [weak self] action in
        self?.handle(action)
    }

    init(
        coordinator: CloudflareChallengeCoordinator = .shared,
        authenticationExpiryCoordinator: AuthenticationExpiryCoordinator? = nil,
        baseURLProvider: @escaping () -> String?,
        presenterProvider: @escaping () -> UIViewController?,
        onRelogin: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.authenticationExpiryCoordinator = authenticationExpiryCoordinator
        self.baseURLProvider = baseURLProvider
        self.presenterProvider = presenterProvider
        self.onRelogin = onRelogin
        stateObserver = NotificationCenter.default.addObserver(
            forName: .cloudflareChallengeStateDidChange,
            object: coordinator,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh(animated: true)
            }
        }
        if let authenticationExpiryCoordinator {
            authenticationObserver = NotificationCenter.default.addObserver(
                forName: .authenticationExpiryStateDidChange,
                object: authenticationExpiryCoordinator,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh(animated: true)
                }
            }
        }
    }

    deinit {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
        if let authenticationObserver {
            NotificationCenter.default.removeObserver(authenticationObserver)
        }
    }

    func install(in view: UIView) {
        guard indicator.superview !== view else { return }
        indicator.removeFromSuperview()
        view.addSubview(indicator)
        refresh(animated: false)
    }

    func refresh(animated: Bool) {
        let reasons = baseURLProvider().map { coordinator.reasons(for: $0) } ?? []
        let authenticationExpired = baseURLProvider().map {
            authenticationExpiryCoordinator?.isPending(for: $0) ?? false
        } ?? false
        indicator.configure(
            reasons: reasons,
            authenticationExpired: authenticationExpired
        )
        indicator.configureTheme()
        indicator.setPresented(!reasons.isEmpty || authenticationExpired, animated: animated)
    }

    func updatePlacement(in availableBounds: CGRect) {
        indicator.updatePlacement(in: availableBounds)
    }

    private func handle(_ action: CloudflareChallengeIndicatorView.Action) {
        guard let baseURL = baseURLProvider() else { return }
        switch action {
        case .relogin:
            DispatchQueue.main.async { [weak self] in
                self?.onRelogin?()
            }

        case .ignoreAuthentication:
            authenticationExpiryCoordinator?.clear(for: baseURL)

        case .openChallenge:
            guard coordinator.requiresVerification(for: baseURL) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let presenter = self.presenterProvider(),
                      presenter.presentedViewController == nil
                else { return }
                let coordinator = self.coordinator
                ChallengeViewController.present(from: presenter) { result in
                    guard result == .completed else { return }
                    coordinator.clearAll(for: baseURL)
                }
            }

        case .disableReporting:
            AppSettings.shared.linuxDoReadTimingsEnabled = false
            coordinator.clear(.readTiming, for: baseURL)

        case .ignoreGeneralRequest:
            coordinator.clear(.generalRequest, for: baseURL)
        }
    }
}
