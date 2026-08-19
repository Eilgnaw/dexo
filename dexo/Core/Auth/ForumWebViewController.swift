import UIKit
import WebKit

/// In-app browser used for links opened from forum content. It shares the
/// persisted forum Web session so pages that are not rendered natively still
/// receive the user's login and Cloudflare cookies.
final class ForumWebViewController: BaseViewController {
    private let targetURL: URL
    private let forumURL: URL

    private var webView: WKWebView?
    private var proxyLease: AnyObject?
    private var setupTask: Task<Void, Never>?
    private var progressObservation: NSKeyValueObservation?
    private var isObservingCookieChanges = false
    private var isFinalCookieSyncInProgress = false

    private lazy var coordinator = Coordinator(
        onNavigationFinished: { [weak self] title in
            self?.navigationFinished(title: title)
        },
        onCookiesChanged: { [weak self] in
            self?.syncCookies()
        },
        openExternally: { url in
            UIApplication.shared.open(url)
        }
    )

    private let progressView: UIProgressView = {
        let progressView = UIProgressView(progressViewStyle: .bar)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.isHidden = true
        return progressView
    }()

    init(targetURL: URL, forumURL: URL) {
        self.targetURL = targetURL
        self.forumURL = forumURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = targetURL.host ?? String(localized: "forum_browser.title")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )

        let openInBrowserButton = UIBarButtonItem(
            image: UIImage(systemName: "safari"),
            style: .plain,
            target: self,
            action: #selector(openInSystemBrowser)
        )
        openInBrowserButton.accessibilityLabel = String(localized: "forum_browser.open_in_system_browser")
        navigationItem.rightBarButtonItem = openInBrowserButton

        view.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        setupTask = Task { [weak self] in
            await self?.setUpWebView()
        }
    }

    override func applyThemeBackground() {
        super.applyThemeBackground()
        let color = ThemeManager.shared.cardBackgroundColor
        webView?.backgroundColor = color
        webView?.scrollView.backgroundColor = color
        webView?.underPageBackgroundColor = color
    }

    private func makeWebViewConfiguration() async throws -> (WKWebViewConfiguration, AnyObject?) {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: "document.documentElement.style.colorScheme = 'light dark';",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        let lease = try await WebViewDoHConfigurator.configure(configuration)
        return (configuration, lease)
    }

    private func setUpWebView() async {
        do {
            let (configuration, lease) = try await makeWebViewConfiguration()
            guard !Task.isCancelled else { return }

            proxyLease = lease
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.translatesAutoresizingMaskIntoConstraints = false
            webView.navigationDelegate = coordinator
            webView.uiDelegate = coordinator
            webView.allowsBackForwardNavigationGestures = true
            webView.isOpaque = false
            if let userAgent = WebCookieStore.shared.userAgent {
                webView.customUserAgent = userAgent
            }
            self.webView = webView

            view.insertSubview(webView, belowSubview: progressView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])

            progressObservation = webView.observe(\.estimatedProgress, options: .new) { [weak self] webView, _ in
                self?.progressView.progress = Float(webView.estimatedProgress)
                self?.progressView.isHidden = webView.estimatedProgress >= 1
            }
            applyThemeBackground()

            await seedCookies(in: webView)
            guard !Task.isCancelled else { return }
            webView.configuration.websiteDataStore.httpCookieStore.add(coordinator)
            isObservingCookieChanges = true
            progressView.isHidden = false
            webView.load(URLRequest(url: targetURL))
        } catch {
            guard !Task.isCancelled else { return }
            showProxyUnavailableAlert()
        }
    }

    private func seedCookies(in webView: WKWebView) async {
        let candidates = WebCookieStore.shared.cookies(for: forumURL)
            + WebCookieStore.shared.cookies(for: targetURL)
        var seen = Set<String>()
        let cookies = candidates.filter { cookie in
            seen.insert("\(cookie.domain)|\(cookie.name)|\(cookie.path)").inserted
        }
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in cookies {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                cookieStore.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    private func navigationFinished(title: String?) {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.title = title
        } else {
            self.title = webView?.url?.host ?? targetURL.host ?? String(localized: "forum_browser.title")
        }
        syncCookies()
    }

    private func syncCookies() {
        Task { @MainActor in
            await syncWebSession()
        }
    }

    private func syncWebSession() async {
        guard let webView else { return }
        await WebCookieStore.shared.syncFromWebView(
            webView.configuration.websiteDataStore,
            for: forumURL
        )

        guard isForumURL(webView.url),
              let evaluatedUserAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String,
              !evaluatedUserAgent.isEmpty
        else { return }
        WebCookieStore.shared.userAgent = evaluatedUserAgent
    }

    private func isForumURL(_ url: URL?) -> Bool {
        guard let host = url?.host, let forumHost = forumURL.host else { return false }
        return host.caseInsensitiveCompare(forumHost) == .orderedSame
    }

    private func showProxyUnavailableAlert() {
        let alert = UIAlertController(
            title: String(localized: "doh.proxy.error.title"),
            message: String(localized: "doh.proxy.error.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    @objc private func openInSystemBrowser() {
        UIApplication.shared.open(webView?.url ?? targetURL)
    }

    @objc private func closeTapped() {
        setupTask?.cancel()
        syncAndDismiss()
    }

    private func syncAndDismiss() {
        guard !isFinalCookieSyncInProgress else { return }
        isFinalCookieSyncInProgress = true
        Task { @MainActor in
            await syncWebSession()
            dismiss(animated: true)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if !isFinalCookieSyncInProgress,
           isBeingDismissed || navigationController?.isBeingDismissed == true
        {
            syncCookies()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil, isObservingCookieChanges {
            webView?.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
            isObservingCookieChanges = false
        }
    }

    private final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        private let onNavigationFinished: (String?) -> Void
        private let onCookiesChanged: () -> Void
        private let openExternally: (URL) -> Void
        private let trustEvaluator: WebViewProxyTrustEvaluator?

        init(
            onNavigationFinished: @escaping (String?) -> Void,
            onCookiesChanged: @escaping () -> Void,
            openExternally: @escaping (URL) -> Void
        ) {
            self.onNavigationFinished = onNavigationFinished
            self.onCookiesChanged = onCookiesChanged
            self.openExternally = openExternally
            trustEvaluator = WebViewDoHConfigurator.makeTrustEvaluator()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased()
            else {
                decisionHandler(.allow)
                return
            }

            if scheme == "http" || scheme == "https" || ["about", "blob", "data"].contains(scheme) {
                decisionHandler(.allow)
            } else {
                openExternally(url)
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if let credential = trustEvaluator?.credential(for: challenge) {
                completionHandler(.useCredential, credential)
                return
            }
            completionHandler(.performDefaultHandling, nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onNavigationFinished(webView.title)
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            onCookiesChanged()
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
}

extension UIViewController {
    func presentForumWebView(_ url: URL, forumBaseURL: String) {
        guard let forumURL = URL(string: forumBaseURL) else {
            UIApplication.shared.open(url)
            return
        }
        let controller = ForumWebViewController(targetURL: url, forumURL: forumURL)
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .fullScreen
        present(navigationController, animated: true)
    }
}
