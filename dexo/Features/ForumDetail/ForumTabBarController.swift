import UIKit

final class ForumTabBarController: UITabBarController, UITabBarControllerDelegate {
    override var childForStatusBarStyle: UIViewController? { selectedViewController }

    private let api: DiscourseAPI
    private let forum: ForumInstance
    private weak var authGate: AuthGating?
    private(set) var navigationControllers: [UINavigationController] = []
    private(set) var homeSplitViewController: ForumHomeSplitViewController?
    var notificationPoller: NotificationPoller?
    var onSelectionChanged: (() -> Void)?

    init(api: DiscourseAPI, forum: ForumInstance, authGate: AuthGating? = nil) {
        self.api = api
        self.forum = forum
        self.authGate = authGate
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior = .onScrollDown
        }

        let homeRoot = ForumHomeSplitViewController(forum: forum, api: api, authGate: authGate)
        homeSplitViewController = homeRoot
        homeRoot.tabBarItem = UITabBarItem(title: String(localized: "tab.home"), image: UIImage(systemName: "house"), tag: 0)

        let meVC = MeViewController(api: api, authGate: authGate)
        let meNav = ForumNavigationController(rootViewController: meVC)
        meNav.delegate = self
        meNav.tabBarItem = UITabBarItem(title: String(localized: "tab.me"), image: UIImage(systemName: "person"), tag: 1)

        let searchVC = SearchViewController(api: api)
        let searchNav = ForumNavigationController(rootViewController: searchVC)
        searchNav.delegate = self
        searchNav.tabBarItem = UITabBarItem(title: String(localized: "search.title"), image: UIImage(systemName: "magnifyingglass"), tag: 2)

        navigationControllers = [homeRoot.topicNavigationController, meNav, searchNav]

        if #available(iOS 18.0, *) {
            let homeTab = UITab(title: String(localized: "tab.home"), image: UIImage(systemName: "house"), identifier: "home") { _ in homeRoot }
            let meTab = UITab(title: String(localized: "tab.me"), image: UIImage(systemName: "person"), identifier: "me") { _ in meNav }
            let searchTab = UISearchTab { _ in searchNav }
            self.tabs = [homeTab, meTab, searchTab]
            if traitCollection.userInterfaceIdiom == .pad {
                self.mode = .tabBar
            }
        } else {
            viewControllers = [homeRoot, meNav, searchNav]
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        syncTabBarVisibility()
    }

    func syncTabBarVisibility(
        homeShowingDetail: Bool? = nil,
        showing viewController: UIViewController? = nil,
        animated: Bool = false
    ) {
        guard isViewLoaded else { return }
        let shouldHide: Bool
        if let home = homeSplitViewController, selectedViewController === home {
            shouldHide = homeShowingDetail ?? home.hasPushedHomePage
        } else if let navigation = selectedViewController as? UINavigationController {
            let visibleController = viewController ?? navigation.topViewController
            shouldHide = visibleController !== navigation.viewControllers.first
                && visibleController?.hidesBottomBarWhenPushed == true
        } else {
            shouldHide = false
        }

        if #available(iOS 18.0, *) {
            guard isTabBarHidden != shouldHide else { return }
            setTabBarHidden(shouldHide, animated: animated)
        } else {
            // The home navigation stack sits inside the split view, so its
            // pushed controller cannot hide this tab bar by itself.
            guard tabBar.isHidden != shouldHide else { return }
            tabBar.isHidden = shouldHide
            view.setNeedsLayout()
        }
    }

    // MARK: - UITabBarControllerDelegate

    // iOS 17 and earlier (viewControllers-based tabs)
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        guard viewController == selectedViewController else { return true }
        return !handleHomeTabReTap()
    }

    // iOS 18+ (UITab-based tabs)
    @available(iOS 18.0, *)
    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        guard tab == tabBarController.selectedTab else { return true }
        return !handleHomeTabReTap()
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        syncTabBarVisibility()
        onSelectionChanged?()
    }

    @available(iOS 18.0, *)
    func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
        syncTabBarVisibility()
        onSelectionChanged?()
    }

    /// Returns `true` if the re-tap was handled (home tab at root).
    private func handleHomeTabReTap() -> Bool {
        if let split = homeSplitViewController, split === selectedViewController {
            return split.scrollToTopOrRefreshIfAtRoot()
        }
        guard let homeNav = navigationControllers.first,
              homeNav == selectedViewController,
              homeNav.viewControllers.count == 1,
              let homeVC = homeNav.viewControllers.first as? HomeViewController
        else { return false }

        homeVC.scrollToTopOrRefresh()
        return true
    }
}

extension ForumTabBarController: UINavigationControllerDelegate {
    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        guard selectedViewController === navigationController else { return }
        syncTabBarVisibility(showing: viewController, animated: animated)
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        guard selectedViewController === navigationController else { return }
        // Also reconcile the final page when an interactive pop is cancelled.
        syncTabBarVisibility(showing: viewController)
    }
}

/// Profile status bars follow the contrast of their image or accent header.
/// Pushed screens still supply their own (normally default) status-bar style.
private final class ForumNavigationController: UINavigationController {
    override var childForStatusBarStyle: UIViewController? { topViewController }
}
