import UIKit

/// Home navigation is categories → topic list → topic detail. The compact
/// column starts at the topic list and opens categories from its navigation bar.
final class ForumHomeSplitViewController: UISplitViewController, UISplitViewControllerDelegate, UINavigationControllerDelegate {
    var onPaneLayout: (() -> Void)?
    override var childForStatusBarStyle: UIViewController? {
        compactLayout ? compactNavigationController : topicNavigationController
    }

    private let api: DiscourseAPI
    private let forum: ForumInstance
    private weak var authGate: AuthGating?
    private let homeViewModel: HomeViewModel
    private lazy var homeViewController = HomeViewController(
        api: api,
        authGate: authGate,
        viewModel: homeViewModel,
        usesCategorySidebar: true
    )
    private(set) lazy var topicNavigationController: UINavigationController = ForumPaneNavigationController()
    private lazy var compactNavigationController = ForumPaneNavigationController()
    private lazy var sidebarViewController = ForumCategorySidebarViewController(forum: forum, viewModel: homeViewModel)
    private lazy var sidebarNavigationController = ForumPaneNavigationController()
    private var topicStack: [UIViewController] = []
    private var compactLayout = false
    private var changingColumns = false
    private var lastPaneFrame: CGRect = .null
    private var lastNavigationFrame: CGRect = .null
    private var lastSinglePanePresentation: Bool?

    // iOS 17 can remain expanded in a compact-width window. Only isCollapsed
    // decides which navigation controller owns the topic stack.
    private var wantsSinglePane: Bool {
        traitCollection.horizontalSizeClass == .compact || hidesCategoriesInPortrait
    }
    private var needsCategoryMenu: Bool { compactLayout || wantsSinglePane }
    var hasPushedHomePage: Bool {
        let navigation = compactLayout ? compactNavigationController : topicNavigationController
        return navigation.viewControllers.count > 1
    }

    private var hidesCategoriesInPortrait: Bool {
        // An unfolded phone can have a regular-width, portrait-shaped window.
        let size = view.bounds.size
        if size.width > 0, size.height > 0 {
            return size.height > size.width
        }
        let windowSize = view.window?.bounds.size
            ?? view.window?.screen.bounds.size
            ?? UIScreen.main.bounds.size
        return windowSize.height > windowSize.width
    }

    init(forum: ForumInstance, api: DiscourseAPI, authGate: AuthGating?) {
        self.forum = forum
        self.api = api
        self.authGate = authGate
        self.homeViewModel = HomeViewModel(api: api)
        super.init(style: .doubleColumn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        preferredSplitBehavior = wantsSinglePane ? .overlay : .tile
        preferredDisplayMode = .oneBesideSecondary
        displayModeButtonVisibility = .never
        primaryBackgroundStyle = .sidebar
        presentsWithGesture = false

        sidebarViewController.onSelectCategory = { [weak self] id in self?.selectCategory(id) }
        sidebarViewController.onMinimize = { ForumOverlayManager.shared.minimize() }
        sidebarNavigationController.setNavigationBarHidden(true, animated: false)
        homeViewController.title = String(localized: "tab.home")
        topicStack = [homeViewController]
        topicNavigationController.delegate = self
        compactNavigationController.delegate = self
        setViewController(compactNavigationController, for: .compact)
        compactLayout = isCollapsed
        preferredDisplayMode = compactLayout || wantsSinglePane
            ? .secondaryOnly : .oneBesideSecondary
        renderNavigation()
        updateForCurrentSize()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateTheme),
            name: ThemeManager.themeDidChangeNotification,
            object: nil
        )
        updateTheme()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateForCurrentSize()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        syncTabBarVisibility()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateForCurrentSize()
        let pane = activePaneFrame(in: view)
        let navigationBar = activeNavigationBarFrame(in: view)
        if pane != lastPaneFrame || navigationBar != lastNavigationFrame {
            lastPaneFrame = pane
            lastNavigationFrame = navigationBar
            onPaneLayout?()
        }
    }

    private func updateForCurrentSize() {
        guard isViewLoaded, !changingColumns else { return }
        let shouldCompact = isCollapsed
        if shouldCompact != compactLayout {
            storeVisibleStack()
            compactLayout = shouldCompact
            preferredDisplayMode = compactLayout || wantsSinglePane
                ? .secondaryOnly : .oneBesideSecondary
            renderNavigation()
            updateCategoryMenuButton()
        }
        let singlePane = wantsSinglePane
        if lastSinglePanePresentation != singlePane {
            lastSinglePanePresentation = singlePane
            preferredSplitBehavior = singlePane ? .overlay : .tile
            if !compactLayout {
                preferredDisplayMode = singlePane ? .secondaryOnly : .oneBesideSecondary
                if singlePane { hide(.primary) }
                else { show(.primary) }
            }
            updateCategoryMenuButton()
            syncTabBarVisibility()
        }
    }

    private func storeVisibleStack() {
        guard !changingColumns else { return }
        let stack: [UIViewController]
        if compactLayout {
            stack = compactNavigationController.viewControllers
        } else {
            stack = topicNavigationController.viewControllers
        }
        if !stack.isEmpty { topicStack = stack }
    }

    private func renderNavigation(syncTabBar: Bool = true) {
        guard isViewLoaded, !changingColumns else { return }
        changingColumns = true
        defer {
            changingColumns = false
            if syncTabBar { syncTabBarVisibility() }
        }

        compactNavigationController.setViewControllers([], animated: false)
        sidebarNavigationController.setViewControllers([], animated: false)
        topicNavigationController.setViewControllers([], animated: false)
        setViewController(nil, for: .primary)
        setViewController(nil, for: .secondary)

        if compactLayout {
            compactNavigationController.setViewControllers(topicStack, animated: false)
            setViewController(compactNavigationController, for: .compact)
        } else {
            sidebarNavigationController.setViewControllers([sidebarViewController], animated: false)
            topicNavigationController.setViewControllers(topicStack, animated: false)
            setViewController(sidebarNavigationController, for: .primary)
            setViewController(topicNavigationController, for: .secondary)
            preferredDisplayMode = compactLayout || wantsSinglePane
                ? .secondaryOnly : .oneBesideSecondary
        }
        updateCategoryMenuButton()
        view.setNeedsLayout()
    }

    func openTopic(topicID: Int, initialFloor: Int?, animated: Bool) {
        topicStack = [homeViewController]
        renderNavigation(syncTabBar: false)
        let detail = TopicDetailControllerFactory.make(api: api, topicId: topicID, initialFloor: initialFloor)
        let navigation = compactLayout ? compactNavigationController : topicNavigationController
        navigation.pushViewController(detail, animated: animated)
    }

    func scrollToTopOrRefreshIfAtRoot() -> Bool {
        let stack = compactLayout ? compactNavigationController.viewControllers : topicNavigationController.viewControllers
        guard stack.count == 1, stack.first === homeViewController else { return false }
        homeViewController.scrollToTopOrRefresh()
        return true
    }

    func activeNavigationBarFrame(in coordinateView: UIView) -> CGRect {
        let navigation = compactLayout ? compactNavigationController : topicNavigationController
        let bar = navigation.navigationBar
        return bar.convert(bar.bounds, to: coordinateView)
    }

    func activePaneFrame(in coordinateView: UIView) -> CGRect {
        let navigation = compactLayout ? compactNavigationController : topicNavigationController
        if let pane = navigation.viewIfLoaded,
           pane.window != nil,
           pane.safeAreaLayoutGuide.layoutFrame.width > 0 {
            return pane.convert(pane.safeAreaLayoutGuide.layoutFrame, to: coordinateView)
        }
        return view.convert(view.safeAreaLayoutGuide.layoutFrame, to: coordinateView)
    }

    private func selectCategory(_ categoryID: Int?) {
        topicStack = [homeViewController]
        sidebarViewController.selectedCategoryID = categoryID
        renderNavigation()
        homeViewController.selectCategoryFromSidebar(categoryID)
        updateCategoryMenuButton()
    }

    private func makeCategoryMenuItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    guard let self else { completion([]); return }
                    completion(self.homeViewController.buildCategoryMenuElements { [weak self] id in
                        self?.selectCategory(id)
                    })
                },
            ])
        )
        item.accessibilityLabel = String(localized: "home.filter.accessibility.label")
        item.accessibilityValue = homeViewModel.selectedCategory()?.name
            ?? String(localized: "home.filter.all_categories")
        item.accessibilityHint = String(localized: "home.filter.accessibility.hint")
        item.accessibilityIdentifier = "forum.categories.menu"
        return item
    }

    private func updateCategoryMenuButton() {
        guard isViewLoaded else { return }
        homeViewController.setCategoryNavigationButton(needsCategoryMenu ? makeCategoryMenuItem() : nil)
    }

    private func syncTabBarVisibility(showingDetail: Bool? = nil, animated: Bool = false) {
        (tabBarController as? ForumTabBarController)?.syncTabBarVisibility(
            homeShowingDetail: showingDetail,
            animated: animated
        )
    }

    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        if viewController === homeViewController {
            homeViewController.setCategoryNavigationButton(needsCategoryMenu ? makeCategoryMenuItem() : nil)
        }
        if !changingColumns {
            syncTabBarVisibility(showingDetail: viewController !== homeViewController, animated: animated)
        }
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        guard !changingColumns else { return }
        if compactLayout, navigationController === compactNavigationController {
            topicStack = navigationController.viewControllers
        } else if !compactLayout, navigationController === topicNavigationController {
            topicStack = navigationController.viewControllers
        }
        syncTabBarVisibility(showingDetail: viewController !== homeViewController)
    }

    func splitViewController(
        _ splitViewController: UISplitViewController,
        displayModeForExpandingToProposedDisplayMode proposedDisplayMode: UISplitViewController.DisplayMode
    ) -> UISplitViewController.DisplayMode {
        wantsSinglePane ? .secondaryOnly : .oneBesideSecondary
    }

    func splitViewControllerDidCollapse(_ splitViewController: UISplitViewController) {
        updateForCurrentSize()
    }

    func splitViewControllerDidExpand(_ splitViewController: UISplitViewController) {
        updateForCurrentSize()
    }

    @objc private func updateTheme() {
        view.backgroundColor = ThemeManager.shared.cardBackgroundColor
        for navigation in [sidebarNavigationController, compactNavigationController, topicNavigationController] {
            navigation.navigationBar.tintColor = ThemeManager.shared.accentColor
        }
    }
}

private final class ForumPaneNavigationController: UINavigationController {
    override var childForStatusBarStyle: UIViewController? { topViewController }
}

private final class ForumCategorySidebarViewController: ObservableViewController, UITableViewDelegate {
    private nonisolated enum Item: Hashable, Sendable {
        case all
        case category(Int)
    }

    private let forum: ForumInstance
    private let viewModel: HomeViewModel
    private var categoriesByID: [Int: DiscourseCategory] = [:]
    private var depthsByID: [Int: Int] = [:]
    private var expandedCategoryIDs: Set<Int> = []
    private var animatesNextSnapshot = false
    private var disclosureCategoryToRefresh: Int?
    var onSelectCategory: ((Int?) -> Void)?
    var onMinimize: (() -> Void)?
    var selectedCategoryID: Int? {
        didSet { if isViewLoaded { updateSelection() } }
    }

    private let titleLabel = UILabel()
    private let sectionLabel = UILabel()
    private lazy var minimizeButton: UIButton = {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "smallcircle.filled.circle"), for: .normal)
        button.accessibilityLabel = String(localized: "forum.minimize.accessibility.label")
        button.accessibilityHint = String(localized: "forum.minimize.accessibility.hint")
        button.addTarget(self, action: #selector(minimizeTapped), for: .touchUpInside)
        return button
    }()
    private lazy var tableView: UITableView = {
        let table = ThemedTableView(frame: .zero, style: .plain)
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 48
        table.selectionFollowsFocus = false
        table.accessibilityIdentifier = "forum.sidebar.categories"
        return table
    }()
    private lazy var dataSource = UITableViewDiffableDataSource<Int, Item>(tableView: tableView) {
        [weak self] table, indexPath, item in
        guard let self else { return UITableViewCell() }
        let reuseID = "ForumSidebarCategory"
        let cell = table.dequeueReusableCell(withIdentifier: reuseID)
            ?? UITableViewCell(style: .default, reuseIdentifier: reuseID)
        cell.selectionStyle = .none
        cell.focusStyle = .custom
        cell.focusEffect = nil
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 2
        switch item {
        case .all:
            content.text = String(localized: "home.filter.all_categories")
            content.image = UIImage(systemName: "square.grid.2x2")
            cell.indentationLevel = 0
            cell.accessibilityIdentifier = "forum.sidebar.all"
        case .category(let id):
            guard let category = self.categoriesByID[id] else { return cell }
            content.text = category.name
            content.image = UIImage(systemName: "circle.fill")
            content.imageProperties.tintColor = Self.color(fromHex: category.color)
            cell.indentationLevel = min(self.depthsByID[id] ?? 0, 3)
            cell.accessibilityIdentifier = "forum.sidebar.category.\(id)"
            if let children = category.subcategoryList, !children.isEmpty {
                let expanded = self.expandedCategoryIDs.contains(id)
                let button = UIButton(type: .system)
                button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
                button.setImage(UIImage(systemName: expanded ? "chevron.down" : "chevron.right"), for: .normal)
                button.tintColor = ThemeManager.shared.accentColor
                button.accessibilityLabel = expanded
                    ? String(localized: "forum.sidebar.collapse_subcategories")
                    : String(localized: "forum.sidebar.expand_subcategories")
                button.accessibilityIdentifier = "forum.sidebar.toggle.\(id)"
                button.addAction(UIAction { [weak self] _ in self?.toggleSubcategories(for: id) }, for: .touchUpInside)
                cell.accessoryView = button
            } else {
                cell.accessoryView = nil
            }
        }
        if case .all = item { cell.accessoryView = nil }
        cell.contentConfiguration = content
        cell.indentationWidth = 18
        self.configureSelectionAppearance(for: cell, item: item)
        return cell
    }
    private lazy var refreshControl: UIRefreshControl = {
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(refreshCategories), for: .valueChanged)
        return control
    }()

    init(forum: ForumInstance, viewModel: HomeViewModel) {
        self.forum = forum
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        titleLabel.text = forum.title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingTail
        sectionLabel.text = String(localized: "tab.categories")
        sectionLabel.font = .preferredFont(forTextStyle: .subheadline)
        sectionLabel.adjustsFontForContentSizeCategory = true
        tableView.refreshControl = refreshControl

        let header = UIStackView(arrangedSubviews: [titleLabel, minimizeButton])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 8
        for item in [header, sectionLabel, tableView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            minimizeButton.widthAnchor.constraint(equalToConstant: 44),
            minimizeButton.heightAnchor.constraint(equalToConstant: 44),
            sectionLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            sectionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sectionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tableView.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        updateSelection()
    }

    override func updateUI() {
        _ = ThemeManager.shared.revision
        _ = FontManager.shared.revision
        categoriesByID.removeAll()
        depthsByID.removeAll()
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems([Item.all])
        var seenIDs = Set<Int>()
        func append(_ categories: [DiscourseCategory], depth: Int) {
            for category in categories {
                guard seenIDs.insert(category.id).inserted else { continue }
                categoriesByID[category.id] = category
                depthsByID[category.id] = depth
                snapshot.appendItems([Item.category(category.id)])
                if expandedCategoryIDs.contains(category.id) {
                    append(category.subcategoryList ?? [], depth: depth + 1)
                }
            }
        }
        append(viewModel.categories, depth: 0)
        if let id = disclosureCategoryToRefresh,
           snapshot.itemIdentifiers.contains(.category(id)) {
            snapshot.reconfigureItems([.category(id)])
        }
        disclosureCategoryToRefresh = nil
        dataSource.apply(snapshot, animatingDifferences: animatesNextSnapshot)
        animatesNextSnapshot = false
        selectedCategoryID = viewModel.selectedCategoryId
        updateSelection()
        titleLabel.textColor = ThemeManager.shared.accentColor
        sectionLabel.textColor = ThemeManager.shared.accentColor
        minimizeButton.tintColor = ThemeManager.shared.accentColor
    }

    private func updateSelection() {
        let selectedItem = selectedCategoryID.map(Item.category) ?? .all
        if let indexPath = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: indexPath, animated: false)
        }
        for cell in tableView.visibleCells {
            guard let indexPath = tableView.indexPath(for: cell),
                  let item = dataSource.itemIdentifier(for: indexPath) else { continue }
            configureSelectionAppearance(for: cell, item: item, selectedItem: selectedItem)
        }
    }

    private func configureSelectionAppearance(
        for cell: UITableViewCell,
        item: Item,
        selectedItem: Item? = nil
    ) {
        let selected = item == (selectedItem ?? selectedCategoryID.map(Item.category) ?? .all)
        let background = cell.backgroundView ?? UIView()
        background.backgroundColor = selected
            ? ThemeManager.shared.accentColor.withAlphaComponent(0.12)
            : ThemeManager.shared.cardBackgroundColor
        cell.backgroundView = background
        if selected { cell.accessibilityTraits.insert(.selected) }
        else { cell.accessibilityTraits.remove(.selected) }
    }

    private func toggleSubcategories(for categoryID: Int) {
        if !expandedCategoryIDs.insert(categoryID).inserted {
            expandedCategoryIDs.remove(categoryID)
        }
        disclosureCategoryToRefresh = categoryID
        animatesNextSnapshot = true
        updateUI()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .all: onSelectCategory?(nil)
        case .category(let id): onSelectCategory?(id)
        }
    }

    @objc private func minimizeTapped() { onMinimize?() }

    @objc private func refreshCategories() {
        Task {
            await viewModel.reloadCategories()
            await viewModel.loadTopics()
            refreshControl.endRefreshing()
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
}
