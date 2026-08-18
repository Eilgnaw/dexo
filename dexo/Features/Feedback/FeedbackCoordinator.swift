import UIKit

@MainActor
final class FeedbackCoordinator {
    enum Presentation {
        case push
        case modal
    }

    static let shared = FeedbackCoordinator()

    private weak var promptViewController: FeedbackPromptViewController?
    private weak var feedbackViewController: FeedbackViewController?

    private init() {}

    func presentShakePrompt(in window: UIWindow) {
        guard window.windowScene?.activationState == .foregroundActive,
              promptViewController == nil,
              feedbackViewController == nil,
              let root = window.rootViewController,
              let presenter = topViewController(from: root),
              presenter.viewIfLoaded?.window != nil,
              presenter.transitionCoordinator == nil,
              !presenter.isBeingDismissed,
              !presenter.isBeingPresented,
              !(presenter is UIAlertController),
              !(presenter is FeedbackPromptViewController),
              !(presenter is FeedbackViewController) else { return }

        let prompt = FeedbackPromptViewController { [weak self, weak presenter] result in
            guard let self else { return }
            self.promptViewController = nil
            guard case .submit = result, let presenter else { return }
            self.openFeedback(from: presenter, presentation: .modal)
        }
        promptViewController = prompt
        presenter.present(prompt, animated: true)
    }

    func openFeedback(from source: UIViewController, presentation: Presentation) {
        guard feedbackViewController == nil else { return }

        do {
            let context = FeedbackURLBuilder.Context.current(
                userInterfaceStyle: source.traitCollection.userInterfaceStyle
            )
            let url = try FeedbackURLBuilder.makeURL(context: context)
            let showsCloseButton = presentation == .modal || source.navigationController == nil
            let viewController = FeedbackViewController(
                targetURL: url,
                showsCloseButton: showsCloseButton
            )
            feedbackViewController = viewController

            if presentation == .push, let navigationController = source.navigationController {
                navigationController.pushViewController(viewController, animated: true)
            } else {
                let navigationController = UINavigationController(rootViewController: viewController)
                navigationController.modalPresentationStyle = .pageSheet
                source.present(navigationController, animated: true)
            }
        } catch {
            presentUnavailableAlert(from: source)
        }
    }

    private func presentUnavailableAlert(from source: UIViewController) {
        guard source.presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: String(localized: "feedback.load_error.title"),
            message: String(localized: "feedback.load_error.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
        source.present(alert, animated: true)
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
}
