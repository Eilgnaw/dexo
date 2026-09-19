import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        let window = FeedbackWindow(windowScene: windowScene)
        window.rootViewController = MainTabBarController()
        window.overrideUserInterfaceStyle = AppSettings.shared.appearanceMode.userInterfaceStyle
        ThemeManager.shared.apply(to: window)
        window.backgroundColor = ThemeManager.shared.backgroundColor
        self.window = window

        let notificationOwnsLaunch = PushDeepLinkCoordinator.shared.activate(
            window: window,
            launchResponse: connectionOptions.notificationResponse
        )
        let launch = ForumLaunchCoordinator(database: .shared, settings: .shared)
        if let forum = try? launch.startupForum(hasPendingNotification: notificationOwnsLaunch) {
            // Keep the list window hidden until the user minimizes the forum.
            if ForumOverlayManager.shared.present(forum: forum, in: window, animated: false) == nil {
                window.makeKeyAndVisible()
            }
        } else if !notificationOwnsLaunch {
            window.makeKeyAndVisible()
        }

        #if DEBUG
        FPSOverlay.shared.install(on: windowScene)
        #endif
    }

    func sceneDidDisconnect(_ scene: UIScene) {}
    func windowScene(
        _ windowScene: UIWindowScene,
        didUpdate previousCoordinateSpace: UICoordinateSpace,
        interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
        traitCollection previousTraitCollection: UITraitCollection
    ) {
        ForumOverlayManager.shared.updateGeometry(for: windowScene)
    }
    func sceneDidBecomeActive(_ scene: UIScene) {}
    func sceneWillResignActive(_ scene: UIScene) {}
    func sceneWillEnterForeground(_ scene: UIScene) {
//        ProxyManager.shared.start()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
//        ProxyManager.shared.stop()
    }
}
