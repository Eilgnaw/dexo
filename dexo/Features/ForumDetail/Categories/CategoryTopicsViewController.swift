import UIKit

import Perception

@Perceptible
private final class CategoryTopicsViewModel {
    var topics: [DiscourseTopicList.Topic] = []
    var isLoading = false
    var isLoadingMore = false
    var canLoadMore = false

    private let api: DiscourseAPI
    private let slug: String
    private let categoryId: Int
    private var currentPage = 0
    private var usersById: [Int: DiscourseTopicList.User] = [:]

    init(api: DiscourseAPI, slug: String, categoryId: Int) {
        self.api = api
        self.slug = slug
        self.categoryId = categoryId
    }

    func avatarTemplate(for topic: DiscourseTopicList.Topic) -> String? {
        guard let firstPoster = topic.posters?.first else { return nil }
        return usersById[firstPoster.userId]?.avatarTemplate
    }

    func visibleTopics(excluding blockedUsernames: Set<String>) -> [DiscourseTopicList.Topic] {
        TopicListFilter.excludingBlockedAuthors(
            from: topics,
            usersById: usersById,
            blockedUsernames: blockedUsernames
        )
    }

    func loadTopics() async {
        isLoading = true
        currentPage = 0
        do {
            let result = try await api.fetchCategoryTopics(slug: slug, id: categoryId, page: 0)
            topics = result.topicList.topics
            canLoadMore = result.topicList.moreTopicsUrl != nil
            indexUsers(result.users)
        } catch {
            // Error silently handled for now
        }
        isLoading = false
    }

    func loadMoreTopics() async {
        guard canLoadMore, !isLoadingMore else { return }
        isLoadingMore = true
        let nextPage = currentPage + 1
        do {
            let result = try await api.fetchCategoryTopics(slug: slug, id: categoryId, page: nextPage)
            currentPage = nextPage
            let existingIds = Set(topics.map(\.id))
            let newTopics = result.topicList.topics.filter { !existingIds.contains($0.id) }
            topics.append(contentsOf: newTopics)
            canLoadMore = result.topicList.moreTopicsUrl != nil
            indexUsers(result.users)
        } catch {
            // Silently fail on load-more
        }
        isLoadingMore = false
    }

    private func indexUsers(_ users: [DiscourseTopicList.User]?) {
        guard let users else { return }
        for user in users {
            usersById[user.id] = user
        }
    }
}

final class CategoryTopicsViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let category: DiscourseCategory
    private let viewModel: CategoryTopicsViewModel
    private var locallyReadTopicIDs: Set<Int> = []

    private lazy var tableView: UITableView = {
        let tv = ThemedTableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(TopicCell.self, forCellReuseIdentifier: TopicCell.reuseIdentifier)
        tv.delegate = self
        tv.showsVerticalScrollIndicator = false
        return tv
    }()

    private lazy var dataSource: UITableViewDiffableDataSource<Int, Int> = {
        UITableViewDiffableDataSource<Int, Int>(tableView: tableView) { [weak self] tableView, indexPath, topicId in
            guard let self,
                  let cell = tableView.dequeueReusableCell(withIdentifier: TopicCell.reuseIdentifier, for: indexPath) as? TopicCell,
                  let topic = self.viewModel.topics.first(where: { $0.id == topicId }) else {
                return UITableViewCell()
            }
            let assetBaseURL = self.api.assetBaseURL
            var avatarURL: URL?
            if let template = self.viewModel.avatarTemplate(for: topic) {
                let sized = template.replacingOccurrences(of: "{size}", with: "96")
                let urlString = sized.hasPrefix("http") ? sized : assetBaseURL + sized
                avatarURL = URL(string: urlString)
            }
            let categoryColor = Self.color(fromHex: self.category.color)
            cell.configure(
                with: topic,
                avatarURL: avatarURL,
                categoryName: self.category.name,
                categoryColor: categoryColor,
                isLocallyRead: self.locallyReadTopicIDs.contains(topic.id)
            )
            return cell
        }
    }()

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

    private lazy var refreshControl: UIRefreshControl = {
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        return rc
    }()

    init(api: DiscourseAPI, category: DiscourseCategory) {
        self.api = api
        self.category = category
        self.viewModel = CategoryTopicsViewModel(api: api, slug: category.slug, categoryId: category.id)
        super.init(nibName: nil, bundle: nil)
        title = category.name
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.tableFooterView = footerSpinner
        tableView.refreshControl = refreshControl

        view.addSubview(tableView)
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        Task {
            await viewModel.loadTopics()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadLocalReadState()
    }

    private func reloadLocalReadState() {
        let ids = ReadHistoryScope.current(api: api)
            .flatMap { try? LocalReadHistoryStore.shared.topicIDs(scope: $0) } ?? []
        guard ids != locallyReadTopicIDs else { return }
        locallyReadTopicIDs = ids
        updateUI()
    }

    override func updateUI() {
        _ = AppSettings.shared.localBlocklistRevision
        let topics = viewModel.visibleTopics(
            excluding: AppSettings.shared.localBlockedUsernames(for: api.baseURL)
        )
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        var seen = Set<Int>()
        let uniqueIds = topics.compactMap { topic -> Int? in
            guard seen.insert(topic.id).inserted else { return nil }
            return topic.id
        }
        snapshot.appendItems(uniqueIds, toSection: 0)
        let currentIds = Set(dataSource.snapshot().itemIdentifiers)
        let idsToRefresh = uniqueIds.filter { currentIds.contains($0) }
        if !idsToRefresh.isEmpty {
            snapshot.reconfigureItems(idsToRefresh)
        }
        dataSource.apply(snapshot, animatingDifferences: true)

        if viewModel.isLoading {
            activityIndicator.startAnimating()
            tableView.isHidden = true
        } else {
            activityIndicator.stopAnimating()
            tableView.isHidden = false
        }

        if viewModel.isLoadingMore {
            footerSpinner.startAnimating()
        } else {
            footerSpinner.stopAnimating()
        }
    }

    @objc private func pullToRefresh() {
        Task {
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

extension CategoryTopicsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let topicId = dataSource.itemIdentifier(for: indexPath) else { return }
        let detailVC = TopicDetailControllerFactory.make(
            api: api,
            topicId: topicId,
            initialFloor: viewModel.topics.first(where: { $0.id == topicId })?.resumePostNumber
        )
        navigationController?.pushViewController(detailVC, animated: true)
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
