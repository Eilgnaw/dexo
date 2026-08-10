import UIKit

protocol TopicDetailBottomBarDelegate: AnyObject {
    func bottomBarDidTapOPOnly()
    func bottomBarDidTapJumpToFloor()
    func bottomBarDidToggleReverseOrder()
    func bottomBarDidToggleSummaryMode()
    func bottomBarDidTapReply()
    func bottomBarDidTapScrollToTop()
    /// Whether the reverse / summary modes are currently active.
    var bottomBarIsReverseOrder: Bool { get }
    var bottomBarIsSummaryMode: Bool { get }

    /// Long-press on the jump-to-floor button begins a continuous scrub gesture.
    /// The bar forwards every state change (begin/change/end) so the VC can
    /// drive the overlay floor in real time without the user ever having to
    /// lift their finger. Locations are in the window's coordinate space.
    func bottomBarDidBeginScrubFromJump(at locationInWindow: CGPoint, buttonFrame: CGRect)
    func bottomBarDidUpdateScrub(at locationInWindow: CGPoint)
    func bottomBarDidEndScrub(cancelled: Bool)
}

nonisolated enum TopicDetailBottomBarDisplayMode: Equatable, Sendable {
    case expanded
    case scrollToTop
}

/// Directional hysteresis for the bottom bar. Keeping this independent from
/// UIScrollView makes snapshot-driven offset changes and rubber-banding easy
/// to exclude from the interaction policy.
nonisolated struct TopicDetailBottomBarScrollState: Equatable, Sendable {
    static let collapseDistance: CGFloat = 24
    static let expandDistance: CGFloat = 12
    static let minimumDistanceFromTopToCollapse: CGFloat = 44
    static let topTolerance: CGFloat = 8
    static let movementEpsilon: CGFloat = 0.5

    private(set) var mode: TopicDetailBottomBarDisplayMode = .expanded
    private var downwardDistance: CGFloat = 0
    private var upwardDistance: CGFloat = 0

    mutating func beginGesture() {
        downwardDistance = 0
        upwardDistance = 0
    }

    mutating func forceExpanded() {
        mode = .expanded
        beginGesture()
    }

    @discardableResult
    mutating func update(
        delta: CGFloat,
        distanceFromTop: CGFloat,
        isUserDriven: Bool,
        isWithinScrollBounds: Bool,
        isContentScrollable: Bool
    ) -> TopicDetailBottomBarDisplayMode {
        if !isContentScrollable || distanceFromTop <= Self.topTolerance {
            forceExpanded()
            return mode
        }

        guard isUserDriven, isWithinScrollBounds, abs(delta) >= Self.movementEpsilon else {
            return mode
        }

        if delta > 0 {
            upwardDistance = 0
            downwardDistance += delta
            if downwardDistance >= Self.collapseDistance,
               distanceFromTop > Self.minimumDistanceFromTopToCollapse
            {
                mode = .scrollToTop
                downwardDistance = 0
            }
        } else {
            downwardDistance = 0
            upwardDistance += -delta
            if upwardDistance >= Self.expandDistance {
                mode = .expanded
                upwardDistance = 0
            }
        }

        return mode
    }
}

final class TopicDetailBottomBar: UIView {
    weak var delegate: TopicDetailBottomBarDelegate?

    private static let buttonSize: CGFloat = 44
    private static let buttonSpacing: CGFloat = 12
    private static let expandedWidth = buttonSize * 3 + buttonSpacing * 2
    private static let glassMergeDistance: CGFloat = 10

    private(set) var displayMode: TopicDetailBottomBarDisplayMode = .expanded
    private var modeAnimator: UIViewPropertyAnimator?
    private var glassContainerView: UIVisualEffectView?

    private(set) lazy var opOnlyButton = makeCircularButton(icon: "person", a11yLabel: String(localized: "topic.bottombar.op_only"))
    private(set) lazy var jumpToFloorButton = makeCircularButton(icon: "number", a11yLabel: String(localized: "topic.bottombar.jump_to_floor"))
    private lazy var replyButton = makeCircularButton(icon: "arrowshape.turn.up.left", a11yLabel: String(localized: "reply.title"))
    private lazy var scrollToTopButton = makeCircularButton(icon: "arrow.up", a11yLabel: String(localized: "topic.bottombar.scroll_to_top"))

    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: Self.expandedWidth)

    /// Hide the OP-filter and jump-to-floor pills when the topic is being
    /// shown as a reply tree — neither floor numbers nor the OP filter make
    /// sense once posts are reordered into a DFS view.
    var hidesFloorControls: Bool = false {
        didSet {
            guard oldValue != hidesFloorControls else { return }
            opOnlyButton.isHidden = hidesFloorControls
            jumpToFloorButton.isHidden = hidesFloorControls
            setDisplayMode(.expanded, animated: false)
            widthConstraint.constant = hidesFloorControls ? Self.buttonSize : Self.expandedWidth
            setNeedsLayout()
        }
    }

    private lazy var stackView: UIStackView = {
        let sv = UIStackView(arrangedSubviews: [opOnlyButton, jumpToFloorButton, replyButton])
        sv.axis = .horizontal
        sv.spacing = Self.buttonSpacing
        sv.alignment = .center
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear

        if #available(iOS 26.0, *) {
            // A shared glass container is what lets the three independent
            // button droplets physically merge while they converge. Keep it
            // at the expanded width so the effect is not clipped while the
            // bar's own width constraint springs down to a single button.
            let containerEffect = UIGlassContainerEffect()
            containerEffect.spacing = Self.glassMergeDistance
            let containerView = UIVisualEffectView(effect: containerEffect)
            containerView.translatesAutoresizingMaskIntoConstraints = false
            containerView.clipsToBounds = false
            containerView.contentView.clipsToBounds = false
            addSubview(containerView)
            containerView.contentView.addSubview(stackView)
            containerView.contentView.addSubview(scrollToTopButton)
            glassContainerView = containerView

            NSLayoutConstraint.activate([
                containerView.centerXAnchor.constraint(equalTo: centerXAnchor),
                containerView.centerYAnchor.constraint(equalTo: centerYAnchor),
                containerView.widthAnchor.constraint(equalToConstant: Self.expandedWidth),
                containerView.heightAnchor.constraint(equalToConstant: Self.buttonSize),
            ])
        } else {
            addSubview(stackView)
            addSubview(scrollToTopButton)
        }

        opOnlyButton.addTarget(self, action: #selector(opOnlyTapped), for: .touchUpInside)
        jumpToFloorButton.addTarget(self, action: #selector(jumpToFloorTapped), for: .touchUpInside)
        replyButton.addTarget(self, action: #selector(replyTapped), for: .touchUpInside)
        scrollToTopButton.addTarget(self, action: #selector(scrollToTopTapped), for: .touchUpInside)

        scrollToTopButton.alpha = 0
        scrollToTopButton.transform = CGAffineTransform(scaleX: 0.58, y: 0.58)
        scrollToTopButton.isUserInteractionEnabled = false
        scrollToTopButton.accessibilityElementsHidden = true

        // Long-press + drag the jump button to scrub through floors. We don't
        // require an initial movement, so the gesture begins after a short
        // hold; subsequent movement is reported via the same recognizer.
        let scrubGesture = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleScrubGesture(_:))
        )
        scrubGesture.minimumPressDuration = 0.22
        // The default `allowableMovement` (10pt) cancels the gesture if the
        // user moves before recognition — but they may rest a finger then
        // immediately drag, which is exactly the scrub flow we want.
        scrubGesture.allowableMovement = .greatestFiniteMagnitude
        jumpToFloorButton.addGestureRecognizer(scrubGesture)

        let size = Self.buttonSize
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: size),
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            scrollToTopButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            scrollToTopButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            opOnlyButton.widthAnchor.constraint(equalToConstant: size),
            opOnlyButton.heightAnchor.constraint(equalToConstant: size),
            jumpToFloorButton.widthAnchor.constraint(equalToConstant: size),
            jumpToFloorButton.heightAnchor.constraint(equalToConstant: size),
            replyButton.widthAnchor.constraint(equalToConstant: size),
            replyButton.heightAnchor.constraint(equalToConstant: size),
            scrollToTopButton.widthAnchor.constraint(equalToConstant: size),
            scrollToTopButton.heightAnchor.constraint(equalToConstant: size),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - State

    func setDisplayMode(_ mode: TopicDetailBottomBarDisplayMode, animated: Bool) {
        guard mode != displayMode || modeAnimator != nil else { return }
        displayMode = mode

        if let animator = modeAnimator {
            animator.stopAnimation(false)
            animator.finishAnimation(at: .current)
            modeAnimator = nil
        }

        let isCompact = mode == .scrollToTop
        let reducesMotion = UIAccessibility.isReduceMotionEnabled
        updateInteractionForDisplayMode(isCompact: isCompact)

        let applyTargetGeometry = { [self] in
            widthConstraint.constant = isCompact ? Self.buttonSize : Self.expandedWidth
            stackView.transform = isCompact && !reducesMotion
                ? CGAffineTransform(scaleX: 0.30, y: 0.30)
                : .identity
            opOnlyButton.transform = .identity
            jumpToFloorButton.transform = .identity
            replyButton.transform = .identity
            scrollToTopButton.transform = isCompact || reducesMotion
                ? .identity
                : CGAffineTransform(scaleX: 0.58, y: 0.58)
        }
        let applyTargetOpacity = { [self] in
            stackView.alpha = isCompact ? 0 : 1
            scrollToTopButton.alpha = isCompact ? 1 : 0
        }
        let applyAnimatedTargetState = { [self] in
            applyTargetGeometry()
            applyTargetOpacity()
            superview?.layoutIfNeeded()
        }

        guard animated, window != nil else {
            applyAnimatedTargetState()
            return
        }

        let duration: TimeInterval = reducesMotion ? 0.15 : 0.46
        let animator: UIViewPropertyAnimator
        if reducesMotion {
            applyTargetGeometry()
            superview?.layoutIfNeeded()
            animator = UIViewPropertyAnimator(duration: duration, curve: .easeInOut)
            animator.addAnimations(applyTargetOpacity)
        } else {
            let spring = UISpringTimingParameters(dampingRatio: 0.67)
            animator = UIViewPropertyAnimator(duration: duration, timingParameters: spring)
            animator.addAnimations {
                applyTargetGeometry()
                if isCompact {
                    self.stackView.alpha = 0
                } else {
                    self.scrollToTopButton.alpha = 0
                }
                self.superview?.layoutIfNeeded()
            }
            animator.addAnimations({
                if isCompact {
                    self.scrollToTopButton.alpha = 1
                } else {
                    self.stackView.alpha = 1
                }
            }, delayFactor: 0.10)
        }
        animator.addCompletion { [weak self, weak animator] _ in
            guard let self, self.modeAnimator === animator else { return }
            self.modeAnimator = nil
        }
        modeAnimator = animator
        animator.startAnimation()
    }

    private func updateInteractionForDisplayMode(isCompact: Bool) {
        [opOnlyButton, jumpToFloorButton, replyButton].forEach {
            $0.isUserInteractionEnabled = !isCompact
            $0.accessibilityElementsHidden = isCompact
        }
        scrollToTopButton.isUserInteractionEnabled = isCompact
        scrollToTopButton.accessibilityElementsHidden = !isCompact
    }

    func setOPOnlySelected(_ selected: Bool) {
        updateButtonAppearance(opOnlyButton, selected: selected)
    }

    private func updateButtonAppearance(_ button: UIButton, selected: Bool) {
        if selected {
            button.configuration?.baseForegroundColor = .white
            button.backgroundColor = .tintColor
            button.layer.sublayers?
                .filter { $0 is CAShapeLayer || ($0.name == "glassLayer") }
                .forEach { $0.isHidden = true }
            // Hide the effect view when selected
            button.subviews.compactMap { $0 as? UIVisualEffectView }.forEach { $0.isHidden = true }
        } else {
            button.configuration?.baseForegroundColor = .label
            button.backgroundColor = .clear
            button.subviews.compactMap { $0 as? UIVisualEffectView }.forEach { $0.isHidden = false }
        }
    }

    // MARK: - Factory

    private func makeCircularButton(icon: String, a11yLabel: String) -> UIButton {
        let size = Self.buttonSize
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: icon)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        config.baseForegroundColor = .label
        config.background.backgroundColor = .clear

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer.cornerRadius = size / 2
        button.clipsToBounds = false
        button.accessibilityLabel = a11yLabel

        if #available(iOS 26.0, *) {
            // Use an explicit UIGlassEffect rather than Configuration.glass().
            // The container can then identify and morph every droplet as the
            // button frames approach one another.
            addGlassBackground(to: button, size: size)
        } else {
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOpacity = 0.12
            button.layer.shadowOffset = CGSize(width: 0, height: 2)
            button.layer.shadowRadius = 4
            addGlassBackground(to: button, size: size)
        }

        return button
    }

    private func addGlassBackground(to button: UIButton, size: CGFloat) {
        if #available(iOS 26, *) {
            let glassEffect = UIGlassEffect()
            glassEffect.isInteractive = true
            let glassView = UIVisualEffectView(effect: glassEffect)
            glassView.translatesAutoresizingMaskIntoConstraints = false
            glassView.layer.cornerRadius = size / 2
            glassView.clipsToBounds = true
            glassView.isUserInteractionEnabled = false
            button.insertSubview(glassView, at: 0)

            NSLayoutConstraint.activate([
                glassView.topAnchor.constraint(equalTo: button.topAnchor),
                glassView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                glassView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                glassView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        } else {
            let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            effectView.translatesAutoresizingMaskIntoConstraints = false
            effectView.layer.cornerRadius = size / 2
            effectView.clipsToBounds = true
            effectView.isUserInteractionEnabled = false
            button.insertSubview(effectView, at: 0)
            NSLayoutConstraint.activate([
                effectView.topAnchor.constraint(equalTo: button.topAnchor),
                effectView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                effectView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                effectView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }
    }

    // MARK: - Actions

    @objc private func opOnlyTapped() {
        delegate?.bottomBarDidTapOPOnly()
    }

    @objc private func jumpToFloorTapped() {
        delegate?.bottomBarDidTapJumpToFloor()
    }

    /// No-op since the long-press menu was replaced by the scrubber gesture;
    /// retained as a hook for callers that still ping it after mode toggles.
    func refreshJumpMenu() {}

    @objc private func replyTapped() {
        delegate?.bottomBarDidTapReply()
    }

    @objc private func scrollToTopTapped() {
        delegate?.bottomBarDidTapScrollToTop()
    }

    @objc private func handleScrubGesture(_ gesture: UILongPressGestureRecognizer) {
        let locationInWindow = gesture.location(in: nil)
        switch gesture.state {
        case .began:
            delegate?.bottomBarDidBeginScrubFromJump(
                at: locationInWindow,
                buttonFrame: jumpToFloorButton.convert(jumpToFloorButton.bounds, to: self)
            )
        case .changed:
            delegate?.bottomBarDidUpdateScrub(at: locationInWindow)
        case .ended:
            delegate?.bottomBarDidEndScrub(cancelled: false)
        case .cancelled, .failed:
            delegate?.bottomBarDidEndScrub(cancelled: true)
        default:
            break
        }
    }
}
