#if DEBUG
import UIKit

/// Debug-only client used to verify the local MITM proxy without involving
/// WKWebView. Both the request and its TLS trust decision are owned by an
/// ordinary URLSession.
final class URLSessionProxyTestViewController: BaseViewController {
    override var backgroundStyle: BackgroundStyle { .grouped }

    private enum SetupError: Error {
        case unsupportedOS
        case proxyUnavailable
        case missingTrustEvaluator
    }

    private var proxyLease: AnyObject?
    private var setupTask: Task<Void, Never>?
    private var requestTask: URLSessionDataTask?
    private var session: URLSession?
    private var sessionDelegate: URLSessionProxyTrustDelegate?

    private lazy var addressField: UITextField = {
        let textField = UITextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.borderStyle = .none
        textField.clearButtonMode = .whileEditing
        textField.keyboardType = .URL
        textField.returnKeyType = .go
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.placeholder = String(localized: "settings.debug.urlsession_proxy_test.address_placeholder")
        textField.text = "https://baidu.com/"
        textField.addTarget(self, action: #selector(sendRequest), for: .editingDidEndOnExit)
        return textField
    }()

    private lazy var sendButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "settings.debug.urlsession_proxy_test.send")
        configuration.cornerStyle = .medium

        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isEnabled = false
        button.addTarget(self, action: #selector(sendRequest), for: .touchUpInside)
        return button
    }()

    private let addressCard: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 12
        return view
    }()

    private let statusIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = false
        return indicator
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FontManager.shared.font(size: 14, weight: .medium)
        label.numberOfLines = 2
        return label
    }()

    private let statusCard: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 12
        return view
    }()

    private let resultTextView: UITextView = {
        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.layer.cornerRadius = 12
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.text = String(localized: "settings.debug.urlsession_proxy_test.result_placeholder")
        return textView
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.debug.urlsession_proxy_test")

        addressCard.addSubview(addressField)
        addressCard.addSubview(sendButton)
        statusCard.addSubview(statusIndicator)
        statusCard.addSubview(statusLabel)
        view.addSubview(addressCard)
        view.addSubview(statusCard)
        view.addSubview(resultTextView)

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            addressCard.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 16),
            addressCard.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 16),
            addressCard.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -16),

            addressField.topAnchor.constraint(equalTo: addressCard.topAnchor, constant: 10),
            addressField.bottomAnchor.constraint(equalTo: addressCard.bottomAnchor, constant: -10),
            addressField.leadingAnchor.constraint(equalTo: addressCard.leadingAnchor, constant: 14),
            addressField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -10),

            sendButton.trailingAnchor.constraint(equalTo: addressCard.trailingAnchor, constant: -10),
            sendButton.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),

            statusCard.topAnchor.constraint(equalTo: addressCard.bottomAnchor, constant: 12),
            statusCard.leadingAnchor.constraint(equalTo: addressCard.leadingAnchor),
            statusCard.trailingAnchor.constraint(equalTo: addressCard.trailingAnchor),

            statusIndicator.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 14),
            statusIndicator.centerYAnchor.constraint(equalTo: statusCard.centerYAnchor),
            statusLabel.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 12),
            statusLabel.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -12),
            statusLabel.leadingAnchor.constraint(equalTo: statusIndicator.trailingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -14),

            resultTextView.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 12),
            resultTextView.leadingAnchor.constraint(equalTo: addressCard.leadingAnchor),
            resultTextView.trailingAnchor.constraint(equalTo: addressCard.trailingAnchor),
            resultTextView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -16),
        ])

        updateStatus(String(localized: "settings.debug.urlsession_proxy_test.starting"), isBusy: true)
        setupTask = Task { [weak self] in
            await self?.setUpSession()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isMovingFromParent else { return }
        setupTask?.cancel()
        requestTask?.cancel()
        requestTask = nil
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil
        proxyLease = nil
    }

    override func applyThemeBackground() {
        super.applyThemeBackground()
        let theme = ThemeManager.shared
        addressCard.backgroundColor = theme.cardBackgroundColor
        statusCard.backgroundColor = theme.cardBackgroundColor
        resultTextView.backgroundColor = theme.codeBackgroundColor
        sendButton.configuration?.baseBackgroundColor = theme.accentColor
        statusIndicator.color = theme.accentColor
    }

    private func setUpSession() async {
        do {
            guard #available(iOS 17.0, *) else {
                throw SetupError.unsupportedOS
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60

            guard let lease = try await WebViewDoHConfigurator.configureDebugMITM(configuration) else {
                throw SetupError.proxyUnavailable
            }
            guard !Task.isCancelled else { return }
            guard let trustEvaluator = WebViewDoHConfigurator.makeTrustEvaluator() else {
                throw SetupError.missingTrustEvaluator
            }

            let delegate = URLSessionProxyTrustDelegate(trustEvaluator: trustEvaluator)
            proxyLease = lease
            sessionDelegate = delegate
            session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            sendButton.isEnabled = true
            updateStatus(String(localized: "settings.debug.urlsession_proxy_test.ready"), isBusy: false)
        } catch {
            guard !Task.isCancelled else { return }
            updateStatus(error.localizedDescription, isBusy: false)
            showSetupError(error)
        }
    }

    @objc private func sendRequest() {
        guard let session else { return }
        guard let url = Self.normalizedURL(from: addressField.text ?? "") else {
            showInvalidURLAlert()
            return
        }

        addressField.text = url.absoluteString
        addressField.resignFirstResponder()
        requestTask?.cancel()
        resultTextView.text = String(localized: "settings.debug.urlsession_proxy_test.waiting_response")
        sendButton.isEnabled = false
        updateStatus(String(localized: "settings.debug.urlsession_proxy_test.requesting"), isBusy: true)

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Dexo-URLSession-Proxy-Test/1.0", forHTTPHeaderField: "User-Agent")
        print("[URLSessionProxyTest] GET \(url.absoluteString)")

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            Task { @MainActor in
                self.handleResponse(data: data, response: response, error: error)
            }
        }
        requestTask = task
        task.resume()
    }

    private func handleResponse(data: Data?, response: URLResponse?, error: Error?) {
        requestTask = nil
        sendButton.isEnabled = session != nil

        if let error {
            let nsError = error as NSError
            updateStatus(String(localized: "settings.debug.urlsession_proxy_test.failed"), isBusy: false)
            resultTextView.text = "Error Domain: \(nsError.domain)\nError Code: \(nsError.code)\n\n\(error.localizedDescription)"
            print("[URLSessionProxyTest] failed: \(nsError.domain) \(nsError.code) \(error.localizedDescription)")
            return
        }

        guard let response = response as? HTTPURLResponse else {
            updateStatus(String(localized: "settings.debug.urlsession_proxy_test.failed"), isBusy: false)
            resultTextView.text = String(localized: "settings.debug.urlsession_proxy_test.no_http_response")
            return
        }

        let body = data ?? Data()
        let headers = response.allHeaderFields.map {
            "\(String(describing: $0.key)): \(String(describing: $0.value))"
        }.sorted().joined(separator: "\n")
        let bodyPreview: String
        if let text = String(data: body.prefix(32_768), encoding: .utf8) {
            bodyPreview = text
        } else {
            bodyPreview = String(localized: "settings.debug.urlsession_proxy_test.binary_body")
        }

        updateStatus(
            String(
                format: String(localized: "settings.debug.urlsession_proxy_test.success_format"),
                Int64(response.statusCode),
                Int64(body.count)
            ),
            isBusy: false
        )
        resultTextView.text = "HTTP \(response.statusCode)\n\(headers)\n\n\(bodyPreview)"
        print("[URLSessionProxyTest] response \(response.statusCode), body=\(body.count) bytes")
    }

    private func updateStatus(_ text: String, isBusy: Bool) {
        statusLabel.text = text
        isBusy ? statusIndicator.startAnimating() : statusIndicator.stopAnimating()
    }

    private static func normalizedURL(from input: String) -> URL? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let lowercaseValue = value.lowercased()
        if !lowercaseValue.hasPrefix("http://") && !lowercaseValue.hasPrefix("https://") {
            guard !value.contains("://") else { return nil }
            value = "https://" + value
        }

        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else {
            return nil
        }
        return components.url
    }

    private func showSetupError(_ error: Error) {
        let message: String
        if case SetupError.unsupportedOS = error {
            message = String(localized: "settings.debug.urlsession_proxy_test.unsupported.message")
        } else {
            message = String(localized: "settings.debug.urlsession_proxy_test.setup_failed.message")
        }

        let alert = UIAlertController(
            title: String(localized: "settings.debug.urlsession_proxy_test.setup_failed.title"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
        present(alert, animated: true)
    }

    private func showInvalidURLAlert() {
        let alert = UIAlertController(
            title: String(localized: "add_forum.error.invalid_url"),
            message: String(localized: "settings.debug.webview_proxy_test.invalid_url.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
        present(alert, animated: true)
    }
}

private nonisolated final class URLSessionProxyTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let trustEvaluator: WebViewProxyTrustEvaluator

    init(trustEvaluator: WebViewProxyTrustEvaluator) {
        self.trustEvaluator = trustEvaluator
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if let credential = trustEvaluator.credential(for: challenge) {
            print("[URLSessionProxyTest] accepted proxy CA for \(challenge.protectionSpace.host)")
            completionHandler(.useCredential, credential)
        } else {
            print("[URLSessionProxyTest] rejected proxy CA for \(challenge.protectionSpace.host)")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
#endif
