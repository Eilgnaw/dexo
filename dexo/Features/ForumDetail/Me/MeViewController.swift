import UIKit

final class MeViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let viewModel: MeViewModel
    private weak var authGate: AuthGating?
    private var notificationPoller: NotificationPoller? {
        (tabBarController as? ForumTabBarController)?.notificationPoller
    }

    private let accentBackdrop = UIView()
    private let profileHeader = ProfileHeaderView()
    private let menu = MeMenuView()
    private let skeletonView = MeSkeletonView()
    private let scrollView = UIScrollView()
    private let content = UIStackView()
    private let refreshControl = UIRefreshControl()
    private let navigationTitleLabel = UILabel()
    private lazy var navigationTitleContainer = UIStackView(arrangedSubviews: [navigationTitleLabel])
    private let navigationLoadingIndicator = UIActivityIndicatorView(style: .medium)
    private lazy var loadingBarItem = UIBarButtonItem(customView: navigationLoadingIndicator)
    private var profileLoadTask: Task<Void, Never>?
    private var profileLoadGeneration = 0
    private var minimumContentHeight: NSLayoutConstraint!
    private var skeletonTop: NSLayoutConstraint!
    private var restingTopInset: CGFloat = 0
    private var hasConfiguredInsets = false
    private var isUpdatingInsets = false
    private var isOnScreen = false
    private var navigationProgress: CGFloat = 0

    override var backgroundStyle: BackgroundStyle { .grouped }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        let background = navigationBackdropColor
        let foreground = ProfileHeaderPalette(accent: background, background: background)
            .foreground.resolvedColor(with: traitCollection)
        return foreground == .white ? .lightContent : .darkContent
    }

    private var navigationBackdropColor: UIColor {
        let palette = profileHeader.pagePalette
        return palette.background.resolvedColor(with: traitCollection).blended(
            into: palette.header.background.resolvedColor(with: traitCollection),
            ratio: navigationProgress
        )
    }

    private var navigationForeground: UIColor {
        let background = navigationBackdropColor
        return ProfileHeaderPalette(accent: background, background: background)
            .foreground.resolvedColor(with: traitCollection)
    }

    init(api: DiscourseAPI, authGate: AuthGating? = nil, viewModel: MeViewModel? = nil) {
        self.api = api
        self.viewModel = viewModel ?? MeViewModel(api: api)
        self.authGate = authGate
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "tab.me")
        navigationItem.largeTitleDisplayMode = .never
        navigationTitleLabel.text = title
        navigationTitleLabel.accessibilityTraits = .header
        navigationTitleLabel.accessibilityIdentifier = "me.navigation.title"
        navigationTitleLabel.adjustsFontSizeToFitWidth = true
        navigationTitleLabel.minimumScaleFactor = 0.8
        navigationItem.titleView = navigationTitleContainer
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        scrollView.refreshControl = refreshControl
        scrollView.accessibilityIdentifier = "me.scroll"
        refreshControl.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        content.axis = .vertical
        content.addArrangedSubview(profileHeader)
        content.addArrangedSubview(menu)
        profileHeader.setContentHuggingPriority(.required, for: .vertical)

        view.addSubview(accentBackdrop)
        view.addSubview(scrollView)
        scrollView.addSubview(content)
        view.addSubview(skeletonView)
        for subview in [accentBackdrop, scrollView, content, skeletonView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        minimumContentHeight = content.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor)
        skeletonTop = skeletonView.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            accentBackdrop.topAnchor.constraint(equalTo: view.topAnchor),
            accentBackdrop.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            accentBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            accentBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            minimumContentHeight,
            skeletonTop,
            skeletonView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            skeletonView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            skeletonView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        skeletonView.setLoading(false)
        navigationLoadingIndicator.accessibilityLabel = String(localized: "me.loading_profile")

        profileHeader.onStatTapped = { [weak self] in self?.handleStatTapped($0) }
        profileHeader.onMessageTapped = { [weak self] in self?.handleAction(.messages) }
        profileHeader.onAppearanceChanged = { [weak self] in self?.updateUI() }
        menu.onAction = { [weak self] in self?.handleAction($0) }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(authDidChange(_:)),
            name: .discourseAuthDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(readTimingsSettingDidChange),
            name: .linuxDoReadTimingsSettingDidChange,
            object: nil
        )
        applySurfaceTheme()
        loadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        isOnScreen = true
        super.viewWillAppear(animated)
        applySurfaceTheme()
        updateScrollPresentation(force: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateScrollPresentation(force: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        isOnScreen = false
        super.viewWillDisappear(animated)
        guard let bar = navigationController?.navigationBar else { return }
        bar.isUserInteractionEnabled = true
        let restore = {
            bar.alpha = 1
            bar.transform = .identity
            bar.tintColor = ThemeManager.shared.accentColor
        }
        if let transitionCoordinator {
            transitionCoordinator.animate(alongsideTransition: { _ in restore() })
        } else {
            restore()
        }
    }

    override func updateUI() {
        // Read all state before branching, including both badges and appearance.
        // Otherwise an initially hidden branch can miss later Perception updates.
        let isLoading = viewModel.isLoading || profileLoadTask != nil
        let errorMessage = viewModel.errorMessage
        let user = viewModel.currentUser
        let profile = viewModel.userProfile
        let summary = viewModel.summary
        let unreadNotifications = notificationPoller?.hasUnreadNotifications ?? false
        let unreadMessages = notificationPoller?.hasUnreadMessages ?? false
        _ = AppSettings.shared.localBlocklistRevision
        let readTimingsStatus = ForumPolicy.readTimingReportingStatus(baseURL: api.baseURL)
        _ = ThemeManager.shared.revision
        _ = FontManager.shared.revision
        let isAuthenticated = authGate?.isAuthenticated() ?? false
        let username = isAuthenticated ? AuthManager.shared.username(for: api.baseURL) : nil

        profileHeader.configure(
            user: isAuthenticated ? user : nil,
            profile: isAuthenticated ? profile : nil,
            summary: isAuthenticated ? summary : nil,
            isAuthenticated: isAuthenticated,
            fallbackUsername: username,
            assetBaseURL: api.assetBaseURL,
            unreadMessages: unreadMessages
        )
        applySurfaceTheme()
        menu.configure(
            isAuthenticated: isAuthenticated,
            showsFollowing: api.isLinuxDo,
            showsChallenge: isAuthenticated && api.isLinuxDo
                && KeychainHelper.getUserApiKey(for: api.baseURL) == AuthManager.webAuthSentinel,
            showsConnect: api.isLinuxDo,
            showsReadTimings: api.isLinuxDo,
            readTimingsStatus: readTimingsStatus,
            blockedCount: AppSettings.shared.localBlockedUsers(for: api.baseURL).count,
            unreadNotifications: unreadNotifications,
            palette: profileHeader.pagePalette
        )

        let showsSkeleton = isAuthenticated && isLoading && user == nil
        skeletonView.setLoading(showsSkeleton)
        scrollView.isHidden = showsSkeleton
        let showsRefreshIndicator = isAuthenticated && isLoading && user != nil
        navigationItem.leftBarButtonItem = showsRefreshIndicator ? loadingBarItem : nil
        if showsRefreshIndicator {
            navigationLoadingIndicator.startAnimating()
        } else {
            navigationLoadingIndicator.stopAnimating()
        }
        updateScrollPresentation(force: true)
        view.setNeedsLayout()

        if let errorMessage, presentedViewController == nil {
            let alert = UIAlertController(title: nil, message: errorMessage, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
            present(alert, animated: true)
            // Never mutate tracked state from inside the observation read scope.
            DispatchQueue.main.async { [weak self] in self?.viewModel.errorMessage = nil }
        }
    }

    private func applySurfaceTheme() {
        let palette = profileHeader.pagePalette
        view.backgroundColor = palette.background
        accentBackdrop.backgroundColor = navigationBackdropColor
        refreshControl.tintColor = palette.header.foreground
        navigationLoadingIndicator.color = navigationForeground
        skeletonView.configureTheme()
        // Resolve against the page, not the bar's adaptive scroll-edge traits:
        // UIKit can otherwise leave a white title on the light collapsed bar.
        navigationTitleLabel.font = FontManager.shared.font(size: 17, weight: .semibold)
        navigationTitleLabel.textColor = navigationForeground
        navigationTitleLabel.sizeToFit()

        applyNavigationAppearance()
        setNeedsStatusBarAppearanceUpdate()
        navigationController?.setNeedsStatusBarAppearanceUpdate()
    }

    private func applyNavigationAppearance() {
        let palette = profileHeader.pagePalette
        // Fade the surface, not the buttons supplied by the forum container.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = palette.background.withAlphaComponent(navigationProgress)
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: navigationForeground]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
        navigationItem.compactScrollEdgeAppearance = appearance
        navigationItem.rightBarButtonItems?.forEach { $0.tintColor = navigationForeground }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection), isViewLoaded {
            applySurfaceTheme()
            updateScrollPresentation(force: true)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        isUpdatingInsets = true
        let top = (view.window?.safeAreaInsets.top ?? 0) + (navigationController?.navigationBar.bounds.height ?? 44)
        let bottom = view.safeAreaInsets.bottom
        let distance = scrollView.contentOffset.y + restingTopInset
        var insets = scrollView.contentInset
        if !hasConfiguredInsets {
            insets.top = top
        } else {
            // Preserve any temporary extra inset owned by UIRefreshControl.
            insets.top += top - restingTopInset
        }
        insets.bottom = bottom
        if scrollView.contentInset != insets { scrollView.contentInset = insets }
        if !hasConfiguredInsets || top != restingTopInset {
            scrollView.contentOffset.y = hasConfiguredInsets ? distance - top : -top
        }
        restingTopInset = top
        hasConfiguredInsets = true
        skeletonTop.constant = top
        // Even a short list has enough scroll range to move the personal card
        // out of the way and leave the first list row below the ordinary bar.
        let collapseRange = max(profileHeader.avatarHeight + 1, profileHeader.bounds.height)
        let minimum = -top - bottom + collapseRange
        if minimumContentHeight.constant != minimum { minimumContentHeight.constant = minimum }
        isUpdatingInsets = false
        updateScrollPresentation()
    }

    private func updateScrollPresentation(force: Bool = false) {
        guard !isUpdatingInsets else { return }
        let geometry = MeHeaderScrollGeometry(
            contentOffsetY: scrollView.contentOffset.y, topInset: restingTopInset,
            avatarHeight: profileHeader.avatarHeight
        )
        profileHeader.updateBackdrop(topInset: restingTopInset, pullDistance: geometry.pullDistance)
        let progress = skeletonView.isHidden ? geometry.navigationProgress : 0
        profileHeader.setLoading(false) // The navigation loading indicator is now always visible.
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(
            top: restingTopInset,
            left: 0, bottom: view.safeAreaInsets.bottom, right: 0
        )
        guard isOnScreen, navigationController?.topViewController === self,
              let bar = navigationController?.navigationBar else { return }
        // UIKit may reset bar visibility while rebuilding its appearance.
        let needsAppearance = force || progress != navigationProgress
        guard needsAppearance || bar.alpha != 1 || navigationTitleLabel.alpha != progress
                || bar.transform != .identity else { return }
        let previousStatusBarStyle = preferredStatusBarStyle
        navigationProgress = progress
        if needsAppearance { applyNavigationAppearance() }
        bar.isUserInteractionEnabled = true
        // Apply the finger's current progress directly. Queuing a timed animation
        // on every scroll event would make the bar lag behind or jump on reversal.
        UIView.performWithoutAnimation {
            bar.alpha = 1
            bar.transform = .identity
            bar.tintColor = navigationForeground
            navigationTitleLabel.textColor = navigationForeground
            navigationTitleLabel.alpha = progress
            navigationLoadingIndicator.color = navigationForeground
            accentBackdrop.backgroundColor = navigationBackdropColor
        }
        if force || preferredStatusBarStyle != previousStatusBarStyle {
            setNeedsStatusBarAppearanceUpdate()
            navigationController?.setNeedsStatusBarAppearanceUpdate()
        }
    }

    private func loadData(forceRefresh: Bool = false) {
        guard authGate?.isAuthenticated() == true, profileLoadTask == nil, !viewModel.isLoading else { return }
        profileLoadGeneration += 1
        let generation = profileLoadGeneration
        let model = viewModel
        profileLoadTask = Task { [weak self] in
            if forceRefresh {
                await model.reload()
            } else {
                await model.loadProfile()
            }
            guard let self, self.profileLoadGeneration == generation else { return }
            self.profileLoadTask = nil
            self.refreshControl.endRefreshing()
            self.updateUI()
        }
        // Show feedback before the async request gets its first main-actor turn.
        updateUI()
    }

    @objc private func authDidChange(_ notification: Notification) {
        let changedURL = (notification.userInfo?["baseURL"] as? String)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard changedURL == api.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { return }
        scrollView.setContentOffset(CGPoint(x: 0, y: -restingTopInset), animated: false)
        if authGate?.isAuthenticated() == true {
            loadData(forceRefresh: true)
        } else {
            profileLoadGeneration += 1
            profileLoadTask?.cancel()
            profileLoadTask = nil
            viewModel.clearCachedProfile()
            viewModel.requiresLogin = true
            refreshControl.endRefreshing()
        }
        updateUI()
    }

    @objc private func readTimingsSettingDidChange() {
        updateUI()
    }

    @objc private func pullToRefresh() {
        guard authGate?.isAuthenticated() == true else {
            refreshControl.endRefreshing()
            return
        }
        loadData(forceRefresh: true)
    }

    private func handleAction(_ action: MeMenuView.Action) {
        switch action {
        case .login:
            authGate?.requireAuth { [weak self] in self?.loadData(forceRefresh: true) }
        case .logout:
            logoutTapped()
        default:
            authGate?.requireAuth { [weak self] in self?.openDestination(action) }
        }
    }

    private func openDestination(_ action: MeMenuView.Action) {
        let username = viewModel.currentUser?.username ?? AuthManager.shared.username(for: api.baseURL)
        let destination: UIViewController
        switch action {
        case .messages:
            guard let authGate else { return }
            notificationPoller?.clearMessages()
            destination = MessagesViewController(api: api, authGate: authGate)
        case .notifications:
            notificationPoller?.clearNotifications()
            destination = NotificationsViewController(api: api, authGate: authGate)
        case .bookmarks:
            guard let username else { return }
            destination = BookmarksViewController(api: api, username: username)
        case .read:
            destination = ReadTopicsViewController(api: api)
        case .following:
            guard let username else { return }
            destination = FollowedUsersViewController(api: api, currentUsername: username)
        case .connect:
            guard api.isLinuxDo else { return }
            presentForumWebView(
                ForumWebViewController.SessionScope.connectURL,
                forumBaseURL: api.baseURL,
                sessionScope: .linuxDoConnect
            )
            return
        case .localBlocklist:
            destination = LocalBlocklistViewController(baseURL: api.baseURL)
        case .pushNotifications:
            guard let username else { return }
            destination = PushNotificationSettingsViewController(api: api, username: username)
        case .readTimings:
            destination = LinuxDoReadTimingSettingsViewController()
        case .challenge:
            ChallengeViewController.present(from: self)
            return
        case .login, .logout:
            return
        }
        navigationController?.pushViewController(destination, animated: true)
    }

    private func logoutTapped() {
        let alert = UIAlertController(
            title: String(localized: "me.logout.confirm.title"),
            message: String(localized: "me.logout.confirm.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "me.logout"), style: .destructive) { [weak self] _ in
            self?.authGate?.performLogout()
        })
        alert.addAction(UIAlertAction(title: String(localized: "cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func handleStatTapped(_ stat: ProfileHeaderView.StatType) {
        guard let username = viewModel.currentUser?.username else { return }
        switch stat {
        case .topics:
            navigationController?.pushViewController(UserPostsViewController(api: api, username: username, filter: .topics), animated: true)
        case .posts:
            navigationController?.pushViewController(UserPostsViewController(api: api, username: username, filter: .posts), animated: true)
        case .likes, .days:
            break
        }
    }

}

extension MeViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateScrollPresentation()
    }
}
