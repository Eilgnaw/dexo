//
//  AppDelegate.swift
//  dexo
//
//  Created by Eilgnaw on 3/21/26.
//

import Lightbox
import SDWebImage
import SDWebImageSVGCoder
import UIKit
import UserNotifications

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    private var shouldReconcilePushSubscriptions = false
    private var authChangeObserver: NSObjectProtocol?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if !EncryptedDNSManager.shared.applyCurrentSettings() {
            AppSettings.shared.dohEnabled = false
        }

        SDImageCodersManager.shared.addCoder(SDImageSVGCoder.shared)
        SDImageCodersManager.shared.addCoder(SDImageAWebPCoder.shared)

        // One-time: clear legacy shared cache (all images now use per-type caches)
        if !UserDefaults.standard.bool(forKey: "legacyCacheCleared") {
            SDImageCache.shared.clearDisk {
                UserDefaults.standard.set(true, forKey: "legacyCacheCleared")
            }
        }

        LightboxConfig.loadImage = { imageView, url, completion in
            // Browser URLs point at the Discourse lightbox href (original
            // asset), not the inline thumbnail src. Refreshing the cache here
            // prevents an earlier low-resolution response for an equivalent
            // key from remaining on screen when the user zooms in.
            imageView.sd_setImage(
                with: url,
                placeholderImage: nil,
                options: [.retryFailed, .highPriority, .refreshCached],
                context: ImageCacheManager.shared.fullScreenContentContext,
                progress: nil
            ) { image, _, _, _ in
                completion?(image)
            }
        }
        LightboxConfig.preload = 2
        LightboxConfig.makeLoadingIndicator = {
            let indicator = UIActivityIndicatorView(style: .large)
            indicator.color = .white
            indicator.startAnimating()
            return indicator
        }
        // ImageBrowserController draws its own dot-style page indicator.
        LightboxConfig.PageIndicator.enabled = false

        do {
            try ForumLaunchCoordinator(database: .shared, settings: .shared).initializeDefaultForum()
        } catch {
            debugLog("[Launch] Default forum initialization failed: \(error)")
        }

        if let forums = try? DatabaseManager.shared.fetchAllForums() {
            for forum in forums {
                AuthManager.shared.restoreAuthState(for: forum)
            }
        }
        UNUserNotificationCenter.current().delegate = self
        authChangeObserver = NotificationCenter.default.addObserver(
            forName: .discourseAuthDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await PushSubscriptionReconciler.reconcileAll()
            }
        }
        if (try? DatabaseManager.shared.fetchAllPushSubscriptions().isEmpty) == false {
            shouldReconcilePushSubscriptions = true
            application.registerForRemoteNotifications()
        }
        Task {
            await ForumNotificationMetadataSynchronizer.syncAll()
        }

        return true
    }

    deinit {
        if let authChangeObserver {
            NotificationCenter.default.removeObserver(authChangeObserver)
        }
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        APNSTokenProvider.shared.didRegister(deviceToken: deviceToken)
        if shouldReconcilePushSubscriptions {
            shouldReconcilePushSubscriptions = false
            Task {
                await PushSubscriptionReconciler.reconcileAll()
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        APNSTokenProvider.shared.didFailToRegister(error: error)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .badge, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        PushDeepLinkCoordinator.shared.receive(response: response)
    }
}
