import UIKit
import CookedHTML

/// Modal that presents a `.table` block at full landscape width. Triggered by
/// the expand button overlaid on the inline table by `TableRenderer`.
final class TableFullscreenViewController: UIViewController {
    private let block: ContentBlock
    private let baseConfig: NativeRenderConfig
    private weak var delegate: PostCellDelegate?
    private var renderedTable: UIView?
    private var lastRenderedWidth: CGFloat = 0
    /// Strong reference so the custom transition stays alive for present + dismiss.
    private let expandTransition: TableExpandTransitionController

    init(block: ContentBlock, baseConfig: NativeRenderConfig, delegate: PostCellDelegate?, sourceView: UIView?) {
        self.block = block
        self.baseConfig = baseConfig
        self.delegate = delegate
        self.expandTransition = TableExpandTransitionController(sourceView: sourceView)
        super.init(nibName: nil, bundle: nil)
        // `.overFullScreen` keeps the presenting VC's view in the hierarchy.
        // With `.fullScreen` iOS tears it down on present and rebuilds it on
        // dismiss — the rebuild flashes a black frame before the post detail
        // is ready. `.overFullScreen` avoids that gap.
        modalPresentationStyle = .overFullScreen
        transitioningDelegate = expandTransition
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The app is otherwise portrait-only (see `MainTabBarController`). This VC
    // opts into landscape so iOS rotates the screen on present + restores on
    // dismiss. `Project.swift` has to advertise landscape support on iPhone
    // for the request to be honored.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyTheme()

        let closeButton = UIButton(type: .close)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        }, for: .touchUpInside)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: ThemeManager.themeDidChangeNotification,
            object: nil
        )
    }

    @objc private func themeDidChange() {
        applyTheme()
    }

    private func applyTheme() {
        view.backgroundColor = ThemeManager.shared.backgroundColor
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // `supportedInterfaceOrientations` alone won't make iOS rotate an
        // already-presented portrait app — these explicit calls request the
        // geometry update. Required on iOS 16+, harmless on real devices,
        // and necessary for the simulator (which doesn't auto-rotate via
        // accelerometer).
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            if let scene = view.window?.windowScene {
                let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscapeRight)
                scene.requestGeometryUpdate(prefs) { _ in }
            }
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let availableWidth = view.safeAreaLayoutGuide.layoutFrame.width - tableHorizontalInset * 2
        guard availableWidth > 0 else { return }
        // Only re-render if width meaningfully changed — `viewDidLayoutSubviews`
        // fires on every keyboard/inset tweak too. ~1pt tolerance is enough.
        if abs(availableWidth - lastRenderedWidth) < 1 { return }
        renderTable(at: availableWidth)
        lastRenderedWidth = availableWidth
    }

    private func renderTable(at width: CGFloat) {
        renderedTable?.removeFromSuperview()

        let config = NativeRenderConfig(
            baseFont: baseConfig.baseFont,
            baseColor: baseConfig.baseColor,
            linkColor: baseConfig.linkColor,
            codeFont: baseConfig.codeFont,
            codeBackgroundColor: baseConfig.codeBackgroundColor,
            contentWidth: width,
            baseURL: baseConfig.baseURL
        )

        guard let tableView = TableRenderer.renderBare(block, config: config, delegate: delegate) else {
            return
        }

        // Outer vertical scroll so a tall table can scroll up/down. The inner
        // `tableView` (returned by `TableRenderer.renderBare`) is itself a
        // horizontal scroll view; its height is pinned to its bordered
        // container's intrinsic height, which feeds the outer scroll's
        // `contentSize.height` and triggers vertical scrolling when the table
        // exceeds the screen.
        let verticalScroll = UIScrollView()
        verticalScroll.translatesAutoresizingMaskIntoConstraints = false
        verticalScroll.alwaysBounceVertical = true
        verticalScroll.showsHorizontalScrollIndicator = false
        verticalScroll.contentInsetAdjustmentBehavior = .never
        tableView.translatesAutoresizingMaskIntoConstraints = false
        verticalScroll.addSubview(tableView)
        view.addSubview(verticalScroll)

        NSLayoutConstraint.activate([
            verticalScroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: closeButtonClearance),
            verticalScroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: tableHorizontalInset),
            verticalScroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -tableHorizontalInset),
            verticalScroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -tableHorizontalInset),

            tableView.topAnchor.constraint(equalTo: verticalScroll.contentLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: verticalScroll.contentLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: verticalScroll.contentLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: verticalScroll.contentLayoutGuide.bottomAnchor),
            // Lock the inner table's outer width to the visible scroll width
            // so the outer view scrolls vertically only — the inner scroll
            // still handles any horizontal overflow inside the table.
            tableView.widthAnchor.constraint(equalTo: verticalScroll.frameLayoutGuide.widthAnchor),
        ])
        renderedTable = verticalScroll
    }

    private let tableHorizontalInset: CGFloat = 16
    /// Leaves room above the table for the floating close button.
    private let closeButtonClearance: CGFloat = 56
}

// MARK: - Hero Zoom Transition

/// Drives a "snapshot zoom" present/dismiss for `TableFullscreenViewController`:
/// instead of the default modal slide, the inline table appears to enlarge
/// into the landscape fullscreen view (and shrink back on dismiss).
final class TableExpandTransitionController: NSObject, UIViewControllerTransitioningDelegate {
    private weak var sourceView: UIView?

    init(sourceView: UIView?) {
        self.sourceView = sourceView
        super.init()
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        TableExpandAnimator(isPresenting: true, sourceView: sourceView)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        TableExpandAnimator(isPresenting: false, sourceView: sourceView)
    }
}

private final class TableExpandAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool
    private weak var sourceView: UIView?

    init(isPresenting: Bool, sourceView: UIView?) {
        self.isPresenting = isPresenting
        self.sourceView = sourceView
        super.init()
    }

    private static let presentDuration: TimeInterval = 0.28
    private static let dismissDuration: TimeInterval = 0.2
    private static let presentStartScale: CGFloat = 0.75

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        isPresenting ? Self.presentDuration : Self.dismissDuration
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        if isPresenting {
            animatePresent(using: context)
        } else {
            animateDismiss(using: context)
        }
    }

    // MARK: - Present
    //
    // Scale-up + fade from the screen center. iOS's orientation change runs
    // alongside; the combined motion reads as "the table grows into landscape".

    private func animatePresent(using context: UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let toView = context.view(forKey: .to) else {
            context.completeTransition(false)
            return
        }

        toView.frame = container.bounds
        container.addSubview(toView)

        toView.transform = CGAffineTransform(scaleX: Self.presentStartScale, y: Self.presentStartScale)
        toView.alpha = 0

        UIView.animate(
            withDuration: Self.presentDuration,
            delay: 0,
            options: [.curveEaseOut]
        ) {
            toView.transform = .identity
            toView.alpha = 1
        } completion: { _ in
            context.completeTransition(!context.transitionWasCancelled)
        }
    }

    // MARK: - Dismiss
    //
    // Just a fast fade — no scale reverse. The user asked for the close not to
    // include rotation theatrics; a quick alpha drop hands the screen off to
    // iOS's own (unavoidable) rotation animation with minimal extra motion.

    private func animateDismiss(using context: UIViewControllerContextTransitioning) {
        guard let fromView = context.view(forKey: .from) else {
            context.completeTransition(false)
            return
        }

        UIView.animate(
            withDuration: Self.dismissDuration,
            delay: 0,
            options: [.curveEaseIn]
        ) {
            fromView.alpha = 0
        } completion: { _ in
            context.completeTransition(!context.transitionWasCancelled)
        }
    }
}
