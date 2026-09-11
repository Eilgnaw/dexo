import UIKit

final class ForumListViewController: ObservableViewController {
    override var backgroundStyle: BackgroundStyle { .grouped }

    private let viewModel = ForumListViewModel()
    private let settings = AppSettings.shared

    private let emptyStateImageView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "rectangle.stack.badge.plus"))
        imageView.contentMode = .scaleAspectFit
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 46, weight: .regular)
        return imageView
    }()

    private let emptyStateTitleLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "forum.empty.title")
        label.textAlignment = .center
        return label
    }()

    private let emptyStateMessageLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "forum.empty.message")
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    private lazy var emptyStateButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "forum.empty.add")
        configuration.image = UIImage(systemName: "plus")
        configuration.imagePadding = 6
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: #selector(addForumTapped), for: .touchUpInside)
        return button
    }()

    private lazy var emptyStateView: UIView = {
        let container = UIView()
        let stack = UIStackView(arrangedSubviews: [
            emptyStateImageView,
            emptyStateTitleLabel,
            emptyStateMessageLabel,
            emptyStateButton,
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(20, after: emptyStateMessageLabel)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            emptyStateImageView.widthAnchor.constraint(equalToConstant: 64),
            emptyStateImageView.heightAnchor.constraint(equalToConstant: 64),
            emptyStateMessageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])
        return container
    }()

    private lazy var tableView: UITableView = {
        let tv = ThemedTableView(frame: .zero, style: .insetGrouped)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(ForumListCell.self, forCellReuseIdentifier: ForumListCell.reuseIdentifier)
        tv.delegate = self
        return tv
    }()

    private lazy var dataSource: ReorderableDataSource = {
        let ds = ReorderableDataSource(tableView: tableView) { [weak self] tableView, indexPath, forumId in
            guard let self,
                  let cell = tableView.dequeueReusableCell(withIdentifier: ForumListCell.reuseIdentifier, for: indexPath) as? ForumListCell,
                  let forum = self.viewModel.forums.first(where: { $0.id == forumId }) else {
                return UITableViewCell()
            }
            cell.configure(with: forum)
            return cell
        }
        ds.onMove = { [weak self] from, to in
            self?.viewModel.moveForum(from: from.row, to: to.row)
        }
        return ds
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "tab.forums")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addForumTapped)
        )
        navigationItem.leftBarButtonItem = editButtonItem

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        viewModel.loadForums()
    }

    override func updateUI() {
        _ = FontManager.shared.scale
        _ = ThemeManager.shared.revision
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int64>()
        snapshot.appendSections([0])
        let ids = viewModel.forums.compactMap(\.id)
        snapshot.appendItems(ids, toSection: 0)
        let currentIds = Set(dataSource.snapshot().itemIdentifiers)
        let idsToRefresh = ids.filter { currentIds.contains($0) }
        if !idsToRefresh.isEmpty {
            snapshot.reconfigureItems(idsToRefresh)
        }
        dataSource.apply(snapshot, animatingDifferences: true)

        let showsEmptyState = ids.isEmpty && !viewModel.isLoading
        if showsEmptyState, tableView.backgroundView !== emptyStateView {
            tableView.backgroundView = emptyStateView
        } else if !showsEmptyState, tableView.backgroundView != nil {
            tableView.backgroundView = nil
        }
        editButtonItem.isEnabled = !ids.isEmpty
        if ids.isEmpty, isEditing {
            setEditing(false, animated: true)
        }

        emptyStateImageView.tintColor = ThemeManager.shared.accentColor
        emptyStateTitleLabel.font = FontManager.shared.font(size: 22, weight: .semibold)
        emptyStateMessageLabel.font = FontManager.shared.font(size: 15)
        var buttonConfiguration = emptyStateButton.configuration
        buttonConfiguration?.baseBackgroundColor = ThemeManager.shared.accentColor
        emptyStateButton.configuration = buttonConfiguration
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
    }

    @objc private func addForumTapped() {
        let addVC = AddForumViewController()
        addVC.onForumAdded = { [weak self] in
            self?.viewModel.loadForums()
        }
        let nav = UINavigationController(rootViewController: addVC)
        present(nav, animated: true)
    }
}

// MARK: - UITableViewDelegate

extension ForumListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < viewModel.forums.count,
              let window = view.window else { return }
        let forum = viewModel.forums[indexPath.row]
        openForum(forum, in: window, showAutoOpenPrompt: true)
    }

    private func openForum(_ forum: ForumInstance, in window: UIWindow, showAutoOpenPrompt: Bool) {
        guard ForumURLPolicy.isSecure(forum.baseURL) else {
            showBlockedForumAlert(for: forum)
            return
        }

        settings.lastOpenedForumId = forum.id
        ForumOverlayManager.shared.present(forum: forum, in: window)
        if showAutoOpenPrompt {
            showAutoOpenPromptIfNeeded()
        }
    }

    private func showBlockedForumAlert(for forum: ForumInstance) {
        guard presentedViewController == nil else { return }

        guard let candidate = try? ForumURLPolicy.httpsUpgradeCandidate(from: forum.baseURL) else {
            let alert = UIAlertController(
                title: String(localized: "forum.security.blocked.title"),
                message: String(localized: "forum.security.blocked.message"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
            present(alert, animated: true)
            return
        }

        let alert = UIAlertController(
            title: String(localized: "forum.https_upgrade.title"),
            message: String(localized: "forum.https_upgrade.message \(candidate)"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: String(localized: "forum.https_upgrade.action"),
            style: .default
        ) { [weak self] _ in
            self?.performHTTPSUpgrade(for: forum)
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func performHTTPSUpgrade(for forum: ForumInstance) {
        let progressAlert = UIAlertController(
            title: String(localized: "forum.https_upgrade.checking"),
            message: nil,
            preferredStyle: .alert
        )
        present(progressAlert, animated: true)

        Task { [weak self, weak progressAlert] in
            guard let self, let progressAlert else { return }
            do {
                let updated = try await self.viewModel.upgradeForumToHTTPS(forum)
                progressAlert.dismiss(animated: true) { [weak self] in
                    self?.showHTTPSUpgradeSucceeded(updated)
                }
            } catch {
                debugLog("[ForumList] HTTPS upgrade failed: \(error)")
                progressAlert.dismiss(animated: true) { [weak self] in
                    self?.showHTTPSUpgradeFailed()
                }
            }
        }
    }

    private func showHTTPSUpgradeSucceeded(_ forum: ForumInstance) {
        let alert = UIAlertController(
            title: String(localized: "forum.https_upgrade.success.title"),
            message: String(localized: "forum.https_upgrade.success.message \(forum.baseURL)"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.open"), style: .default) { [weak self] _ in
            guard let self, let window = self.view.window else { return }
            self.openForum(forum, in: window, showAutoOpenPrompt: true)
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func showHTTPSUpgradeFailed() {
        let alert = UIAlertController(
            title: String(localized: "forum.https_upgrade.failure.title"),
            message: String(localized: "forum.https_upgrade.failure.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
        present(alert, animated: true)
    }

    private func showAutoOpenPromptIfNeeded() {
        guard !settings.hasShownAutoOpenPrompt else { return }
        settings.hasShownAutoOpenPrompt = true
        let alert = UIAlertController(
            title: String(localized: "forum.auto_open.title"),
            message: String(localized: "forum.auto_open.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.enable"), style: .default) { [weak self] _ in
            self?.settings.autoOpenLastForum = true
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.no_thanks"), style: .cancel))
        if let containerVC = ForumOverlayManager.shared.currentContainer {
            containerVC.present(alert, animated: true)
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let deleteAction = UIContextualAction(style: .destructive, title: String(localized: "action.delete")) { [weak self] _, _, completion in
            self?.viewModel.deleteForum(at: indexPath.row)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        .none
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }
}

// MARK: - Reorderable diffable data source

private final class ReorderableDataSource: UITableViewDiffableDataSource<Int, Int64> {
    var onMove: ((IndexPath, IndexPath) -> Void)?

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        true
    }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        // Sync the data source's snapshot with the move the table view just animated.
        // Without this, the next `apply(...)` (e.g. from observation tracking after
        // the model mutates) diffs against a stale snapshot and re-animates the row,
        // which produces the "drop position doesn't stick" behaviour.
        var snap = snapshot()
        let items = snap.itemIdentifiers(inSection: 0)
        guard sourceIndexPath.row < items.count else { return }
        let moved = items[sourceIndexPath.row]
        snap.deleteItems([moved])
        let remaining = snap.itemIdentifiers(inSection: 0)
        if destinationIndexPath.row >= remaining.count {
            snap.appendItems([moved], toSection: 0)
        } else {
            snap.insertItems([moved], beforeItem: remaining[destinationIndexPath.row])
        }
        apply(snap, animatingDifferences: false)
        onMove?(sourceIndexPath, destinationIndexPath)
    }
}
