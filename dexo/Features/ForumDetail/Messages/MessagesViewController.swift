import UIKit

final class MessagesViewController: ObservableViewController {
    private let viewModel: MessagesViewModel
    private let api: DiscourseAPI
    private weak var authGate: AuthGating?

    private lazy var tableView: UITableView = {
        let tv = ThemedTableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseIdentifier)
        tv.delegate = self
        tv.dataSource = self
        return tv
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .medium)
        ai.hidesWhenStopped = true
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
    }()

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "messages.empty")
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    private lazy var refreshControl: UIRefreshControl = {
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        return rc
    }()

    private lazy var filterControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [
            String(localized: "messages.filter.inbox"),
            String(localized: "messages.filter.sent"),
        ])
        control.selectedSegmentIndex = 0
        control.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
        return control
    }()

    /// Currently selected PM view, derived from the segmented control.
    private var currentFilter: PrivateMessageFilter {
        filterControl.selectedSegmentIndex == 1 ? .sent : .inbox
    }

    init(api: DiscourseAPI, authGate: AuthGating? = nil) {
        self.api = api
        self.viewModel = MessagesViewModel(api: api)
        self.authGate = authGate
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "messages.title")
        navigationItem.titleView = filterControl
        tableView.refreshControl = refreshControl
        tableView.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))

        view.addSubview(tableView)
        view.addSubview(activityIndicator)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])

        Task {
            await viewModel.loadMessages(username: authGate?.currentUsername() ?? "", filter: currentFilter)
        }
    }

    override func updateUI() {
        if viewModel.isLoading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }

        if !viewModel.isLoading, viewModel.messages.isEmpty {
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }

        tableView.reloadData()
    }

    @objc private func pullToRefresh() {
        Task {
            await viewModel.loadMessages(username: authGate?.currentUsername() ?? "", filter: currentFilter)
            refreshControl.endRefreshing()
        }
    }

    @objc private func filterChanged() {
        // Clear the current list immediately so the table doesn't show the
        // previous filter's rows while the new view loads.
        viewModel.messages = []
        tableView.reloadData()
        Task {
            await viewModel.loadMessages(username: authGate?.currentUsername() ?? "", filter: currentFilter)
        }
    }
}

// MARK: - UITableViewDataSource

extension MessagesViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: MessageCell.reuseIdentifier, for: indexPath) as? MessageCell else {
            return UITableViewCell()
        }
        let topic = viewModel.messages[indexPath.row]
        cell.configure(with: topic, users: viewModel.users, assetBaseURL: api.assetBaseURL, hasUnread: viewModel.hasUnread(topicId: topic.id))
        cell.accessoryType = .disclosureIndicator
        return cell
    }
}

// MARK: - UITableViewDelegate

extension MessagesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let topic = viewModel.messages[indexPath.row]
        Task { await viewModel.markMessageRead(topicId: topic.id) }
        let detailVC = TopicDetailControllerFactory.make(
            api: api,
            topicId: topic.id,
            initialFloor: topic.resumePostNumber
        )
        navigationController?.pushViewController(detailVC, animated: true)
    }
}
