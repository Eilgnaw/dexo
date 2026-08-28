import UIKit

final class ForumTabBarController: UITabBarController, UITabBarControllerDelegate {
    override var childForStatusBarStyle: UIViewController? { selectedViewController }

    private let api: DiscourseAPI
    private weak var authGate: AuthGating?
    private(set) var navigationControllers: [UINavigationController] = []
    var notificationPoller: NotificationPoller?

    init(api: DiscourseAPI, authGate: AuthGating? = nil) {
        self.api = api
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

        let homeVC = HomeViewController(api: api, authGate: authGate)
        let homeNav = ForumNavigationController(rootViewController: homeVC)
        homeNav.tabBarItem = UITabBarItem(title: String(localized: "tab.home"), image: UIImage(systemName: "house"), tag: 0)

        let meVC = MeViewController(api: api, authGate: authGate)
        let meNav = ForumNavigationController(rootViewController: meVC)
        meNav.tabBarItem = UITabBarItem(title: String(localized: "tab.me"), image: UIImage(systemName: "person"), tag: 1)

        let searchVC = SearchViewController(api: api)
        let searchNav = ForumNavigationController(rootViewController: searchVC)
        searchNav.tabBarItem = UITabBarItem(title: String(localized: "search.title"), image: UIImage(systemName: "magnifyingglass"), tag: 2)

        navigationControllers = [homeNav, meNav, searchNav]

        if #available(iOS 18.0, *) {
            let homeTab = UITab(title: String(localized: "tab.home"), image: UIImage(systemName: "house"), identifier: "home") { _ in homeNav }
            let meTab = UITab(title: String(localized: "tab.me"), image: UIImage(systemName: "person"), identifier: "me") { _ in meNav }
            let searchTab = UISearchTab { _ in searchNav }
            self.tabs = [homeTab, meTab, searchTab]
            if traitCollection.userInterfaceIdiom == .pad {
                self.mode = .tabSidebar
            }
        } else {
            viewControllers = [homeNav, meNav, searchNav]
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

    /// Returns `true` if the re-tap was handled (home tab at root).
    private func handleHomeTabReTap() -> Bool {
        guard let homeNav = navigationControllers.first,
              homeNav == selectedViewController,
              homeNav.viewControllers.count == 1,
              let homeVC = homeNav.viewControllers.first as? HomeViewController
        else { return false }

        homeVC.scrollToTopOrRefresh()
        return true
    }
}

/// Profile status bars follow the contrast of their image or accent header.
/// Pushed screens still supply their own (normally default) status-bar style.
private final class ForumNavigationController: UINavigationController {
    override var childForStatusBarStyle: UIViewController? { topViewController }
}
