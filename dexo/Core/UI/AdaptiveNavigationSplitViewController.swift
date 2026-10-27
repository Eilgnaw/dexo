import UIKit

/// A two-column navigation container that keeps one logical navigation stack
/// while moving between compact and wide layouts.
///
/// In a wide window the root controller stays in the primary column and pushes
/// from it replace the secondary column. In a compact window, UIKit combines
/// the same controllers into an ordinary push stack.
final class AdaptiveNavigationSplitViewController: UISplitViewController,
    UISplitViewControllerDelegate,
    UINavigationControllerDelegate
{
    var onPaneLayout: (() -> Void)?
    var onNavigationChange: ((_ visibleViewController: UIViewController, _ showsDetail: Bool) -> Void)?

    override var childForStatusBarStyle: UIViewController? {
        activeNavigationController
    }

    let rootViewController: UIViewController
    let primaryNavigationController = AdaptivePaneNavigationController()

    private let secondaryNavigationController = AdaptivePaneNavigationController()
    private let placeholderViewController = AdaptiveSplitPlaceholderViewController()
    private var lastPaneFrame: CGRect = .null
    private var lastNavigationFrame: CGRect = .null
    private var detailStack: [UIViewController] = []
    private var isReconcilingColumns = false
    private var isTransitioningColumns = false

    private var activeNavigationController: UINavigationController {
        if isCollapsed { return primaryNavigationController }
        return secondaryShowsDetail ? secondaryNavigationController : primaryNavigationController
    }

    private var secondaryShowsDetail: Bool {
        guard let top = secondaryNavigationController.topViewController else { return false }
        return top !== placeholderViewController
    }

    var visibleViewController: UIViewController {
        activeNavigationController.topViewController ?? rootViewController
    }

    var showsDetail: Bool {
        isCollapsed
            ? primaryNavigationController.topViewController !== rootViewController
            : secondaryShowsDetail
    }

    var isSinglePanePresentation: Bool { isCollapsed }

    init(rootViewController: UIViewController) {
        self.rootViewController = rootViewController
        super.init(style: .doubleColumn)

        // Keep the root reachable before this split controller loads so callers
        // can configure its navigation items while constructing a tab hierarchy.
        primaryNavigationController.setViewControllers([rootViewController], animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        preferredSplitBehavior = .tile
        preferredDisplayMode = .oneBesideSecondary
        displayModeButtonVisibility = .never
        primaryBackgroundStyle = .sidebar
        presentsWithGesture = false

        primaryNavigationController.delegate = self
        secondaryNavigationController.delegate = self
        secondaryNavigationController.setViewControllers([placeholderViewController], animated: false)
        setViewController(primaryNavigationController, for: .primary)
        setViewController(secondaryNavigationController, for: .secondary)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateTheme),
            name: ThemeManager.themeDidChangeNotification,
            object: nil
        )
        updateTheme()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let pane = activePaneFrame(in: view)
        let navigation = activeNavigationBarFrame(in: view)
        if pane != lastPaneFrame || navigation != lastNavigationFrame {
            lastPaneFrame = pane
            lastNavigationFrame = navigation
            onPaneLayout?()
        }
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        isTransitioningColumns = true
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            if !self.isCollapsed {
                self.reconcileExpandedColumns()
            }
            self.isTransitioningColumns = false
        }
        super.viewWillTransition(to: size, with: coordinator)
    }

    func setRootRightBarButtonItems(_ items: [UIBarButtonItem]) {
        rootViewController.navigationItem.rightBarButtonItems = items
    }

    func activeNavigationBarFrame(in coordinateView: UIView) -> CGRect {
        let bar = activeNavigationController.navigationBar
        return bar.convert(bar.bounds, to: coordinateView)
    }

    func activePaneFrame(in coordinateView: UIView) -> CGRect {
        if let pane = activeNavigationController.viewIfLoaded,
           pane.window != nil,
           pane.safeAreaLayoutGuide.layoutFrame.width > 0
        {
            return pane.convert(pane.safeAreaLayoutGuide.layoutFrame, to: coordinateView)
        }
        return view.convert(view.safeAreaLayoutGuide.layoutFrame, to: coordinateView)
    }

    func showDetailViewController(_ viewController: UIViewController, animated: Bool) {
        detailStack = [viewController]
        if isCollapsed {
            primaryNavigationController.pushViewController(viewController, animated: animated)
        } else {
            secondaryNavigationController.setViewControllers([viewController], animated: animated)
        }
        notifyNavigationChange()
    }

    private func notifyNavigationChange() {
        onNavigationChange?(visibleViewController, showsDetail)
    }

    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        let isDetail = navigationController === secondaryNavigationController
            ? viewController !== placeholderViewController
            : viewController !== rootViewController
        onNavigationChange?(viewController, isDetail)
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        if !isReconcilingColumns, !isTransitioningColumns {
            if navigationController === primaryNavigationController, isCollapsed {
                detailStack = Array(navigationController.viewControllers.dropFirst())
            } else if navigationController === secondaryNavigationController, !isCollapsed {
                detailStack = navigationController.viewControllers.filter { $0 !== placeholderViewController }
            }
        }
        notifyNavigationChange()
    }

    func splitViewController(
        _ splitViewController: UISplitViewController,
        displayModeForExpandingToProposedDisplayMode proposedDisplayMode: UISplitViewController.DisplayMode
    ) -> UISplitViewController.DisplayMode {
        .oneBesideSecondary
    }

    func splitViewController(
        _ splitViewController: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        detailStack.isEmpty ? .primary : .secondary
    }

    func splitViewController(
        _ splitViewController: UISplitViewController,
        collapseSecondary secondaryViewController: UIViewController,
        onto primaryViewController: UIViewController
    ) -> Bool {
        // The watermark is only a wide-layout empty state. Discard it instead
        // of letting UIKit add it to the compact navigation stack.
        secondaryViewController === secondaryNavigationController && detailStack.isEmpty
    }

    func splitViewControllerDidCollapse(_ splitViewController: UISplitViewController) {
        notifyNavigationChange()
        view.setNeedsLayout()
    }

    func splitViewControllerDidExpand(_ splitViewController: UISplitViewController) {
        guard !isTransitioningColumns else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCollapsed else { return }
            self.reconcileExpandedColumns()
        }
    }

    private func reconcileExpandedColumns() {
        isReconcilingColumns = true
        let details = detailStack
        primaryNavigationController.setViewControllers([rootViewController], animated: false)
        secondaryNavigationController.setViewControllers(
            details.isEmpty ? [placeholderViewController] : details,
            animated: false
        )
        isReconcilingColumns = false
        notifyNavigationChange()
        view.setNeedsLayout()
    }

    @objc private func updateTheme() {
        view.backgroundColor = ThemeManager.shared.cardBackgroundColor
        for navigation in [
            primaryNavigationController,
            secondaryNavigationController,
        ] {
            navigation.navigationBar.tintColor = ThemeManager.shared.accentColor
        }
        placeholderViewController.updateTheme()
    }
}

final class AdaptivePaneNavigationController: UINavigationController {
    override var childForStatusBarStyle: UIViewController? { topViewController }
}

extension UIViewController {
    /// Routes navigation initiated by an adaptive split's root into its detail
    /// column. Calls from detail screens remain ordinary pushes.
    func pushViewControllerAdaptively(_ viewController: UIViewController, animated: Bool) {
        var ancestor = parent
        while let current = ancestor {
            if let split = current as? AdaptiveNavigationSplitViewController,
               self === split.rootViewController
            {
                split.showDetailViewController(viewController, animated: animated)
                return
            }
            ancestor = current.parent
        }
        navigationController?.pushViewController(viewController, animated: animated)
    }
}

private final class AdaptiveSplitPlaceholderViewController: BaseViewController {
    override var backgroundStyle: BackgroundStyle { .grouped }

    private let contentView = AdaptiveSplitPlaceholderView()

    override func loadView() {
        view = contentView
    }

    func updateTheme() {
        guard isViewLoaded else { return }
        applyThemeBackground()
        contentView.updateTheme()
    }
}

private final class AdaptiveSplitPlaceholderView: UIView {
    private let watermarkView = UIView()
    private let shadowImageView = AdaptiveSplitPlaceholderView.makeImageView()
    private let highlightImageView = AdaptiveSplitPlaceholderView.makeImageView()
    private let imageView = AdaptiveSplitPlaceholderView.makeImageView()
    private var watermarkCenterX: NSLayoutConstraint!
    private var watermarkCenterY: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        watermarkView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(watermarkView)
        for imageView in [shadowImageView, highlightImageView, imageView] {
            imageView.translatesAutoresizingMaskIntoConstraints = false
            watermarkView.addSubview(imageView)
        }
        watermarkCenterX = watermarkView.centerXAnchor.constraint(equalTo: centerXAnchor)
        watermarkCenterY = watermarkView.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([
            watermarkView.widthAnchor.constraint(equalToConstant: 132),
            watermarkView.heightAnchor.constraint(equalToConstant: 132),
            watermarkCenterX,
            watermarkCenterY,

            shadowImageView.widthAnchor.constraint(equalTo: watermarkView.widthAnchor),
            shadowImageView.heightAnchor.constraint(equalTo: watermarkView.heightAnchor),
            shadowImageView.centerXAnchor.constraint(equalTo: watermarkView.centerXAnchor, constant: 2),
            shadowImageView.centerYAnchor.constraint(equalTo: watermarkView.centerYAnchor, constant: 2),

            highlightImageView.widthAnchor.constraint(equalTo: watermarkView.widthAnchor),
            highlightImageView.heightAnchor.constraint(equalTo: watermarkView.heightAnchor),
            highlightImageView.centerXAnchor.constraint(equalTo: watermarkView.centerXAnchor, constant: -1.5),
            highlightImageView.centerYAnchor.constraint(equalTo: watermarkView.centerYAnchor, constant: -1.5),

            imageView.widthAnchor.constraint(equalTo: watermarkView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: watermarkView.heightAnchor),
            imageView.centerXAnchor.constraint(equalTo: watermarkView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: watermarkView.centerYAnchor),
        ])
        updateTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateConstraints() {
        // UIKit tracks reserved regions read during constraint updates and
        // invalidates this layout when the fold becomes active or inactive.
        updateWatermarkPosition()
        super.updateConstraints()
    }

    private func updateWatermarkPosition() {
        var target = CGPoint(x: bounds.midX, y: bounds.midY)
        if #available(iOS 27.1, *),
           let division = reservedRegions(kind: .division, options: .includeInactive).first
        {
            let frame = division.frame
            if frame.height >= frame.width {
                target.x = (frame.maxX + bounds.maxX) / 2
            } else {
                target.y = (frame.maxY + bounds.maxY) / 2
            }
        }
        watermarkCenterX.constant = target.x - bounds.midX
        watermarkCenterY.constant = target.y - bounds.midY
    }

    func updateTheme() {
        shadowImageView.tintColor = .label
        shadowImageView.alpha = 0.12
        highlightImageView.tintColor = ThemeManager.shared.backgroundColor
        highlightImageView.alpha = 0.55
        imageView.tintColor = .systemGray
        imageView.alpha = 0.72
    }

    private static func makeImageView() -> UIImageView {
        let imageView = UIImageView(image: UIImage(named: "DexoMark"))
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = false
        return imageView
    }
}
