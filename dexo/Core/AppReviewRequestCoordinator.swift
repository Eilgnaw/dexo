import Foundation
import StoreKit
import UIKit

@MainActor
final class AppReviewRequestCoordinator {
    static let shared = AppReviewRequestCoordinator()

    private static let lastRequestedVersionKey = "appReview.lastRequestedMarketingVersion"

    private let defaults: UserDefaults
    private let marketingVersion: () -> String?
    private let requestReview: @MainActor () -> Bool

    convenience init(
        defaults: UserDefaults = .standard,
        marketingVersion: @escaping () -> String? = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        }
    ) {
        self.init(
            defaults: defaults,
            marketingVersion: marketingVersion,
            requestReview: {
                AppReviewRequestCoordinator.requestSystemReview()
            }
        )
    }

    init(
        defaults: UserDefaults,
        marketingVersion: @escaping () -> String?,
        requestReview: @escaping @MainActor () -> Bool
    ) {
        self.defaults = defaults
        self.marketingVersion = marketingVersion
        self.requestReview = requestReview
    }

    /// Requests the system review sheet after the server confirms a new like.
    /// Removing a like never triggers a request. A missing foreground scene
    /// leaves the version eligible so the next successful like can retry.
    @discardableResult
    func requestAfterLikeChange(liked: Bool) -> Bool {
        guard liked,
              let version = marketingVersion()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty,
              defaults.string(forKey: Self.lastRequestedVersionKey) != version,
              requestReview()
        else { return false }

        defaults.set(version, forKey: Self.lastRequestedVersionKey)
        return true
    }

    private static func requestSystemReview() -> Bool {
        let activeScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard let scene = activeScenes.first(where: { scene in
            scene.windows.contains(where: \.isKeyWindow)
        }) ?? activeScenes.first
        else { return false }

        if #available(iOS 16.0, *) {
            AppStore.requestReview(in: scene)
        } else {
            SKStoreReviewController.requestReview(in: scene)
        }
        return true
    }
}
