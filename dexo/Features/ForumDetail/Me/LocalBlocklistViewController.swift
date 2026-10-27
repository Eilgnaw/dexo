import UIKit

final class LocalBlocklistViewController: ObservableViewController {
    private let settings = AppSettings.shared
    private let baseURL: String
    private var entries: [AppSettings.LocalBlockedUser] = []

    private lazy var tableView: UITableView = {
        let tableView = ThemedTableView(frame: .zero, style: .insetGrouped)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 56
        return tableView
    }()

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "me.local_blocklist.empty")
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    init(baseURL: String) {
        self.baseURL = baseURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "me.local_blocklist")
        view.addSubview(tableView)
        view.addSubview(emptyLabel)

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor, constant: -32),
        ])
    }

    override func updateUI() {
        _ = settings.localBlocklistRevision
        entries = settings.localBlockedUsers(for: baseURL)
        emptyLabel.isHidden = !entries.isEmpty
        tableView.reloadData()
    }
}

extension LocalBlocklistViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = entries[indexPath.row]
        let cell = UITableViewCell()
        var content = cell.defaultContentConfiguration()
        content.text = "@\(entry.username)"
        content.image = UIImage(systemName: "person.crop.circle.badge.xmark")
        content.imageProperties.tintColor = ThemeManager.shared.accentColor
        cell.contentConfiguration = content
        return cell
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        String(localized: "me.local_blocklist.footer \(AppSettings.maximumLocalBlockedUsers)")
    }

    func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete,
              entries.indices.contains(indexPath.row)
        else { return }
        let entry = entries[indexPath.row]
        settings.unblockUserLocally(username: entry.username, baseURL: entry.forumBaseURL)
    }
}

extension LocalBlocklistViewController: UITableViewDelegate {
    func tableView(
        _ tableView: UITableView,
        titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath
    ) -> String? {
        String(localized: "user.local_unblock")
    }
}
