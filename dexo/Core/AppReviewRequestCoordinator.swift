import StoreKit
import UIKit

@MainActor
final class AppReviewRequestCoordinator {
    static let shared = AppReviewRequestCoordinator()

    private let requestReview: @MainActor () -> Bool

    convenience init() {
        self.init(requestReview: {
            AppReviewRequestCoordinator.requestSystemReview()
        })
    }

    init(requestReview: @escaping @MainActor () -> Bool) {
        self.requestReview = requestReview
    }

    /// Requests the system review sheet after the server confirms a new like.
    /// Removing a like never triggers a request.
    @discardableResult
    func requestAfterLikeChange(liked: Bool) -> Bool {
        guard liked else { return false }
        return requestReview()
    }

    /// Requests a review after a reply has been published successfully.
    @discardableResult
    func requestAfterPublishedReply() -> Bool {
        requestReview()
    }

    /// Requests a review after login-related prompts have finished.
    @discardableResult
    func requestAfterLogin() -> Bool {
        requestReview()
    }

    private static func requestSystemReview() -> Bool {
        let activeScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard let scene = activeScenes.first(where: { scene in
            scene.windows.contains(where: \.isKeyWindow)
        }) ?? activeScenes.first
        else { return false }

        SKStoreReviewController.requestReview(in: scene)
        return true
    }
}
