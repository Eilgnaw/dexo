import UIKit
import WebKit

/// Presents a WKWebView so users can log in to a Discourse forum via their browser.
/// Fires onSuccess once the Discourse session cookie `_t` is detected.
final class WebLoginViewController: BaseViewController {
    private let targetURL: URL
    private let onSuccess: ([HTTPCookie], String?) -> Void

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
        if #unavailable(iOS 16.4) {
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

    private lazy var coordinator = Coordinator(targetURL: targetURL, onCookiesReady: { [weak self] cookies in
        self?.handleCookiesReady(cookies)
    })

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

    init(targetURL: URL, onSuccess: @escaping ([HTTPCookie], String?) -> Void) {
        self.targetURL = targetURL
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
        NSLayoutConstraint.activate([
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
        setupTask?.cancel()
        dismiss(animated: true)
    }

    @objc private func doneTapped() {
        guard let webView else { return }
        coordinator.collectAndFire(from: webView)
    }

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

    private func handleCookiesReady(_ cookies: [HTTPCookie]) {
        Task { @MainActor in
            guard let webView else { return }
            // Do not mutate the app-wide cookie store here. AuthManager first
            // persists the new auth marker, then installs these cookies. This
            // preserves the previous login if Keychain persistence fails.
            let evaluatedUserAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
            let userAgent = evaluatedUserAgent ?? webView.customUserAgent
            dismiss(animated: true) {
                self.onSuccess(cookies, userAgent)
            }
        }
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
    /// import-map shim. This keeps the rewritten modules compatible with the
    /// forum's strict Content Security Policy while still installing before
    /// deferred module scripts execute.
    private static func moduleShimsBootstrap(source: String) -> String {
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
        private let targetHost: String
        private let onCookiesReady: ([HTTPCookie]) -> Void
        private let trustEvaluator: WebViewProxyTrustEvaluator?
        private(set) var didCallback = false

        init(targetURL: URL, onCookiesReady: @escaping ([HTTPCookie]) -> Void) {
            self.targetHost = targetURL.host?.lowercased() ?? ""
            self.onCookiesReady = onCookiesReady
            trustEvaluator = WebViewDoHConfigurator.makeTrustEvaluator()
        }

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

        /// Collect cookies and fire the callback. Only invoked from the "Done" button tap —
        /// auto-dismiss on navigation finish / cookie change was intentionally removed so
        /// the user decides when to hand off to the app.
        func collectAndFire(from webView: WKWebView) {
            guard !didCallback else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.didCallback else { return }
                let relevant = cookies.filter {
                    WebCookieStore.cookieDomain($0.domain, matchesHost: self.targetHost)
                }
                self.didCallback = true
                DispatchQueue.main.async { self.onCookiesReady(relevant) }
            }
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
    private static let minimumAdvertisedVersion = OperatingSystemVersion(
        majorVersion: 16,
        minorVersion: 7,
        patchVersion: 0
    )

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
