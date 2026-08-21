import UIKit

final class MainTabBarController: UITabBarController {
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: ThemeManager.themeDidChangeNotification,
            object: nil
        )
    }

    @objc private func themeDidChange() {
        tabBar.tintColor = ThemeManager.shared.accentColor
    }

    // Keep the iPhone UI in portrait. iPad continues to support every
    // orientation declared by the target's Info.plist settings.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        traitCollection.userInterfaceIdiom == .pad ? .all : .portrait
    }
}
