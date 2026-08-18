import Foundation
import UIKit
import UserNotifications

@MainActor
final class PushDeepLinkCoordinator {
    static let shared = PushDeepLinkCoordinator()

    private struct Destination {
        let forumBaseURL: String
        let relativeURL: String
        let notificationIdentifier: String
        let threadIdentifier: String
    }

    private weak var window: UIWindow?
    private var pendingDestination: Destination?

    private init() {}

    func activate(window: UIWindow) {
        self.window = window
        openPendingDestinationIfPossible()
    }

    func receive(response: UNNotificationResponse) {
        let notification = response.notification
        let content = notification.request.content
        let userInfo = content.userInfo
        guard let forumBaseURL = userInfo["dexo_forum_base_url"] as? String,
              let relativeURL = userInfo["dexo_relative_url"] as? String else { return }
        pendingDestination = Destination(
            forumBaseURL: forumBaseURL,
            relativeURL: relativeURL,
            notificationIdentifier: notification.request.identifier,
            threadIdentifier: content.threadIdentifier
        )
        openPendingDestinationIfPossible()
    }

    private func openPendingDestinationIfPossible() {
        guard let destination = pendingDestination, let window else { return }
        guard let forums = try? DatabaseManager.shared.fetchAllForums(),
              let forum = forums.first(where: {
                Self.normalized($0.baseURL) == Self.normalized(destination.forumBaseURL)
              }) else {
            pendingDestination = nil
            presentNavigationError(message: String(localized: "push.navigation.forum_unavailable"))
            return
        }
        guard let container = ForumOverlayManager.shared.present(forum: forum, in: window) else {
            pendingDestination = nil
            presentNavigationError(message: String(localized: "push.navigation.forum_unavailable"))
            return
        }
        AppSettings.shared.lastOpenedForumId = forum.id
        let accepted = container.openPushNotification(
            relativeURL: destination.relativeURL
        ) { [weak self] in
            self?.clearDeliveredNotifications(matching: destination)
        }
        pendingDestination = nil
        if !accepted {
            presentNavigationError(message: String(localized: "push.navigation.destination_unavailable"))
        }
    }

    private func clearDeliveredNotifications(matching destination: Destination) {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let identifiers = notifications.compactMap { notification -> String? in
                let request = notification.request
                if request.identifier == destination.notificationIdentifier {
                    return request.identifier
                }
                guard !destination.threadIdentifier.isEmpty,
                      request.content.threadIdentifier == destination.threadIdentifier,
                      let forumBaseURL = request.content.userInfo["dexo_forum_base_url"] as? String,
                      Self.normalized(forumBaseURL) == Self.normalized(destination.forumBaseURL)
                else { return nil }
                return request.identifier
            }
            if !identifiers.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(
                    withIdentifiers: identifiers
                )
            }
            if notifications.count == identifiers.count {
                Task { @MainActor in
                    if #available(iOS 16.0, *) {
                        try? await UNUserNotificationCenter.current().setBadgeCount(0)
                    } else {
                        UIApplication.shared.applicationIconBadgeNumber = 0
                    }
                }
            }
        }
    }

    private func presentNavigationError(message: String) {
        guard let window,
              let root = ForumOverlayManager.shared.currentContainer ?? window.rootViewController,
              let presenter = topViewController(from: root),
              presenter.presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: String(localized: "push.navigation.error.title"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
        presenter.present(alert, animated: true)
    }

    private func topViewController(from root: UIViewController) -> UIViewController? {
        if let presented = root.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = root as? UINavigationController {
            guard let visible = navigation.visibleViewController else { return navigation }
            return topViewController(from: visible)
        }
        if let tabBar = root as? UITabBarController {
            guard let selected = tabBar.selectedViewController else { return tabBar }
            return topViewController(from: selected)
        }
        return root
    }

    private nonisolated static func normalized(_ value: String) -> String? {
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host != nil else { return nil }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string
    }
}
