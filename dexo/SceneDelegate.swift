import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        let window = FeedbackWindow(windowScene: windowScene)
        window.rootViewController = MainTabBarController()
        window.overrideUserInterfaceStyle = AppSettings.shared.appearanceMode.userInterfaceStyle
        ThemeManager.shared.apply(to: window)
        window.makeKeyAndVisible()
        self.window = window
        PushDeepLinkCoordinator.shared.activate(window: window)

        #if DEBUG
        FPSOverlay.shared.install(on: windowScene)
        #endif
    }

    func sceneDidDisconnect(_ scene: UIScene) {}
    func sceneDidBecomeActive(_ scene: UIScene) {}
    func sceneWillResignActive(_ scene: UIScene) {}
    func sceneWillEnterForeground(_ scene: UIScene) {
//        ProxyManager.shared.start()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
//        ProxyManager.shared.stop()
    }
}
