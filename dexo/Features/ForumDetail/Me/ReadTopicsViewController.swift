import Perception
import UIKit

private enum ReadTopicSource: Int, CaseIterable {
    case local
    case cloud
}

@Perceptible
private final class ReadTopicsViewModel {
    var selectedSource: ReadTopicSource = .local
    var localTopics: [LocalReadTopic] = [] {
        didSet { rebuildRows() }
    }
    var cloudTopics: [DiscourseTopicList.Topic] = [] {
        didSet { rebuildRows() }
    }
    var isLoadingCloud = false
    var isLoadingMore = false
    var canLoadMore = false
    var cloudErrorMessage: String?

    private let api: DiscourseAPI
    private var currentPage = 0
    private var usersById: [Int: DiscourseTopicList.User] = [:]
    private var categoriesById: [Int: DiscourseCategory] = [:]
    private(set) var rows: [ReadTopicRow] = []
    private var rowsById: [Int: ReadTopicRow] = [:]

    init(api: DiscourseAPI) {
        self.api = api
    }

    private func rebuildRows() {
        let rebuilt: [ReadTopicRow]
        switch selectedSource {
        case .local:
            rebuilt = localTopics.map {
                ReadTopicRow(id: $0.topicId, local: $0, cloud: nil, cloudOrder: nil)
            }
        case .cloud:
            let localByTopicId = Dictionary(uniqueKeysWithValues: localTopics.map { ($0.topicId, $0) })
            rebuilt = cloudTopics.enumerated().map { index, topic in
                ReadTopicRow(
                    id: topic.id,
                    local: localByTopicId[topic.id],
                    cloud: topic,
                    cloudOrder: index
                )
            }
        }
        rows = rebuilt
        rowsById = Dictionary(uniqueKeysWithValues: rebuilt.map { ($0.id, $0) })
    }

    func row(id: Int) -> ReadTopicRow? {
        rowsById[id]
    }

    func avatarTemplate(for row: ReadTopicRow) -> String? {
        if let firstPoster = row.cloud?.posters?.first,
           let template = usersById[firstPoster.userId]?.avatarTemplate
        {
            return template
        }
        return row.local?.avatarTemplate
    }

    func category(for row: ReadTopicRow) -> DiscourseCategory? {
        guard let categoryId = row.topic.categoryId else { return nil }
        return categoriesById[categoryId]
    }

    func selectSource(_ source: ReadTopicSource) {
        selectedSource = source
        rebuildRows()
    }

    func loadTopics() async {
        refreshLocal()
        isLoadingCloud = true
        cloudErrorMessage = nil
        currentPage = 0
        usersById.removeAll()
        do {
            async let cloudResult = api.fetchReadTopics(page: 0)
            async let categoriesResult: Void = loadCategoriesIfNeeded()
            let result = try await cloudResult
            _ = await categoriesResult
            cloudTopics = result.topicList.topics
            canLoadMore = result.topicList.moreTopicsUrl != nil
            indexUsers(result.users)
        } catch {
            cloudTopics = []
            canLoadMore = false
            cloudErrorMessage = error.localizedDescription
        }
        isLoadingCloud = false
    }

    func refreshLocal() {
        guard let scope = ReadHistoryScope.current(api: api) else {
            localTopics = []
            return
        }
        localTopics = (try? LocalReadHistoryStore.shared.fetch(scope: scope)) ?? []
    }

    func loadMoreTopics() async {
        guard selectedSource != .local, canLoadMore, !isLoadingCloud, !isLoadingMore else { return }
        isLoadingMore = true
        let nextPage = currentPage + 1
        do {
            let result = try await api.fetchReadTopics(page: nextPage)
            currentPage = nextPage
            let existingIds = Set(cloudTopics.map(\.id))
            cloudTopics.append(contentsOf: result.topicList.topics.filter { !existingIds.contains($0.id) })
            canLoadMore = result.topicList.moreTopicsUrl != nil
            indexUsers(result.users)
        } catch {
            cloudErrorMessage = error.localizedDescription
        }
        isLoadingMore = false
    }

    private func indexUsers(_ users: [DiscourseTopicList.User]?) {
        for user in users ?? [] { usersById[user.id] = user }
    }

    private func loadCategoriesIfNeeded() async {
        guard categoriesById.isEmpty else { return }
        do {
            let list = try await api.fetchAllCategories()
            indexCategories(list.categoryList.categories)
        } catch {
            // Category labels are optional presentation metadata.
        }
    }

    private func indexCategories(_ categories: [DiscourseCategory]) {
        for category in categories {
            categoriesById[category.id] = category
            if let children = category.subcategoryList { indexCategories(children) }
        }
    }
}

final class ReadTopicsViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let viewModel: ReadTopicsViewModel

    private lazy var segmentedControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [
            String(localized: "read.segment.local"),
            String(localized: "read.segment.cloud"),
        ])
        control.selectedSegmentIndex = ReadTopicSource.local.rawValue
        control.addTarget(self, action: #selector(sourceChanged(_:)), for: .valueChanged)
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
    }()

    private lazy var tableView: UITableView = {
        let table = ThemedTableView(frame: .zero, style: .plain)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.register(TopicCell.self, forCellReuseIdentifier: TopicCell.reuseIdentifier)
        table.delegate = self
        table.showsVerticalScrollIndicator = false
        return table
    }()

    private lazy var dataSource: UITableViewDiffableDataSource<Int, Int> = .init(tableView: tableView) { [weak self] tableView, indexPath, topicId in
        guard let self,
              let row = self.viewModel.row(id: topicId),
              let cell = tableView.dequeueReusableCell(
                  withIdentifier: TopicCell.reuseIdentifier,
                  for: indexPath
              ) as? TopicCell
        else { return UITableViewCell() }

        var avatarURL: URL?
        if let template = self.viewModel.avatarTemplate(for: row) {
            let sized = template.replacingOccurrences(of: "{size}", with: "96")
            avatarURL = URL(string: sized.hasPrefix("http") ? sized : self.api.assetBaseURL + sized)
        }
        let category = self.viewModel.category(for: row)
        cell.configure(
            with: row.topic,
            avatarURL: avatarURL,
            categoryName: category?.name,
            categoryColor: category.flatMap { Self.color(fromHex: $0.color) },
            timestampOverride: row.displayDate,
            isLocallyRead: row.local != nil,
            origins: row.origins
        )
        return cell
    }

    private let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    private let footerSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.frame = CGRect(x: 0, y: 0, width: 0, height: 44)
        return spinner
    }()

    private let stateLabel: UILabel = {
        let label = UILabel()
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    private lazy var retryButton: UIButton = {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = String(localized: "action.retry")
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(retryCloud), for: .touchUpInside)
        button.isHidden = true
        return button
    }()

    private lazy var refreshControl: UIRefreshControl = {
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        return control
    }()

    init(api: DiscourseAPI) {
        self.api = api
        viewModel = ReadTopicsViewModel(api: api)
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "me.read")
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.tableFooterView = footerSpinner
        tableView.refreshControl = refreshControl
        tableView.tableHeaderView = UIView(
            frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude)
        )

        view.addSubview(segmentedControl)
        view.addSubview(tableView)
        view.addSubview(activityIndicator)
        view.addSubview(stateLabel)
        view.addSubview(retryButton)

        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            segmentedControl.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            segmentedControl.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),

            stateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor, constant: -20),
            stateLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stateLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 12),
        ])

        Task { await viewModel.loadTopics() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.refreshLocal()
        updateUI()
    }

    override func updateUI() {
        let rows = viewModel.rows
        segmentedControl.selectedSegmentIndex = viewModel.selectedSource.rawValue

        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows.map(\.id))
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let refreshable = rows.map(\.id).filter(existing.contains)
        if !refreshable.isEmpty { snapshot.reconfigureItems(refreshable) }
        dataSource.apply(snapshot, animatingDifferences: true)

        if viewModel.isLoadingCloud && rows.isEmpty {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
        viewModel.isLoadingMore ? footerSpinner.startAnimating() : footerSpinner.stopAnimating()

        let cloudFailed = viewModel.selectedSource == .cloud
            && viewModel.cloudErrorMessage != nil
            && rows.isEmpty
        if cloudFailed {
            stateLabel.text = viewModel.cloudErrorMessage
            stateLabel.isHidden = false
            retryButton.isHidden = false
        } else if !viewModel.isLoadingCloud, rows.isEmpty {
            switch viewModel.selectedSource {
            case .local: stateLabel.text = String(localized: "read.empty.local")
            case .cloud: stateLabel.text = String(localized: "read.empty.cloud")
            }
            stateLabel.isHidden = false
            retryButton.isHidden = true
        } else {
            stateLabel.isHidden = true
            retryButton.isHidden = true
        }
    }

    @objc private func sourceChanged(_ sender: UISegmentedControl) {
        guard let source = ReadTopicSource(rawValue: sender.selectedSegmentIndex) else { return }
        viewModel.selectSource(source)
        updateUI()
    }

    @objc private func pullToRefresh() {
        Task {
            await viewModel.loadTopics()
            refreshControl.endRefreshing()
        }
    }

    @objc private func retryCloud() {
        Task { await viewModel.loadTopics() }
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

extension ReadTopicsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let topicId = dataSource.itemIdentifier(for: indexPath),
              let row = viewModel.row(id: topicId)
        else { return }
        navigationController?.pushViewController(
            TopicDetailControllerFactory.make(
                api: api,
                topicId: topicId,
                initialFloor: row.topic.resumePostNumber
            ),
            animated: true
        )
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row >= tableView.numberOfRows(inSection: 0) - 1 else { return }
        Task { await viewModel.loadMoreTopics() }
    }
}
