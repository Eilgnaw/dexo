import CookedHTML
import SafariServices
import UIKit

private nonisolated enum ReplyItem: Hashable, Sendable {
    case post(Int)
    case boosts(Int)
}

final class RepliesViewController: BaseViewController {
    private let api: DiscourseAPI
    private let postId: Int
    private let topicId: Int
    private let baseURL: String
    private let assetBaseURL: String
    private let validReactions: [String]

    private var replies: [DiscourseTopicDetail.Post] = []
    private var parsedBlocks: [Int: [AnnotatedBlock]] = [:]
    private var expandedBoostPostIds: Set<Int> = []

    private lazy var tableView: UITableView = {
        let tv = ThemedTableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(PostNativeCell.self, forCellReuseIdentifier: PostNativeCell.reuseIdentifier)
        tv.register(BoostCell.self, forCellReuseIdentifier: BoostCell.reuseIdentifier)
        tv.delegate = self
        tv.separatorStyle = .none
        return tv
    }()

    private lazy var dataSource: UITableViewDiffableDataSource<Int, ReplyItem> = .init(tableView: tableView) { [weak self] tableView, indexPath, item in
        guard let self else { return UITableViewCell() }

        switch item {
        case .post(let postId):
            guard let post = self.replies.first(where: { $0.id == postId }),
                  let annotatedBlocks = self.parsedBlocks[postId],
                  let cell = tableView.dequeueReusableCell(withIdentifier: PostNativeCell.reuseIdentifier, for: indexPath) as? PostNativeCell
            else {
                return UITableViewCell()
            }
            let postLink = "\(self.baseURL)/t/\(self.topicId)/\(post.postNumber)"
            let config = NativeRenderConfig.default(contentWidth: tableView.bounds.width - 24, baseURL: self.baseURL)
            let floorNumber = (self.replies.firstIndex(where: { $0.id == postId }) ?? 0) + 1
            let isBoostsExpanded = self.expandedBoostPostIds.contains(postId)
            cell.configure(
                with: post,
                annotatedBlocks: annotatedBlocks,
                cachedContentViews: nil,
                config: config,
                delegate: self,
                floorNumber: floorNumber,
                postLink: postLink,
                baseURL: self.baseURL,
                assetBaseURL: self.assetBaseURL,
                validReactions: validReactions,
                isBoostsExpanded: isBoostsExpanded,
                showsSeparator: !isBoostsExpanded,
                hidesLikeButton: self.hidesLikeButton
            )
            return cell

        case .boosts(let postId):
            guard let post = self.replies.first(where: { $0.id == postId }),
                  let cell = tableView.dequeueReusableCell(withIdentifier: BoostCell.reuseIdentifier, for: indexPath) as? BoostCell
            else {
                return UITableViewCell()
            }
            cell.configure(
                post: post,
                delegate: self,
                assetBaseURL: self.assetBaseURL,
                contentWidth: tableView.bounds.width - 24
            )
            return cell
        }
    }

    private let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .medium)
        ai.hidesWhenStopped = true
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
    }()

    private let readTracker = TopicReadTracker()
    private var readFlushTimer: Timer?
    private var pendingReadFlush: DispatchWorkItem?
    private static let readFlushInterval: TimeInterval = 60
    private static let readFlushDebounce: TimeInterval = 1.5
    private let hidesLikeButton: Bool

    init(api: DiscourseAPI, postId: Int, topicId: Int, validReactions: [String] = []) {
        self.api = api
        self.postId = postId
        self.topicId = topicId
        self.validReactions = validReactions
        self.baseURL = api.baseURL
        self.assetBaseURL = api.assetBaseURL
        self.hidesLikeButton = ForumPolicy.hidesLikeButton(baseURL: api.baseURL)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Replies"

        view.addSubview(tableView)
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        Task {
            await loadReplies()
        }

        let nc = NotificationCenter.default
        nc.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        nc.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resumeReadTracking()
        startReadFlushTimer()
        scheduleDebouncedReadFlush()
    }

    @objc private func appDidEnterBackground() {
        cancelPendingReadFlush()
        stopReadFlushTimer()
        flushReadTimings()
        readTracker.pause()
    }

    @objc private func appWillEnterForeground() {
        resumeReadTracking()
        startReadFlushTimer()
        scheduleDebouncedReadFlush()
    }

    private func scheduleDebouncedReadFlush() {
        cancelPendingReadFlush()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingReadFlush = nil
            self?.flushReadTimings()
        }
        pendingReadFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readFlushDebounce, execute: work)
    }

    private func cancelPendingReadFlush() {
        pendingReadFlush?.cancel()
        pendingReadFlush = nil
    }

    private func resumeReadTracking() {
        readTracker.startSession()
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let item = dataSource.itemIdentifier(for: indexPath),
                  case .post(let postId) = item,
                  let post = replies.first(where: { $0.id == postId }) else { continue }
            readTracker.recordVisible(postNumber: post.postNumber)
        }
    }

    private func startReadFlushTimer() {
        stopReadFlushTimer()
        let timer = Timer(timeInterval: Self.readFlushInterval, repeats: true) { [weak self] _ in
            self?.flushReadTimings()
        }
        RunLoop.main.add(timer, forMode: .common)
        readFlushTimer = timer
    }

    private func stopReadFlushTimer() {
        readFlushTimer?.invalidate()
        readFlushTimer = nil
    }

    private func flushReadTimings() {
        let snap = readTracker.snapshotDelta()
        debugLog("[ReadTracker] replies topic=\(topicId) flush topic_time=\(snap.topicTime) posts=\(snap.timings.count)")
        guard !snap.timings.isEmpty else { return }
        let topicId = self.topicId
        let api = self.api
        Task.detached {
            try? await api.postTopicTimings(
                topicId: topicId,
                topicTime: snap.topicTime,
                timings: snap.timings
            )
        }
    }

    // MARK: - Data Loading

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, ReplyItem>()
        snapshot.appendSections([0])
        var items: [ReplyItem] = []
        for post in replies {
            items.append(.post(post.id))
            if expandedBoostPostIds.contains(post.id) {
                items.append(.boosts(post.id))
            }
        }
        snapshot.appendItems(items, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func loadReplies() async {
        activityIndicator.startAnimating()
        defer { activityIndicator.stopAnimating() }

        do {
            let response = try await api.fetchPostReplies(postId: postId)
            replies = response
            parsedBlocks = [:]
            expandedBoostPostIds = []

            for post in response {
                let annotated = CookedHTMLParser.parseAnnotated(html: post.cooked, baseURL: baseURL)
                parsedBlocks[post.id] = annotated
            }

            applySnapshot()
        } catch {
            // silently fail
        }
    }
}

// MARK: - UITableViewDelegate

extension RepliesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        200
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .post(let postId) = item,
              let post = replies.first(where: { $0.id == postId }) else { return }
        readTracker.recordVisible(postNumber: post.postNumber)
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .post(let postId) = item,
              let post = replies.first(where: { $0.id == postId }) else { return }
        readTracker.recordHidden(postNumber: post.postNumber)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleDebouncedReadFlush()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scheduleDebouncedReadFlush() }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelPendingReadFlush()
    }
}

extension RepliesViewController {
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelPendingReadFlush()
        stopReadFlushTimer()
        flushReadTimings()
        readTracker.pause()
    }
}

// MARK: - PostCellDelegate

extension RepliesViewController: PostCellDelegate {
    func postCell(didTapImageURL url: URL, inPostId postId: Int) {
        openExternalURL(url)
    }

    func postCell(didTapLinkURL url: URL) {
        openLink(url)
    }

    private func openLink(_ url: URL) {
        if let route = ForumTopicLinkParser.parse(url, baseURL: baseURL) {
            let detail = TopicDetailControllerFactory.make(
                api: api,
                topicId: route.topicId,
                initialFloor: route.floor
            )
            if let navigationController {
                navigationController.pushViewController(detail, animated: true)
            } else {
                present(UINavigationController(rootViewController: detail), animated: true)
            }
            return
        }
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            presentForumWebView(url, forumBaseURL: baseURL)
        } else {
            UIApplication.shared.open(url)
        }
    }

    private func openExternalURL(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            let safari = SFSafariViewController(url: url)
            present(safari, animated: true)
        } else {
            UIApplication.shared.open(url)
        }
    }

    func postCell(didTapShowRepliesForPostId postId: Int) {
        let repliesVC = RepliesViewController(
            api: api,
            postId: postId,
            topicId: topicId,
            validReactions: validReactions
        )
        if let sheet = repliesVC.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(repliesVC, animated: true)
    }

    func postCell(didTapToggleDetails detailsIndex: Int, postId: Int) {
        // Details toggle not supported in native rendering — no-op
    }

    func postCell(didTapReplyToPost post: DiscourseTopicDetail.Post) {
        guard let authGate = findAuthGating() else { return }
        authGate.requireAuth { [weak self] in
            guard let self else { return }
            self.presentReplyComposer(for: post)
        }
    }

    func postCell(didTapReplyReferenceForPost post: DiscourseTopicDetail.Post) {
        // The replies list is already a "what replied to what" view — chasing
        // the parent reference here would duplicate that context. No-op.
    }

    func postCell(didToggleCollapseForPostId postId: Int) {
        // No tree-mode UI in the replies list; nothing to collapse.
    }

    func postCell(didTapLoadMoreChildrenForParentId parentPostId: Int) {
        // No tree-mode UI in the replies list; nothing to expand.
    }

    func postCell(didToggleBookmarkForPost post: DiscourseTopicDetail.Post, isBookmarked: Bool) {
        Task {
            do {
                if isBookmarked {
                    _ = try await api.createBookmark(postId: post.id)
                } else if let bookmarkId = post.bookmarkId {
                    try await api.deleteBookmark(id: bookmarkId)
                }
            } catch {
                // Optimistic UI — server state will reconcile on next refresh
            }
        }
    }

    func postCell(didTapAvatarForUsername username: String) {
        let vc = UserProfileViewController(api: api, username: username)
        if let navigationController {
            navigationController.pushViewController(vc, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: vc)
            present(nav, animated: true)
        }
    }

    func postCell(didTapReaction reactionId: String, forPost post: DiscourseTopicDetail.Post) {
        Task {
            do {
                try await api.toggleReaction(postId: post.id, reactionId: reactionId)
                playReactionSuccessFeedback(
                    forPostId: post.id,
                    animated: post.currentUserReaction?.id != reactionId
                )
                if await refreshPost(id: post.id), post.currentUserReaction?.id != reactionId {
                    playReactionDestinationFeedback(forPostId: post.id)
                }
            } catch {
                debugLog("didTapReaction 发生错误: \(error)")
                presentChallengePromptIfNeeded(error: error, on: api)
            }
        }
    }

    func postCell(didToggleLikeForPost post: DiscourseTopicDetail.Post, liked: Bool) {
        Task {
            do {
                if liked {
                    try await api.likePost(postId: post.id)
                } else {
                    try await api.unlikePost(postId: post.id)
                }
                playReactionSuccessFeedback(forPostId: post.id, animated: liked)
                if await refreshPost(id: post.id), liked {
                    playReactionDestinationFeedback(forPostId: post.id)
                }
            } catch {
                presentChallengePromptIfNeeded(error: error, on: api)
            }
        }
    }

    /// Re-fetch a single post and reconfigure its row.
    private func playReactionSuccessFeedback(forPostId postId: Int, animated: Bool) {
        guard let indexPath = dataSource.indexPath(for: .post(postId)) else {
            if animated { ReactionFeedback.play(from: nil) }
            return
        }
        let cell = tableView.cellForRow(at: indexPath) as? PostNativeCell
        if let cell {
            cell.playReactionSuccessFeedback(animated: animated)
        } else if animated {
            ReactionFeedback.play(from: nil)
        }
    }

    private func playReactionDestinationFeedback(forPostId postId: Int) {
        guard let indexPath = dataSource.indexPath(for: .post(postId)) else { return }
        (tableView.cellForRow(at: indexPath) as? PostNativeCell)?.playReactionDestinationFeedback()
    }

    private func refreshPost(id: Int) async -> Bool {
        guard let fresh = try? await api.fetchPost(id: id) else { return false }
        guard let index = replies.firstIndex(where: { $0.id == id }) else { return false }
        let existing = replies[index]
        let cookedChanged = existing.cooked != fresh.cooked
        // Carry over plugin-only fields stripped by /posts/{id}.json so the
        // boost button / poll state aren't reset by the refresh.
        var merged = fresh
        merged.boosts = existing.boosts
        merged.canBoost = existing.canBoost
        merged.polls = existing.polls
        merged.pollsVotes = existing.pollsVotes
        replies[index] = merged
        if cookedChanged {
            parsedBlocks[id] = CookedHTMLParser.parseAnnotated(html: merged.cooked, baseURL: api.baseURL)
        }
        var snapshot = dataSource.snapshot()
        let item = ReplyItem.post(id)
        if snapshot.itemIdentifiers.contains(item) {
            snapshot.reconfigureItems([item])
            await dataSource.apply(snapshot, animatingDifferences: false)
        }
        return true
    }

    func postCell(didTapBoostForPost post: DiscourseTopicDetail.Post) {
        guard let authGate = findAuthGating() else { return }
        authGate.requireAuth { [weak self] in
            self?.presentBoostComposer(for: post)
        }
    }

    func postCell(didTapToggleBoostsForPost post: DiscourseTopicDetail.Post, sourceView: UIView) {
        if expandedBoostPostIds.contains(post.id) {
            expandedBoostPostIds.remove(post.id)
        } else {
            expandedBoostPostIds.insert(post.id)
        }
        refreshBoostUI()
    }

    func postCell(didTapDeleteBoost boost: DiscourseTopicDetail.Boost) {
        let alert = UIAlertController(
            title: String(localized: "action.delete"),
            message: String(localized: "topic_detail.boost.delete.confirm"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "action.delete"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                do {
                    try await self.api.deleteBoost(id: boost.id)
                    guard let index = self.replies.firstIndex(where: { $0.boosts.contains(where: { $0.id == boost.id }) }) else { return }
                    self.replies[index].boosts.removeAll { $0.id == boost.id }
                    self.replies[index].canBoost = true
                    if self.replies[index].boosts.isEmpty {
                        self.expandedBoostPostIds.remove(self.replies[index].id)
                    }
                    self.refreshBoostUI()
                } catch {
                    if self.presentChallengePromptIfNeeded(error: error, on: self.api) {
                        return
                    }
                    let failureAlert = UIAlertController(
                        title: String(localized: "reply.send.failed"),
                        message: error.localizedDescription,
                        preferredStyle: .alert
                    )
                    failureAlert.addAction(UIAlertAction(title: String(localized: "weblogin.done"), style: .default))
                    self.present(failureAlert, animated: true)
                }
            }
        })
        present(alert, animated: true)
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

    private func refreshBoostUI() {
        applySnapshot()
        tableView.reloadData()
    }

    private func presentReplyComposer(for post: DiscourseTopicDetail.Post) {
        let composer = ReplyComposerViewController(
            api: api,
            topicId: topicId,
            replyToPost: post,
            baseURL: baseURL
        )
        composer.onPostCreated = { [weak self] _, _ in
            guard let self else { return }
            Task { await self.loadReplies() }
        }
        let nav = UINavigationController(rootViewController: composer)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    private func presentBoostComposer(for post: DiscourseTopicDetail.Post) {
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = String(localized: "reply.placeholder")
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "reply.send"), style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let raw = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { return }

            Task {
                do {
                    let boost = try await self.api.createBoost(postId: post.id, raw: raw)
                    guard let index = self.replies.firstIndex(where: { $0.id == post.id }) else { return }
                    if !self.replies[index].boosts.contains(where: { $0.id == boost.id }) {
                        self.replies[index].boosts.append(boost)
                    }
                    self.replies[index].canBoost = false
                    self.expandedBoostPostIds.insert(post.id)
                    self.refreshBoostUI()
                } catch {
                    if self.presentChallengePromptIfNeeded(error: error, on: self.api) {
                        return
                    }
                    let failureAlert = UIAlertController(
                        title: String(localized: "reply.send.failed"),
                        message: error.localizedDescription,
                        preferredStyle: .alert
                    )
                    failureAlert.addAction(UIAlertAction(title: String(localized: "weblogin.done"), style: .default))
                    self.present(failureAlert, animated: true)
                }
            }
        })
        present(alert, animated: true)
    }

    func postCell(didVotePoll pollName: String, options: [String], forPost post: DiscourseTopicDetail.Post) {
        // Voting not supported in replies sheet
    }

    func postCell(didRemovePollVote pollName: String, forPost post: DiscourseTopicDetail.Post) {
        // Voting not supported in replies sheet
    }

    func postCell(didTapFlagPost post: DiscourseTopicDetail.Post, sourceView: UIView) {
        // Flag not supported in replies sheet
    }

    func postCell(didLongPressPost post: DiscourseTopicDetail.Post) {
        Task {
            do {
                let detail = try await api.fetchPost(id: post.id)
                guard let raw = detail.raw, !raw.isEmpty else { return }
                let vc = RawContentViewController(raw: raw, username: post.username, floorNumber: post.postNumber)
                let nav = UINavigationController(rootViewController: vc)
                if let sheet = nav.sheetPresentationController {
                    sheet.detents = [.medium(), .large()]
                    sheet.prefersGrabberVisible = true
                }
                present(nav, animated: true)
            } catch {
                let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
                present(alert, animated: true)
            }
        }
    }
}
