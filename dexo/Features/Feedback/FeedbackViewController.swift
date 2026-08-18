import UIKit
import WebKit

final class FeedbackViewController: BaseViewController {
    private struct WebThemePalette {
        let brand: String
        let page: String
        let surface: String
        let raised: String
        let ink: String
        let inkMuted: String
        let inkSubtle: String
        let line: String
        let isDark: Bool

        var javaScript: String {
            let properties = [
                "--brand": brand,
                "--c-page": page,
                "--c-surface": surface,
                "--c-raised": raised,
                "--c-ink": ink,
                "--c-ink-muted": inkMuted,
                "--c-ink-subtle": inkSubtle,
                "--c-line": line,
                "--c-info": brand,
                "--tw-ring-offset-color": surface,
            ]
            let assignments = properties
                .map { "root.style.setProperty('\($0.key)', '#\($0.value)', 'important');" }
                .joined()
            let declarations = properties
                .map { "\($0.key):#\($0.value)!important;" }
                .joined()
            return """
            (function() {
              var root = document.documentElement;
              if (!root) { return; }
              \(assignments)
              var style = document.getElementById('dexo-feedback-theme');
              if (!style) {
                style = document.createElement('style');
                style.id = 'dexo-feedback-theme';
                root.appendChild(style);
              }
              style.textContent = ':root{\(declarations)}';
              root.style.colorScheme = '\(isDark ? "dark" : "light")';
              root.classList.toggle('dark', \(isDark ? "true" : "false"));
              var meta = document.querySelector('meta[name="theme-color"]');
              if (meta) { meta.setAttribute('content', '#\(surface)'); }
            })();
            """
        }
    }

    private let targetURL: URL
    private let showsCloseButton: Bool

    private var webView: WKWebView?
    private var progressObservation: NSKeyValueObservation?

    private let progressView: UIProgressView = {
        let progressView = UIProgressView(progressViewStyle: .bar)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.isHidden = true
        return progressView
    }()

    private let errorLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 15)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = String(localized: "feedback.load_error.message")
        return label
    }()

    private lazy var retryButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "action.retry")
        configuration.cornerStyle = .large
        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = FontManager.shared.font(size: 17, weight: .semibold)
        button.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        return button
    }()

    private lazy var errorStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [errorLabel, retryButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.isHidden = true
        return stack
    }()

    init(targetURL: URL, showsCloseButton: Bool) {
        self.targetURL = targetURL
        self.showsCloseButton = showsCloseButton
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "feedback.title")

        if showsCloseButton {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(closeTapped)
            )
        }

        view.addSubview(errorStack)
        view.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            errorStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            retryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])

        applyThemeBackground()
        startWebViewSetup()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent
            || isBeingDismissed
            || navigationController?.isBeingDismissed == true {
            tearDownWebView()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        applyThemeBackground()
    }

    override func applyThemeBackground() {
        guard isViewLoaded else { return }
        let theme = ThemeManager.shared
        view.backgroundColor = theme.cardBackgroundColor
        progressView.progressTintColor = theme.accentColor
        errorLabel.textColor = .secondaryLabel
        retryButton.configuration?.baseBackgroundColor = theme.accentColor
        retryButton.configuration?.baseForegroundColor = .white
        webView?.backgroundColor = theme.cardBackgroundColor
        webView?.scrollView.backgroundColor = theme.backgroundColor
        webView?.evaluateJavaScript(makeWebThemePalette().javaScript)
    }

    private func startWebViewSetup() {
        hideError()
        progressView.progress = 0
        progressView.isHidden = false
        setUpWebView()
    }

    private func setUpWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Feedback is an independent first-party service and must not inherit the
        // forum WebViews' shared DoH proxy configuration. A dedicated ephemeral
        // data store keeps this WebView on the system network path even while the
        // app's DoH switch is enabled.
        let dataStore = WKWebsiteDataStore.nonPersistent()
        if #available(iOS 17.0, *) {
            dataStore.proxyConfigurations = []
        }
        configuration.websiteDataStore = dataStore
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: makeWebThemePalette().javaScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        self.webView?.removeFromSuperview()
        self.webView = webView

        view.insertSubview(webView, belowSubview: progressView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: .new) { [weak self] webView, _ in
            self?.progressView.progress = Float(webView.estimatedProgress)
            self?.progressView.isHidden = webView.estimatedProgress >= 1
        }
        applyThemeBackground()
        loadTarget(in: webView)
    }

    private func loadTarget(in webView: WKWebView) {
        hideError()
        progressView.progress = 0
        progressView.isHidden = false
        webView.load(URLRequest(url: targetURL))
    }

    private func showError() {
        errorStack.isHidden = false
        progressView.isHidden = true
        webView?.isHidden = true
    }

    private func hideError() {
        errorStack.isHidden = true
        webView?.isHidden = false
    }

    @objc private func retryTapped() {
        if let webView {
            loadTarget(in: webView)
        } else {
            startWebViewSetup()
        }
    }

    @objc private func closeTapped() {
        tearDownWebView()
        dismiss(animated: true)
    }

    private func tearDownWebView() {
        progressObservation?.invalidate()
        progressObservation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    private func isFeedbackURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return host == targetURL.host?.lowercased()
    }

    private func openExternally(_ url: URL) {
        UIApplication.shared.open(url)
    }

    private func makeWebThemePalette() -> WebThemePalette {
        let theme = ThemeManager.shared
        let traits = UITraitCollection(userInterfaceStyle: traitCollection.userInterfaceStyle)
        func hex(_ color: UIColor) -> String {
            color.resolvedColor(with: traits).hexString
        }
        return WebThemePalette(
            brand: hex(theme.accentColor),
            page: hex(theme.backgroundColor),
            surface: hex(theme.cardBackgroundColor),
            raised: hex(theme.codeBackgroundColor),
            ink: hex(.label),
            inkMuted: hex(.secondaryLabel),
            inkSubtle: hex(.tertiaryLabel),
            line: hex(.separator),
            isDark: traitCollection.userInterfaceStyle == .dark
        )
    }
}

extension FeedbackViewController: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }

        if scheme == "http" || scheme == "https" {
            if isFeedbackURL(url) {
                decisionHandler(.allow)
            } else {
                openExternally(url)
                decisionHandler(.cancel)
            }
            return
        }

        if ["about", "blob", "data"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            openExternally(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(makeWebThemePalette().javaScript)
        hideError()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationError(error)
    }

    private func handleNavigationError(_ error: Error) {
        let error = error as NSError
        guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else { return }
        showError()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else { return nil }
        if isFeedbackURL(url) {
            webView.load(navigationAction.request)
        } else {
            openExternally(url)
        }
        return nil
    }
}
