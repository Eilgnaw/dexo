import UIKit

final class MainTabBarController: UITabBarController {
    private lazy var challengeIndicatorHost = CloudflareChallengeIndicatorHost(
        baseURLProvider: {
            CloudflareChallengeCoordinator.shared.primaryPendingBaseURL
        },
        presenterProvider: { [weak self] in self }
    )

    override func viewDidLoad() {
        super.viewDidLoad()

        let forumListVC = ForumListViewController()
        let forumListNav = UINavigationController(rootViewController: forumListVC)
        forumListNav.tabBarItem = UITabBarItem(title: String(localized: "tab.forums"), image: UIImage(systemName: "list.bullet"), tag: 0)

        let settingsVC = SettingsViewController()
        let settingsNav = UINavigationController(rootViewController: settingsVC)
        settingsNav.tabBarItem = UITabBarItem(title: String(localized: "tab.settings"), image: UIImage(systemName: "gearshape"), tag: 1)

        if #available(iOS 18.0, *) {
            let forumsTab = UITab(title: String(localized: "tab.forums"), image: UIImage(systemName: "list.bullet"), identifier: "forums") { _ in forumListNav }
            let settingsTab = UITab(title: String(localized: "tab.settings"), image: UIImage(systemName: "gearshape"), identifier: "settings") { _ in settingsNav }
            tabs = [forumsTab, settingsTab]
            if traitCollection.userInterfaceIdiom == .pad {
                mode = .tabSidebar
            }
        } else {
            viewControllers = [forumListNav, settingsNav]
        }

        tabBar.tintColor = ThemeManager.shared.accentColor
        challengeIndicatorHost.install(in: view)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: ThemeManager.themeDidChangeNotification,
            object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        challengeIndicatorHost.refresh(animated: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safeBounds = view.bounds.inset(by: view.safeAreaInsets)
        let horizontalBounds: CGRect
        if let selectedView = selectedViewController?.viewIfLoaded,
           selectedView.window === view.window {
            let pane = selectedView.convert(selectedView.safeAreaLayoutGuide.layoutFrame, to: view)
            let intersection = safeBounds.intersection(pane)
            horizontalBounds = intersection.isNull ? safeBounds : intersection
        } else {
            horizontalBounds = safeBounds
        }
        let tabBarFrame = tabBar.convert(tabBar.bounds, to: view)
        let bottom = tabBarFrame.minY > view.bounds.midY
            ? min(safeBounds.maxY - 72, tabBarFrame.minY - 80)
            : safeBounds.maxY - 72
        let availableBounds = bottom - safeBounds.minY >= 96
            ? CGRect(
                x: horizontalBounds.minX,
                y: safeBounds.minY,
                width: horizontalBounds.width,
                height: bottom - safeBounds.minY
            )
            : horizontalBounds
        challengeIndicatorHost.updatePlacement(in: availableBounds)
    }

    @objc private func themeDidChange() {
        tabBar.tintColor = ThemeManager.shared.accentColor
        challengeIndicatorHost.indicator.configureTheme()
    }

    // Keep the iPhone UI in portrait. iPad continues to support every
    // orientation declared by the target's Info.plist settings.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        traitCollection.userInterfaceIdiom == .pad ? .all : .portrait
    }
}
