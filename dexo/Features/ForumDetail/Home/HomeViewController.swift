import UIKit

final class HomeViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let viewModel: HomeViewModel
    private weak var authGate: AuthGating?
    private var locallyReadTopicIDs: Set<Int> = []
    private var didPresentChallengeForCurrentFailure = false

    private lazy var sortBarButton: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "arrow.up.arrow.down"),
            menu: nil
        )
        item.accessibilityLabel = String(localized: "home.sort.accessibility.label")
        return item
    }()

    /// Right bar button items injected by the container (e.g. minimize button), captured before we add our own.
    private var inheritedRightBarItems: [UIBarButtonItem] = []

    private let categoryButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = String(localized: "home.filter.all_categories")
        config.image = UIImage(systemName: "line.3.horizontal.decrease", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13))
        config.imagePlacement = .leading
        config.imagePadding = 6
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = FontManager.shared.font(size: 15, weight: .medium)
            return a
        }
        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        return button
    }()

    private lazy var tableView: UITableView = {
        let tv = ThemedTableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(TopicCell.self, forCellReuseIdentifier: TopicCell.reuseIdentifier)
        tv.delegate = self
        tv.showsVerticalScrollIndicator = false

        return tv
    }()

    private let pinnedBar = PinnedTopicBar()

    private let emptyHeaderPlaceholder = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))

    /// Cache hex→UIColor conversions to avoid repeated string parsing.
    private var categoryColorCache: [String: UIColor] = [:]

    private lazy var dataSource: UITableViewDiffableDataSource<Int, Int> = .init(tableView: tableView) { [weak self] tableView, indexPath, topicId in
        guard let self,
              let topic = self.viewModel.topicsById[topicId]
        else {
            return UITableViewCell()
        }
        let category = self.viewModel.category(for: topic)
        let categoryColor: UIColor? = category.flatMap { cat in
            let hex = cat.color
            if let cached = self.categoryColorCache[hex] { return cached }
            let color = Self.color(fromHex: hex)
            if let color { self.categoryColorCache[hex] = color }
            return color
        }

        guard let cell = tableView.dequeueReusableCell(withIdentifier: TopicCell.reuseIdentifier, for: indexPath) as? TopicCell else {
            return UITableViewCell()
        }
        let assetBaseURL = self.api.assetBaseURL
        var avatarURL: URL?
        if let template = self.viewModel.avatarTemplate(for: topic) {
            let sized = template.replacingOccurrences(of: "{size}", with: "96")
            let urlString = sized.hasPrefix("http") ? sized : assetBaseURL + sized
            avatarURL = URL(string: urlString)
        }
        cell.configure(
            with: topic,
            avatarURL: avatarURL,
            categoryName: category?.name,
            categoryColor: categoryColor,
            timestampKind: self.viewModel.feedMode.timestampKind,
            isLocallyRead: self.locallyReadTopicIDs.contains(topic.id)
        )
        return cell
    }

    private let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .medium)
        ai.hidesWhenStopped = true
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
    }()

    private let footerSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.frame = CGRect(x: 0, y: 0, width: 0, height: 44)
        return spinner
    }()

    private let errorLabel: UILabel = {
        let label = UILabel()
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    private let loginButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = String(localized: "home.login_prompt")
        config.cornerStyle = .medium
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }()

    private let composeButtonSize: CGFloat = 56
    private let composeButtonEdgeMargin: CGFloat = 20
    private var composeDragDistance: CGFloat = 0

    private lazy var composeButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        button.setImage(UIImage(systemName: "plus", withConfiguration: config), for: .normal)
        button.backgroundColor = ThemeManager.shared.accentColor
        button.tintColor = .white
        button.layer.cornerRadius = 28
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.25
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.layer.shadowRadius = 4
        button.addTarget(self, action: #selector(composeButtonTouchDown), for: .touchDown)
        button.addTarget(self, action: #selector(composeTapped), for: .touchUpInside)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleComposePan(_:)))
        button.addGestureRecognizer(pan)

        return button
    }()

    private lazy var refreshControl: UIRefreshControl = {
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        return rc
    }()

    /// A programmatic scroll-to-top can finish a few points away from UIKit's
    /// latest adjusted top inset while the iOS 26 tab bar expands. Remembering
    /// the first tap makes the second tap's refresh behavior deterministic.
    private var shouldRefreshOnNextHomeTabTap = false

    init(api: DiscourseAPI, authGate: AuthGating? = nil) {
        self.api = api
        self.viewModel = HomeViewModel(api: api)
        self.authGate = authGate
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var hasPlacedComposeButton = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        if !hasPlacedComposeButton {
            hasPlacedComposeButton = true
            let safe = view.safeAreaLayoutGuide.layoutFrame
            composeButton.center = CGPoint(
                x: safe.maxX - composeButtonEdgeMargin - composeButtonSize / 2,
                y: safe.maxY - composeButtonEdgeMargin - composeButtonSize / 2
            )
        }

        if tableView.tableHeaderView === pinnedBar,
           pinnedBar.frame.width != tableView.bounds.width {
            pinnedBar.frame.size.width = tableView.bounds.width
            tableView.tableHeaderView = pinnedBar
        }
    }

    private func installPinnedHeader(items: [PinnedTopicBar.Item]) {
        pinnedBar.setItems(items)
        if items.isEmpty {
            if tableView.tableHeaderView !== emptyHeaderPlaceholder {
                tableView.tableHeaderView = emptyHeaderPlaceholder
            }
        } else {
            pinnedBar.frame = CGRect(
                x: 0,
                y: 0,
                width: tableView.bounds.width,
                height: PinnedTopicBar.height
            )
            if tableView.tableHeaderView !== pinnedBar {
                tableView.tableHeaderView = pinnedBar
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.tableFooterView = footerSpinner
        tableView.refreshControl = refreshControl

        tableView.tableHeaderView = emptyHeaderPlaceholder
        pinnedBar.onSelect = { [weak self] topicId in
            guard let self else { return }
            let detailVC = TopicDetailControllerFactory.make(api: self.api, topicId: topicId)
            self.navigationController?.pushViewController(detailVC, animated: true)
        }
        view.addSubview(tableView)

        view.addSubview(activityIndicator)
        view.addSubview(errorLabel)
        view.addSubview(loginButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            loginButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loginButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 16),
        ])

        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(authDidChange(_:)),
            name: .discourseAuthDidChange,
            object: nil
        )

        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: categoryButton)
        inheritedRightBarItems = navigationItem.rightBarButtonItems ?? []
        navigationItem.rightBarButtonItems = inheritedRightBarItems + [Self.makeRightBarSpacer(), sortBarButton]

        view.addSubview(composeButton)
        composeButton.frame = CGRect(x: 0, y: 0, width: composeButtonSize, height: composeButtonSize)

        Task {
            await viewModel.loadTopics()
        }
        Task {
            await api.loadOrFetchEmojiMap()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadLocalReadState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentChallengePromptIfPossible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        shouldRefreshOnNextHomeTabTap = false
    }

    private func reloadLocalReadState() {
        let ids: Set<Int>
        if let scope = ReadHistoryScope.current(api: api) {
            ids = (try? LocalReadHistoryStore.shared.topicIDs(scope: scope)) ?? []
        } else {
            ids = []
        }
        guard ids != locallyReadTopicIDs else { return }
        locallyReadTopicIDs = ids
        updateUI()
    }

    override func updateUI() {
        _ = AppSettings.shared.localBlocklistRevision
        // Login-required state
        if viewModel.requiresLogin {
            errorLabel.text = viewModel.errorMessage
            errorLabel.isHidden = false
            loginButton.isHidden = false
            tableView.isHidden = true
            navigationItem.rightBarButtonItems = inheritedRightBarItems
            activityIndicator.stopAnimating()
            presentChallengePromptIfPossible()
            return
        }

        loginButton.isHidden = true
        tableView.isHidden = false
        navigationItem.rightBarButtonItems = inheritedRightBarItems + [Self.makeRightBarSpacer(), sortBarButton]
        composeButton.backgroundColor = ThemeManager.shared.accentColor
        categoryButton.menu = UIMenu(title: "", children: buildCategoryMenuElements())
        sortBarButton.menu = buildSortMenu()
        updateCategoryButton()
        // Show non-login errors (e.g. rate limit) when topic list is empty
        if let error = viewModel.errorMessage, viewModel.topics.isEmpty {
            errorLabel.text = error
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        let topics = viewModel.visibleTopics(
            excluding: AppSettings.shared.localBlockedUsernames(for: api.baseURL)
        )
        var seen = Set<Int>()
        var pinnedItems: [PinnedTopicBar.Item] = []
        var regularIds: [Int] = []
        for topic in topics {
            guard seen.insert(topic.id).inserted else { continue }
            if topic.pinned == true {
                let color = viewModel.category(for: topic).flatMap { Self.color(fromHex: $0.color) }
                pinnedItems.append(PinnedTopicBar.Item(
                    topicId: topic.id,
                    title: topic.fancyTitle,
                    iconColor: color,
                    isLocallyRead: locallyReadTopicIDs.contains(topic.id)
                ))
            } else {
                regularIds.append(topic.id)
            }
        }
        snapshot.appendItems(regularIds, toSection: 0)
        let currentIds = Set(dataSource.snapshot().itemIdentifiers)
        let idsToRefresh = regularIds.filter { currentIds.contains($0) }
        if !idsToRefresh.isEmpty {
            snapshot.reconfigureItems(idsToRefresh)
        }
        dataSource.apply(snapshot, animatingDifferences: true)
        installPinnedHeader(items: pinnedItems)

        if viewModel.isLoading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }

        if viewModel.isLoadingMore {
            footerSpinner.startAnimating()
        } else {
            footerSpinner.stopAnimating()
        }

        presentChallengePromptIfPossible()
    }

    private func presentChallengePromptIfPossible() {
        guard viewModel.requiresChallenge else {
            didPresentChallengeForCurrentFailure = false
            return
        }
        guard api.isLinuxDo,
              !didPresentChallengeForCurrentFailure,
              viewIfLoaded?.window != nil,
              presentedViewController == nil
        else { return }

        didPresentChallengeForCurrentFailure = true
        presentChallengePrompt()
    }

    private func buildSortMenu() -> UIMenu {
        let modes: [(TopicFeedMode, String, String)] = [
            (.activity, String(localized: "home.activity"), "clock.arrow.circlepath"),
            (.created, String(localized: "home.created"), "calendar"),
            (.hot, String(localized: "home.hot"), "flame"),
            (.top, String(localized: "home.top"), "chart.bar"),
        ]
        let actions = modes.map { mode, title, symbol -> UIAction in
            let state: UIMenuElement.State = viewModel.feedMode == mode ? .on : .off
            return UIAction(title: title, image: UIImage(systemName: symbol), state: state) { [weak self] _ in
                self?.selectFeedMode(mode)
            }
        }
        return UIMenu(title: "", children: actions)
    }

    private func selectFeedMode(_ mode: TopicFeedMode) {
        guard viewModel.selectFeedMode(mode) else { return }
        sortBarButton.menu = buildSortMenu()
        Task {
            await viewModel.loadTopics()
        }
    }

    @objc private func pullToRefresh() {
        Task {
            await viewModel.loadTopics()
            refreshControl.endRefreshing()
        }
    }

    @objc private func handleComposePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            composeDragDistance = 0
        case .changed:
            composeButton.center = CGPoint(
                x: composeButton.center.x + translation.x,
                y: composeButton.center.y + translation.y
            )
            composeDragDistance += abs(translation.x) + abs(translation.y)
            gesture.setTranslation(.zero, in: view)
        case .ended, .cancelled:
            snapComposeButtonToEdge(velocity: gesture.velocity(in: view))
        default:
            break
        }
    }

    private func snapComposeButtonToEdge(velocity: CGPoint) {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let margin = composeButtonEdgeMargin
        let half = composeButtonSize / 2
        let center = composeButton.center

        // Determine left or right based on position + velocity bias
        let goRight: Bool
        if abs(velocity.x) > 200 {
            goRight = velocity.x > 0
        } else {
            goRight = center.x > view.bounds.midX
        }

        let targetX = goRight
            ? safe.maxX - margin - half
            : safe.minX + margin + half

        // Clamp Y within safe area
        let targetY = min(max(center.y, safe.minY + half + margin), safe.maxY - half - margin)

        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            usingSpringWithDamping: 0.7,
            initialSpringVelocity: 0.5,
            options: .curveEaseOut
        ) {
            self.composeButton.center = CGPoint(x: targetX, y: targetY)
        }
    }

    @objc private func composeButtonTouchDown() {
        composeDragDistance = 0
    }

    @objc private func composeTapped() {
        guard composeDragDistance < 10 else { return }
        authGate?.requireAuth { [weak self] in
            self?.presentTopicComposer()
        }
    }

    private func presentTopicComposer() {
        let composer = TopicComposerViewController(api: api)
        composer.onTopicCreated = { [weak self] _ in
            Task {
                await self?.viewModel.loadTopics()
            }
        }
        let nav = UINavigationController(rootViewController: composer)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    /// Called when the home tab is re-tapped. Scrolls to top if not already there, otherwise refreshes.
    func scrollToTopOrRefresh() {
        guard !refreshControl.isRefreshing else { return }

        let topOffset = -tableView.adjustedContentInset.top
        let isAtTop = tableView.contentOffset.y <= topOffset + 1
        if isAtTop || shouldRefreshOnNextHomeTabTap {
            shouldRefreshOnNextHomeTabTap = false

            // Correct any small offset left by the tab bar expansion before
            // revealing the refresh control.
            tableView.setContentOffset(CGPoint(x: 0, y: topOffset), animated: false)

            // Already at top — trigger refresh
            refreshControl.beginRefreshing()
            tableView.setContentOffset(CGPoint(x: 0, y: topOffset - refreshControl.frame.height), animated: true)
            pullToRefresh()
        } else {
            shouldRefreshOnNextHomeTabTap = true
            tableView.setContentOffset(CGPoint(x: 0, y: topOffset), animated: true)
        }
    }

    @objc private func loginTapped() {
        // A successful login posts `discourseAuthDidChange`; the observer below
        // performs one complete categories + topics reload with the new
        // credential.
        authGate?.requireAuth {}
    }

    @objc private func authDidChange(_ notification: Notification) {
        guard let changedBaseURL = notification.userInfo?["baseURL"] as? String,
              changedBaseURL == api.baseURL
        else { return }

        Task {
            await viewModel.reloadAfterAuthChange()
        }
    }

    private func updateCategoryButton() {
        let selected = viewModel.selectedCategory()
        let title = selected?.name ?? String(localized: "home.filter.all_categories")
        var config = categoryButton.configuration ?? UIButton.Configuration.plain()
        config.title = title
        if let selected, let color = Self.color(fromHex: selected.color) {
            config.image = UIImage(systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10))
            config.baseForegroundColor = color
        } else {
            config.image = UIImage(systemName: "line.3.horizontal.decrease", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13))
            config.baseForegroundColor = nil
        }
        categoryButton.configuration = config
        categoryButton.sizeToFit()

        categoryButton.accessibilityLabel = String(localized: "home.filter.accessibility.label")
        categoryButton.accessibilityValue = title
        categoryButton.accessibilityHint = String(localized: "home.filter.accessibility.hint")
        categoryButton.accessibilityTraits = [.button]
    }

    private func buildCategoryMenuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = []

        let allAction = UIAction(
            title: String(localized: "home.filter.all_categories"),
            state: viewModel.selectedCategoryId == nil ? .on : .off
        ) { [weak self] _ in
            self?.selectCategory(nil)
        }
        elements.append(allAction)

        for cat in viewModel.categories {
            let state: UIMenuElement.State = viewModel.selectedCategoryId == cat.id ? .on : .off
            let catColor = Self.color(fromHex: cat.color)
            let catImage = Self.colorDotImage(color: catColor)
            let catAction = UIAction(title: cat.name, image: catImage, state: state) { [weak self] _ in
                self?.selectCategory(cat.id)
            }
            if let subs = cat.subcategoryList, !subs.isEmpty {
                var groupChildren: [UIMenuElement] = [catAction]
                for sub in subs {
                    let subState: UIMenuElement.State = viewModel.selectedCategoryId == sub.id ? .on : .off
                    let subColor = Self.color(fromHex: sub.color)
                    let subImage = Self.colorDotImage(color: subColor)
                    let subAction = UIAction(title: sub.name, image: subImage, state: subState) { [weak self] _ in
                        self?.selectCategory(sub.id)
                    }
                    groupChildren.append(subAction)
                }
                elements.append(UIMenu(title: cat.name, image: catImage, children: groupChildren))
            } else {
                elements.append(catAction)
            }
        }
        return elements
    }

    private func selectCategory(_ categoryId: Int?) {
        guard viewModel.selectCategory(categoryId) else { return }
        updateCategoryButton()
        Task {
            await viewModel.loadTopics()
        }
    }

    private static func color(fromHex hex: String) -> UIColor? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func makeRightBarSpacer() -> UIBarButtonItem {
        if #available(iOS 26.0, *) {
            return .fixedSpace()
        }
        let spacer = UIBarButtonItem(barButtonSystemItem: .fixedSpace, target: nil, action: nil)
        spacer.width = 16
        return spacer
    }

    private static func colorDotImage(color: UIColor?) -> UIImage? {
        guard let color else { return nil }
        let size = CGSize(width: 12, height: 12)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysOriginal)
    }
}

extension HomeViewController: UITableViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        shouldRefreshOnNextHomeTabTap = false
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let topicId = dataSource.itemIdentifier(for: indexPath) else { return }
        let detailVC = TopicDetailControllerFactory.make(api: api, topicId: topicId)
        navigationController?.pushViewController(detailVC, animated: true)
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let topicId = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: topicId as NSCopying, previewProvider: { [weak self] in
            guard let self else { return nil }
            return TopicDetailControllerFactory.make(api: self.api, topicId: topicId)
        })
    }

    func tableView(_ tableView: UITableView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: any UIContextMenuInteractionCommitAnimating) {
        guard let detailVC = animator.previewViewController else { return }
        animator.addCompletion { [weak self] in
            self?.navigationController?.pushViewController(detailVC, animated: true)
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let totalRows = tableView.numberOfRows(inSection: 0)
        if indexPath.row >= totalRows - 1 {
            Task {
                await viewModel.loadMoreTopics()
            }
        }
    }
}
