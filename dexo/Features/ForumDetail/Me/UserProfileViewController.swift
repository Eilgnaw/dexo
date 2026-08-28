import UIKit

final class UserProfileViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let viewModel: UserProfileViewModel
    private let profileHeader = ProfileHeaderView()
    private let menu = UserProfileMenuView()
    private let skeleton = MeSkeletonView()
    private let scrollView = UIScrollView()
    private let content = UIStackView()
    private let topBackdrop = UIView()
    private let refreshControl = UIRefreshControl()
    private let navigationTitle = UILabel()
    // UIKit owns the outer title view's alpha during navigation transitions.
    // Fade only its label so that scroll-driven opacity cannot be overwritten.
    private lazy var navigationTitleContainer = UIStackView(arrangedSubviews: [navigationTitle])
    private var loadTask: Task<Void, Never>?
    private var minimumContentHeight: NSLayoutConstraint!
    private var skeletonTop: NSLayoutConstraint!
    private var topInset: CGFloat = 0
    private var hasConfiguredInsets = false
    private var isUpdatingInsets = false
    private var isOnScreen = false
    private var navigationProgress: CGFloat = 0
    private let messagePrefillTitle: String?
    private let messagePrefillBody: String?

    override var backgroundStyle: BackgroundStyle { .grouped }

    private var navigationSurface: UIColor {
        let palette = profileHeader.pagePalette
        return palette.background.resolvedColor(with: traitCollection).blended(
            into: palette.header.background.resolvedColor(with: traitCollection), ratio: navigationProgress
        )
    }

    private var navigationForeground: UIColor {
        let background = navigationSurface
        return ProfileHeaderPalette(accent: background, background: background)
            .foreground.resolvedColor(with: traitCollection)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        navigationForeground == .white ? .lightContent : .darkContent
    }

    init(
        api: DiscourseAPI, username: String,
        messagePrefillTitle: String? = nil, messagePrefillBody: String? = nil,
        viewModel: UserProfileViewModel? = nil
    ) {
        self.api = api
        self.viewModel = viewModel ?? UserProfileViewModel(api: api, username: username)
        self.messagePrefillTitle = messagePrefillTitle
        self.messagePrefillBody = messagePrefillBody
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = viewModel.username
        navigationItem.largeTitleDisplayMode = .never
        navigationTitle.accessibilityIdentifier = "user.navigation.title"
        navigationTitle.accessibilityTraits = .header
        navigationItem.titleView = navigationTitleContainer
        scrollView.accessibilityIdentifier = "user.profile.scroll"
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        scrollView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(refreshProfile), for: .valueChanged)
        content.axis = .vertical
        content.addArrangedSubview(profileHeader)
        content.addArrangedSubview(menu)
        profileHeader.setContentHuggingPriority(.required, for: .vertical)
        view.addSubview(topBackdrop)
        view.addSubview(scrollView)
        scrollView.addSubview(content)
        view.addSubview(skeleton)
        for subview in [topBackdrop, scrollView, content, skeleton] { subview.translatesAutoresizingMaskIntoConstraints = false }
        minimumContentHeight = content.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor)
        skeletonTop = skeleton.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            topBackdrop.topAnchor.constraint(equalTo: view.topAnchor),
            topBackdrop.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            minimumContentHeight, skeletonTop,
            skeleton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            skeleton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        profileHeader.onAppearanceChanged = { [weak self] in self?.updateUI() }
        profileHeader.onStatTapped = { [weak self] in self?.handleStatTapped($0) }
        profileHeader.onMessageTapped = { [weak self] in self?.handleMessageTapped() }
        menu.onAction = { [weak self] action in
            switch action {
            case .follow: self?.handleFollowTapped()
            case .localBlock: self?.handleLocalBlockTapped()
            case .topics: self?.handleStatTapped(.topics)
            case .posts: self?.handleStatTapped(.posts)
            case .retry: self?.loadData()
            }
        }
        loadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        isOnScreen = true
        super.viewWillAppear(animated)
        updateNavigation(force: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateNavigation(force: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        isOnScreen = false
        super.viewWillDisappear(animated)
        guard let bar = navigationController?.navigationBar else { return }
        let restore = {
            bar.alpha = 1
            bar.transform = .identity
            bar.isUserInteractionEnabled = true
            bar.tintColor = ThemeManager.shared.accentColor
        }
        if let transitionCoordinator {
            transitionCoordinator.animate(alongsideTransition: { _ in restore() })
        } else {
            restore()
        }
    }

    override func updateUI() {
        let profile = viewModel.userProfile
        let summary = viewModel.summary
        let isLoading = viewModel.isLoading || loadTask != nil
        let isOwnProfile = viewModel.isOwnProfile
        let showsFollow = viewModel.showsFollowButton
        let isFollowing = viewModel.isFollowing
        let isFollowLoading = viewModel.isUpdatingFollow
        let showsLocalBlock = viewModel.showsLocalBlockButton
        let isLocallyBlocked = viewModel.isLocallyBlocked
        let errorMessage = viewModel.errorMessage
        _ = ThemeManager.shared.revision
        _ = FontManager.shared.revision

        profileHeader.configure(
            user: nil, profile: profile, summary: summary, isAuthenticated: true,
            fallbackUsername: profile?.username ?? viewModel.username, assetBaseURL: api.assetBaseURL,
            messageAction: isOwnProfile ? .inbox : .compose, showsMessageButton: profile != nil
        )
        profileHeader.setLoading(isLoading && profile != nil)
        menu.configure(
            hasProfile: profile != nil, showsFollow: showsFollow, isFollowing: isFollowing,
            isFollowLoading: isFollowLoading, showsLocalBlock: showsLocalBlock,
            isLocallyBlocked: isLocallyBlocked, errorMessage: errorMessage, palette: profileHeader.pagePalette
        )
        let showsSkeleton = isLoading && profile == nil
        skeleton.configureTheme()
        skeleton.setLoading(showsSkeleton)
        scrollView.isHidden = showsSkeleton
        view.backgroundColor = profileHeader.pagePalette.background
        refreshControl.tintColor = profileHeader.pagePalette.header.foreground
        navigationTitle.text = profile?.name?.isEmpty == false ? profile?.name : viewModel.username
        navigationTitle.font = FontManager.shared.font(size: 17, weight: .semibold)
        navigationTitle.sizeToFit()
        updateNavigation(force: true)
        view.setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded, traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) { updateUI() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        isUpdatingInsets = true
        // Keep identity below the always-available back button; only the photo
        // extends behind the transparent navigation and status bars.
        let top = (view.window?.safeAreaInsets.top ?? 0) + (navigationController?.navigationBar.bounds.height ?? 44)
        let bottom = view.safeAreaInsets.bottom
        let distance = scrollView.contentOffset.y + topInset
        var insets = scrollView.contentInset
        insets.top = hasConfiguredInsets ? insets.top + top - topInset : top
        insets.bottom = bottom
        if insets != scrollView.contentInset { scrollView.contentInset = insets }
        if !hasConfiguredInsets || top != topInset {
            scrollView.contentOffset.y = hasConfiguredInsets ? distance - top : -top
        }
        topInset = top
        hasConfiguredInsets = true
        skeletonTop.constant = top
        let minimum = -top - bottom + max(profileHeader.avatarHeight, profileHeader.bounds.height)
        if minimumContentHeight.constant != minimum { minimumContentHeight.constant = minimum }
        isUpdatingInsets = false
        updateNavigation()
    }

    private func updateNavigation(force: Bool = false) {
        guard !isUpdatingInsets else { return }
        let geometry = MeHeaderScrollGeometry(contentOffsetY: scrollView.contentOffset.y, topInset: topInset, avatarHeight: profileHeader.avatarHeight)
        profileHeader.updateBackdrop(topInset: topInset, pullDistance: geometry.pullDistance)
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: topInset, left: 0, bottom: view.safeAreaInsets.bottom, right: 0)
        guard isOnScreen, navigationController?.topViewController === self, let bar = navigationController?.navigationBar else { return }
        let progress = skeleton.isHidden ? geometry.navigationProgress : 0
        let needsAppearance = force || progress != navigationProgress
        guard needsAppearance || bar.alpha != 1 || navigationTitle.alpha != progress else { return }
        let previousStyle = preferredStatusBarStyle
        navigationProgress = progress
        let palette = profileHeader.pagePalette
        if needsAppearance {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = palette.background.withAlphaComponent(progress)
            appearance.shadowColor = .clear
            appearance.titleTextAttributes = [.foregroundColor: navigationForeground]
            navigationItem.standardAppearance = appearance
            navigationItem.scrollEdgeAppearance = appearance
            navigationItem.compactAppearance = appearance
            navigationItem.compactScrollEdgeAppearance = appearance
        }
        UIView.performWithoutAnimation {
            // Never fade the entire bar on a pushed profile: back must remain usable.
            bar.alpha = 1
            bar.transform = .identity
            bar.isUserInteractionEnabled = true
            bar.tintColor = navigationForeground
            navigationTitle.textColor = navigationForeground
            navigationTitle.alpha = progress
            topBackdrop.backgroundColor = navigationSurface
        }
        if force || preferredStatusBarStyle != previousStyle {
            setNeedsStatusBarAppearanceUpdate()
            navigationController?.setNeedsStatusBarAppearanceUpdate()
        }
    }

    @objc private func refreshProfile() { loadData() }

    private func loadData() {
        guard loadTask == nil, !viewModel.isLoading else { return }
        let model = viewModel
        loadTask = Task { [weak self] in
            await model.load()
            guard let self else { return }
            self.loadTask = nil
            self.refreshControl.endRefreshing()
            self.updateUI()
        }
        updateUI()
    }

    private func handleMessageTapped() {
        if viewModel.isOwnProfile {
            guard let authGate = findAuthGating() else { return }
            authGate.requireAuth { [weak self] in
                guard let self else { return }
                let vc = MessagesViewController(api: self.api, authGate: authGate)
                self.navigationController?.pushViewController(vc, animated: true)
            }
        } else {
            presentMessageComposer()
        }
    }

    private func findAuthGating() -> AuthGating? {
        var vc: UIViewController? = self
        while let parent = vc?.parent {
            if let gate = parent as? AuthGating { return gate }
            for child in parent.children {
                if let gate = child as? AuthGating { return gate }
                for grandchild in child.children {
                    if let gate = grandchild as? AuthGating { return gate }
                }
            }
            vc = parent
        }
        return nil
    }

    // MARK: - Actions

    private func handleFollowTapped() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.toggleFollow()
            } catch {
                guard !Task.isCancelled else { return }
                let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func handleLocalBlockTapped() {
        guard viewModel.toggleLocalBlock() == .limitReached else { return }
        let alert = UIAlertController(
            title: nil,
            message: String(
                localized: "user.local_blocklist.limit_reached \(AppSettings.maximumLocalBlockedUsers)"
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
        present(alert, animated: true)
    }

    private func presentMessageComposer() {
        let composer = MessageComposerViewController(
            api: api,
            recipients: viewModel.username,
            prefillTitle: messagePrefillTitle,
            prefillBody: messagePrefillBody
        )
        composer.onSent = { [weak self] in
            self?.presentMessageSentConfirmation()
        }
        let nav = UINavigationController(rootViewController: composer)
        present(nav, animated: true)
    }

    private func presentMessageSentConfirmation() {
        let done = UIAlertController(title: nil, message: String(localized: "user.message_sent"), preferredStyle: .alert)
        done.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
        present(done, animated: true)
    }

    // MARK: - Stat Taps

    private func handleStatTapped(_ statType: ProfileHeaderView.StatType) {
        switch statType {
        case .topics:
            let vc = UserPostsViewController(api: api, username: viewModel.username, filter: .topics)
            navigationController?.pushViewController(vc, animated: true)
        case .posts:
            let vc = UserPostsViewController(api: api, username: viewModel.username, filter: .posts)
            navigationController?.pushViewController(vc, animated: true)
        case .likes, .days:
            break
        }
    }
}

extension UserProfileViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateNavigation() }
}
