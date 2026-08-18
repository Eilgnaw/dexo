import UIKit

final class FeedbackPromptViewController: BaseViewController {
    enum Result {
        case submit
        case cancel
    }

    override var backgroundStyle: BackgroundStyle { .grouped }

    private let onFinish: (Result) -> Void
    private var hasFinished = false

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FontManager.shared.font(size: 22, weight: .semibold)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = String(localized: "feedback.prompt.title")
        return label
    }()

    private let messageLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FontManager.shared.font(size: 15)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = String(localized: "feedback.prompt.message")
        return label
    }()

    private lazy var submitButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "feedback.action.submit")
        configuration.cornerStyle = .large
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = FontManager.shared.font(size: 17, weight: .semibold)
        button.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        return button
    }()

    private lazy var cancelButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.title = String(localized: "action.cancel")
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = FontManager.shared.font(size: 17)
        button.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        return button
    }()

    init(onFinish: @escaping (Result) -> Void) {
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            messageLabel,
            submitButton,
            cancelButton,
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.setCustomSpacing(20, after: messageLabel)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            submitButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        if let sheet = sheetPresentationController {
            sheet.detents = [
                .custom(identifier: .init("feedbackPrompt")) { context in
                    min(260, context.maximumDetentValue)
                },
            ]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }
        applyThemeBackground()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
    }

    override func applyThemeBackground() {
        super.applyThemeBackground()
        guard isViewLoaded else { return }
        let theme = ThemeManager.shared
        titleLabel.textColor = .label
        messageLabel.textColor = .secondaryLabel
        submitButton.configuration?.baseBackgroundColor = theme.accentColor
        submitButton.configuration?.baseForegroundColor = .white
        cancelButton.configuration?.baseForegroundColor = theme.accentColor
    }

    @objc private func submitTapped() {
        finish(with: .submit, dismissFirst: true)
    }

    @objc private func cancelTapped() {
        finish(with: .cancel, dismissFirst: true)
    }

    private func finish(with result: Result, dismissFirst: Bool) {
        guard !hasFinished else { return }
        hasFinished = true
        if dismissFirst {
            dismiss(animated: true) { [onFinish] in
                onFinish(result)
            }
        } else {
            onFinish(result)
        }
    }
}

extension FeedbackPromptViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish(with: .cancel, dismissFirst: false)
    }
}
