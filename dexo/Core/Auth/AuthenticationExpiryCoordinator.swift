import Foundation

/// A forum-scoped, actionable reminder that a previously saved login was
/// rejected. The credential itself is removed by AuthManager; only the forum
/// URL is persisted here so the reminder survives an app restart.
final class AuthenticationExpiryCoordinator {
    static let shared = AuthenticationExpiryCoordinator()

    private static let storageKey = "authenticationExpiredForumURLs"
    private let defaults: UserDefaults
    private var pendingURLs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pendingURLs = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    func isPending(for baseURL: String) -> Bool {
        pendingURLs.contains(Self.normalizedURL(baseURL))
    }

    @discardableResult
    func report(for baseURL: String) -> Bool {
        let url = Self.normalizedURL(baseURL)
        guard pendingURLs.insert(url).inserted else { return false }
        persistAndNotify(url)
        return true
    }

    func clear(for baseURL: String) {
        let url = Self.normalizedURL(baseURL)
        guard pendingURLs.remove(url) != nil else { return }
        persistAndNotify(url)
    }

    private func persistAndNotify(_ url: String) {
        defaults.set(pendingURLs.sorted(), forKey: Self.storageKey)
        NotificationCenter.default.post(
            name: .authenticationExpiryStateDidChange,
            object: self,
            userInfo: ["baseURL": url]
        )
    }

    private static func normalizedURL(_ baseURL: String) -> String {
        baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

extension Notification.Name {
    static let authenticationExpiryStateDidChange = Notification.Name(
        "authenticationExpiryStateDidChange"
    )
}
