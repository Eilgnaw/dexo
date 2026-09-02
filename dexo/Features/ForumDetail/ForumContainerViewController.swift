import AuthenticationServices
import Perception
import UIKit

final class ForumContainerViewController: BaseViewController, AuthGating {
    override var childForStatusBarStyle: UIViewController? { children.first }

    private struct PendingPushDestination {
        let topicID: Int
        let floor: Int?
        let completion: () -> Void
    }

    private(set) var forum: ForumInstance
    private let api: DiscourseAPI
    private let authManager = AuthManager.shared
    private var notificationPoller: NotificationPoller?
    private var hasPendingReadTimingsChallengeAlert = false
    private var hasPendingPostLoginPushPrompt = false
    private var pendingPushRegistrationError: Error?
    private var isRegisteringPush = false
    private var pendingPushDestination: PendingPushDestination?

    private let pushRegistrationLoadingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        return indicator
    }()

    private let pushRegistrationLoadingLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        label.accessibilityTraits = .updatesFrequently
        return label
    }()

    private let pushRegistrationLoadingCard: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 14
        return view
    }()

    private lazy var pushRegistrationLoadingOverlay: UIView = {
        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true
        overlay.accessibilityViewIsModal = true
        overlay.accessibilityIdentifier = "push.registration.loading"

        let stack = UIStackView(arrangedSubviews: [
            pushRegistrationLoadingIndicator,
            pushRegistrationLoadingLabel,
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12

        pushRegistrationLoadingCard.addSubview(stack)
        overlay.addSubview(pushRegistrationLoadingCard)
        NSLayoutConstraint.activate([
            pushRegistrationLoadingCard.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            pushRegistrationLoadingCard.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            pushRegistrationLoadingCard.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 32),
            pushRegistrationLoadingCard.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: pushRegistrationLoadingCard.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: pushRegistrationLoadingCard.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: pushRegistrationLoadingCard.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: pushRegistrationLoadingCard.bottomAnchor, constant: -24),
        ])
        return overlay
    }()

    init(forum: ForumInstance) {
        self.forum = forum
        self.api = DiscourseAPI(forum: forum)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func stopPoller() {
        notificationPoller?.stop()
        notificationPoller = nil
    }

    @discardableResult
    func openPushNotification(
        relativeURL: String,
        completion: @escaping () -> Void = {}
    ) -> Bool {
        guard let destination = URL(string: relativeURL, relativeTo: URL(string: api.baseURL))?.absoluteURL,
              destination.scheme?.lowercased() == "https",
              destination.host?.lowercased() == URL(string: api.baseURL)?.host?.lowercased(),
              let route = Self.topicRoute(from: destination) else { return false }
        pendingPushDestination = PendingPushDestination(
            topicID: route.topicID,
            floor: route.floor,
            completion: completion
        )
        openPendingPushDestinationIfPossible()
        return true
    }

    private func openPendingPushDestinationIfPossible() {
        guard viewIfLoaded?.window != nil,
              let destination = pendingPushDestination else { return }
        guard let tabBar = children.first as? ForumTabBarController,
              let navigationController = tabBar.navigationControllers.first else { return }
        pendingPushDestination = nil
        if #available(iOS 18.0, *) {
            tabBar.selectedTab = tabBar.tabs.first
        } else {
            tabBar.selectedIndex = 0
        }
        let viewController = TopicDetailControllerFactory.make(
            api: api,
            topicId: destination.topicID,
            initialFloor: destination.floor
        )
        navigationController.popToRootViewController(animated: false)
        navigationController.pushViewController(viewController, animated: true)
        destination.completion()
    }

    private static func topicRoute(from url: URL) -> (topicID: Int, floor: Int?)? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard let topicIndex = components.firstIndex(of: "t") else { return nil }
        let tail = components.dropFirst(topicIndex + 1)
        guard !tail.isEmpty else { return nil }
        if let topicID = Int(tail[tail.startIndex]) {
            let floorIndex = tail.index(after: tail.startIndex)
            let floor = floorIndex < tail.endIndex ? Int(tail[floorIndex]) : nil
            return (topicID, floor)
        }
        let topicIDIndex = tail.index(after: tail.startIndex)
        guard topicIDIndex < tail.endIndex, let topicID = Int(tail[topicIDIndex]) else {
            return nil
        }
        let floorIndex = tail.index(after: topicIDIndex)
        let floor = floorIndex < tail.endIndex ? Int(tail[floorIndex]) : nil
        return (topicID, floor)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        authManager.restoreAuthState(for: forum)

        setupTabBar()
        setupPushRegistrationLoadingOverlay()
        configureNavItems()
        startObservingAuth()
        startNotificationPoller()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(forumAuthenticationDidChange(_:)),
            name: .discourseAuthDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(readTimingsChallengeWasDetected),
            name: .linuxDoReadTimingsChallengeDetected,
            object: api
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(presentPendingAlertsIfPossible),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func forumAuthenticationDidChange(_ notification: Notification) {
        let changedBaseURL = (notification.userInfo?["baseURL"] as? String)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let currentBaseURL = forum.baseURL.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        guard changedBaseURL == currentBaseURL else { return }

        if isAuthenticated() {
            if notificationPoller == nil {
                startNotificationPoller()
            }
        } else {
            notificationPoller?.stop()
            notificationPoller = nil
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        openPendingPushDestinationIfPossible()
        presentPendingAlertsIfPossible()
    }

    @objc private func readTimingsChallengeWasDetected() {
        hasPendingReadTimingsChallengeAlert = true
        presentPendingAlertsIfPossible()
    }

    @objc private func presentPendingAlertsIfPossible() {
        guard viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
              presentedViewController == nil,
              !isRegisteringPush
        else { return }

        if let error = pendingPushRegistrationError {
            pendingPushRegistrationError = nil
            presentPushRegistrationError(error)
            return
        }

        if hasPendingReadTimingsChallengeAlert {
            presentPendingReadTimingsAlert()
            return
        }

        presentPostLoginPushPromptIfNeeded()
    }

    private func presentPendingReadTimingsAlert() {
        hasPendingReadTimingsChallengeAlert = false
        let alert = UIAlertController(
            title: String(localized: "settings.read_timings.challenge.title"),
            message: String(localized: "settings.read_timings.challenge.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: String(localized: "settings.read_timings.challenge.disable"),
            style: .destructive
        ) { [weak self] _ in
            AppSettings.shared.linuxDoReadTimingsEnabled = false
            self?.schedulePendingAlertPresentation()
        })
        alert.addAction(UIAlertAction(
            title: String(localized: "settings.read_timings.challenge.open"),
            style: .default
        ) { [weak self] _ in
            guard let self else { return }
            ChallengeViewController.present(from: self) { [weak self] in
                self?.api.resumeTopicTimingUploadsAfterChallenge()
            }
        })
        present(alert, animated: true)
    }

    private func presentPostLoginPushPromptIfNeeded() {
        guard hasPendingPostLoginPushPrompt else { return }
        guard isAuthenticated(),
              let username = currentUsername() ?? forum.username,
              !username.isEmpty
        else {
            hasPendingPostLoginPushPrompt = false
            return
        }

        let coordinator = PushSubscriptionCoordinator(api: api)
        guard !coordinator.isEnabled(username: username) else {
            hasPendingPostLoginPushPrompt = false
            return
        }

        hasPendingPostLoginPushPrompt = false
        let alert = UIAlertController(
            title: String(localized: "push.settings.title"),
            message: String(localized: "push.login_prompt.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: String(localized: "action.no_thanks"),
            style: .cancel
        ) { [weak self] _ in
            self?.schedulePendingAlertPresentation()
        })
        alert.addAction(UIAlertAction(
            title: String(localized: "action.enable"),
            style: .default
        ) { [weak self] _ in
            self?.enablePushAfterLogin(username: username)
        })
        present(alert, animated: true)
    }

    private func schedulePendingAlertPresentation() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.presentPendingAlertsIfPossible()
        }
    }

    private func setupPushRegistrationLoadingOverlay() {
        view.addSubview(pushRegistrationLoadingOverlay)
        NSLayoutConstraint.activate([
            pushRegistrationLoadingOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            pushRegistrationLoadingOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pushRegistrationLoadingOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pushRegistrationLoadingOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func showPushRegistrationLoading() {
        isRegisteringPush = true
        let theme = ThemeManager.shared
        pushRegistrationLoadingOverlay.backgroundColor = theme.backgroundColor.withAlphaComponent(0.88)
        pushRegistrationLoadingCard.backgroundColor = theme.cardBackgroundColor
        pushRegistrationLoadingIndicator.color = theme.accentColor
        pushRegistrationLoadingLabel.text = String(localized: "push.login_prompt.loading")
        pushRegistrationLoadingIndicator.startAnimating()
        pushRegistrationLoadingOverlay.isHidden = false
        view.bringSubviewToFront(pushRegistrationLoadingOverlay)
        UIAccessibility.post(
            notification: .screenChanged,
            argument: pushRegistrationLoadingLabel
        )
    }

    private func hidePushRegistrationLoading() {
        isRegisteringPush = false
        pushRegistrationLoadingIndicator.stopAnimating()
        pushRegistrationLoadingOverlay.isHidden = true
    }

    private func enablePushAfterLogin(username: String) {
        guard !isRegisteringPush else { return }
        showPushRegistrationLoading()
        let coordinator = PushSubscriptionCoordinator(api: api)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await coordinator.enable(username: username)
            } catch {
                pendingPushRegistrationError = error
            }
            hidePushRegistrationLoading()
            schedulePendingAlertPresentation()
        }
    }

    private func presentPushRegistrationError(_ error: Error) {
        let alert = UIAlertController(
            title: String(localized: "push.error.title"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default) { [weak self] _ in
            self?.schedulePendingAlertPresentation()
        })
        present(alert, animated: true)
    }

    private func startObservingAuth() {
        withPerceptionTracking {
            _ = self.authManager.isAuthenticated(for: self.forum.baseURL)
            _ = self.authManager.username(for: self.forum.baseURL)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.startObservingAuth()
                // Start poller on login, stop on logout
                if self.isAuthenticated() {
                    if self.notificationPoller == nil {
                        self.startNotificationPoller()
                    }
                } else {
                    self.notificationPoller?.stop()
                    self.notificationPoller = nil
                }
            }
        }
    }

    private func startNotificationPoller() {
        guard isAuthenticated() else { return }
        let poller = NotificationPoller(api: api) { [weak self] in
            self?.currentUsername()
        }
        poller.start()
        notificationPoller = poller

        // Pass poller to tab bar so MeViewController can read counts
        if let tabBarVC = children.first as? ForumTabBarController {
            tabBarVC.notificationPoller = poller
        }

        // Observe total unread count to update tab badge
        observeUnreadBadge()
    }

    private func observeUnreadBadge() {
        guard let poller = notificationPoller else { return }
        withPerceptionTracking {
            _ = poller.hasAnyUnread
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let tabBarVC = self.children.first as? ForumTabBarController else { return }
                // Red dot: empty string shows dot without number
                let badge: String? = poller.hasAnyUnread ? "" : nil
                if #available(iOS 18.0, *) {
                    guard tabBarVC.tabs.count > 1 else { return }
                    tabBarVC.tabs[1].badgeValue = badge
                } else {
                    tabBarVC.viewControllers?[1].tabBarItem.badgeValue = badge
                }
                self.observeUnreadBadge()
            }
        }
    }

    private func setupTabBar() {
        let tabBarVC = ForumTabBarController(api: api, authGate: self)
        addChild(tabBarVC)
        view.addSubview(tabBarVC.view)
        tabBarVC.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            tabBarVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            tabBarVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBarVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBarVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground() // 磨砂
        tabBarVC.tabBar.standardAppearance = appearance
        tabBarVC.tabBar.scrollEdgeAppearance = appearance // 强制覆盖，不让系统自动切换
        tabBarVC.tabBar.tintColor = ThemeManager.shared.accentColor

        tabBarVC.didMove(toParent: self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateTabBarTheme),
            name: ThemeManager.themeDidChangeNotification,
            object: nil
        )
    }

    @objc private func updateTabBarTheme() {
        guard let tabBarVC = children.first as? ForumTabBarController else { return }
        tabBarVC.tabBar.tintColor = ThemeManager.shared.accentColor
    }

    private func configureNavItems() {
        guard let tabBarVC = children.first as? ForumTabBarController else { return }

        let titles = [
            String(localized: "tab.home"),
            String(localized: "tab.me"),
        ]

        for (i, nav) in tabBarVC.navigationControllers.enumerated() {
            guard let rootVC = nav.viewControllers.first else { continue }
            if i < titles.count {
                rootVC.title = titles[i]
            }
            let minimizeItem = UIBarButtonItem(
                image: UIImage(systemName: "smallcircle.filled.circle"),
                style: .plain,
                target: self,
                action: #selector(dismissButtonTapped)
            )
            minimizeItem.accessibilityLabel = String(localized: "forum.minimize.accessibility.label")
            minimizeItem.accessibilityHint = String(localized: "forum.minimize.accessibility.hint")
            let rightItems = [
                minimizeItem,
//                UIBarButtonItem(
//                    image: UIImage(systemName: "ellipsis"),
//                    style: .plain,
//                    target: self,
//                    action: #selector(menuButtonTapped)
//                ),
            ]

            // On iOS 17, add search button to Home tab (iOS 18+ uses UISearchTab)
//            if #unavailable(iOS 18.0), i == 0 {
//                rightItems.append(
//                    UIBarButtonItem(
//                        image: UIImage(systemName: "magnifyingglass"),
//                        style: .plain,
//                        target: self,
//                        action: #selector(searchButtonTapped)
//                    )
//                )
//            }

            rootVC.navigationItem.rightBarButtonItems = rightItems
        }
    }

    // MARK: - Actions

    @objc private func menuButtonTapped() {
        let baseURL = forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        if authManager.isAuthenticated(for: baseURL) {
            if let username = authManager.username(for: baseURL) {
                alert.title = "@\(username)"
            }
            alert.addAction(UIAlertAction(title: "Log Out", style: .destructive) { [weak self] _ in
                self?.performLogout()
            })
        } else {
            alert.addAction(UIAlertAction(title: "Log In", style: .default) { [weak self] _ in
                self?.performLogin()
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func dismissButtonTapped() {
        ForumOverlayManager.shared.minimize()
    }

    @objc private func searchButtonTapped() {
        let searchVC = SearchViewController(api: api)
        let searchNav = UINavigationController(rootViewController: searchVC)
        present(searchNav, animated: true)
    }

    // MARK: - Auth Actions

    private func performLogin() {
        Task {
            do {
                try await authManager.login(forum: forum, presentationAnchor: view.window!)
                completeSuccessfulLogin()
            } catch AuthError.cancelled {
                // The user intentionally closed the system auth sheet.
            } catch {
                presentLoginFailure()
            }
        }
    }

    func performLogout() {
        let coordinator = PushSubscriptionCoordinator(api: api)
        if let username = authManager.username(for: forum.baseURL) ?? forum.username {
            if coordinator.hasSubscription(username: username) {
                Task {
                    await coordinator.disableForLogout(username: username)
                    self.finishLogout()
                }
                return
            }
        }
        coordinator.retireLocalSubscriptions()
        finishLogout()
    }

    private func finishLogout() {
        hasPendingPostLoginPushPrompt = false
        pendingPushRegistrationError = nil
        authManager.logout(forum: forum)
        refreshForumFromDatabase()
    }

    private func refreshForumFromDatabase() {
        if let forums = try? DatabaseManager.shared.fetchAllForums(),
           let updated = forums.first(where: { $0.id == forum.id })
        {
            forum = updated
        }
    }

    private func completeSuccessfulLogin(then action: (() -> Void)? = nil) {
        refreshForumFromDatabase()
        action?()

        guard let username = currentUsername() ?? forum.username,
              !username.isEmpty
        else { return }

        let coordinator = PushSubscriptionCoordinator(api: api)
        guard !coordinator.isEnabled(username: username) else { return }
        hasPendingPostLoginPushPrompt = true
        schedulePendingAlertPresentation()
    }

    // MARK: - AuthGating

    func requireAuth(then action: @escaping () -> Void) {
        let baseURL = forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if authManager.isAuthenticated(for: baseURL) {
            action()
            return
        }

        let alert = UIAlertController(
            title: String(localized: "login.required.title"),
            message: String(localized: "login.required.message"),
            preferredStyle: .alert
        )
        // Option 1: Discourse User API Key (RSA) login
        alert.addAction(UIAlertAction(title: String(localized: "login.method.api_key"), style: .default) { [weak self] _ in
            guard let self else { return }
            Task {
                do {
                    try await self.authManager.login(forum: self.forum, presentationAnchor: self.view.window!)
                    self.completeSuccessfulLogin(then: action)
                } catch AuthError.cancelled {
                    // Keep the auth gate closed without showing an error for
                    // an intentional cancellation.
                } catch {
                    self.presentLoginFailure()
                }
            }
        })
        // Option 2: Web login (WKWebView, handles Cloudflare-protected forums)
        alert.addAction(UIAlertAction(title: String(localized: "login.method.web"), style: .default) { [weak self] _ in
            guard let self else { return }
            self.presentWebLogin(then: action)
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func presentWebLogin(then action: @escaping () -> Void) {
        guard let url = URL(string: forum.baseURL + "/login") else { return }
        let vc = WebLoginViewController(targetURL: url) { [weak self] cookies, userAgent in
            guard let self else { return }
            Task {
                do {
                    try await self.authManager.loginViaWeb(forum: self.forum, cookies: cookies, userAgent: userAgent)
                    self.completeSuccessfulLogin(then: action)
                } catch {
                    self.presentLoginFailure()
                }
            }
        }
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    private func presentLoginFailure() {
        let alert = UIAlertController(
            title: String(localized: "login.failed.title"),
            message: String(localized: "login.failed.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
        present(alert, animated: true)
    }

    func isAuthenticated() -> Bool {
        let baseURL = forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return authManager.isAuthenticated(for: baseURL)
    }

    func currentUsername() -> String? {
        let baseURL = forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return authManager.username(for: baseURL)
    }
}
