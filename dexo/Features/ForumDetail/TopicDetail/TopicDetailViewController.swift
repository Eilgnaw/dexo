import CookedHTML
import Lightbox
import SDWebImage
import UIKit

private nonisolated enum TopicDetailItem: Hashable, Sendable {
    case post(Int)
    case boosts(Int)
    /// Tree-mode "view N more replies" row, keyed by the parent post whose
    /// extra direct replies it expands.
    case loadMoreChildren(Int)
}

// MARK: - Topic Read Tracker

/// Tracks how long each post was visible on screen so we can POST `/topics/timings`
/// and have Discourse mark the posts as read (which is what `/read.json` reflects).
/// `nonisolated` to dodge the iOS 26 back-deploy `swift_task_deinitOnExecutorMainActorBackDeploy`
/// crash for MainActor helper deinits.
nonisolated final class TopicReadTracker {
    private var visibleStarts: [Int: CFTimeInterval] = [:]
    private var elapsedByPost: [Int: Int] = [:]
    private var totalSentByPost: [Int: Int] = [:]
    private var sessionStart: CFTimeInterval?
    private var sessionAccumulated: Int = 0

    /// Begin / resume the topic-level timer. Idempotent.
    func startSession() {
        guard sessionStart == nil else { return }
        sessionStart = CACurrentMediaTime()
    }

    func recordVisible(postNumber: Int) {
        guard visibleStarts[postNumber] == nil else { return }
        visibleStarts[postNumber] = CACurrentMediaTime()
    }

    func recordHidden(postNumber: Int) {
        guard let start = visibleStarts.removeValue(forKey: postNumber) else { return }
        addElapsed(postNumber: postNumber, elapsed: msSince(start))
    }

    /// Roll up in-flight timers and stop counting until the next `startSession`.
    /// Used when the VC is covered (push) or app backgrounded — the user isn't
    /// actually reading anymore so per-post and topic timers must freeze.
    func pause() {
        let now = CACurrentMediaTime()
        for (postNumber, start) in visibleStarts {
            addElapsed(postNumber: postNumber, elapsed: Int((now - start) * 1000))
        }
        visibleStarts = [:]
        if let start = sessionStart {
            sessionAccumulated += Int((now - start) * 1000)
            sessionStart = nil
        }
    }

    /// Snapshot the unsent delta and reset delta state. Visible cells and the
    /// session timer keep ticking — their start times are reset to `now` so
    /// the next snapshot picks up cleanly without double-counting (the server
    /// treats `/topics/timings` POSTs as additive).
    func snapshotDelta() -> (topicTime: Int, timings: [Int: Int]) {
        let now = CACurrentMediaTime()
        for (postNumber, start) in visibleStarts {
            addElapsed(postNumber: postNumber, elapsed: Int((now - start) * 1000))
            visibleStarts[postNumber] = now
        }
        if let start = sessionStart {
            sessionAccumulated += Int((now - start) * 1000)
            sessionStart = now
        }
        let snapTopic = sessionAccumulated
        let snapTimings = elapsedByPost
        for (postNumber, ms) in snapTimings {
            totalSentByPost[postNumber, default: 0] += ms
        }
        sessionAccumulated = 0
        elapsedByPost = [:]
        return (snapTopic, snapTimings)
    }

    /// - Skips flash-by visits (< 500 ms).
    /// - Caps cumulative *sent + pending* at MAX_TRACKING_TIME (6 min) to match
    ///   Discourse's per-session ceiling, so a post sitting on-screen for hours
    ///   doesn't skew server-side `avg_time` scoring.
    private func addElapsed(postNumber: Int, elapsed: Int) {
        guard elapsed >= Self.minVisibleMs else { return }
        let pending = elapsedByPost[postNumber, default: 0]
        let alreadySent = totalSentByPost[postNumber, default: 0]
        let remaining = max(0, Self.maxPerPostMs - pending - alreadySent)
        let toAdd = min(elapsed, remaining)
        if toAdd > 0 {
            elapsedByPost[postNumber] = pending + toAdd
        }
    }

    private func msSince(_ start: CFTimeInterval) -> Int {
        Int((CACurrentMediaTime() - start) * 1000)
    }

    private static let maxPerPostMs = 6 * 60 * 1000
    private static let minVisibleMs = 1000
}

// MARK: - Frame Drop Detector (temporary perf debugging)
final class FrameDropDetector {
#if DEBUG
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    /// Collects [PERF] messages between frames; flushed only when a drop is detected.
    private(set) var pendingLogs: [String] = []

    static let shared = FrameDropDetector()

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func log(_ message: String) {
        pendingLogs.append(message)
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer {
            lastTimestamp = link.timestamp
            pendingLogs.removeAll(keepingCapacity: true)
        }
        guard lastTimestamp > 0 else { return }
        let elapsed = (link.timestamp - lastTimestamp) * 1000
        // 60fps = 16.6ms per frame; flag anything over 25ms (~1.5 frames)
        if elapsed > 25 {
            let dropped = Int(elapsed / 16.6) - 1
            debugLog("🔴 [PERF] FRAME DROP: \(String(format: "%.1f", elapsed))ms (~\(dropped) frames dropped)")
            for msg in pendingLogs {
                debugLog("   ↳ \(msg)")
            }
        }
    }
#else
    static let shared = FrameDropDetector()
    func start() {}
    func stop() {}
    func log(_ message: String) {}
#endif
}

final class LegacyTopicDetailViewController: ObservableViewController {
    private let viewModel: TopicDetailViewModel
    private let api: DiscourseAPI
    private let topicId: Int
    private let baseURL: String
    private let assetBaseURL: String
    private var hasTitleHeader = false
    private var pendingScrollIndexPath: (indexPath: IndexPath, position: UITableView.ScrollPosition)?
    private var lastScrollOffset: CGFloat = 0
    /// VC-level cache of rendered content views keyed by post ID.
    /// Avoids re-creating the entire view tree when scrolling back to a post.
    /// Legacy-only cache. Keeping it bounded is essential now that a cached
    /// AsyncTextView can retain a multi-megabyte bitmap.
    private let contentViewCache = LRUCache<Int, [UIView]>(capacity: 18)
    /// Tracks whether a pagination flow (jump, load-earlier, load-more, reverse,
    /// summary) is currently in flight. `updateUI` defers snapshot application
    /// while non-`.idle` so the flow's own synchronous apply isn't fought by
    /// the observable-driven default path.
    ///
    /// - `.idle`: `updateUI` is free to apply snapshots as observable state
    ///   changes (e.g. content edits, reaction updates).
    /// - `.jumping`: `jumpToFloor` / `loadTopic` cleared & is re-loading. The
    ///   Task that started the flow will apply the snapshot and scroll
    ///   explicitly once the VM await returns.
    /// - `.loadingEarlier`: a prepend is in flight or queued. The Task awaits
    ///   the VM; the snapshot apply itself is deferred to a settled scroll
    ///   view (no drag, no decel) so the content shift can't fight against
    ///   the pan gesture or residual momentum. Applied either inline (if
    ///   already settled when the VM returns) or via
    ///   `flushPendingLoadEarlierIfReady` from a settle delegate.
    /// - `.loadingMore`: an append is in flight. The Task applies the snapshot
    ///   while preserving the current contentOffset.
    private enum PaginationContext {
        case idle
        case jumping
        case loadingEarlier
        case loadingMore
    }
    private var paginationContext: PaginationContext = .idle
    /// A load-earlier response that's waiting for the scroll view to settle
    /// (`isDragging` / `isDecelerating` / `isTracking` all false) before
    /// applying. Trying to apply mid-drag fights the pan handler; mid-
    /// decel fights residual velocity. Both manifest as "anchor doesn't
    /// restore" + "fires again on the same gesture". Deferring to idle
    /// dodges both.
    private var pendingLoadEarlier: (addedPostIds: [Int], token: UInt)?
    /// Bumped every time `paginationContext` is set to a non-idle value. Each
    /// pagination Task captures the token at launch and only mutates
    /// `paginationContext` / applies its snapshot if its token still matches —
    /// otherwise a newer flow has taken over and the Task's results are stale.
    ///
    /// Without this, a load-earlier Task whose VM response was discarded by
    /// `loadGeneration` would still run its trailing `paginationContext = .idle`
    /// while a preempting jump was mid-await, opening the door for `updateUI`
    /// to apply an intermediate empty snapshot.
    private var paginationToken: UInt = 0
    /// Token captured when the fast-path `scrollToRow(animated: true)` starts.
    /// The animation has no completion callback, so we rely on the table
    /// view's `scrollViewDidEndScrollingAnimation` delegate to release the
    /// context. Reset to `nil` either there (clean end) or when a newer
    /// pagination flow preempts the fast scroll.
    private var fastPathScrollToken: UInt?
    /// One-shot gate for the scroll-driven load-earlier trigger. Disarmed
    /// after each trigger and re-armed only on a fresh `willBeginDragging`.
    /// Without this, a single drag on a fast simulator can produce multiple
    /// back-to-back triggers: the Task returns within the gesture, the apply
    /// step overrides `contentOffset` to anchor-restored position, then
    /// UIKit's pan handler immediately re-overrides it based on the still-
    /// active pan translation — looking from `scrollViewDidScroll` like a
    /// fresh scroll-up from far below right back into the trigger zone.
    /// A contentOffset-threshold re-arm can't dodge that; the only stable
    /// signal is "the user started a new drag".
    private var loadEarlierArmed: Bool = true
    /// Cache actual cell heights to avoid jumps from inaccurate estimates
    private var cellHeightCache: [TopicDetailItem: CGFloat] = [:]
    /// Per-block heights computed by `BlockHeightCalculator`, fed back into
    /// `cell.configure` so each block view gets an explicit `heightAnchor` and
    /// the cell skips the Core-Text-typesetting cascade in `systemLayoutSizeFitting`.
    private var precomputedBlockHeights: [Int: [CGFloat?]] = [:]
    /// Total cell height (chrome + content stack + spacing). Returned directly
    /// from `heightForRowAt` to bypass `automaticDimension` measurement entirely.
    private var precomputedTotalHeights: [Int: CGFloat] = [:]
    /// Tracks the table width the cache was computed against. A width change
    /// (rotation, split-view resize) invalidates the entire cache.
    private var precomputedWidth: CGFloat = 0
    private var renderCacheEnvironment: RenderEnvironment?
    /// Serial background queue that warms `precomputedBlockHeights` /
    /// `precomputedTotalHeights` ahead of cellForRowAt. The synchronous
    /// `precomputeHeights(forPostId:)` in the cell provider is otherwise a
    /// 30–80ms `boundingRect` typesetting pass for paragraph-heavy posts —
    /// directly visible as a frame drop the moment such a post scrolls in.
    private let heightWarmupQueue = DispatchQueue(label: "topic.heightWarmup", qos: .userInitiated)
    /// Width the warmup task in-flight is using. Set on dispatch, cleared on
    /// completion. Used to skip duplicate scheduling.
    private var heightWarmupInFlightWidth: CGFloat = 0
    private var isThemeRefreshScheduled = false
    private var pendingThemeRefresh = false
    private let imageZoomTransition = ImageZoomTransitionDelegate()
    private lazy var boostDanmaku = BoostDanmakuOverlay(hostView: view)
    private let readTracker = TopicReadTracker()
    private var readFlushTimer: Timer?
    private var pendingReadFlush: DispatchWorkItem?
    private static let readFlushInterval: TimeInterval = 60
    private static let readFlushDebounce: TimeInterval = 1.5
    private let hidesLikeButton: Bool

    private lazy var tableView: UITableView = {
        let tv = ThemedTableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(PostNativeCell.self, forCellReuseIdentifier: PostNativeCell.reuseIdentifier)
        tv.register(PostCollapsedCell.self, forCellReuseIdentifier: PostCollapsedCell.reuseIdentifier)
        tv.register(LoadMoreChildrenCell.self, forCellReuseIdentifier: LoadMoreChildrenCell.reuseIdentifier)
        tv.register(BoostCell.self, forCellReuseIdentifier: BoostCell.reuseIdentifier)
        tv.delegate = self
        tv.separatorStyle = .none
        tv.showsVerticalScrollIndicator = false
        tv.isHidden = true
        return tv
    }()

    private lazy var dataSource: UITableViewDiffableDataSource<Int, TopicDetailItem> = .init(tableView: tableView) { [weak self] tableView, indexPath, item in
        guard let self else { return UITableViewCell() }

        switch item {
        case .post(let postId):
            // In tree mode, a collapsed parent renders as a compact summary row
            // instead of the full post — dispatch to PostCollapsedCell here.
            if self.viewModel.isTreeMode, self.viewModel.collapsedPostIds.contains(postId),
               let post = self.viewModel.postsById[postId],
               let cell = tableView.dequeueReusableCell(withIdentifier: PostCollapsedCell.reuseIdentifier, for: indexPath) as? PostCollapsedCell
            {
                let depth = self.viewModel.postDepths[postId] ?? 0
                cell.configure(
                    with: post,
                    treeDepth: depth,
                    treeLineState: self.viewModel.postTreeLineStates[postId],
                    baseURL: self.baseURL,
                    delegate: self
                )
                return cell
            }
            let cellStart = CACurrentMediaTime()
            guard let post = self.viewModel.postsById[postId],
                  let annotatedBlocks = self.viewModel.parsedBlocks[postId],
                  let cell = tableView.dequeueReusableCell(withIdentifier: PostNativeCell.reuseIdentifier, for: indexPath) as? PostNativeCell
            else {
                return UITableViewCell()
            }
            let floorNumber: Int
            // Use stream-based floor number (O(1) dictionary lookup) when not filtering
            let allPostIds = self.viewModel.allPostIds
            if !self.viewModel.isFilteringByOP, let streamIndex = allPostIds.firstIndex(of: postId) {
                floorNumber = streamIndex + 1
            } else {
                floorNumber = (self.viewModel.visiblePosts.firstIndex(where: { $0.id == postId }) ?? 0) + 1
            }
            let postLink = "\(self.baseURL)/t/\(self.topicId)/\(post.postNumber)"
            let depth = self.viewModel.isTreeMode ? (self.viewModel.postDepths[postId] ?? 0) : 0
            let indent = PostNativeCell.treeContentIndent(forDepth: depth)
            let config = NativeRenderConfig.default(contentWidth: tableView.bounds.width - 24 - indent, baseURL: self.baseURL)
            let isBoostsExpanded = self.viewModel.expandedBoostPostIds.contains(postId)
            // Branch lines on the leading edge already carry the visual
            // grouping between posts in tree mode, so the bottom hairline
            // would just compete with them — drop it for tree-mode cells.
            let showsSeparator = !isBoostsExpanded && !self.viewModel.isTreeMode
            let treeLineState = self.viewModel.isTreeMode ? self.viewModel.postTreeLineStates[postId] : nil
            let cachedViews = self.contentViewCache[postId]
            self.precomputeHeights(forPostId: postId, blocks: annotatedBlocks, config: config, tableWidth: tableView.bounds.width)
            let isOP = post.username == self.viewModel.opUsername
            cell.configure(
                with: post,
                annotatedBlocks: annotatedBlocks,
                cachedContentViews: cachedViews,
                config: config,
                delegate: self,
                floorNumber: floorNumber,
                postLink: postLink,
                baseURL: self.baseURL,
                assetBaseURL: self.assetBaseURL,
                validReactions: self.viewModel.topic?.validReactions ?? [],
                isBoostsExpanded: isBoostsExpanded,
                showsSeparator: showsSeparator,
                precomputedBlockHeights: self.precomputedBlockHeights[postId],
                hidesLikeButton: self.hidesLikeButton,
                isOP: isOP,
                treeDepth: depth,
                treeLineState: treeLineState
            )
            // Cache newly rendered views for future reuse
            if cachedViews == nil {
                self.contentViewCache[postId] = cell.currentContentViews
            }
            let cellEnd = CACurrentMediaTime()
            let ms = (cellEnd - cellStart) * 1000
            if ms > 2 { FrameDropDetector.shared.log("cellForRow post#\(postId) \(String(format: "%.1f", ms))ms blocks=\(annotatedBlocks.count) cached=\(cachedViews != nil)") }
            return cell

        case .boosts(let postId):
            guard let post = self.viewModel.postsById[postId],
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

        case .loadMoreChildren(let parentId):
            guard let load = self.viewModel.pendingChildLoads[parentId],
                  let cell = tableView.dequeueReusableCell(withIdentifier: LoadMoreChildrenCell.reuseIdentifier, for: indexPath) as? LoadMoreChildrenCell
            else {
                return UITableViewCell()
            }
            cell.configure(
                parentPostId: parentId,
                remaining: load.remaining,
                treeDepth: load.depth,
                treeLineState: load.treeLineState,
                isLoading: self.viewModel.loadingChildrenParentIds.contains(parentId),
                delegate: self
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

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 20, weight: .bold)
        label.numberOfLines = 0
        return label
    }()

    private let tagsContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let navTitleLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 17, weight: .semibold)
        label.numberOfLines = 1
        return label
    }()

    private let errorLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 14)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let footerSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.frame = CGRect(x: 0, y: 0, width: 0, height: 44)
        return spinner
    }()

    /// Shown in place of `footerSpinner` when a load-more attempt failed.
    /// Keeps the same 44pt footer slot so the table doesn't visibly shift —
    /// just a tertiary-tinted refresh icon + label centered in the spinner's
    /// usual position. Tap fires the same load-more flow as auto-pagination.
    private lazy var footerRetryView: UIControl = {
        let control = UIControl()
        control.frame = CGRect(x: 0, y: 0, width: 0, height: 44)

        let icon = UIImageView(image: UIImage(
            systemName: "arrow.clockwise",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        ))
        icon.tintColor = .tertiaryLabel

        let label = UILabel()
        label.text = String(localized: "topic_detail.load_more_retry")
        label.font = FontManager.shared.font(size: 13)
        label.textColor = .tertiaryLabel

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        control.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: control.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: control.centerYAnchor),
        ])

        control.addTarget(self, action: #selector(footerRetryTapped), for: .touchUpInside)
        return control
    }()

    private lazy var topLoadingBar: UIView = {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = .clear
        bar.alpha = 0
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = String(localized: "topic_detail.loading_earlier")
        label.font = FontManager.shared.font(size: 13)
        label.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 36),
        ])
        return bar
    }()

    private let bottomBar = TopicDetailBottomBar()

    /// Draggable reply FAB used only in tree mode (where the bottom-bar's
    /// floor controls are hidden and a centered single button would look off).
    /// Hidden in flat mode; the bottom bar handles reply there.
    private let floatingReplyButton = FloatingReplyButton()
    private var floatingReplyButtonPositioned: Bool = false
    /// Mirrors `viewModel.isTreeMode` so `updateUI` can refresh tree-mode-
    /// dependent affordances (right bar button, bottom-bar visibility) on
    /// the first cycle after the VM flips the flag — e.g. when a PM load
    /// silently downgrades tree mode to flat because the nested endpoint
    /// returned the standard post-stream layout.
    private var lastSeenTreeMode: Bool?

    private var jumpScrubber: JumpScrubberOverlay?
    private var jumpScrubStartLocation: CGPoint = .zero
    private var jumpScrubHasMoved: Bool = false
    /// Starting floor at the moment the scrubber was summoned. Floor changes
    /// are computed relative to this anchor.
    private var jumpScrubStartFloor: Int = 1
    /// Drag distance that maps to a full-range sweep. Same value on both
    /// sides so the floor delta per pixel is constant regardless of where
    /// the user is starting in the topic — dragging 30pt always means the
    /// same number of floors whether you're at floor 1 or floor 600.
    private var jumpScrubReferenceDistance: CGFloat = 1
    /// Pixels of finger travel before we start applying floor changes; small
    /// enough to feel responsive, large enough that just press-and-release
    /// on the button never confirms a stray floor.
    private let jumpScrubMoveThreshold: CGFloat = 8

    private lazy var jumpOverlay: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        v.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }()

    private var initialFloor: Int?

    init(api: DiscourseAPI, topicId: Int, initialFloor: Int? = nil) {
        self.api = api
        self.viewModel = TopicDetailViewModel(api: api)
        self.topicId = topicId
        self.baseURL = api.baseURL
        self.assetBaseURL = api.assetBaseURL
        self.initialFloor = initialFloor
        self.hidesLikeButton = ForumPolicy.hidesLikeButton(baseURL: api.baseURL)
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
#if DEBUG
        FrameDropDetector.shared.start()
#endif
        navigationItem.largeTitleDisplayMode = .never
        title = String(localized: "topic_detail.default_title")
        // Restore the user's preferred reading mode from the previous session
        // so opening a topic doesn't reset their choice.
        viewModel.isTreeMode = AppSettings.shared.topicTreeMode
        viewModel.treeSort = AppSettings.shared.topicTreeSort
        navigationItem.rightBarButtonItem = treeModeBarButtonItem()
        updateBottomBarVisibility()
//        tableView.tableFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))

        view.addSubview(tableView)
        view.addSubview(activityIndicator)
        view.addSubview(errorLabel)
        view.addSubview(bottomBar)
        view.addSubview(floatingReplyButton)
        view.addSubview(topLoadingBar)

        bottomBar.delegate = self
        floatingReplyButton.addTarget(self, action: #selector(floatingReplyButtonTapped), for: .touchUpInside)
        tableView.tableFooterView = footerSpinner

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

            bottomBar.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            topLoadingBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topLoadingBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topLoadingBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        Task {
            let jumpFloor = initialFloor
            initialFloor = nil
            // Deep-link entry to a specific floor (notification / search / PM /
            // bookmark): tree mode can't locate an arbitrary floor — posts are in
            // DFS order and `allPostIds` is hash-keyed, so `jumpToFloor`'s index
            // math addresses the wrong post. Force-exit to the flat stream first
            // so the target floor resolves against the canonical ordered stream.
            if let jumpFloor, jumpFloor > 1 {
                exitTreeModeSideEffects()
            }
            let token = enterPaginationContext(.jumping)
            if viewModel.isTreeMode {
                await viewModel.loadNestedTopic(id: topicId)
            } else {
                await viewModel.loadTopic(id: topicId, containerWidth: view.bounds.width)
            }
            handleLoadErrorIfNeeded()
            // If the user opened the jump sheet (or replied) before the initial
            // load finished, the newer flow has bumped the token — bail and let
            // it handle its own snapshot/scroll.
            guard paginationTokenIsCurrent(token) else { return }
            if let jumpFloor, jumpFloor > 1 {
                invalidateRenderCaches()
                await viewModel.jumpToFloor(jumpFloor, containerWidth: view.bounds.width)
                guard paginationTokenIsCurrent(token) else { return }
                applyJumpSnapshot(target: jumpFloor, position: .top)
            } else {
                // No explicit target — just apply the snapshot once data is in.
                let snapshot = buildSnapshot()
                dataSource.apply(snapshot, animatingDifferences: false, completion: nil)
            }
            endPaginationContext(token)
        }
        Task {
            await api.loadOrFetchEmojiMap()
            hasTitleHeader = false
            updateUI()
        }

        // Registered once. Selector-based observers are auto-cleared on dealloc
        // (iOS 9+), so no explicit removeObserver needed.
        let nc = NotificationCenter.default
        nc.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        nc.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
        nc.addObserver(
            self, selector: #selector(topicThemeDidChange),
            name: ThemeManager.themeDidChangeNotification, object: nil
        )
        nc.addObserver(
            self, selector: #selector(topicFontDidChange),
            name: FontManager.fontDidChangeNotification, object: nil
        )
        nc.addObserver(
            self, selector: #selector(topicImageHeightDidChange(_:)),
            name: TappableImageContainer.intrinsicHeightDidChangeNotification, object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resumeReadTracking()
        startReadFlushTimer()
        // Initial "rush" flush: same code path as scroll-stop — debounced by
        // `readFlushDebounce` (1.5s) so visible cells cross the 1s min threshold
        // and get included in the snapshot.
        scheduleDebouncedReadFlush()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true else {
            return
        }
        refreshThemeAppearance()
    }

    @objc private func topicThemeDidChange() {
        refreshThemeAppearance()
    }

    @objc private func topicFontDidChange() {
        invalidateRenderCaches()
        hasTitleHeader = false
        tableView.reloadData()
        updateUI()
    }

    @objc private func topicImageHeightDidChange(_ notification: Notification) {
        guard let sender = notification.object as? UIView,
              sender.isDescendant(of: tableView),
              let postId = notification.userInfo?["postId"] as? Int
        else { return }
        invalidatePrecomputedHeights(forPostId: postId)
        cellHeightCache.removeValue(forKey: .post(postId))
    }

    /// Rebuilds only rendered content, not topic data or height measurements.
    /// This is needed because the topic controller intentionally keeps rendered
    /// view trees alive across cell reuse, while some renderers capture colors
    /// at render time and AsyncTextView stores a rasterized bitmap.
    private func refreshThemeAppearance() {
        guard isViewLoaded else { return }
        contentViewCache.removeAll()

        // Pagination owns snapshot application while it is active. Defer the
        // reload until that flow has finished instead of mixing two snapshot
        // mutations in the same run-loop turn.
        guard paginationContext == .idle else {
            pendingThemeRefresh = true
            return
        }
        guard !isThemeRefreshScheduled else { return }
        isThemeRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isThemeRefreshScheduled = false
            guard self.paginationContext == .idle else {
                self.pendingThemeRefresh = true
                return
            }

            guard let visibleIndexPaths = self.tableView.indexPathsForVisibleRows,
                  !visibleIndexPaths.isEmpty
            else { return }

            let currentSnapshot = self.dataSource.snapshot()
            let visibleItems = Set(visibleIndexPaths.compactMap {
                self.dataSource.itemIdentifier(for: $0)
            })
            let reloadableItems = visibleItems.filter {
                currentSnapshot.indexOfItem($0) != NSNotFound
            }
            guard !reloadableItems.isEmpty else { return }

            for indexPath in visibleIndexPaths {
                (self.tableView.cellForRow(at: indexPath) as? PostNativeCell)?.markContentDirty()
            }

            var refreshedSnapshot = currentSnapshot
            refreshedSnapshot.reloadItems(Array(reloadableItems))
            let offset = self.tableView.contentOffset
            UIView.performWithoutAnimation {
                self.dataSource.apply(refreshedSnapshot, animatingDifferences: false)
                self.tableView.layoutIfNeeded()
            }
            self.tableView.setContentOffset(offset, animated: false)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelPendingReadFlush()
        stopReadFlushTimer()
        flushReadTimings()
        // Pause stops the topic timer (and clears in-flight visible-cell timers)
        // until the next viewWillAppear, so any time the VC is off-screen — push,
        // tab switch, app background — doesn't get attributed to the next snapshot.
        readTracker.pause()
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

    /// Schedule a flush 1.5s from now, replacing any earlier pending one. Used by
    /// scroll-stop and entry hooks so a fresh batch of visible cells gets time to
    /// cross the 1s `minVisibleMs` threshold before we snapshot them.
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

    /// Start a fresh tracking session and re-arm timers for cells that are already
    /// on screen — those cells won't receive a new `willDisplay` callback after a
    /// pause (push→pop, foreground from background), so we'd miss their time.
    private func resumeReadTracking() {
        readTracker.startSession()
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let item = dataSource.itemIdentifier(for: indexPath),
                  case .post(let postId) = item,
                  let post = viewModel.postsById[postId] else { continue }
            readTracker.recordVisible(postNumber: post.postNumber)
        }
    }

    private func startReadFlushTimer() {
        stopReadFlushTimer()
        // Schedule on .common so the periodic flush also fires during table-view
        // scrolling (the run loop is in tracking mode then; .default-only timers stall).
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
        debugLog("[ReadTracker] topic=\(topicId) flush topic_time=\(snap.topicTime) posts=\(snap.timings.count)")
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = tableView.bounds.width
        if width > 0 {
            let environment = RenderEnvironment(
                contentWidth: width,
                displayScale: view.window?.screen.scale ?? UIScreen.main.scale,
                fontRevision: FontManager.shared.revision,
                themeRevision: ThemeManager.shared.revision
            )
            if let previous = renderCacheEnvironment, previous != environment {
                invalidateRenderCaches()
                for cell in tableView.visibleCells {
                    (cell as? PostNativeCell)?.markContentDirty()
                }
                tableView.reloadData()
            }
            renderCacheEnvironment = environment
        }
        // Reserve bottom space for the floating button row
        let bottomInset: CGFloat = 44 + 12 + 12
        if tableView.contentInset.bottom != bottomInset {
            tableView.contentInset.bottom = bottomInset
            tableView.verticalScrollIndicatorInsets.bottom = bottomInset
        }

        // Keep the floating FAB on-screen after rotations / safe-area changes.
        // First positioning has to wait until this point because earlier in
        // `viewDidLoad` the view isn't in a window yet — safe-area insets are
        // zero, so a default-position computed there lands top-left.
        if !floatingReplyButton.isHidden, view.bounds.width > 0 {
            if !floatingReplyButtonPositioned {
                floatingReplyButton.placeAtDefaultPosition()
                floatingReplyButtonPositioned = true
            } else {
                floatingReplyButton.reclampToParent()
            }
        }

        warmHeightCacheInBackground()

        // Retry the scroll after further layout passes in case the target row's
        // height changed after initial display (e.g. async image loads).
        if let pending = pendingScrollIndexPath {
            if let item = dataSource.itemIdentifier(for: pending.indexPath),
               cellHeightCache[item] != nil {
                pendingScrollIndexPath = nil
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                tableView.scrollToRow(at: pending.indexPath, at: pending.position, animated: false)
                CATransaction.commit()
                lastScrollOffset = tableView.contentOffset.y
            }
        }
    }

    // MARK: - Pagination flow primitives
    //
    // The four pagination operations (initial load, jump, load-more,
    // load-earlier) all share the same three-step shape:
    //
    //   1. Set `paginationContext` so `updateUI` defers snapshot apply.
    //   2. Await the VM operation. During the await, observable mutations
    //      will queue `updateUI` calls but the snapshot apply step is
    //      skipped (the context is non-`.idle`).
    //   3. After the VM returns, synchronously precompute heights for
    //      newly-loaded posts (so `rectForRow` gives accurate offsets),
    //      apply the snapshot, restore scroll position, then set the
    //      context back to `.idle`. A trailing `updateUI` will re-fire on
    //      RunLoop tick but the snapshot already matches, so it's a no-op.
    //
    // This keeps the snapshot/scroll state under the control of the entry
    // point that initiated the operation rather than spread across
    // observable callbacks.

    /// Switch into a new pagination context and return a token the caller can
    /// re-check on Task completion. The token only matches as long as no
    /// later flow has taken over.
    @discardableResult
    private func enterPaginationContext(_ context: PaginationContext) -> UInt {
        paginationToken &+= 1
        paginationContext = context
        // A window-replacing flow lands the user at a new position; reset the
        // load-earlier gate so the first pull-up after the jump can fire.
        if case .jumping = context { loadEarlierArmed = true }
        // Drop any pending load-earlier apply — its captured token is now
        // stale, and applying its prepend over the new flow's window would
        // splice old posts into the wrong place (or just no-op via the token
        // check, leaking the array reference).
        pendingLoadEarlier = nil
        return paginationToken
    }

    /// Reset to `.idle` iff the caller's `token` still owns the context. Skip
    /// when a newer flow has overwritten the context — that flow will reset
    /// `.idle` on its own completion.
    private func endPaginationContext(_ token: UInt) {
        guard paginationToken == token else { return }
        paginationContext = .idle
        if pendingThemeRefresh {
            pendingThemeRefresh = false
            refreshThemeAppearance()
        }
    }

    /// True iff the flow that captured `token` still owns the context. Tasks
    /// gate their `applyXxxSnapshot` on this so a stale completion never
    /// clobbers a newer flow's visible state (e.g. an old jump's
    /// `applyJumpSnapshot` scrolling to its target after the user has already
    /// kicked off another jump to a different floor).
    private func paginationTokenIsCurrent(_ token: UInt) -> Bool {
        paginationToken == token
    }

    /// SF Symbol toggled between flat and tree (indented) layouts. Swapping
    /// modes invalidates every height/content cache because tree-mode indent
    /// shrinks the per-cell content width, so the entire stack has to be
    /// re-measured.
    private func treeModeBarButtonItem() -> UIBarButtonItem {
        let name = viewModel.isTreeMode ? "list.bullet.indent" : "list.bullet"
        let image = UIImage(systemName: name)
        // In tree mode the button doubles as a sort-order menu: tap toggles
        // tree/flat, long-press opens a sort picker (top/new/old).
        if viewModel.isTreeMode {
            let button = UIButton(type: .system)
            button.setImage(image, for: .normal)
            button.addTarget(self, action: #selector(treeModeToggleTapped), for: .touchUpInside)
            button.showsMenuAsPrimaryAction = false
            button.menu = treeSortMenu()
            button.accessibilityLabel = String(localized: "topic_detail.tree_mode")
            let item = UIBarButtonItem(customView: button)
            item.accessibilityLabel = String(localized: "topic_detail.tree_mode")
            return item
        }
        let item = UIBarButtonItem(
            image: image,
            style: .plain,
            target: self,
            action: #selector(treeModeToggleTapped)
        )
        item.accessibilityLabel = String(localized: "topic_detail.tree_mode")
        return item
    }

    /// Sort picker shown on long-press of the tree-mode toggle. Hits the same
    /// nested endpoint with a different `sort` param, then reloads.
    private func treeSortMenu() -> UIMenu {
        let current = viewModel.treeSort
        let options: [(String, String, String)] = [
            ("top", String(localized: "topic_detail.tree_sort.top"), "flame"),
            ("new", String(localized: "topic_detail.tree_sort.new"), "clock"),
            ("old", String(localized: "topic_detail.tree_sort.old"), "clock.arrow.circlepath"),
        ]
        let actions = options.map { value, title, symbol -> UIAction in
            UIAction(
                title: title,
                image: UIImage(systemName: symbol),
                state: current == value ? .on : .off
            ) { [weak self] _ in
                self?.applyTreeSort(value)
            }
        }
        return UIMenu(title: String(localized: "topic_detail.tree_sort.title"), children: actions)
    }

    private func applyTreeSort(_ sort: String) {
        guard viewModel.isTreeMode, viewModel.treeSort != sort else { return }
        viewModel.treeSort = sort
        AppSettings.shared.topicTreeSort = sort
        invalidateRenderCaches()
        let token = enterPaginationContext(.jumping)
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.loadNestedTopic(id: self.topicId, sort: sort)
            self.handleLoadErrorIfNeeded()
            guard self.paginationTokenIsCurrent(token) else { return }
            let snapshot = self.buildSnapshot()
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
            self.endPaginationContext(token)
            self.navigationItem.rightBarButtonItem = self.treeModeBarButtonItem()
        }
    }

    private func updateBottomBarVisibility() {
        let isTree = viewModel.isTreeMode
        bottomBar.hidesFloorControls = isTree
        // Tree mode hides the entire bottom bar in favor of the floating FAB
        // (the bar would otherwise contain just one centered reply button).
        bottomBar.isHidden = isTree
        floatingReplyButton.isHidden = !isTree
        if isTree {
            view.bringSubviewToFront(floatingReplyButton)
            // Actual placement happens in `viewDidLayoutSubviews` once the
            // view has real bounds + safe-area insets. Trigger a layout so
            // that runs promptly when we toggled mid-session.
            view.setNeedsLayout()
        }
    }

    @objc private func floatingReplyButtonTapped() {
        replyButtonTapped()
    }

    @objc private func treeModeToggleTapped() {
        viewModel.isTreeMode.toggle()
        AppSettings.shared.topicTreeMode = viewModel.isTreeMode
        navigationItem.rightBarButtonItem = treeModeBarButtonItem()
        updateBottomBarVisibility()
        invalidateRenderCaches()
        // Each mode pulls from a different endpoint; refetch so the data
        // matches what the renderer expects (server tree vs. flat stream).
        let token = enterPaginationContext(.jumping)
        Task { [weak self] in
            guard let self else { return }
            if self.viewModel.isTreeMode {
                await self.viewModel.loadNestedTopic(id: self.topicId)
            } else {
                await self.viewModel.loadTopic(id: self.topicId, containerWidth: self.view.bounds.width)
            }
            self.handleLoadErrorIfNeeded()
            guard self.paginationTokenIsCurrent(token) else { return }
            let snapshot = self.buildSnapshot()
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
            self.endPaginationContext(token)
        }
    }

    /// Drop every render cache. Called before a window-replacing flow
    /// (`jumpToFloor`, `enableReverseOrder`, `toggleSummaryMode`) — the new
    /// posts will produce fresh heights and content views on first display.
    private func invalidateRenderCaches() {
        cellHeightCache.removeAll()
        contentViewCache.removeAll()
        precomputedBlockHeights.removeAll()
        precomputedTotalHeights.removeAll()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        contentViewCache.removeAll()
        // Heights are inexpensive compared with view trees, but clearing them
        // here guarantees stale environment entries cannot survive pressure.
        cellHeightCache.removeAll()
        precomputedBlockHeights.removeAll()
        precomputedTotalHeights.removeAll()
    }

    /// Build the diffable-data-source snapshot from the current view-model
    /// state. Pure — no side effects.
    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<Int, TopicDetailItem> {
        var snapshot = NSDiffableDataSourceSnapshot<Int, TopicDetailItem>()
        snapshot.appendSections([0])
        // Read visiblePosts first — accessing it recomputes the tree flatten,
        // which is what populates `pendingChildLoads`.
        let visible = viewModel.visiblePosts
        // Map each "view more" row's anchor post → the parents whose extra
        // replies it expands, so we can interleave the row(s) right after the
        // parent's last loaded descendant. A parent and its last child can
        // share an anchor when both have unfetched replies — render the deeper
        // one first so indentation reads top-to-bottom like the rest of the tree.
        var anchorToParents: [Int: [PendingChildLoad]] = [:]
        if viewModel.isTreeMode {
            for load in viewModel.pendingChildLoads.values {
                anchorToParents[load.anchorPostId, default: []].append(load)
            }
            for key in anchorToParents.keys {
                anchorToParents[key]?.sort { $0.depth > $1.depth }
            }
        }
        var seen = Set<Int>()
        var items: [TopicDetailItem] = []
        for post in visible {
            guard viewModel.parsedBlocks[post.id] != nil,
                  seen.insert(post.id).inserted else { continue }
            items.append(.post(post.id))
            if viewModel.expandedBoostPostIds.contains(post.id) {
                items.append(.boosts(post.id))
            }
            for load in anchorToParents[post.id] ?? [] {
                items.append(.loadMoreChildren(load.parentPostId))
            }
        }
        snapshot.appendItems(items, toSection: 0)
        return snapshot
    }

    /// Synchronously precompute block + total heights for `postIds` using the
    /// same code path the background warmup uses. Called before reading
    /// `rectForRow` so the table-view's cumulative-height math (used for
    /// scroll-position restoration) uses real heights instead of the 200pt
    /// estimate — which would otherwise drift the user's reading position
    /// by ten-plus floors after a load-earlier on text-heavy threads.
    private func precomputeHeightsSync(forPostIds postIds: [Int]) {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        if width != precomputedWidth {
            precomputedBlockHeights.removeAll(keepingCapacity: true)
            precomputedTotalHeights.removeAll(keepingCapacity: true)
            precomputedWidth = width
        }
        let chrome = PostNativeCell.chromeHeight()
        let stackSpacing = NativeContentRenderer.contentStackSpacing
        let isTreeMode = viewModel.isTreeMode
        for postId in postIds {
            guard precomputedBlockHeights[postId] == nil,
                  let blocks = viewModel.parsedBlocks[postId]
            else { continue }
            // Indent shrinks the per-post content width, so heights must be
            // measured at the post's actual depth — not at the flat-mode width.
            let depth = isTreeMode ? (viewModel.postDepths[postId] ?? 0) : 0
            let indent = PostNativeCell.treeContentIndent(forDepth: depth)
            let config = NativeRenderConfig.default(contentWidth: width - 24 - indent, baseURL: baseURL)
            let heights = BlockHeightCalculator.perBlockHeights(annotatedBlocks: blocks, config: config)
            precomputedBlockHeights[postId] = heights
            if heights.allSatisfy({ $0 != nil }) {
                let resolved = heights.compactMap { $0 }
                let contentH = resolved.isEmpty
                    ? 0
                    : resolved.reduce(0, +) + CGFloat(heights.count - 1) * stackSpacing
                precomputedTotalHeights[postId] = chrome + contentH
            }
        }
    }

    /// Apply `snapshot` and scroll so the row for `floor` lands at the
    /// requested screen position. Uses a two-pass approach so the offset
    /// is accurate even when cell heights are still estimates near the
    /// target row.
    private func applyJumpSnapshot(target floor: Int, position: UITableView.ScrollPosition) {
        let snapshot = buildSnapshot()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dataSource.apply(snapshot, animatingDifferences: false)
        CATransaction.commit()

        guard let postIndex = viewModel.visibleRowForFloor(floor),
              let safeRow = tableRow(forVisiblePostIndex: postIndex)
        else { return }
        let indexPath = IndexPath(row: safeRow, section: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tableView.scrollToRow(at: indexPath, at: position, animated: false)
        CATransaction.commit()
        tableView.layoutIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tableView.scrollToRow(at: indexPath, at: position, animated: false)
        CATransaction.commit()
        lastScrollOffset = tableView.contentOffset.y
        // Keep a retry target in case the cell's height changes later (async
        // image loads, delayed content sizing).
        pendingScrollIndexPath = (indexPath, position)
    }

    /// Apply `snapshot` after a load-earlier prepend, keeping the anchor
    /// post visually anchored. New posts' heights are precomputed first so
    /// the cumulative-height math used by `rectForRow` is accurate.
    /// Apply the prepend, anchoring the cell that was at the top of the
    /// viewport at apply time to the same screen position.
    ///
    /// Always called from a settled scroll view (the trigger path defers via
    /// `pendingLoadEarlier`), so no pan/decel fighting.
    ///
    /// The naive `contentOffset += deltaHeight` approach was off by several
    /// floors when prepended posts contained blocks BlockHeightCalculator
    /// can't size (table / details / poll / rawHTML) — those fall back to a
    /// 200pt estimate, and `contentSize` grows by less than the real total.
    ///
    /// Instead: scroll the anchor row to the top, then offset by its
    /// captured screen-Y. UITableView positions cells using the same
    /// (possibly estimated) cumulative heights it uses to compute
    /// `rectForRow`, so even when those numbers are wrong in absolute terms
    /// the anchor cell still lands at exactly the screen position we asked
    /// for — internally consistent is enough for visual correctness.
    private func applyLoadEarlierSnapshot(addedPostIds: [Int]) {
        precomputeHeightsSync(forPostIds: addedPostIds)
        let unresolved = addedPostIds.filter { precomputedTotalHeights[$0] == nil }

        // Capture the top visible row AT APPLY TIME (not at trigger time) —
        // the user may have moved between trigger and apply, and the row
        // they're actually looking at when the snapshot lands is the one
        // we want to anchor to.
        var anchor: (postId: Int, screenY: CGFloat)?
        if let topVisible = tableView.indexPathsForVisibleRows?.sorted().first,
           let item = dataSource.itemIdentifier(for: topVisible)
        {
            let postId: Int
            switch item {
            case .post(let id), .boosts(let id), .loadMoreChildren(let id): postId = id
            }
            let cellMinY = tableView.rectForRow(at: topVisible).minY
            let screenY = cellMinY - tableView.contentOffset.y
            anchor = (postId, screenY)
        }

        let snapshot = buildSnapshot()
        debugLog("[loadEarlier] applying snapshotItems=\(snapshot.itemIdentifiers.count) added=\(addedPostIds.count) heightsUnresolved=\(unresolved.count) anchor=\(anchor.map { "post#\($0.postId)@\($0.screenY)" } ?? "nil")")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dataSource.apply(snapshot, animatingDifferences: false)
        CATransaction.commit()

        guard let anchor,
              let newIndexPath = dataSource.indexPath(for: .post(anchor.postId))
        else {
            debugLog("[loadEarlier] anchor lookup failed — falling back to deltaHeight shift")
            // Fallback: shift by content-size delta. Imprecise for posts
            // with unsizable blocks, but better than nothing.
            tableView.layoutIfNeeded()
            lastScrollOffset = tableView.contentOffset.y
            return
        }

        // Two-pass scrollToRow + layoutIfNeeded:
        //   pass 1 — places the anchor at top using estimated cumulative
        //            heights for the just-prepended rows (they're not yet
        //            displayed and lack precomputed heights for poll-like
        //            blocks);
        //   layoutIfNeeded forces the anchor + cells just below it to
        //            render, populating their real heights;
        //   pass 2 — re-places using whatever is now known, mostly to
        //            absorb any contentSize adjustment UITableView did
        //            during the layout pass.
        // Then a final manual offset to honor the anchor's captured screen-Y
        // (rather than pinning the anchor exactly at the top edge).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tableView.scrollToRow(at: newIndexPath, at: .top, animated: false)
        CATransaction.commit()
        tableView.layoutIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tableView.scrollToRow(at: newIndexPath, at: .top, animated: false)
        let cellMinY = tableView.rectForRow(at: newIndexPath).minY
        tableView.contentOffset.y = cellMinY - anchor.screenY
        CATransaction.commit()
        debugLog("[loadEarlier] anchored — newCellMinY=\(cellMinY) screenY=\(anchor.screenY) offset=\(tableView.contentOffset.y)")
        lastScrollOffset = tableView.contentOffset.y
    }

    /// Apply `snapshot` after a load-more append, preserving the current
    /// scroll position so the user's reading position doesn't jump.
    private func applyLoadMoreSnapshot(addedPostIds: [Int]) {
        // Build first: iterating `visiblePosts` recomputes `postDepths`, which
        // `precomputeHeightsSync` reads to size each new tree-mode row at its
        // depth-indented width. Measuring before the depths refresh sizes the
        // freshly-loaded (deeper) posts at the flat full width and clips them.
        let snapshot = buildSnapshot()
        precomputeHeightsSync(forPostIds: addedPostIds)
        let offsetBefore = tableView.contentOffset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dataSource.apply(snapshot, animatingDifferences: false)
        if abs(tableView.contentOffset.y - offsetBefore.y) > 1 {
            tableView.contentOffset = offsetBefore
        }
        CATransaction.commit()
        lastScrollOffset = tableView.contentOffset.y
    }

    override func updateUI() {
        let uiStart = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - uiStart) * 1000
            if ms > 1 { FrameDropDetector.shared.log("updateUI \(String(format: "%.1f", ms))ms") }
        }
        // Refresh tree-mode-dependent chrome when the VM flips the flag —
        // see `lastSeenTreeMode` doc for why.
        if lastSeenTreeMode != viewModel.isTreeMode {
            lastSeenTreeMode = viewModel.isTreeMode
            navigationItem.rightBarButtonItem = treeModeBarButtonItem()
            updateBottomBarVisibility()
        }

        // Title header (set once, but rebuild when canLoadEarlier changes after a jump)
        if let topic = viewModel.topic, !hasTitleHeader {
            let displayTitle = topic.fancyTitle ?? topic.title
            configureTitleLabel(displayTitle)
            updateTitleHeader()
            hasTitleHeader = true
        }

        // Loading
        if viewModel.isLoading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }

        // Error
        if let error = viewModel.errorMessage {
            errorLabel.text = error
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }

        // Footer slot — avoid replacing tableFooterView repeatedly as it
        // changes contentSize. Three states share the slot: spinner while a
        // load-more is in flight, retry control when one failed, otherwise
        // a zero-height placeholder.
        if viewModel.loadMoreFailed {
            if footerSpinner.isAnimating { footerSpinner.stopAnimating() }
            if tableView.tableFooterView !== footerRetryView {
                tableView.tableFooterView = footerRetryView
            }
        } else if viewModel.isLoadingMore {
            if tableView.tableFooterView !== footerSpinner {
                tableView.tableFooterView = footerSpinner
            }
            footerSpinner.startAnimating()
        } else if footerSpinner.isAnimating || tableView.tableFooterView === footerRetryView {
            footerSpinner.stopAnimating()
            tableView.tableFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))
        }

        // Top loading bar for loading earlier posts
        if viewModel.isLoadingEarlier {
            UIView.animate(withDuration: 0.25) {
                self.topLoadingBar.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.25) {
                self.topLoadingBar.alpha = 0
            }
        }

        // OP filter button state
        bottomBar.setOPOnlySelected(viewModel.isFilteringByOP)

        // Snapshot apply — skipped when a pagination flow is mid-flight
        // (the flow's own Task will apply synchronously once the VM await
        // returns, with the right anchor / scroll-target context).
        if viewModel.isReady {
            tableView.isHidden = false
            if case .idle = paginationContext {
                let snapshot = buildSnapshot()
                let current = dataSource.snapshot()
                if snapshot.itemIdentifiers != current.itemIdentifiers {
                    let offsetBefore = current.numberOfItems > 0 ? tableView.contentOffset : nil
                    dataSource.apply(snapshot, animatingDifferences: false)
                    if let offsetBefore, abs(tableView.contentOffset.y - offsetBefore.y) > 1 {
                        tableView.contentOffset = offsetBefore
                    }
                }
            }
            warmHeightCacheInBackground()
        }
    }

    private func updateTitleHeader() {
        let container = UIView()
        container.addSubview(titleLabel)
        container.addSubview(tagsContainer)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let tags = viewModel.topic?.tags ?? []
        configureTags(tags)
        let hasVisibleTags = !tags.isEmpty

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            tagsContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: hasVisibleTags ? 8 : 0),
            tagsContainer.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            tagsContainer.trailingAnchor.constraint(lessThanOrEqualTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            tagsContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        let targetSize = CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height)
        let size = container.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        container.frame.size = size
        tableView.tableHeaderView = container
    }

    private func configureTags(_ tags: [DiscourseTopicDetail.Tag]) {
        tagsContainer.subviews.forEach { $0.removeFromSuperview() }
        tagsContainer.constraints.forEach { tagsContainer.removeConstraint($0) }
        guard !tags.isEmpty else { return }

        let hSpacing: CGFloat = 6
        let vSpacing: CGFloat = 6
        let maxWidth = tableView.bounds.width - 32 // 16pt padding on each side

        var buttons: [UIButton] = []
        for tag in tags {
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.filled()
            config.title = tag.name
            config.baseForegroundColor = ThemeManager.shared.accentColor
            config.baseBackgroundColor = ThemeManager.shared.codeBackgroundColor
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = FontManager.shared.font(size: 13, weight: .medium)
                return outgoing
            }
            config.image = UIImage(systemName: "tag")
            config.imagePadding = 4
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            button.configuration = config
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                let vc = TagTopicsViewController(api: self.api, tag: tag)
                self.navigationController?.pushViewController(vc, animated: true)
            }, for: .touchUpInside)
            buttons.append(button)
        }

        // Flow layout: calculate positions with line wrapping
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for button in buttons {
            let size = button.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + vSpacing
                lineHeight = 0
            }
            button.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            tagsContainer.addSubview(button)
            x += size.width + hSpacing
            lineHeight = max(lineHeight, size.height)
        }
        let totalHeight = y + lineHeight
        tagsContainer.heightAnchor.constraint(equalToConstant: totalHeight).isActive = true
    }

    // MARK: - Emoji Title

    private static let emojiPattern = try! NSRegularExpression(pattern: ":[\\w\\-+]+:")

    private func configureTitleLabel(_ title: String) {
        guard !EmojiStore.lookupMap.isEmpty else {
            titleLabel.text = title
            navTitleLabel.text = title
            return
        }
        let matches = Self.emojiPattern.matches(in: title, range: NSRange(title.startIndex..., in: title))
        let hasEmoji = matches.contains(where: {
            let nsTitle = title as NSString
            let full = nsTitle.substring(with: $0.range)
            let code = String(full.dropFirst().dropLast())
            return EmojiStore.url(for: code) != nil
        })
        guard hasEmoji else {
            titleLabel.text = title
            navTitleLabel.text = title
            return
        }

        let headerResult = buildEmojiAttributedString(title, font: titleLabel.font ?? FontManager.shared.font(size: 20, weight: .bold))
        let navResult = buildEmojiAttributedString(title, font: navTitleLabel.font ?? FontManager.shared.font(size: 17, weight: .semibold))

        titleLabel.attributedText = headerResult
        navTitleLabel.attributedText = navResult
        navTitleLabel.sizeToFit()
        loadTitleEmojiImages(in: headerResult, label: titleLabel)
        loadTitleEmojiImages(in: navResult, label: navTitleLabel)
    }

    private func buildEmojiAttributedString(_ title: String, font: UIFont) -> NSMutableAttributedString {
        let matches = Self.emojiPattern.matches(in: title, range: NSRange(title.startIndex..., in: title))
        let result = NSMutableAttributedString()
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var lastEnd = title.startIndex

        for match in matches {
            guard let fullRange = Range(match.range, in: title) else { continue }
            let code = String(title[fullRange].dropFirst().dropLast())

            if lastEnd < fullRange.lowerBound {
                result.append(NSAttributedString(string: String(title[lastEnd..<fullRange.lowerBound]), attributes: attrs))
            }

            if let urlString = EmojiStore.url(for: code), let url = URL(string: urlString) {
                let attachment = EmojiTextAttachment()
                attachment.emojiURL = url
                attachment.bounds = CGRect(x: 0, y: font.descender, width: font.lineHeight, height: font.lineHeight)
                result.append(NSAttributedString(attachment: attachment))
            } else {
                result.append(NSAttributedString(string: String(title[fullRange]), attributes: attrs))
            }

            lastEnd = fullRange.upperBound
        }

        if lastEnd < title.endIndex {
            result.append(NSAttributedString(string: String(title[lastEnd...]), attributes: attrs))
        }
        return result
    }

    private func loadTitleEmojiImages(in attributedString: NSMutableAttributedString, label: UILabel) {
        attributedString.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedString.length)) { value, _, _ in
            guard let attachment = value as? EmojiTextAttachment, let url = attachment.emojiURL else { return }
            SDWebImageManager.shared.loadImage(with: url, options: [], context: ImageCacheManager.shared.emojiContext, progress: nil) { [weak self] image, _, _, _, _, _ in
                guard let image, let self else { return }
                attachment.image = image
                label.setNeedsDisplay()
                self.view.setNeedsLayout()
            }
        }
    }

    // MARK: - Container Access

    private func replyButtonTapped() {
        guard let authGate = findAuthGating() else { return }
        authGate.requireAuth { [weak self] in
            self?.presentReplyComposer()
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

    // MARK: - Link Handling

    private func handleLink(_ url: URL) {
        guard isWebURL(url) else {
            UIApplication.shared.open(url)
            return
        }

        guard let baseHost = URL(string: baseURL)?.host,
              let linkHost = url.host
        else {
            presentForumWebView(url, forumBaseURL: baseURL)
            return
        }

        if linkHost.caseInsensitiveCompare(baseHost) == .orderedSame {
            if let route = ForumTopicLinkParser.parse(url, baseURL: baseURL) {
                let detailVC = TopicDetailControllerFactory.make(
                    api: api,
                    topicId: route.topicId,
                    initialFloor: route.floor
                )
                navigationController?.pushViewController(detailVC, animated: true)
            } else if let (slug, categoryId) = parseCategoryInfo(from: url) {
                let category = DiscourseCategory(id: categoryId, name: slug, slug: slug)
                let vc = CategoryTopicsViewController(api: api, category: category)
                navigationController?.pushViewController(vc, animated: true)
            } else if let tag = parseTagInfo(from: url) {
                let vc = TagTopicsViewController(api: api, tag: tag)
                navigationController?.pushViewController(vc, animated: true)
            } else if let username = parseUsername(from: url) {
                let vc = UserProfileViewController(api: api, username: username)
                navigationController?.pushViewController(vc, animated: true)
            } else {
                presentForumWebView(url, forumBaseURL: baseURL)
            }
        } else {
            presentForumWebView(url, forumBaseURL: baseURL)
        }
    }

    private func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func parseCategoryInfo(from url: URL) -> (slug: String, id: Int)? {
        let components = url.pathComponents
        guard let cIndex = components.firstIndex(of: "c"),
              cIndex + 2 < components.count else { return nil }
        let remaining = Array(components[(cIndex + 1)...])
        // Format: /c/slug/id or /c/parent-slug/child-slug/id
        // The last numeric component is the category ID, slug is right before it
        for i in remaining.indices.reversed() {
            let cleaned = remaining[i].replacingOccurrences(of: ".json", with: "")
            if let id = Int(cleaned), i > 0 {
                let slug = remaining[i - 1]
                return (slug, id)
            }
        }
        return nil
    }

    private func parseTagInfo(from url: URL) -> DiscourseTopicDetail.Tag? {
        let components = url.pathComponents

        if let tagIndex = components.firstIndex(where: { $0 == "tag" || $0 == "tags" }),
           tagIndex + 2 < components.count
        {
            let tagName = components[tagIndex + 1]
            let tagIdString = components[tagIndex + 2]

            // 转 Int，失败就返回 nil
            if let tagId = Int(tagIdString) {
                return DiscourseTopicDetail.Tag(id: tagId, name: tagName, slug: tagName)
            }
        }

        return nil
    }

    private func parseUsername(from url: URL) -> String? {
        let components = url.pathComponents
        // Format: /u/{username}
        guard let uIndex = components.firstIndex(of: "u"),
              uIndex + 1 < components.count else { return nil }
        return components[uIndex + 1]
    }

    private func parseTagName(from url: URL) -> String? {
        let components = url.pathComponents
        // Format: /tag/{tag_name} or /tags/{tag_name}
        if let tagIndex = components.firstIndex(where: { $0 == "tag" || $0 == "tags" }),
           tagIndex + 1 < components.count
        {
            return components[tagIndex + 1]
        }
        return nil
    }
}

// MARK: - TopicDetailBottomBarDelegate

extension LegacyTopicDetailViewController: TopicDetailBottomBarDelegate {
    func bottomBarDidTapOPOnly() {
        viewModel.isFilteringByOP.toggle()
    }

    func bottomBarDidTapJumpToFloor() {
        let total = viewModel.totalFloors
        guard total > 0 else { return }

        let sheet = JumpToFloorSheetViewController(
            totalFloors: total,
            currentFloor: currentVisibleFloor() ?? 1,
            firstUnreadFloor: firstUnreadFloor(),
            isReverseOrder: viewModel.isReverseOrder,
            isSummaryMode: viewModel.isSummaryMode
        )
        sheet.onJump = { [weak self] floor in
            self?.performJump(toFloor: floor)
        }
        sheet.onToggleReverseOrder = { [weak self] in
            self?.bottomBarDidToggleReverseOrder()
        }
        sheet.onToggleSummaryMode = { [weak self] in
            self?.bottomBarDidToggleSummaryMode()
        }
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium()]
            presentation.prefersGrabberVisible = true
        }
        present(sheet, animated: true)
    }

    func bottomBarDidTapScrollToTop() {
        tableView.setContentOffset(
            CGPoint(x: tableView.contentOffset.x, y: -tableView.adjustedContentInset.top),
            animated: !UIAccessibility.isReduceMotionEnabled
        )
    }

    /// Convert a `visiblePosts` index into the table view's row index, taking
    /// into account that each preceding post with an **expanded** boost row —
    /// or a trailing tree-mode "view more replies" row — adds one extra row to
    /// the snapshot. Clamped to the current row count to defend against a
    /// snapshot/cell-state mismatch (out-of-bounds crash).
    private func tableRow(forVisiblePostIndex postIndex: Int) -> Int? {
        let rowCount = tableView.numberOfRows(inSection: 0)
        guard rowCount > 0 else { return nil }
        var targetRow = postIndex
        let expanded = viewModel.expandedBoostPostIds
        let visible = viewModel.visiblePosts
        // Count of "view more" rows anchored after each post (inserted below).
        var loadMoreCounts: [Int: Int] = [:]
        for load in viewModel.pendingChildLoads.values {
            loadMoreCounts[load.anchorPostId, default: 0] += 1
        }
        for i in 0..<min(postIndex, visible.count) {
            if expanded.contains(visible[i].id) { targetRow += 1 }
            targetRow += loadMoreCounts[visible[i].id] ?? 0
        }
        return min(targetRow, rowCount - 1)
    }

    /// Resolve the floor of the topmost visible row. UIKit doesn't formally
    /// guarantee `indexPathsForVisibleRows` is ordered, and stale entries can
    /// linger mid-snapshot-apply, so we sort and iterate until a valid post
    /// is found — protects against the scrubber opening at a stale "last
    /// loaded" floor after a jump.
    private func currentVisibleFloor() -> Int? {
        guard let visible = tableView.indexPathsForVisibleRows, !visible.isEmpty else {
            return nil
        }
        for indexPath in visible.sorted() {
            guard let item = dataSource.itemIdentifier(for: indexPath) else { continue }
            let postId: Int
            switch item {
            case .post(let id), .boosts(let id), .loadMoreChildren(let id):
                postId = id
            }
            if let post = viewModel.postsById[postId] {
                return post.postNumber
            }
        }
        return nil
    }

    /// First floor the authenticated user hasn't read yet, if Discourse
    /// reported `last_read_post_number`. Returns `nil` when everything is
    /// read or the field is missing (anonymous fetch).
    private func firstUnreadFloor() -> Int? {
        guard let lastRead = viewModel.topic?.lastReadPostNumber,
              lastRead > 0,
              lastRead < viewModel.totalFloors
        else { return nil }
        return lastRead + 1
    }

    private func performJump(toFloor floor: Int) {
        guard floor >= 1 else { return }

        // Tree mode can't locate an arbitrary floor reliably: posts are in DFS
        // order, the target may be a deep or not-yet-loaded child, and
        // `allPostIds` is hash-keyed rather than stream-ordered there — so
        // `jumpToFloor`'s index math would address the wrong post. Force-exit to
        // the flat stream, reload, then jump. Done before the `totalFloors`
        // bound check below: in tree mode that count reflects only the loaded
        // subtree, so a valid higher floor would otherwise be wrongly rejected.
        if viewModel.isTreeMode {
            performJumpAfterExitingTreeMode(toFloor: floor)
            return
        }

        let total = viewModel.totalFloors
        guard floor <= total else { return }

        // Fast path: floor already in the current window — just scroll.
        // Take the .jumping context for the duration of the animation so the
        // intra-animation scroll callbacks don't trigger a stray load-earlier
        // with an anchor captured at some intermediate row.
        if viewModel.isFloorLoaded(floor),
           let postIndex = viewModel.visibleRowForFloor(floor),
           let safeRow = tableRow(forVisiblePostIndex: postIndex)
        {
            let token = enterPaginationContext(.jumping)
            fastPathScrollToken = token
            tableView.scrollToRow(
                at: IndexPath(row: safeRow, section: 0),
                at: .top,
                animated: true
            )
            return
        }

        // Slow path: replace the window. The pagination context gates
        // `updateUI`'s default snapshot apply, then our Task applies the new
        // snapshot + scroll in one synchronous step once the VM await returns.
        showJumpOverlay()
        hasTitleHeader = false
        invalidateRenderCaches()
        let token = enterPaginationContext(.jumping)
        Task {
            await viewModel.jumpToFloor(floor, containerWidth: view.bounds.width)
            guard paginationTokenIsCurrent(token) else {
                hideJumpOverlay()
                return
            }
            applyJumpSnapshot(target: floor, position: .top)
            endPaginationContext(token)
            hideJumpOverlay()
        }
    }

    /// Drop out of tree mode, reload the flat stream centered on `floor`, then
    /// scroll there. `jumpToFloor` can't run against the tree window
    /// (`allPostIds` is hash-keyed), so we re-fetch via the flat endpoint —
    /// `near_post_number` lands the target in the loaded window in one request.
    private func performJumpAfterExitingTreeMode(toFloor floor: Int) {
        exitTreeModeSideEffects()
        showJumpOverlay()
        hasTitleHeader = false
        let token = enterPaginationContext(.jumping)
        Task {
            await viewModel.loadTopic(id: topicId, containerWidth: view.bounds.width, nearPostNumber: floor)
            guard paginationTokenIsCurrent(token) else {
                hideJumpOverlay()
                return
            }
            applyJumpSnapshot(target: floor, position: .top)
            endPaginationContext(token)
            hideJumpOverlay()
        }
    }

    /// Side effects of leaving tree mode without re-fetching: flip the flag,
    /// refresh the toolbar toggle + bottom bar, and wipe render caches (tree
    /// indent shrinks the content width, so every cached height is stale).
    /// Deliberately does NOT persist `AppSettings.topicTreeMode` — a forced exit
    /// for a jump shouldn't permanently change the user's default reading mode.
    private func exitTreeModeSideEffects() {
        guard viewModel.isTreeMode else { return }
        viewModel.isTreeMode = false
        navigationItem.rightBarButtonItem = treeModeBarButtonItem()
        updateBottomBarVisibility()
        invalidateRenderCaches()
    }

    private func showJumpOverlay() {
        if jumpOverlay.superview == nil {
            view.addSubview(jumpOverlay)
            NSLayoutConstraint.activate([
                jumpOverlay.topAnchor.constraint(equalTo: tableView.topAnchor),
                jumpOverlay.leadingAnchor.constraint(equalTo: tableView.leadingAnchor),
                jumpOverlay.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),
                jumpOverlay.bottomAnchor.constraint(equalTo: tableView.bottomAnchor),
            ])
        }
        jumpOverlay.isHidden = false
    }

    private func hideJumpOverlay() {
        jumpOverlay.isHidden = true
    }

    func bottomBarDidTapReply() {
        replyButtonTapped()
    }

    var bottomBarIsReverseOrder: Bool { viewModel.isReverseOrder }
    var bottomBarIsSummaryMode: Bool { viewModel.isSummaryMode }

    func bottomBarDidToggleReverseOrder() {
        if viewModel.isReverseOrder {
            // Turning OFF — keep loaded data, just flip the flag. Existing
            // `loadEarlier` / `loadMore` direction returns to canonical.
            viewModel.isReverseOrder = false
            return
        }
        // Turning ON — clear caches and re-fetch OP + last batch.
        hasTitleHeader = false
        invalidateRenderCaches()
        showJumpOverlay()
        let token = enterPaginationContext(.jumping)
        Task {
            await viewModel.enableReverseOrder(containerWidth: view.bounds.width)
            guard paginationTokenIsCurrent(token) else {
                hideJumpOverlay()
                return
            }
            // Reverse mode pins OP at the top of `visiblePosts`; apply the
            // snapshot and let UIKit settle on offset 0 (the OP).
            let snapshot = buildSnapshot()
            dataSource.apply(snapshot, animatingDifferences: false, completion: nil)
            tableView.contentOffset.y = -tableView.adjustedContentInset.top
            endPaginationContext(token)
            hideJumpOverlay()
        }
    }

    func bottomBarDidToggleSummaryMode() {
        // Summary view is a server-filtered re-fetch — invalidate everything
        // that would otherwise hold stale per-floor state.
        hasTitleHeader = false
        invalidateRenderCaches()
        showJumpOverlay()
        let token = enterPaginationContext(.jumping)
        Task {
            await viewModel.toggleSummaryMode(containerWidth: view.bounds.width)
            guard paginationTokenIsCurrent(token) else {
                hideJumpOverlay()
                return
            }
            let snapshot = buildSnapshot()
            dataSource.apply(snapshot, animatingDifferences: false, completion: nil)
            tableView.contentOffset.y = -tableView.adjustedContentInset.top
            endPaginationContext(token)
            hideJumpOverlay()
        }
    }

    // MARK: - Scrubber (continuous long-press → drag → release)

    func bottomBarDidBeginScrubFromJump(at locationInWindow: CGPoint, buttonFrame: CGRect) {
        let total = viewModel.totalFloors
        guard total > 1, jumpScrubber == nil else { return }

        let startingFloor = currentVisibleFloor() ?? 1
        jumpScrubStartLocation = view.convert(locationInWindow, from: nil)
        jumpScrubHasMoved = false
        jumpScrubStartFloor = startingFloor

        // Reference distance = the more restrictive of the two reachable
        // halves (left or right of the press point, minus a comfortable
        // bezel margin). Dragging this distance in either direction sweeps
        // the entire range; overshoot is naturally clamped at floor 1 / last.
        // Constant on both sides so the sensitivity is identical going left
        // or right — same drag → same number of floors, no matter where
        // you start in the topic.
        let safeMargin: CGFloat = 60
        let leftSpace = max(jumpScrubStartLocation.x - safeMargin, 1)
        let rightSpace = max(view.bounds.width - jumpScrubStartLocation.x - safeMargin, 1)
        jumpScrubReferenceDistance = min(leftSpace, rightSpace)

        // Compact arc, centred horizontally above the bottom bar.
        let barTopInView = bottomBar.convert(bottomBar.bounds, to: view).minY
        let radius: CGFloat = 130
        let arcCenter = CGPoint(x: view.bounds.midX, y: barTopInView - 24)

        let overlay = JumpScrubberOverlay(
            totalFloors: total,
            startingFloor: startingFloor,
            arcCenter: arcCenter,
            radius: radius
        )
        overlay.frame = view.bounds
        overlay.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(overlay)
        overlay.presentTransitionIn()
        jumpScrubber = overlay

        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    func bottomBarDidUpdateScrub(at locationInWindow: CGPoint) {
        guard let overlay = jumpScrubber else { return }
        let location = view.convert(locationInWindow, from: nil)

        // Don't apply any floor change until the user crosses the move
        // threshold — a stray press-then-release shouldn't confirm a stray
        // floor.
        if !jumpScrubHasMoved {
            let dist = hypot(
                location.x - jumpScrubStartLocation.x,
                location.y - jumpScrubStartLocation.y
            )
            guard dist >= jumpScrubMoveThreshold else { return }
            jumpScrubHasMoved = true
        }

        // Constant sensitivity: a given drag distance always corresponds to
        // the same number of floors, regardless of starting floor. From the
        // middle, dragging X pts feels like dragging X pts from floor 1.
        // Overshoot is clamped to the boundary at the end of the calculation.
        let dx = location.x - jumpScrubStartLocation.x
        let total = viewModel.totalFloors
        let normalized = min(abs(dx) / jumpScrubReferenceDistance, 1.0)
        let curved = pow(normalized, 1.8)
        let delta = Int((curved * CGFloat(total - 1)).rounded())
        let signedDelta = dx >= 0 ? delta : -delta
        let newFloor = max(1, min(total, jumpScrubStartFloor + signedDelta))
        overlay.update(floor: newFloor)
    }

    func bottomBarDidEndScrub(cancelled: Bool) {
        guard let overlay = jumpScrubber else { return }
        jumpScrubber = nil
        overlay.presentTransitionOut()

        // Only jump if the user actually moved and the gesture wasn't
        // interrupted — otherwise the gesture was a no-op accidental press.
        if cancelled || !jumpScrubHasMoved { return }
        let floor = overlay.currentFloor
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        performJump(toFloor: floor)
    }
}

// MARK: - UITableViewDelegate

extension LegacyTopicDetailViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        // The tree-mode "view more replies" row is a fixed-size compact row.
        if case .loadMoreChildren = dataSource.itemIdentifier(for: indexPath) {
            return LoadMoreChildrenCell.cellHeight
        }
        // Collapsed parents render as a fixed-size compact row — short-circuit
        // both the layout solver and the precompute cache.
        if case .post(let postId) = dataSource.itemIdentifier(for: indexPath),
           viewModel.isTreeMode, viewModel.collapsedPostIds.contains(postId)
        {
            return PostCollapsedCell.cellHeight
        }
        // Skip systemLayoutSizeFitting entirely when we have a precomputed total
        // for this post — that's the whole point of BlockHeightCalculator.
        if case .post(let postId) = dataSource.itemIdentifier(for: indexPath),
           let precomputed = precomputedTotalHeights[postId]
        {
            return precomputed
        }
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        if case .loadMoreChildren = dataSource.itemIdentifier(for: indexPath) {
            return LoadMoreChildrenCell.cellHeight
        }
        if case .post(let postId) = dataSource.itemIdentifier(for: indexPath),
           viewModel.isTreeMode, viewModel.collapsedPostIds.contains(postId)
        {
            return PostCollapsedCell.cellHeight
        }
        if case .post(let postId) = dataSource.itemIdentifier(for: indexPath),
           let precomputed = precomputedTotalHeights[postId]
        {
            return precomputed
        }
        if let item = dataSource.itemIdentifier(for: indexPath),
           let cached = cellHeightCache[item]
        {
            return cached
        }
        return 200
    }

    /// Lazily fills `precomputedBlockHeights` / `precomputedTotalHeights` for a
    /// post. A width change wipes the entire cache first — block heights are
    /// width-dependent (text wrapping, image scale).
    private func precomputeHeights(
        forPostId postId: Int,
        blocks: [AnnotatedBlock],
        config: NativeRenderConfig,
        tableWidth: CGFloat
    ) {
        if tableWidth != precomputedWidth {
            precomputedBlockHeights.removeAll(keepingCapacity: true)
            precomputedTotalHeights.removeAll(keepingCapacity: true)
            precomputedWidth = tableWidth
        }
        if precomputedBlockHeights[postId] != nil { return }
        // Background warmup didn't get to this post in time — fall back to
        // synchronous computation. Log the cost so we can tell sync misses
        // apart from cache hits when reading the trace.
        let t0 = CACurrentMediaTime()
        let heights = BlockHeightCalculator.perBlockHeights(annotatedBlocks: blocks, config: config)
        let ms = (CACurrentMediaTime() - t0) * 1000
        if ms > 1 {
            let nilCount = heights.filter { $0 == nil }.count
            debugLog(
                "syncPrecompute post#\(postId) blocks=\(blocks.count) entries=\(heights.count) unsupported=\(nilCount) \(String(format: "%.1f", ms))ms"
            )
        }
        precomputedBlockHeights[postId] = heights
        // Total cell height is only computable when every block is measurable.
        // Posts with one-off unsupported blocks (table/details/poll/rawHTML)
        // still get per-paragraph pinning above; they just fall back to
        // `automaticDimension` for the overall cell sizing.
        if heights.allSatisfy({ $0 != nil }) {
            let spacing = NativeContentRenderer.contentStackSpacing
            let resolved = heights.compactMap { $0 }
            let contentH = resolved.isEmpty ? 0 : resolved.reduce(0, +) + CGFloat(heights.count - 1) * spacing
            precomputedTotalHeights[postId] = PostNativeCell.chromeHeight() + contentH
        }
    }

    /// Drops cached heights for a post so the next display recomputes them.
    /// Call after a mutation that may have re-parsed `parsedBlocks`.
    func invalidatePrecomputedHeights(forPostId postId: Int) {
        precomputedBlockHeights.removeValue(forKey: postId)
        precomputedTotalHeights.removeValue(forKey: postId)
    }

    /// Pre-warm `precomputedBlockHeights` / `precomputedTotalHeights` on a
    /// background queue for every parsed post that hasn't been measured yet.
    /// Idempotent — only computes for missing entries. Safe to call multiple
    /// times (e.g., from both `viewDidLayoutSubviews` and after each snapshot
    /// apply when posts arrive incrementally).
    ///
    /// `BlockHeightCalculator` and `NSAttributedString.boundingRect` are both
    /// thread-safe; we capture an immutable `NativeRenderConfig` on the main
    /// thread (UIFont metrics) and let the worker walk the snapshotted blocks.
    /// Results are merged back on the main thread, gated by the width tag so
    /// stale results from a prior rotation don't pollute the current cache.
    private func warmHeightCacheInBackground() {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        // Clear stale cache before scheduling new work.
        if width != precomputedWidth {
            precomputedBlockHeights.removeAll(keepingCapacity: true)
            precomputedTotalHeights.removeAll(keepingCapacity: true)
            precomputedWidth = width
        }
        // Snapshot the post -> blocks map (plus per-post tree depth) for the
        // work queue. Depth determines the indent and therefore the effective
        // content width — measuring at a wrong width would invalidate the
        // cached heights the moment the cell renders.
        let isTreeMode = viewModel.isTreeMode
        let depths = viewModel.postDepths
        var pending: [(Int, [AnnotatedBlock], Int)] = []
        for (postId, blocks) in viewModel.parsedBlocks {
            if precomputedBlockHeights[postId] == nil {
                let depth = isTreeMode ? (depths[postId] ?? 0) : 0
                pending.append((postId, blocks, depth))
            }
        }
        guard !pending.isEmpty else {
            // Useful as a heartbeat — confirms the trigger fires even when
            // the cache is already warm. `debugLog` so it doesn't get swallowed
            // by `FrameDropDetector`'s drop-only printing.
            debugLog("heightWarmup skipped: all \(viewModel.parsedBlocks.count) parsed posts already cached")
            return
        }
        // Skip if a warmup at the same width is already running — it will
        // pick up these post IDs (we re-snapshot inside the worker).
        if heightWarmupInFlightWidth == width {
            debugLog("heightWarmup skipped: in-flight (pending would be \(pending.count))")
            return
        }
        heightWarmupInFlightWidth = width
        debugLog("heightWarmup dispatching posts=\(pending.count) width=\(Int(width))")

        let baseURLCaptured = baseURL
        let chrome = PostNativeCell.chromeHeight()
        let stackSpacing = NativeContentRenderer.contentStackSpacing

        heightWarmupQueue.async { [weak self] in
            let t0 = CACurrentMediaTime()
            var newHeights: [Int: [CGFloat?]] = [:]
            var newTotals: [Int: CGFloat] = [:]
            // Find the top-3 most expensive posts in this batch so we can see
            // outliers in the trace without spamming a per-post line for
            // every post in the topic.
            var perPostMs: [(postId: Int, ms: Double, blocks: Int, nilCount: Int)] = []
            for (postId, blocks, depth) in pending {
                let pt0 = CACurrentMediaTime()
                let indent = PostNativeCell.treeContentIndent(forDepth: depth)
                let config = NativeRenderConfig.default(contentWidth: width - 24 - indent, baseURL: baseURLCaptured)
                let (heights, profile) = BlockHeightCalculator.perBlockHeightsProfiled(
                    annotatedBlocks: blocks, config: config
                )
                let pms = (CACurrentMediaTime() - pt0) * 1000
                let nilCount = heights.filter { $0 == nil }.count
                perPostMs.append((postId, pms, blocks.count, nilCount))
                // Per-type breakdown for slow posts so we can see exactly which
                // block kind dominates (e.g., paragraph vs image vs onebox).
                if pms > 10 {
                    let breakdown = profile
                        .sorted { $0.value.ms > $1.value.ms }
                        .map { "\($0.key)x\($0.value.count)=\(String(format: "%.1f", $0.value.ms))ms" }
                        .joined(separator: " ")
                    debugLog("heightCalc post#\(postId) total=\(String(format: "%.1f", pms))ms blocks=\(blocks.count) byType: \(breakdown)")
                }
                // Always store, even when entries are nil — the per-block array
                // still drives partial pinning, and storing prevents re-tries
                // on the next warmup pass (which would otherwise loop forever
                // for posts that contain unsupported blocks).
                newHeights[postId] = heights
                if heights.allSatisfy({ $0 != nil }) {
                    let resolved = heights.compactMap { $0 }
                    let contentH = resolved.isEmpty
                        ? 0
                        : resolved.reduce(0, +) + CGFloat(heights.count - 1) * stackSpacing
                    newTotals[postId] = chrome + contentH
                }
            }
            let elapsed = (CACurrentMediaTime() - t0) * 1000
            let top = perPostMs
                .sorted { $0.ms > $1.ms }
                .prefix(3)
                .map { "post#\($0.postId)=\(String(format: "%.1f", $0.ms))ms(blocks=\($0.blocks),nil=\($0.nilCount))" }
                .joined(separator: " ")
            DispatchQueue.main.async {
                guard let self else { return }
                // Discard if a width change happened while the worker ran.
                if self.precomputedWidth == width {
                    for (k, v) in newHeights { self.precomputedBlockHeights[k] = v }
                    for (k, v) in newTotals { self.precomputedTotalHeights[k] = v }
                }
                self.heightWarmupInFlightWidth = 0
                let unsupportedBlocks = newHeights.values.reduce(0) { acc, arr in
                    acc + arr.filter { $0 == nil }.count
                }
                debugLog(
                    "heightWarmup posts=\(pending.count) fullyPinned=\(newTotals.count) unsupportedBlocks=\(unsupportedBlocks) total=\(String(format: "%.1f", elapsed))ms top: \(top)"
                )
                // Posts that arrived during the in-flight worker weren't in
                // its `pending` snapshot. Re-check; this is idempotent — every
                // tried post is now in `precomputedBlockHeights`, so the
                // pending filter excludes them and recursion terminates.
                self.warmHeightCacheInBackground()
            }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let scrollStart = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - scrollStart) * 1000
            if ms > 2 { FrameDropDetector.shared.log("scrollViewDidScroll \(String(format: "%.1f", ms))ms") }
        }
        guard let header = tableView.tableHeaderView else { return }
        let headerBottom = header.frame.maxY
        let offsetY = scrollView.contentOffset.y + scrollView.safeAreaInsets.top
        navigationItem.titleView = offsetY >= headerBottom ? navTitleLabel : nil

        let currentOffset = scrollView.contentOffset.y
        let isScrollingUp = currentOffset < lastScrollOffset
        lastScrollOffset = currentOffset

        // Trigger load-earlier only when:
        // - user is actively scrolling UP (revealing content above)
        // - we're not already in a pagination flow
        // - the VM has room to grow toward earlier posts
        // - we're not in reverse order (top is the pinned OP)
        // - the one-shot gate is armed (re-armed only on a new drag)
        // - we're within 200pt of the visual top.
        guard isScrollingUp,
              case .idle = paginationContext,
              loadEarlierArmed,
              viewModel.canLoadEarlier,
              !viewModel.isReverseOrder
        else { return }
        let contentTop = -(scrollView.adjustedContentInset.top)
        guard scrollView.contentOffset.y <= contentTop + 200 else { return }
        // Disarm immediately; re-armed only on the next `willBeginDragging`.
        loadEarlierArmed = false

        debugLog("[loadEarlier] trigger contentOffset.y=\(scrollView.contentOffset.y) topInset=\(scrollView.adjustedContentInset.top)")
        let token = enterPaginationContext(.loadingEarlier)
        Task {
            let added = await viewModel.loadEarlierPosts(containerWidth: view.bounds.width)
            debugLog("[loadEarlier] returned addedCount=\(added.count) addedIds=\(added.prefix(3))…")
            // Bail if a jump (or another window-replacing flow) overtook us:
            // the VM's loadGeneration check already returned [], but without
            // this guard we'd still clobber the newer flow's paginationContext
            // back to .idle and let updateUI apply an intermediate snapshot.
            guard paginationTokenIsCurrent(token) else { return }
            guard !added.isEmpty else {
                endPaginationContext(token)
                return
            }
            // Defer the snapshot apply until the scroll view is fully settled.
            // Applying mid-drag or mid-deceleration loses the anchor because
            // either the pan recognizer (during drag) or residual velocity
            // (during decel) immediately overrides our restored contentOffset.
            // The trigger gate stays disarmed and `paginationContext` stays
            // `.loadingEarlier` while pending, so another trigger can't fire.
            if tableView.isDragging || tableView.isDecelerating || tableView.isTracking {
                debugLog("[loadEarlier] deferring apply — scroll not settled (dragging=\(tableView.isDragging) decelerating=\(tableView.isDecelerating) tracking=\(tableView.isTracking))")
                pendingLoadEarlier = (added, token)
            } else {
                applyLoadEarlierSnapshot(addedPostIds: added)
                endPaginationContext(token)
            }
        }
    }

    /// Run a queued load-earlier apply once the scroll view is fully settled.
    /// Hooked from `scrollViewDidEndDragging` (no-decel path) and
    /// `scrollViewDidEndDecelerating`. Reentrant-safe — the pending value is
    /// cleared first so a nested settle event can't double-apply.
    private func flushPendingLoadEarlierIfReady() {
        guard let pending = pendingLoadEarlier,
              paginationTokenIsCurrent(pending.token),
              !tableView.isDragging,
              !tableView.isDecelerating,
              !tableView.isTracking
        else { return }
        pendingLoadEarlier = nil
        debugLog("[loadEarlier] flushing pending apply — scroll settled")
        applyLoadEarlierSnapshot(addedPostIds: pending.addedPostIds)
        endPaginationContext(pending.token)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Cache cell height for accurate estimates
        if let item = dataSource.itemIdentifier(for: indexPath) {
            cellHeightCache[item] = cell.bounds.height
            if case .post(let postId) = item, let post = viewModel.postsById[postId] {
                readTracker.recordVisible(postNumber: post.postNumber)
            }
        }

        let totalRows = tableView.numberOfRows(inSection: 0)
        // Load more (forward) — trigger on the last row so the spinner is visible.
        // In reverse mode the bottom of the table is the oldest non-OP loaded
        // post, so what the user wants next is canonically *earlier* posts.
        // Pause auto-trigger when the previous attempt failed: the footer
        // retry control is the explicit handoff to the user.
        guard indexPath.row >= totalRows - 1,
              case .idle = paginationContext,
              !viewModel.loadMoreFailed
        else { return }
        if viewModel.isTreeMode {
            // Tree mode paginates by root-level replies, not by flat stream
            // index, so it uses its own loader. Only fire when the server
            // actually has more roots queued.
            guard viewModel.nestedHasMoreRoots else { return }
            let token = enterPaginationContext(.loadingMore)
            Task {
                let added = await viewModel.loadMoreNestedRoots()
                guard paginationTokenIsCurrent(token) else { return }
                if !added.isEmpty {
                    applyLoadMoreSnapshot(addedPostIds: added)
                }
                handleLoadErrorIfNeeded()
                endPaginationContext(token)
            }
        } else if viewModel.isReverseOrder {
            // Treat reverse-mode "scroll to bottom" as a load-earlier, but
            // without the anchor (we're appending visually in reverse, so the
            // user's current view doesn't shift) — preserve contentOffset.
            let token = enterPaginationContext(.loadingMore)
            Task {
                let added = await viewModel.loadEarlierPosts(containerWidth: view.bounds.width)
                guard paginationTokenIsCurrent(token) else { return }
                if !added.isEmpty {
                    applyLoadMoreSnapshot(addedPostIds: added)
                }
                handleLoadErrorIfNeeded()
                endPaginationContext(token)
            }
        } else {
            let token = enterPaginationContext(.loadingMore)
            Task {
                let added = await viewModel.loadMorePosts(containerWidth: view.bounds.width)
                guard paginationTokenIsCurrent(token) else { return }
                if !added.isEmpty {
                    applyLoadMoreSnapshot(addedPostIds: added)
                }
                handleLoadErrorIfNeeded()
                endPaginationContext(token)
            }
        }
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let item = dataSource.itemIdentifier(for: indexPath) {
            cellHeightCache[item] = cell.bounds.height
            if case .post(let postId) = item, let post = viewModel.postsById[postId] {
                readTracker.recordHidden(postNumber: post.postNumber)
            }
        }
    }

    @objc private func footerRetryTapped() {
        guard case .idle = paginationContext, viewModel.loadMoreFailed else { return }
        // Clearing the flag both swaps the spinner back in (via the next
        // updateUI) and reopens the auto-trigger gate for future rows.
        viewModel.loadMoreFailed = false
        if viewModel.isTreeMode {
            guard viewModel.nestedHasMoreRoots else { return }
            let token = enterPaginationContext(.loadingMore)
            Task {
                let added = await viewModel.loadMoreNestedRoots()
                guard paginationTokenIsCurrent(token) else { return }
                if !added.isEmpty { applyLoadMoreSnapshot(addedPostIds: added) }
                handleLoadErrorIfNeeded()
                endPaginationContext(token)
            }
        } else if viewModel.isReverseOrder {
            let token = enterPaginationContext(.loadingMore)
            Task {
                let added = await viewModel.loadEarlierPosts(containerWidth: view.bounds.width)
                guard paginationTokenIsCurrent(token) else { return }
                if !added.isEmpty { applyLoadMoreSnapshot(addedPostIds: added) }
                handleLoadErrorIfNeeded()
                endPaginationContext(token)
            }
        } else {
            let token = enterPaginationContext(.loadingMore)
            Task {
                let added = await viewModel.loadMorePosts(containerWidth: view.bounds.width)
                guard paginationTokenIsCurrent(token) else { return }
                if !added.isEmpty { applyLoadMoreSnapshot(addedPostIds: added) }
                handleLoadErrorIfNeeded()
                endPaginationContext(token)
            }
        }
    }

    // Match what the official Discourse client does: after scroll settles, wait a
    // beat so newly-revealed posts cross the min-visible threshold, then flush.
    // The pending flush is cancelled if the user starts scrolling again before it fires.
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleDebouncedReadFlush()
        flushPendingLoadEarlierIfReady()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scheduleDebouncedReadFlush()
            flushPendingLoadEarlierIfReady()
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelPendingReadFlush()
        // The user is taking over — drop any in-flight fast-path scroll so the
        // animated jump doesn't keep gating load-earlier and the next user
        // scroll-up can paginate immediately.
        if let token = fastPathScrollToken {
            fastPathScrollToken = nil
            endPaginationContext(token)
        }
        // Re-arm load-earlier on every new drag. Disarmed once per drag inside
        // `scrollViewDidScroll`; this is the single point that gives the user
        // a fresh shot for the next gesture.
        loadEarlierArmed = true
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        // Fast-path jump finished — release the `.jumping` gate it took so
        // legitimate user scrolls can resume triggering load-earlier.
        if let token = fastPathScrollToken {
            fastPathScrollToken = nil
            endPaginationContext(token)
        }
        lastScrollOffset = scrollView.contentOffset.y
    }
}

// MARK: - PostCellDelegate

extension LegacyTopicDetailViewController: PostCellDelegate {
    func postCell(didTapImageURL url: URL, inPostId postId: Int) {
        let request = TopicImageBrowserRequest.make(
            annotatedBlocks: viewModel.parsedBlocks[postId] ?? [],
            tappedURL: url
        )
        let images = request.imageURLs.map { LightboxImage(imageURL: $0) }
        guard !images.isEmpty else { return }
        let controller = ImageBrowserController(images: images, startIndex: request.startIndex)
        controller.dynamicBackground = true

        if let source = TappableImageContainer.lastTapped {
            imageZoomTransition.sourceImageView = source.displayedImageView
            imageZoomTransition.sourceContainer = source
            controller.modalPresentationStyle = .custom
            controller.transitioningDelegate = imageZoomTransition
        } else {
            controller.modalPresentationStyle = .fullScreen
        }

        present(controller, animated: true)
    }

    func postCell(didTapLinkURL url: URL) {
        handleLink(url)
    }

    func postCell(didTapShowRepliesForPostId postId: Int) {
        let repliesVC = RepliesViewController(
            api: api,
            postId: postId,
            topicId: topicId,
            validReactions: viewModel.topic?.validReactions ?? []
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

    /// Pull the raw error out of the just-completed topic load and route it
    /// to the Cloudflare-challenge prompt when applicable. The VM also stores
    /// `errorMessage` for the inline error label; this path supplements that
    /// with an actionable prompt for the linux.do challenge case.
    private func handleLoadErrorIfNeeded() {
        guard let error = viewModel.lastLoadError else { return }
        viewModel.lastLoadError = nil
        presentChallengePromptIfNeeded(error: error, on: api)
    }

    private func playReactionSuccessFeedback(forPostId postId: Int, animated: Bool) {
        if let cell = cellForPost(id: postId) as? PostNativeCell {
            cell.playReactionSuccessFeedback(animated: animated)
        } else if animated {
            ReactionFeedback.play(from: nil)
        }
    }

    private func playReactionDestinationFeedback(forPostId postId: Int) {
        (cellForPost(id: postId) as? PostNativeCell)?.playReactionDestinationFeedback()
    }

    /// Re-fetch a single post and ask the data source to reconfigure its row.
    /// Used after like/reaction toggles since neither endpoint returns the new
    /// post state.
    private func refreshPost(id: Int) async -> Bool {
        guard let fresh = try? await api.fetchPost(id: id) else { return false }
        await viewModel.replacePost(fresh)
        invalidatePrecomputedHeights(forPostId: id)
        var snapshot = dataSource.snapshot()
        let item = TopicDetailItem.post(id)
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
        switch AppSettings.shared.boostDisplayMode {
        case .expand:
            viewModel.toggleBoosts(forPostId: post.id)
            refreshBoostUI()
        case .danmaku:
            // Button bottom edge in view coordinates
            let buttonBottom = sourceView.convert(CGPoint(x: 0, y: sourceView.bounds.maxY), to: view).y
            // Cell top edge: walk up to find the PostNativeCell
            var cellTop = view.safeAreaInsets.top
            var current: UIView? = sourceView
            while let v = current {
                if let cell = v as? PostNativeCell, let indexPath = tableView.indexPath(for: cell) {
                    let rectInView = tableView.convert(tableView.rectForRow(at: indexPath), to: view)
                    cellTop = max(view.safeAreaInsets.top, rectInView.origin.y) + 8
                    break
                }
                current = v.superview
            }
            boostDanmaku.shoot(boosts: post.boosts, assetBaseURL: assetBaseURL,
                               top: cellTop, bottom: buttonBottom)
        }
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
                    if let postId = self.viewModel.posts.first(where: { $0.boosts.contains(where: { $0.id == boost.id }) })?.id {
                        self.viewModel.removeBoost(boostId: boost.id, fromPostId: postId)
                        self.refreshBoostUI()
                    }
                } catch {
                    if self.presentChallengePromptIfNeeded(error: error, on: self.api) {
                        return
                    }
                    let failureAlert = UIAlertController(
                        title: String(localized: "reply.send.failed"),
                        message: error.localizedDescription,
                        preferredStyle: .alert
                    )
                    failureAlert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(failureAlert, animated: true)
                }
            }
        })
        present(alert, animated: true)
    }

    func postCell(didTapAvatarForUsername username: String) {
        // Carry this topic's title + link into the profile so its "send
        // message" composer is prefilled, mirroring the web "message about this
        // topic" flow.
        let prefillTitle = viewModel.topic?.title
        let prefillBody = prefillTitle.map { "[\($0)](\(baseURL)/t/\(topicId))" }
        let vc = UserProfileViewController(
            api: api,
            username: username,
            messagePrefillTitle: prefillTitle,
            messagePrefillBody: prefillBody
        )
        navigationController?.pushViewController(vc, animated: true)
    }

    func postCell(didTapReplyToPost post: DiscourseTopicDetail.Post) {
        guard let authGate = findAuthGating() else { return }
        authGate.requireAuth { [weak self] in
            guard let self else { return }
            self.presentReplyComposer(for: post)
        }
    }

    func postCell(didToggleCollapseForPostId postId: Int) {
        // Pin the tapped row to its current spot in the viewport. Toggling
        // shows/hides its whole subtree (a large height change); without
        // anchoring, the row jumps away from where the user just tapped.
        let anchorDistance: CGFloat? = dataSource.indexPath(for: .post(postId)).map {
            tableView.rectForRow(at: $0).minY - tableView.contentOffset.y
        }

        viewModel.toggleCollapse(postId: postId)
        // Collapsing changes neither the depth nor the width of the surviving
        // posts, so their precomputed heights and cached content views stay
        // valid. The old `invalidateRenderCaches()` here wiped them, forcing
        // every off-screen row back to the 200pt estimate — which threw off the
        // cumulative-height math and made the scroll position jump on toggle.
        var snapshot = buildSnapshot()
        // The toggled post swaps cell type (full post <-> collapsed summary),
        // so reload it explicitly — same item identity means the diff would
        // otherwise reuse the stale cell.
        snapshot.reloadItems([.post(postId)])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dataSource.apply(snapshot, animatingDifferences: false)
        if let anchorDistance, let newIndexPath = dataSource.indexPath(for: .post(postId)) {
            tableView.layoutIfNeeded()
            let target = tableView.rectForRow(at: newIndexPath).minY - anchorDistance
            let minOffset = -tableView.adjustedContentInset.top
            let maxOffset = max(minOffset, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
            tableView.contentOffset.y = min(max(target, minOffset), maxOffset)
        }
        CATransaction.commit()
        lastScrollOffset = tableView.contentOffset.y
    }

    func postCell(didTapLoadMoreChildrenForParentId parentPostId: Int) {
        Task { [weak self] in
            guard let self else { return }
            let added = await self.viewModel.loadMoreChildren(forParentId: parentPostId)
            // Size new posts before they enter the table so the row heights
            // (and the cumulative-height math) are correct on first display.
            if !added.isEmpty {
                self.precomputeHeightsSync(forPostIds: added)
            }
            var snapshot = self.buildSnapshot()
            // On failure the "view more" row survives the rebuild — reload it so
            // the cell's spinner resets back to the tappable state.
            if added.isEmpty, snapshot.itemIdentifiers.contains(.loadMoreChildren(parentPostId)) {
                snapshot.reloadItems([.loadMoreChildren(parentPostId)])
            }
            await self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    func postCell(didTapReplyReferenceForPost post: DiscourseTopicDetail.Post) {
        guard let replyPostNumber = post.replyToPostNumber, replyPostNumber > 0 else { return }

        // First check the currently loaded window. Match on `postNumber`
        // directly — indexing into `allPostIds` by `postNumber - 1` is wrong
        // whenever the stream has gaps (deleted / hidden floors), since the
        // stream is dense by ID but `postNumber` skips removed slots.
        if let parent = viewModel.posts.first(where: { $0.postNumber == replyPostNumber }) {
            presentReplyPreview(for: parent)
            return
        }

        // Not loaded — fetch the post by topic + floor.
        Task { [weak self] in
            guard let self else { return }
            do {
                let parent = try await self.api.fetchPostByNumber(
                    topicId: self.topicId, postNumber: replyPostNumber
                )
                self.presentReplyPreview(for: parent)
            } catch {
                debugLog("[ReplyPreview] fetchPostByNumber(\(replyPostNumber)) failed: \(error)")
            }
        }
    }

    private func presentReplyPreview(for post: DiscourseTopicDetail.Post) {
        let preview = ReplyPreviewViewController(
            api: api,
            post: post,
            topicId: topicId,
            validReactions: viewModel.topic?.validReactions ?? [],
            floorNumber: post.postNumber
        )
        let nav = UINavigationController(rootViewController: preview)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    private func refreshBoostUI() {
        updateUI()
        tableView.reloadData()
    }

    private func presentReplyComposer(for post: DiscourseTopicDetail.Post? = nil) {
        let composer = ReplyComposerViewController(
            api: api,
            topicId: topicId,
            replyToPost: post,
            baseURL: baseURL
        )
        composer.onPostCreated = { [weak self] newPostId, newPostNumber in
            guard let self else { return }
            self.pendingScrollIndexPath = nil

            // Flat mode: the stream position is server-assigned, so refetch
            // centered on the new floor and land on it.
            guard self.viewModel.isTreeMode else {
                self.invalidateRenderCaches()
                let token = self.enterPaginationContext(.jumping)
                Task { [weak self] in
                    guard let self else { return }
                    await self.viewModel.loadTopic(
                        id: self.topicId,
                        containerWidth: self.view.bounds.width,
                        nearPostNumber: newPostNumber
                    )
                    self.handleLoadErrorIfNeeded()
                    guard self.paginationTokenIsCurrent(token) else { return }
                    // Land the new reply at the bottom of the screen so the
                    // composer's last visible content stays in focus.
                    self.applyJumpSnapshot(target: newPostNumber, position: .bottom)
                    self.endPaginationContext(token)
                }
                return
            }

            // Tree mode: splice the single new reply under its parent in the
            // in-memory tree instead of reloading the whole nested topic. This
            // keeps every other post's cached height/content intact and shows
            // the reply right away even if the server's nested view lags.
            let parentId = post?.id
            let token = self.enterPaginationContext(.jumping)
            Task { [weak self] in
                guard let self else { return }
                var spliced = false
                if let newPost = try? await self.api.fetchPost(id: newPostId) {
                    guard self.paginationTokenIsCurrent(token) else { return }
                    spliced = await self.viewModel.insertReplyIntoTree(newPost, parentId: parentId)
                }
                guard self.paginationTokenIsCurrent(token) else { return }
                if spliced {
                    // `visiblePosts` recomputes `postDepths`; read it before
                    // measuring so the new row is sized at its real indented
                    // width rather than the flat full width.
                    _ = self.viewModel.visiblePosts
                    self.precomputeHeightsSync(forPostIds: [newPostId])
                    self.applyJumpSnapshot(target: newPostNumber, position: .bottom)
                } else {
                    // Couldn't fetch / splice the post — fall back to a full
                    // nested reload so the reply still shows up.
                    self.invalidateRenderCaches()
                    await self.viewModel.loadNestedTopic(id: self.topicId)
                    self.viewModel.expandAncestors(ofPostNumber: newPostNumber)
                    self.handleLoadErrorIfNeeded()
                    guard self.paginationTokenIsCurrent(token) else { return }
                    self.applyJumpSnapshot(target: newPostNumber, position: .bottom)
                }
                self.endPaginationContext(token)
            }
        }
        let nav = UINavigationController(rootViewController: composer)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    private func presentBoostComposer(for post: DiscourseTopicDetail.Post) {
        let alert = UIAlertController(
            title: String(localized: "reply.title.to \(post.username)"),
            message: nil,
            preferredStyle: .alert
        )
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
                    self.viewModel.appendBoost(boost, toPostId: post.id)
                    if AppSettings.shared.boostDisplayMode == .danmaku,
                       let cell = self.cellForPost(id: post.id) {
                        let cellRect = self.tableView.convert(cell.frame, to: self.view)
                        let top = max(self.view.safeAreaInsets.top, cellRect.origin.y) + 8
                        let bottom = min(cellRect.maxY, self.view.bounds.height - self.view.safeAreaInsets.bottom)
                        self.boostDanmaku.shoot(boosts: [boost], assetBaseURL: self.assetBaseURL,
                                               top: top, bottom: bottom)
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
                    failureAlert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(failureAlert, animated: true)
                }
            }
        })
        present(alert, animated: true)
    }

    func postCell(didVotePoll pollName: String, options: [String], forPost post: DiscourseTopicDetail.Post) {
        Task {
            do {
                let response = try await api.votePoll(postId: post.id, pollName: pollName, options: options)
                await viewModel.updatePoll(response.poll, votes: response.vote ?? options, forPostId: post.id, pollName: pollName)
                reconfigurePost(post.id)
            } catch {
                // TODO: show error
            }
        }
    }

    func postCell(didRemovePollVote pollName: String, forPost post: DiscourseTopicDetail.Post) {
        Task {
            do {
                let response = try await api.removePollVote(postId: post.id, pollName: pollName)
                await viewModel.updatePoll(response.poll, votes: response.vote ?? [], forPostId: post.id, pollName: pollName)
                reconfigurePost(post.id)
            } catch {
                // TODO: show error
            }
        }
    }

    func postCell(didTapFlagPost post: DiscourseTopicDetail.Post, sourceView: UIView) {
        let alert = UIAlertController(
            title: String(localized: "post.flag"),
            message: String(localized: "post.flag.message"),
            preferredStyle: .actionSheet
        )
        if let popover = alert.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
            popover.permittedArrowDirections = [.up, .down]
        }
        let flagTypes: [(String, Int)] = [
            (String(localized: "post.flag.off_topic"), 3),
            (String(localized: "post.flag.inappropriate"), 4),
            (String(localized: "post.flag.spam"), 8),
        ]
        for (title, typeId) in flagTypes {
            alert.addAction(UIAlertAction(title: title, style: .destructive) { [weak self] _ in
                guard let self else { return }
                Task {
                    do {
                        try await self.api.flagPost(postId: post.id, flagTypeId: typeId)
                        let done = UIAlertController(title: nil, message: String(localized: "post.flag.sent"), preferredStyle: .alert)
                        done.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
                        self.present(done, animated: true)
                    } catch {
                        let fail = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
                        fail.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
                        self.present(fail, animated: true)
                    }
                }
            })
        }
        // Notify moderators with custom message
        alert.addAction(UIAlertAction(title: String(localized: "post.flag.notify_moderators"), style: .default) { [weak self] _ in
            self?.presentFlagWithMessage(post: post)
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func presentFlagWithMessage(post: DiscourseTopicDetail.Post) {
        let alert = UIAlertController(
            title: String(localized: "post.flag.notify_moderators"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.placeholder = String(localized: "post.flag.reason_placeholder")
        }
        alert.addAction(UIAlertAction(title: String(localized: "post.flag.send"), style: .destructive) { [weak self] _ in
            guard let self, let message = alert.textFields?.first?.text, !message.isEmpty else { return }
            Task {
                do {
                    try await self.api.flagPost(postId: post.id, flagTypeId: 7, message: message)
                    let done = UIAlertController(title: nil, message: String(localized: "post.flag.sent"), preferredStyle: .alert)
                    done.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
                    self.present(done, animated: true)
                } catch {
                    let fail = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
                    fail.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
                    self.present(fail, animated: true)
                }
            }
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
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

    private func cellForPost(id postId: Int) -> UITableViewCell? {
        guard let indexPath = dataSource.indexPath(for: .post(postId)) else { return nil }
        return tableView.cellForRow(at: indexPath)
    }

    private func reconfigurePost(_ postId: Int) {
        invalidatePrecomputedHeights(forPostId: postId)
        contentViewCache.removeValue(forKey: postId)
        let item = TopicDetailItem.post(postId)
        if let indexPath = dataSource.indexPath(for: item),
           let cell = tableView.cellForRow(at: indexPath) as? PostNativeCell
        {
            cell.markContentDirty()
        }
        var snapshot = dataSource.snapshot()
        if snapshot.itemIdentifiers.contains(item) {
            snapshot.reconfigureItems([item])
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }
}
