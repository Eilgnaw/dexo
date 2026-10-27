#if DEBUG
import UIKit
import WebKit

/// Debug-only browser used to verify that WKWebView traffic traverses the
/// in-process HTTP CONNECT proxy independently of the DoH switch.
final class WebViewProxyTestViewController: BaseViewController {
    private enum SetupError: Error {
        case unsupportedOS
        case proxyUnavailable
    }

    private var webView: WKWebView?
    private var proxyLease: AnyObject?
    private var setupTask: Task<Void, Never>?
    private var progressObservation: NSKeyValueObservation?
    private var trustEvaluator: WebViewProxyTrustEvaluator?

    private let addressBar = UIView()

    private lazy var addressField: UITextField = {
        let textField = UITextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.borderStyle = .roundedRect
        textField.clearButtonMode = .whileEditing
        textField.keyboardType = .URL
        textField.returnKeyType = .go
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.placeholder = String(localized: "settings.debug.webview_proxy_test.address_placeholder")
        textField.text = "https://baidu.com/"
        textField.addTarget(self, action: #selector(openEnteredAddress), for: .editingDidEndOnExit)
        return textField
    }()

    private lazy var openButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "action.open")
        configuration.cornerStyle = .medium

        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isEnabled = false
        button.addTarget(self, action: #selector(openEnteredAddress), for: .touchUpInside)
        return button
    }()

    private let progressView: UIProgressView = {
        let progressView = UIProgressView(progressViewStyle: .bar)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.isHidden = true
        return progressView
    }()

    private let loadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        return indicator
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.debug.webview_proxy_test")

        addressBar.translatesAutoresizingMaskIntoConstraints = false
        addressBar.addSubview(addressField)
        addressBar.addSubview(openButton)
        view.addSubview(addressBar)
        view.addSubview(progressView)
        view.addSubview(loadingIndicator)

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            addressBar.topAnchor.constraint(equalTo: safeArea.topAnchor),
            addressBar.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            addressBar.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),

            addressField.topAnchor.constraint(equalTo: addressBar.topAnchor, constant: 8),
            addressField.bottomAnchor.constraint(equalTo: addressBar.bottomAnchor, constant: -8),
            addressField.leadingAnchor.constraint(equalTo: addressBar.leadingAnchor, constant: 12),
            addressField.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -8),

            openButton.trailingAnchor.constraint(equalTo: addressBar.trailingAnchor, constant: -12),
            openButton.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),

            progressView.topAnchor.constraint(equalTo: addressBar.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor),
        ])

        loadingIndicator.startAnimating()
        setupTask = Task { [weak self] in
            await self?.setUpWebView()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent {
            setupTask?.cancel()
            webView?.stopLoading()
        }
    }

    override func applyThemeBackground() {
        super.applyThemeBackground()
        let theme = ThemeManager.shared
        addressBar.backgroundColor = theme.cardBackgroundColor
        addressField.backgroundColor = theme.codeBackgroundColor
        openButton.configuration?.baseBackgroundColor = theme.accentColor
        progressView.progressTintColor = theme.accentColor
        loadingIndicator.color = theme.accentColor
        webView?.backgroundColor = theme.cardBackgroundColor
        webView?.underPageBackgroundColor = theme.cardBackgroundColor
    }

    private func setUpWebView() async {
        do {
            guard #available(iOS 17.0, *) else {
                throw SetupError.unsupportedOS
            }
            let configuration = WKWebViewConfiguration()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            guard Self.normalizedURL(from: addressField.text ?? "") != nil,
                  let lease = try await WebViewDoHConfigurator.configureDebugMITM(configuration)
            else {
                throw SetupError.proxyUnavailable
            }
            guard !Task.isCancelled else { return }

            proxyLease = lease
            guard let trustEvaluator = WebViewDoHConfigurator.makeTrustEvaluator() else {
                throw SetupError.proxyUnavailable
            }
            self.trustEvaluator = trustEvaluator
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.translatesAutoresizingMaskIntoConstraints = false
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.isOpaque = false
            self.webView = webView

            view.insertSubview(webView, belowSubview: loadingIndicator)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])

            progressObservation = webView.observe(\.estimatedProgress, options: .new) { [weak self] webView, _ in
                let progress = Float(webView.estimatedProgress)
                self?.progressView.setProgress(progress, animated: true)
                self?.progressView.isHidden = progress >= 1
            }

            loadingIndicator.stopAnimating()
            openButton.isEnabled = true
            applyThemeBackground()
            openEnteredAddress()
        } catch {
            guard !Task.isCancelled else { return }
            loadingIndicator.stopAnimating()
            showSetupError(error)
        }
    }

    @objc private func openEnteredAddress() {
        guard let webView else { return }
        guard let url = Self.normalizedURL(from: addressField.text ?? "") else {
            showInvalidURLAlert()
            return
        }

        addressField.text = url.absoluteString
        addressField.resignFirstResponder()
        webView.load(URLRequest(url: url))
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
              !host.isEmpty,
              let url = components.url
        else {
            return nil
        }
        return url
    }

    private func showSetupError(_ error: Error) {
        let title: String
        let message: String
        switch error {
        case SetupError.unsupportedOS:
            title = String(localized: "settings.debug.webview_proxy_test.unsupported.title")
            message = String(localized: "settings.debug.webview_proxy_test.unsupported.message")
        default:
            title = String(localized: "doh.proxy.error.title")
            message = String(localized: "doh.proxy.error.message")
        }

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
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

    private func showLoadFailure(_ error: Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled),
              presentedViewController == nil
        else {
            return
        }

        let alert = UIAlertController(
            title: String(localized: "settings.debug.webview_proxy_test.load_failed.title"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
        present(alert, animated: true)
    }
}

extension WebViewProxyTestViewController: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if let credential = trustEvaluator?.credential(for: challenge) {
            print("[WebViewProxyTest] accepted proxy CA for \(challenge.protectionSpace.host)")
            completionHandler(.useCredential, credential)
            return
        }
        print("[WebViewProxyTest] rejected proxy CA for \(challenge.protectionSpace.host)")
        completionHandler(.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        addressField.text = webView.url?.absoluteString
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
#endif
