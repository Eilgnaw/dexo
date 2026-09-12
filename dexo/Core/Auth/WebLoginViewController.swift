import UIKit
import WebKit

/// Presents a WKWebView so users can log in to a Discourse forum via their browser.
/// Keeps the login page visible while the captured session is saved.
final class WebLoginViewController: BaseViewController {
    private let targetURL: URL
    private let saveSession: ([HTTPCookie], String?, String?) async throws -> Void
    private let onSuccess: () -> Void
    private var isCompletingLogin = false

    private var webView: WKWebView?
    private var proxyLease: AnyObject?
    private var setupTask: Task<Void, Never>?
    private var diagnosticEntries: [String] = []
    private var diagnosticsRequested = false

    private lazy var diagnostics = WebLoginDiagnostics { [weak self] event in
        self?.appendDiagnostic(event)
    }

    private func makeWebViewConfiguration() async throws -> (WKWebViewConfiguration, AnyObject?) {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        diagnostics.register(with: config)

        // Discourse's current frontend requires relative colors and import
        // maps, which WebKit did not gain until iOS 16.4. The login flow only
        // needs enough compatibility to boot Discourse and capture `_t`.
        if WebLoginCompatibility.requiresLegacyBrowserEnvironment() {
            let runtimePolyfillsSource = try Self.loadRuntimePolyfillsSource()
            let runtimePolyfillsScript = WKUserScript(
                source: runtimePolyfillsSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(runtimePolyfillsScript)

            let polyfillSource = WebLoginCompatibility.browserGatePolyfillJS
            let script = WKUserScript(
                source: polyfillSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(script)

            let moduleShimsSource = try Self.loadModuleShimsSource()
            let moduleShimsScript = WKUserScript(
                source: Self.moduleShimsBootstrap(source: moduleShimsSource),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(moduleShimsScript)
        }

        // Inject color-scheme hint so the page respects dark mode
        let darkModeCSS = WKUserScript(
            source: "document.documentElement.style.colorScheme = 'light dark';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(darkModeCSS)
        let lease = try await WebViewDoHConfigurator.configure(config)
        return (config, lease)
    }

    private lazy var coordinator = Coordinator()

    private let loginIndicator = UIActivityIndicatorView(style: .large)
    private let loginLoadingLabel = UILabel()
    private lazy var loginLoadingOverlay: UIView = {
        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true
        overlay.accessibilityViewIsModal = true
        overlay.accessibilityIdentifier = "weblogin.loading"
        loginLoadingLabel.text = String(localized: "weblogin.loading")
        loginLoadingLabel.font = .preferredFont(forTextStyle: .body)
        loginLoadingLabel.adjustsFontForContentSizeCategory = true
        loginLoadingLabel.numberOfLines = 0
        loginLoadingLabel.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [loginIndicator, loginLoadingLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        overlay.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24),
        ])
        return overlay
    }()

    private lazy var progressView: UIProgressView = {
        let pv = UIProgressView(progressViewStyle: .bar)
        pv.translatesAutoresizingMaskIntoConstraints = false
        return pv
    }()

    private var progressObservation: NSKeyValueObservation?

    private lazy var doneButton = UIBarButtonItem(
        title: String(localized: "weblogin.done"),
        style: .done,
        target: self,
        action: #selector(doneTapped)
    )

    private lazy var debugButton = UIBarButtonItem(
        title: String(localized: "weblogin.debug"),
        style: .plain,
        target: self,
        action: #selector(debugTapped)
    )

    private lazy var diagnosticTextView: UITextView = {
        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        textView.layer.cornerRadius = 12
        textView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        textView.accessibilityLabel = String(localized: "weblogin.debug.title")
        textView.isHidden = true
        return textView
    }()

    init(
        targetURL: URL,
        saveSession: @escaping ([HTTPCookie], String?, String?) async throws -> Void,
        onSuccess: @escaping () -> Void
    ) {
        self.targetURL = targetURL
        self.saveSession = saveSession
        self.onSuccess = onSuccess
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "weblogin.title")

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped)
        )
        doneButton.isEnabled = false
        navigationItem.rightBarButtonItems = [doneButton, debugButton]

        view.addSubview(progressView)
        view.addSubview(diagnosticTextView)
        view.addSubview(loginLoadingOverlay)
        NSLayoutConstraint.activate([
            loginLoadingOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            loginLoadingOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loginLoadingOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loginLoadingOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            diagnosticTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            diagnosticTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            diagnosticTextView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            diagnosticTextView.heightAnchor.constraint(equalToConstant: 240),
        ])
        refreshDiagnosticPanel()

        setupTask = Task { [weak self] in
            await self?.setUpWebView()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        diagnosticTextView.backgroundColor = ThemeManager.shared.codeBackgroundColor
        diagnosticTextView.textColor = .label
    }

    override func applyThemeBackground() {
        super.applyThemeBackground()
        loginLoadingOverlay.backgroundColor = ThemeManager.shared.cardBackgroundColor.withAlphaComponent(0.95)
        loginIndicator.color = ThemeManager.shared.accentColor
        loginLoadingLabel.textColor = ThemeManager.shared.accentColor
    }

    private func setUpWebView() async {
        do {
            let (configuration, lease) = try await makeWebViewConfiguration()
            guard !Task.isCancelled else { return }

            proxyLease = lease
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = coordinator
            webView.uiDelegate = coordinator
            webView.isOpaque = false
            webView.backgroundColor = .systemBackground
            webView.customUserAgent = WebLoginCompatibility.mobileSafariUserAgent()
            webView.translatesAutoresizingMaskIntoConstraints = false
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
                self?.progressView.isHidden = webView.estimatedProgress >= 1.0
            }
            doneButton.isEnabled = true
            if diagnosticsRequested {
                diagnostics.enable(in: webView)
            }
            webView.load(URLRequest(url: targetURL))
        } catch {
            guard !Task.isCancelled else { return }
            showProxyUnavailableAlert()
        }
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

    // MARK: - Actions

    @objc private func cancelTapped() {
        guard !isCompletingLogin else { return }
        setupTask?.cancel()
        dismiss(animated: true)
    }

    @objc private func doneTapped() {
        guard let webView, !isCompletingLogin else { return }
        // Show feedback before the first WebKit IPC or session/network operation.
        setCompletingLogin(true)
        Task {
            do {
                let username: String?
                if ForumPolicy.isLinuxDoFamily(baseURL: targetURL.absoluteString) {
                    guard webView.url?.scheme == "https",
                          webView.url?.host?.lowercased() == targetURL.host?.lowercased()
                    else { throw AuthError.missingWebUsername }
                    username = try await webView.evaluateJavaScript(Self.currentUsernameScript) as? String
                    guard let username, !username.isEmpty else { throw AuthError.missingWebUsername }
                } else {
                    username = nil
                }
                let allCookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                        continuation.resume(returning: $0)
                    }
                }
                let cookies = allCookies.filter {
                    WebCookieStore.cookieDomain($0.domain, matchesHost: targetURL.host ?? "")
                }
                let evaluatedUserAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
                // AuthManager validates the session before replacing saved credentials.
                try await saveSession(cookies, evaluatedUserAgent ?? webView.customUserAgent, username)
                dismiss(animated: true, completion: onSuccess)
            } catch {
                setCompletingLogin(false)
                let message = (error as? AuthError).map {
                    if case .missingWebUsername = $0 { return String(localized: "weblogin.username.missing") }
                    return String(localized: "login.failed.message")
                } ?? String(localized: "login.failed.message")
                let alert = UIAlertController(
                    title: String(localized: "login.failed.title"),
                    message: message,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func setCompletingLogin(_ completing: Bool) {
        isCompletingLogin = completing
        isModalInPresentation = completing
        navigationController?.isModalInPresentation = completing
        doneButton.isEnabled = !completing
        debugButton.isEnabled = !completing
        navigationItem.leftBarButtonItem?.isEnabled = !completing
        loginLoadingOverlay.isHidden = !completing
        if completing {
            applyThemeBackground()
            view.endEditing(true)
            loginIndicator.startAnimating()
            UIAccessibility.post(notification: .screenChanged, argument: loginLoadingLabel)
        } else {
            loginIndicator.stopAnimating()
        }
    }

    /// Read the authenticated page identity, never the login form's identifier.
    static let currentUsernameScript = #"""
    (function() {
        function username(value) {
            return typeof value === 'string' && value.trim() ? value.trim() : null;
        }
        var meta = document.querySelector('meta[name="current-username"]');
        var name = meta && username(meta.content);
        if (name) return name;
        try {
            if (typeof Discourse !== 'undefined' && Discourse.User && Discourse.User.current) {
                var user = Discourse.User.current();
                name = user && username(user.username);
                if (name) return name;
            }
        } catch (_) {}
        try {
            var script = document.querySelector('script#data-preloaded');
            var element = document.querySelector('[data-preloaded]');
            var raw = script ? script.textContent : element && element.getAttribute('data-preloaded');
            var data = raw && JSON.parse(raw);
            var currentUser = data && data.currentUser;
            if (typeof currentUser === 'string') currentUser = JSON.parse(currentUser);
            return currentUser && username(currentUser.username) || null;
        } catch (_) { return null; }
    })();
    """#

    @objc private func debugTapped() {
        if diagnosticsRequested {
            diagnosticsRequested = false
            diagnostics.disable(in: webView)
            diagnosticTextView.isHidden = true
            debugButton.title = String(localized: "weblogin.debug")
            return
        }

        diagnosticsRequested = true
        diagnosticTextView.isHidden = false
        debugButton.title = String(localized: "weblogin.debug.close")
        appendDiagnostic(String(localized: "weblogin.debug.enabled"))

        guard let webView else { return }
        diagnostics.enable(in: webView)
        // The page must load after instrumentation is installed so login API
        // calls made during boot are visible in the diagnostic panel.
        webView.reload()
    }

    private func appendDiagnostic(_ event: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        diagnosticEntries.append("[\(formatter.string(from: Date()))] \(event)")
        if diagnosticEntries.count > 100 {
            diagnosticEntries.removeFirst(diagnosticEntries.count - 100)
        }
        refreshDiagnosticPanel()
    }

    private func refreshDiagnosticPanel() {
        diagnosticTextView.text = diagnosticEntries.isEmpty
            ? String(localized: "weblogin.debug.empty")
            : diagnosticEntries.joined(separator: "\n\n")
        guard !diagnosticEntries.isEmpty else { return }
        diagnosticTextView.scrollRangeToVisible(
            NSRange(location: diagnosticTextView.text.utf16.count, length: 0)
        )
    }

    // MARK: - Polyfills (iOS < 16.4)

    private static func loadRuntimePolyfillsSource() throws -> String {
        guard let url = Bundle.main.url(
            forResource: "web-login-polyfills",
            withExtension: "js"
        ) else {
            throw WebLoginSetupError.missingRuntimePolyfills
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func loadModuleShimsSource() throws -> String {
        guard let url = Bundle.main.url(
            forResource: "es-module-shims",
            withExtension: "js"
        ) else {
            throw WebLoginSetupError.missingModuleShims
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Wait for Discourse's first nonce-bearing script before starting the
    /// import-map and module-source shim. This keeps rewritten modules
    /// compatible with the forum's strict Content Security Policy while still
    /// installing before deferred module scripts execute.
    static func moduleShimsBootstrap(source: String) -> String {
        """
        (function() {
            var installed = false;
            var observer;

            function nonceFromPage() {
                var script = document.querySelector('script[nonce]');
                return script && (script.nonce || script.getAttribute('nonce'));
            }

            function install(nonce) {
                if (installed) return;
                installed = true;
                if (observer) observer.disconnect();
                window.esmsInitOptions = window.esmsInitOptions || {};
                if (nonce) window.esmsInitOptions.nonce = nonce;
                if (typeof window.__dexoESModuleSourceHook === 'function') {
                    window.esmsInitOptions.source = window.__dexoESModuleSourceHook;
                }
                \(source)
            }

            function installIfReady() {
                var nonce = nonceFromPage();
                if (nonce || document.querySelector('script[type="importmap"]')) {
                    install(nonce);
                    return true;
                }
                return false;
            }

            if (installIfReady()) return;

            observer = new MutationObserver(function() {
                installIfReady();
            });
            observer.observe(document, { childList: true, subtree: true });

            document.addEventListener('readystatechange', function() {
                if (!installed && document.readyState !== 'loading') {
                    install(nonceFromPage());
                }
            });
        })();
        """
    }

    // MARK: - Coordinator

    private final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let trustEvaluator = WebViewDoHConfigurator.makeTrustEvaluator()

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if let credential = trustEvaluator?.credential(for: challenge) {
                #if DEBUG
                print("[WebViewDoHProxy] WebLogin accepted proxy CA for \(challenge.protectionSpace.host)")
                #endif
                completionHandler(.useCredential, credential)
                return
            }
            completionHandler(.performDefaultHandling, nil)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView?
        {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

private enum WebLoginSetupError: Error {
    case missingRuntimePolyfills
    case missingModuleShims
}

enum WebLoginCompatibility {
    static let browserGatePolyfillJS = """
    (function() {
        // Work around the WeakMap behavior checked by Discourse's browser gate.
        try {
            new WeakMap().has(0);
        } catch (_) {
            var weakMapHas = WeakMap.prototype.has;
            WeakMap.prototype.has = function(key) {
                var type = typeof key;
                if ((type !== 'object' || key === null) && type !== 'function') return false;
                return weakMapHas.call(this, key);
            };
        }

        // These DOM APIs are newer than iOS 16 and are outside core-js.
        if (typeof AbortSignal !== 'undefined' && typeof AbortController !== 'undefined') {
            if (typeof AbortSignal.timeout !== 'function') {
                AbortSignal.timeout = function(milliseconds) {
                    var controller = new AbortController();
                    setTimeout(function() {
                        try {
                            controller.abort(new DOMException('The operation timed out.', 'TimeoutError'));
                        } catch (_) {
                            controller.abort();
                        }
                    }, milliseconds);
                    return controller.signal;
                };
            }

            if (typeof AbortSignal.any !== 'function') {
                AbortSignal.any = function(signals) {
                    var controller = new AbortController();
                    var candidates = Array.from(signals);
                    var abort = function(event) {
                        var source = event && event.target;
                        try {
                            controller.abort(source && source.reason);
                        } catch (_) {
                            controller.abort();
                        }
                        for (var i = 0; i < candidates.length; i++) {
                            try { candidates[i].removeEventListener('abort', abort); } catch (_) {}
                        }
                    };

                    for (var i = 0; i < candidates.length; i++) {
                        if (candidates[i] && candidates[i].aborted) {
                            try {
                                controller.abort(candidates[i].reason);
                            } catch (_) {
                                controller.abort();
                            }
                            return controller.signal;
                        }
                    }
                    for (var i = 0; i < candidates.length; i++) {
                        candidates[i].addEventListener('abort', abort, { once: true });
                    }
                    return controller.signal;
                };
            }
        }

        // Discourse intentionally blocks engines missing newer layout features.
        // Dexo only needs the login flow, so bypass the startup gate and restore
        // the page's real feature detection as soon as Discourse starts.
        var originalSupports = null;
        try {
            if (typeof CSS !== 'undefined' && typeof CSS.supports === 'function') {
                originalSupports = CSS.supports;
                CSS.supports = function() {
                    var query = arguments.length === 1
                        ? arguments[0]
                        : arguments[0] + ': ' + arguments[1];
                    if (typeof query === 'string' &&
                        (query.indexOf('subgrid') !== -1 || query.indexOf('hsl(from') !== -1)) {
                        return true;
                    }
                    return originalSupports.apply(CSS, arguments);
                };
            }
        } catch (_) {}

        var guardInstalled = false;
        try {
            Object.defineProperty(window, 'unsupportedBrowser', {
                configurable: true,
                get: function() { return false; },
                set: function() {}
            });
            guardInstalled = true;
        } catch (_) {}

        var restored = false;
        function restoreBrowserDetection() {
            if (restored) return;
            restored = true;
            if (originalSupports) CSS.supports = originalSupports;
            if (guardInstalled) {
                try {
                    delete window.unsupportedBrowser;
                    window.unsupportedBrowser = false;
                } catch (_) {}
            }
        }

        document.addEventListener('discourse-init', restoreBrowserDetection, { once: true });
        window.addEventListener('load', restoreBrowserDetection, { once: true });
        setTimeout(restoreBrowserDetection, 15000);
    })();
    """
    private static let minimumNativeBrowserEnvironmentVersion = OperatingSystemVersion(
        majorVersion: 16,
        minorVersion: 4,
        patchVersion: 0
    )
    private static let minimumAdvertisedVersion = OperatingSystemVersion(
        majorVersion: 16,
        minorVersion: 7,
        patchVersion: 0
    )

    /// iOS 15 and early iOS 16 WebKit need the runtime polyfills, import-map
    /// shim, and module syntax transform installed before Discourse boots.
    static func requiresLegacyBrowserEnvironment(
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        isOlder(operatingSystemVersion, than: minimumNativeBrowserEnvironmentVersion)
    }

    /// Advertises at least iOS 16.7 to Discourse on older systems while
    /// retaining the device idiom and the real version on supported systems.
    static func mobileSafariUserAgent(
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom
    ) -> String {
        let advertisedVersion = isOlder(
            operatingSystemVersion,
            than: minimumAdvertisedVersion
        ) ? minimumAdvertisedVersion : operatingSystemVersion
        let major = advertisedVersion.majorVersion
        let minor = advertisedVersion.minorVersion
        let osToken = "\(major)_\(minor)"
        let versionToken = "\(major).\(minor)"
        let device = idiom == .pad ? "iPad" : "iPhone"
        let cpu = idiom == .pad ? "CPU OS" : "CPU iPhone OS"
        return "Mozilla/5.0 (\(device); \(cpu) \(osToken) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(versionToken) Mobile/15E148 Safari/604.1"
    }

    private static func isOlder(
        _ lhs: OperatingSystemVersion,
        than rhs: OperatingSystemVersion
    ) -> Bool {
        if lhs.majorVersion != rhs.majorVersion {
            return lhs.majorVersion < rhs.majorVersion
        }
        if lhs.minorVersion != rhs.minorVersion {
            return lhs.minorVersion < rhs.minorVersion
        }
        return lhs.patchVersion < rhs.patchVersion
    }
}
