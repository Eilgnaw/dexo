import CookedHTML
import Lightbox
import SafariServices
import SDWebImage
import UIKit

enum TopicDetailControllerFactory {
    static func make(api: DiscourseAPI, topicId: Int, initialFloor: Int? = nil) -> UIViewController {
        VirtualizedTopicDetailViewController(api: api, topicId: topicId, initialFloor: initialFloor)
    }
}

nonisolated enum VirtualTopicItem: Hashable, Sendable {
    case title(Int)
    case header(Int)
    case unit(RenderUnitID)
    case acceptedAnswer(Int)
    case footer(Int)
    case boosts(Int)
    case collapsed(Int)
    case blocked(Int)
    case loadMoreChildren(Int)
    case paginationStatus

    var longPressPostId: Int? {
        switch self {
        case .header(let postId), .footer(let postId), .boosts(let postId), .collapsed(let postId):
            return postId
        case .unit(let id):
            return id.postId
        case .title, .acceptedAnswer, .blocked, .loadMoreChildren, .paginationStatus:
            return nil
        }
    }

    var postAnchorId: Int? {
        if case .blocked(let postId) = self { return postId }
        return longPressPostId
    }
}

nonisolated enum VirtualTopicObservedSnapshotPolicy {
    static func allowsApply(
        isReady: Bool,
        isReloadingTreeMode: Bool,
        isPerformingJump: Bool,
        isPaginating: Bool
    ) -> Bool {
        isReady && !isReloadingTreeMode && !isPerformingJump && !isPaginating
    }
}

nonisolated enum VirtualTopicPrependAnchorSelector {
    static func firstPostItem(in items: [VirtualTopicItem]) -> VirtualTopicItem? {
        items.first { $0.postAnchorId != nil }
    }
}

/// Default topic renderer. Posts are flattened into independently reusable
/// header/body/footer items, so a very tall post never forces UIKit to create
/// or draw its complete view tree in one frame.
final class VirtualizedTopicDetailViewController: ObservableViewController, UIGestureRecognizerDelegate {
    private let api: DiscourseAPI
    private let topicId: Int
    private let baseURL: String
    private let viewModel: TopicDetailViewModel
    private var initialFloor: Int?
    private var unitsById: [RenderUnitID: RenderUnit] = [:]
    private var postIdByItem: [VirtualTopicItem: Int] = [:]
    private var preparedLayout: PreparedTopicLayout?
    private var heightPolicyCache: [RenderUnitHeightCacheKey: RenderUnitHeightPolicy] = [:]
    private var resolvedHeights: [RenderUnitID: CGFloat] = [:]
    private var resolvedBoostHeights: [Int: CGFloat] = [:]
    private var solutionSummaryDocuments: [Int: PostRenderDocument] = [:]
    private var solutionSummaryBodyHeights: [Int: CGFloat] = [:]
    private var expandedSolutionPostNumbers: Set<Int> = []
    private var pendingDynamicHeights = DynamicHeightUpdateBuffer()
    private var dynamicStateRevisions: [RenderUnitID: Int] = [:]
    private var expandedDetailsUnitIds: Set<RenderUnitID> = []
    private var pendingPollSelectionsByUnitId: [RenderUnitID: Set<String>] = [:]
    private var revealedSpoilerUnitIds: Set<RenderUnitID> = []
    private var lastEnvironment: RenderEnvironment?
    private var isApplyingSnapshot = false
    private var hasPendingSnapshot = false
    private var pendingSnapshotReloadVisible = false
    private var pendingSnapshotAnchor: (VirtualTopicItem, CGFloat)?
    private var pendingReactionConfirmationPostIds: Set<Int> = []
    private var pendingLoadEarlierPostIds: [Int]?
    private var isLoadingPage = false
    private var loadEarlierArmed = true
    private var lastScrollOffset: CGFloat = 0
    private var bottomBarScrollState = TopicDetailBottomBarScrollState()
    private var lastBottomBarScrollOffset: CGFloat?
    private var isReturningToTop = false
    private var visibleItemCountsByPost: [Int: Int] = [:]
    private var imagePrefetchTokens: [VirtualTopicItem: SDWebImagePrefetchToken] = [:]
    private var jumpScrubber: JumpScrubberOverlay?
    private var jumpScrubStartLocation: CGPoint = .zero
    private var jumpScrubHasMoved = false
    private var jumpScrubStartFloor = 1
    private var jumpScrubReferenceDistance: CGFloat = 1
    private let jumpScrubMoveThreshold: CGFloat = 8
    private let readTracker = TopicReadTracker()
    private var readFlushTimer: Timer?
    private var pendingReadFlush: DispatchWorkItem?
    private static let readFlushInterval: TimeInterval = 60
    private static let readFlushDebounce: TimeInterval = 1.5
    private let imageZoomTransition = ImageZoomTransitionDelegate()
    private lazy var boostDanmaku = BoostDanmakuOverlay(hostView: view)
    private let floatingReplyButton = FloatingReplyButton()
    private var floatingReplyButtonPositioned = false
    private var treeReloadGeneration: UInt = 0
    private var isReloadingTreeMode = false
    private var isPerformingJump = false
    private var modeGeneration: UInt = 0
    private var contentOperationGeneration: UInt = 0
    private var scrollToTopAfterSnapshot = false

    private let timelineLayout = TopicTimelineLayout()
    private lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: timelineLayout)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = ThemeManager.shared.cardBackgroundColor
        view.alwaysBounceVertical = true
        view.showsVerticalScrollIndicator = false
        view.delegate = self
        view.prefetchDataSource = self
        view.register(VirtualTopicTitleCell.self, forCellWithReuseIdentifier: VirtualTopicTitleCell.reuseIdentifier)
        view.register(VirtualPostHeaderCell.self, forCellWithReuseIdentifier: VirtualPostHeaderCell.reuseIdentifier)
        view.register(VirtualPostBlockCell.self, forCellWithReuseIdentifier: VirtualPostBlockCell.reuseIdentifier)
        view.register(VirtualAcceptedAnswersCell.self, forCellWithReuseIdentifier: VirtualAcceptedAnswersCell.reuseIdentifier)
        view.register(VirtualPostFooterCell.self, forCellWithReuseIdentifier: VirtualPostFooterCell.reuseIdentifier)
        view.register(VirtualTopicMessageCell.self, forCellWithReuseIdentifier: VirtualTopicMessageCell.reuseIdentifier)
        view.register(VirtualPostCollapsedCell.self, forCellWithReuseIdentifier: VirtualPostCollapsedCell.reuseIdentifier)
        view.register(VirtualBlockedPostCell.self, forCellWithReuseIdentifier: VirtualBlockedPostCell.reuseIdentifier)
        view.register(VirtualLoadMoreChildrenCell.self, forCellWithReuseIdentifier: VirtualLoadMoreChildrenCell.reuseIdentifier)
        view.register(VirtualBoostsCell.self, forCellWithReuseIdentifier: VirtualBoostsCell.reuseIdentifier)
        return view
    }()

    private lazy var dataSource = UICollectionViewDiffableDataSource<Int, VirtualTopicItem>(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
        guard let self else { return UICollectionViewCell() }
        switch item {
        case .title:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualTopicTitleCell.reuseIdentifier, for: indexPath) as! VirtualTopicTitleCell
            let topic = self.viewModel.topic
            cell.configure(
                title: topic?.fancyTitle ?? topic?.title ?? "",
                tags: topic?.tags ?? [],
                onTag: { [weak self] tag in
                    guard let self else { return }
                    self.navigationController?.pushViewController(TagTopicsViewController(api: self.api, tag: tag), animated: true)
                }
            )
            return cell

        case .header(let postId):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualPostHeaderCell.reuseIdentifier, for: indexPath) as! VirtualPostHeaderCell
            guard let post = self.viewModel.postsById[postId] else { return cell }
            let floor: Int
            if !self.viewModel.isFilteringByOP,
               let streamIndex = self.viewModel.allPostIds.firstIndex(of: postId)
            {
                floor = streamIndex + 1
            } else {
                floor = (self.viewModel.visiblePosts.firstIndex(where: { $0.id == postId }) ?? 0) + 1
            }
            cell.configure(
                post: post,
                floor: floor,
                baseURL: self.baseURL,
                isOP: post.username == self.viewModel.opUsername,
                treeState: self.viewModel.isTreeMode ? self.viewModel.postTreeLineStates[postId] : nil
            )
            cell.onAvatar = { [weak self] in self?.postCell(didTapAvatarForUsername: $0) }
            cell.onReplyReference = { [weak self] in self?.postCell(didTapReplyReferenceForPost: post) }
            return cell

        case .unit(let unitId):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualPostBlockCell.reuseIdentifier, for: indexPath) as! VirtualPostBlockCell
            guard let unit = self.unitsById[unitId], let post = self.viewModel.postsById[unitId.postId] else { return cell }
            let depth = self.viewModel.isTreeMode ? (self.viewModel.postDepths[post.id] ?? 0) : 0
            let indent = PostNativeCell.treeContentIndent(forDepth: depth)
            let config = NativeRenderConfig.default(
                contentWidth: max(1, collectionView.bounds.width - 24 - indent),
                baseURL: self.baseURL
            )
            let heightPolicy = self.preparedLayout?.policy(for: unitId) ?? .fixed(1)
            cell.sizeDelegate = heightPolicy.acceptsDynamicUpdates ? self : nil
            cell.configure(
                unit: unit,
                post: post,
                config: config,
                delegate: self,
                leadingIndent: indent,
                treeState: self.viewModel.isTreeMode ? self.viewModel.postTreeLineStates[post.id] : nil,
                detailsExpanded: self.expandedDetailsUnitIds.contains(unitId),
                onDetailsExpansionChange: { [weak self] expanded in
                    if expanded { self?.expandedDetailsUnitIds.insert(unitId) }
                    else { self?.expandedDetailsUnitIds.remove(unitId) }
                },
                pollPendingSelections: self.pendingPollSelectionsByUnitId[unitId],
                onPollPendingSelectionsChange: { [weak self] selections in
                    self?.pendingPollSelectionsByUnitId[unitId] = selections
                },
                spoilerRevealed: self.revealedSpoilerUnitIds.contains(unitId),
                onSpoilerRevealChange: { [weak self] revealed in
                    if revealed { self?.revealedSpoilerUnitIds.insert(unitId) }
                    else { self?.revealedSpoilerUnitIds.remove(unitId) }
                },
                heightPolicy: heightPolicy
            )
            return cell

        case .footer(let postId):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualPostFooterCell.reuseIdentifier, for: indexPath) as! VirtualPostFooterCell
            guard let post = self.viewModel.postsById[postId] else { return cell }
            let hasExpandedBoosts = self.viewModel.expandedBoostPostIds.contains(postId)
            let separatorPlacement = VirtualPostSeparatorPlacement.resolve(
                isTreeMode: self.viewModel.isTreeMode,
                hasExpandedBoosts: hasExpandedBoosts
            )
            cell.configure(
                post: post,
                menu: self.moreMenu(for: post, sourceView: cell.moreMenuSourceView),
                validReactions: self.viewModel.topic?.validReactions ?? [],
                hidesLikeButton: ForumPolicy.hidesLikeButton(baseURL: self.baseURL),
                treeState: self.viewModel.isTreeMode ? self.viewModel.postTreeLineStates[postId] : nil,
                isLastVisualItem: !hasExpandedBoosts,
                showsSeparator: separatorPlacement.footer
            )
            cell.onReply = { [weak self] in self?.postCell(didTapReplyToPost: post) }
            cell.onLike = { [weak self] in
                self?.postCell(didToggleLikeForPost: post, liked: post.likeAction?.acted != true)
            }
            cell.onReaction = { [weak self] reaction in
                self?.postCell(didTapReaction: reaction, forPost: post)
            }
            cell.onBoost = { [weak self] in
                guard let self else { return }
                if post.boosts.isEmpty {
                    self.postCell(didTapBoostForPost: post)
                } else {
                    self.postCell(didTapToggleBoostsForPost: post, sourceView: cell)
                }
            }
            cell.onCreateBoost = { [weak self] in self?.postCell(didTapBoostForPost: post) }
            cell.onShowReplies = { [weak self] in self?.postCell(didTapShowRepliesForPostId: post.id) }
            cell.onCollapse = { [weak self] in
                self?.postCell(didToggleCollapseForPostId: postId)
            }
            cell.onSolutionToggle = { [weak self] accepting in
                self?.toggleSolution(for: post, accepting: accepting)
            }
            if self.pendingReactionConfirmationPostIds.remove(postId) != nil {
                DispatchQueue.main.async { [weak cell] in
                    cell?.playReactionDestinationFeedback()
                }
            }
            return cell

        case .acceptedAnswer(let postNumber):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: VirtualAcceptedAnswersCell.reuseIdentifier,
                for: indexPath
            ) as! VirtualAcceptedAnswersCell
            guard let answer = self.solutionAnswer(postNumber: postNumber),
                  let document = self.solutionDocument(for: answer)
            else { return cell }
            let contentWidth = max(
                1,
                collectionView.bounds.width
                    - VirtualAcceptedAnswersCell.cardContentHorizontalInsets
            )
            let config = NativeRenderConfig.default(
                contentWidth: contentWidth,
                baseURL: self.baseURL
            )
            cell.configure(
                answer: answer,
                document: document,
                config: config,
                naturalBodyHeight: self.solutionSummaryBodyHeights[postNumber] ?? 1,
                expanded: self.expandedSolutionPostNumbers.contains(postNumber),
                displayFloor: self.solutionDisplayFloor(for: answer),
                baseURL: self.baseURL,
                delegate: self
            )
            cell.onSelect = { [weak self] postNumber in
                self?.performJump(to: postNumber)
            }
            cell.onExpansionChange = { [weak self] expanded in
                guard let self else { return }
                let anchor = self.captureAnchor()
                if expanded {
                    self.expandedSolutionPostNumbers.insert(postNumber)
                } else {
                    self.expandedSolutionPostNumbers.remove(postNumber)
                }
                self.applySnapshot(reloadVisible: true, preserving: anchor)
            }
            return cell

        case .collapsed(let postId):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualPostCollapsedCell.reuseIdentifier, for: indexPath) as! VirtualPostCollapsedCell
            guard let post = self.viewModel.postsById[postId] else { return cell }
            cell.configure(
                post: post,
                depth: self.viewModel.postDepths[postId] ?? 0,
                treeState: self.viewModel.postTreeLineStates[postId],
                baseURL: self.baseURL
            )
            cell.onExpand = { [weak self] in self?.postCell(didToggleCollapseForPostId: $0) }
            return cell

        case .blocked(let postId):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualBlockedPostCell.reuseIdentifier, for: indexPath) as! VirtualBlockedPostCell
            guard let post = self.viewModel.postsById[postId] else { return cell }
            cell.configure(
                username: post.username,
                depth: self.viewModel.isTreeMode ? (self.viewModel.postDepths[postId] ?? 0) : 0,
                treeState: self.viewModel.isTreeMode ? self.viewModel.postTreeLineStates[postId] : nil
            )
            cell.onUnblock = { [weak self] in
                guard let self else { return }
                AppSettings.shared.unblockUserLocally(username: post.username, baseURL: self.baseURL)
            }
            return cell

        case .loadMoreChildren(let parentId):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualLoadMoreChildrenCell.reuseIdentifier, for: indexPath) as! VirtualLoadMoreChildrenCell
            guard let load = self.viewModel.pendingChildLoads[parentId] else { return cell }
            cell.configure(load: load, isLoading: self.viewModel.loadingChildrenParentIds.contains(parentId))
            cell.onLoad = { [weak self] in self?.postCell(didTapLoadMoreChildrenForParentId: $0) }
            return cell

        case .boosts(let postId):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualBoostsCell.reuseIdentifier, for: indexPath) as! VirtualBoostsCell
            guard let post = self.viewModel.postsById[postId] else { return cell }
            let depth = self.viewModel.isTreeMode ? (self.viewModel.postDepths[postId] ?? 0) : 0
            let indent = PostNativeCell.treeContentIndent(forDepth: depth)
            let separatorPlacement = VirtualPostSeparatorPlacement.resolve(
                isTreeMode: self.viewModel.isTreeMode,
                hasExpandedBoosts: true
            )
            cell.configure(
                post: post,
                delegate: self,
                assetBaseURL: self.api.assetBaseURL,
                contentWidth: collectionView.bounds.width,
                leadingIndent: indent,
                treeState: self.viewModel.isTreeMode ? self.viewModel.postTreeLineStates[postId] : nil,
                showsSeparator: separatorPlacement.boosts
            )
            cell.onCollapse = { [weak self] in
                self?.postCell(didToggleCollapseForPostId: postId)
            }
            return cell

        case .paginationStatus:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VirtualTopicMessageCell.reuseIdentifier, for: indexPath) as! VirtualTopicMessageCell
            let isLoading = self.viewModel.isLoadingMore
            cell.configure(
                text: isLoading
                    ? String(localized: "topic_detail.loading_more")
                    : String(localized: "topic_detail.load_more_retry"),
                isLoading: isLoading
            )
            cell.onTap = { [weak self] in self?.retryPagination() }
            return cell
        }
    }

    private let activityIndicator: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.hidesWhenStopped = true
        return view
    }()

    private let navTitleLabel: UILabel = {
        let label = UILabel()
        label.font = FontManager.shared.font(size: 17, weight: .semibold)
        label.numberOfLines = 1
        return label
    }()

    private let errorLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = FontManager.shared.font(size: 14)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.isHidden = true
        return label
    }()

    private let topLoadingBar: UIView = {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = ThemeManager.shared.cardBackgroundColor.withAlphaComponent(0.92)
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
        stack.alignment = .center
        stack.spacing = 8
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 36),
        ])
        return bar
    }()

    private lazy var jumpOverlay: UIView = {
        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = ThemeManager.shared.cardBackgroundColor.withAlphaComponent(0.88)
        overlay.isHidden = true
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        overlay.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
        return overlay
    }()

    private lazy var bottomBar: TopicDetailBottomBar = {
        let bar = TopicDetailBottomBar()
        bar.delegate = self
        return bar
    }()

    init(api: DiscourseAPI, topicId: Int, initialFloor: Int? = nil) {
        self.api = api
        self.topicId = topicId
        baseURL = api.baseURL
        viewModel = TopicDetailViewModel(api: api)
        self.initialFloor = initialFloor
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ThemeManager.shared.cardBackgroundColor
        timelineLayout.delegate = self
        title = String(localized: "topic_detail.default_title")
        viewModel.isTreeMode = AppSettings.shared.topicTreeMode
        viewModel.treeSort = AppSettings.shared.topicTreeSort
        updateTreeModeControls()
        let postLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handlePostLongPress(_:)))
        postLongPress.delegate = self
        collectionView.addGestureRecognizer(postLongPress)

        view.addSubview(collectionView)
        view.addSubview(activityIndicator)
        view.addSubview(errorLabel)
        view.addSubview(topLoadingBar)
        view.addSubview(jumpOverlay)
        view.addSubview(bottomBar)
        view.addSubview(floatingReplyButton)
        floatingReplyButton.addTarget(self, action: #selector(floatingReplyTapped), for: .touchUpInside)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            topLoadingBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topLoadingBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topLoadingBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            jumpOverlay.topAnchor.constraint(equalTo: collectionView.topAnchor),
            jumpOverlay.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
            jumpOverlay.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor),
            jumpOverlay.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor),
            bottomBar.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        collectionView.contentInset.bottom = 68
        updateTreeModeControls()

        NotificationCenter.default.addObserver(self, selector: #selector(renderEnvironmentChanged), name: ThemeManager.themeDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(renderEnvironmentChanged), name: FontManager.fontDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        Task { await initialLoad() }
        Task {
            await api.loadOrFetchEmojiMap()
            applySnapshot(reloadVisible: true)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resumeReadTracking()
        startReadFlushTimer()
        scheduleDebouncedReadFlush()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelPendingReadFlush()
        stopReadFlushTimer()
        flushReadTimings()
        readTracker.pause()
        cancelAllImagePrefetches()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateEnvironmentIfNeeded()
        updateBottomBarForScroll(collectionView)
        if !floatingReplyButton.isHidden, view.bounds.width > 0 {
            if floatingReplyButtonPositioned {
                floatingReplyButton.reclampToParent()
            } else {
                floatingReplyButton.placeAtDefaultPosition()
                floatingReplyButtonPositioned = true
            }
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // The active numeric height table is tiny and necessary for scroll
        // stability. Only discard reusable/off-screen measurements.
        heightPolicyCache.removeAll(keepingCapacity: true)
        cancelAllImagePrefetches()
    }

    override func applyThemeBackground() {
        let color = ThemeManager.shared.cardBackgroundColor
        view.backgroundColor = color
        collectionView.backgroundColor = color
        topLoadingBar.backgroundColor = color.withAlphaComponent(0.92)
        jumpOverlay.backgroundColor = color.withAlphaComponent(0.88)
    }

    private func bottomBarScrollBounds(for scrollView: UIScrollView) -> (minimum: CGFloat, maximum: CGFloat) {
        let minimum = -scrollView.adjustedContentInset.top
        let maximum = max(
            minimum,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        return (minimum, maximum)
    }

    private func boundedBottomBarOffset(for scrollView: UIScrollView) -> CGFloat {
        let bounds = bottomBarScrollBounds(for: scrollView)
        return min(max(scrollView.contentOffset.y, bounds.minimum), bounds.maximum)
    }

    private func updateBottomBarForScroll(_ scrollView: UIScrollView) {
        guard !viewModel.isTreeMode else { return }

        let bounds = bottomBarScrollBounds(for: scrollView)
        let rawOffset = scrollView.contentOffset.y
        let boundedOffset = min(max(rawOffset, bounds.minimum), bounds.maximum)
        let previousOffset = lastBottomBarScrollOffset ?? boundedOffset
        lastBottomBarScrollOffset = boundedOffset

        let isUserDriven = !isReturningToTop
            && (scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating)
        let mode = bottomBarScrollState.update(
            delta: boundedOffset - previousOffset,
            distanceFromTop: boundedOffset - bounds.minimum,
            isUserDriven: isUserDriven,
            isWithinScrollBounds: rawOffset >= bounds.minimum && rawOffset <= bounds.maximum,
            isContentScrollable: bounds.maximum - bounds.minimum > 1
        )
        if bottomBar.displayMode != mode {
            bottomBar.setDisplayMode(mode, animated: true)
        }
    }

    private func finishReturningToTop() {
        guard isReturningToTop else { return }
        isReturningToTop = false
        bottomBarScrollState.forceExpanded()
        lastBottomBarScrollOffset = boundedBottomBarOffset(for: collectionView)
        bottomBar.setDisplayMode(.expanded, animated: true)
    }

    private func scrollToTopicTop() {
        let targetY = -collectionView.adjustedContentInset.top
        guard abs(collectionView.contentOffset.y - targetY) > 1 else {
            bottomBarScrollState.forceExpanded()
            lastBottomBarScrollOffset = targetY
            bottomBar.setDisplayMode(.expanded, animated: true)
            return
        }

        isReturningToTop = true
        bottomBarScrollState.beginGesture()
        lastBottomBarScrollOffset = boundedBottomBarOffset(for: collectionView)
        let animated = !UIAccessibility.isReduceMotionEnabled
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: targetY),
            animated: animated
        )
        if !animated { finishReturningToTop() }
    }

    private func initialLoad() async {
        let generation = nextTreeReloadGeneration()
        activityIndicator.startAnimating()
        if let initialFloor, initialFloor > 1, viewModel.isTreeMode {
            // A forced exit for a deep link is session-local. Preserve the
            // user's preferred default tree mode for the next topic.
            viewModel.isTreeMode = false
            updateTreeModeControls()
        }
        if viewModel.isTreeMode {
            await viewModel.loadNestedTopic(id: topicId, containerWidth: view.bounds.width)
        } else {
            await viewModel.loadTopic(id: topicId, containerWidth: view.bounds.width, nearPostNumber: initialFloor)
        }
        if let floor = initialFloor, floor > 1,
           !viewModel.posts.contains(where: { $0.postNumber == floor })
        {
            _ = await viewModel.jumpToFloor(floor, containerWidth: view.bounds.width)
        }
        guard generation == treeReloadGeneration else { return }
        activityIndicator.stopAnimating()
        applySnapshot(reloadVisible: false)
        if let floor = initialFloor { scrollToFloor(floor, position: .top) }
        initialFloor = nil
    }

    override func updateUI() {
        _ = AppSettings.shared.localBlocklistRevision
        if viewModel.isLoading || isReloadingTreeMode {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
        if VirtualTopicObservedSnapshotPolicy.allowsApply(
            isReady: viewModel.isReady,
            isReloadingTreeMode: isReloadingTreeMode,
            isPerformingJump: isPerformingJump,
            isPaginating: isLoadingPage
        ) {
            applySnapshot(reloadVisible: false)
        }
        if let topic = viewModel.topic {
            title = nil
            TopicCell.applyEmojiTitle(topic.fancyTitle ?? topic.title, to: navTitleLabel)
            navTitleLabel.sizeToFit()
        }
        errorLabel.text = viewModel.errorMessage
        errorLabel.isHidden = viewModel.errorMessage == nil
        topLoadingBar.alpha = viewModel.isLoadingEarlier ? 1 : 0
        bottomBar.setOPOnlySelected(viewModel.isFilteringByOP)
        handleLoadErrorIfNeeded()
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

    private func resumeReadTracking() {
        readTracker.startSession()
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let item = dataSource.itemIdentifier(for: indexPath),
                  let postId = postIdByItem[item],
                  let post = viewModel.postsById[postId]
            else { continue }
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

    private func flushReadTimings() {
        let snapshot = readTracker.snapshotDelta()
        guard !snapshot.timings.isEmpty else { return }
        let api = api
        let topicId = topicId
        Task.detached {
            try? await api.postTopicTimings(
                topicId: topicId,
                topicTime: snapshot.topicTime,
                timings: snapshot.timings
            )
        }
    }

    private func handleLoadErrorIfNeeded() {
        guard let error = viewModel.lastLoadError else { return }
        viewModel.lastLoadError = nil
        presentChallengePromptIfNeeded(error: error, on: api)
    }

    private func retryPagination() {
        guard viewModel.loadMoreFailed, !isLoadingPage else { return }
        viewModel.loadMoreFailed = false
        isLoadingPage = true
        let operationGeneration = contentOperationGeneration
        applySnapshot(reloadVisible: false, preserving: captureAnchor())
        Task {
            let anchor = captureAnchor()
            if viewModel.isTreeMode {
                _ = await viewModel.loadMoreNestedRoots()
            } else if viewModel.isReverseOrder {
                _ = await viewModel.loadEarlierPosts(containerWidth: view.bounds.width)
            } else {
                _ = await viewModel.loadMorePosts(containerWidth: view.bounds.width)
            }
            guard operationGeneration == contentOperationGeneration else {
                isLoadingPage = false
                return
            }
            applySnapshot(reloadVisible: false, preserving: anchor)
            handleLoadErrorIfNeeded()
            isLoadingPage = false
        }
    }

    /// Builds the complete height table before any matching snapshot is
    /// published. Common blocks use the calculator; rare Auto Layout-backed
    /// blocks are fitted once here, outside cell configuration and scrolling.
    private func prepareCurrentLayout() {
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let rootEnvironment = RenderEnvironment(
            contentWidth: width,
            displayScale: scale,
            fontRevision: FontManager.shared.revision,
            themeRevision: ThemeManager.shared.revision
        )

        let result = TopicRenderMetrics.measure("PrepareTopicHeights") {
            () -> ([RenderUnitID: RenderUnitHeightPolicy], [Int: CGFloat], [Int: CGFloat]) in
            var policies: [RenderUnitID: RenderUnitHeightPolicy] = [:]
            var boostHeights: [Int: CGFloat] = [:]
            var solutionHeights: [Int: CGFloat] = [:]

            let blockedUsernames = AppSettings.shared.localBlockedUsernames(for: baseURL)
            for post in viewModel.visiblePosts
            where !blockedUsernames.contains(post.username.lowercased()) {
                guard let document = viewModel.renderDocuments[post.id] else { continue }
                let depth = viewModel.isTreeMode ? (viewModel.postDepths[post.id] ?? 0) : 0
                let indent = PostNativeCell.treeContentIndent(forDepth: depth)
                let contentWidth = max(1, width - 24 - indent)
                let unitEnvironment = RenderEnvironment(
                    contentWidth: contentWidth,
                    displayScale: scale,
                    fontRevision: FontManager.shared.revision,
                    themeRevision: ThemeManager.shared.revision
                )
                let config = NativeRenderConfig.default(contentWidth: contentWidth, baseURL: baseURL)

                for unit in document.units {
                    let expandedRevision = expandedDetailsUnitIds.contains(unit.id) ? 1 : 0
                    let revision = (dynamicStateRevisions[unit.id, default: 0] &* 2) &+ expandedRevision
                    let key = RenderUnitHeightCacheKey(
                        unitId: unit.id,
                        environment: unitEnvironment,
                        dynamicStateRevision: revision
                    )
                    let policy: RenderUnitHeightPolicy
                    if let cached = heightPolicyCache[key] {
                        policy = cached
                    } else {
                        policy = preflightHeightPolicy(for: unit, post: post, config: config)
                        heightPolicyCache[key] = policy
                    }
                    policies[unit.id] = policy
                }

                if viewModel.expandedBoostPostIds.contains(post.id) {
                    boostHeights[post.id] = preflightBoostHeight(
                        post: post,
                        collectionWidth: width,
                        leadingIndent: indent
                    )
                }
            }

            let solutionContentWidth = max(
                1,
                width - VirtualAcceptedAnswersCell.cardContentHorizontalInsets
            )
            let solutionConfig = NativeRenderConfig.default(
                contentWidth: solutionContentWidth,
                baseURL: baseURL
            )
            for answer in viewModel.topic?.acceptedAnswers ?? []
            where !blockedUsernames.contains(answer.username.lowercased()) {
                guard let document = solutionDocument(for: answer) else { continue }
                solutionHeights[answer.postNumber] =
                    VirtualAcceptedAnswersCell.measuredBodyHeight(
                        document: document,
                        config: solutionConfig
                    )
            }
            return (policies, boostHeights, solutionHeights)
        }

        preparedLayout = PreparedTopicLayout(environment: rootEnvironment, unitPolicies: result.0)
        resolvedBoostHeights = result.1
        solutionSummaryBodyHeights = result.2
        if heightPolicyCache.count > 4_000 {
            let active = Set(result.0.keys)
            heightPolicyCache = heightPolicyCache.filter { active.contains($0.key.unitId) }
        }
    }

    private func solutionAnswer(
        postNumber: Int
    ) -> DiscourseTopicDetail.AcceptedAnswer? {
        viewModel.topic?.acceptedAnswers.first { $0.postNumber == postNumber }
    }

    private func solutionDisplayFloor(
        for answer: DiscourseTopicDetail.AcceptedAnswer
    ) -> Int {
        let answerId =
            answer.id
            ?? viewModel.postsById.values.first(where: {
                $0.postNumber == answer.postNumber
            })?.id
        guard let answerId,
              let streamIndex = viewModel.allPostIds.firstIndex(of: answerId)
        else { return answer.postNumber }
        return streamIndex + 1
    }

    /// Prefer the already-parsed authoritative post. If that post is outside
    /// the current virtual window, build the same native document from the
    /// solved-plugin excerpt carried by the topic response.
    private func solutionDocument(
        for answer: DiscourseTopicDetail.AcceptedAnswer
    ) -> PostRenderDocument? {
        let matchingPost =
            answer.id.flatMap { viewModel.postsById[$0] }
            ?? viewModel.postsById.values.first(where: {
                $0.postNumber == answer.postNumber
            })
        if let matchingPost,
           let document = viewModel.renderDocuments[matchingPost.id]
        {
            return document
        }

        guard let cooked = answer.cooked, !cooked.isEmpty else { return nil }
        let syntheticId = answer.id ?? -(max(1, answer.postNumber) + 1)
        let input = PostRenderInput(postId: syntheticId, cookedHTML: cooked)
        if let cached = solutionSummaryDocuments[answer.postNumber],
           cached.contentVersion == input.contentVersion
        {
            return cached
        }
        let annotated = CookedHTMLParser.parseAnnotated(html: cooked, baseURL: baseURL)
        let document = PostRenderDocument(
            postId: syntheticId,
            contentVersion: input.contentVersion,
            annotatedBlocks: annotated,
            units: RenderUnitBuilder.build(
                postId: syntheticId,
                contentVersion: input.contentVersion,
                annotatedBlocks: annotated
            )
        )
        solutionSummaryDocuments[answer.postNumber] = document
        return document
    }

    private func preflightHeightPolicy(
        for unit: RenderUnit,
        post: DiscourseTopicDetail.Post,
        config: NativeRenderConfig
    ) -> RenderUnitHeightPolicy {
        if let measured = BlockHeightCalculator.height(for: unit.block, config: config) {
            let height = ceil(measured) + unit.bottomSpacing
            return blockNeedsDeferredHeight(unit.block) ? .deferred(height) : .fixed(height)
        }

        let measured = measureHostedUnit(unit, post: post, config: config)
        let height = max(1, ceil(measured) + unit.bottomSpacing)
        switch unit.block {
        case .details, .rawHTML:
            return .deferred(height)
        default:
            return .fixed(height)
        }
    }

    private func blockNeedsDeferredHeight(_ block: ContentBlock) -> Bool {
        switch block {
        case .image(_, _, let width, let height, _):
            return width == nil || height == nil || width == 0 || height == 0
        case .details, .rawHTML:
            return true
        default:
            return false
        }
    }

    private func measureHostedUnit(
        _ unit: RenderUnit,
        post: DiscourseTopicDetail.Post,
        config: NativeRenderConfig
    ) -> CGFloat {
        let annotated = AnnotatedBlock(block: unit.block, sourceHTML: unit.sourceHTML)
        let views = NativeContentRenderer.renderBlocks(
            [annotated],
            config: config,
            delegate: nil,
            pollProvider: { name in
                guard let poll = post.polls.first(where: { $0.name == name }) else { return nil }
                return (poll, Set(post.pollsVotes[name] ?? []), post)
            }
        )
        guard let hosted = views.first else { return 1 }
        if let details = findDetailsView(in: hosted) {
            details.setExpanded(expandedDetailsUnitIds.contains(unit.id))
        }
        if let poll = findPollView(in: hosted), let selections = pendingPollSelectionsByUnitId[unit.id] {
            poll.restorePendingSelections(selections)
        }
        return hosted.systemLayoutSizeFitting(
            CGSize(width: config.contentWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    private func preflightBoostHeight(
        post: DiscourseTopicDetail.Post,
        collectionWidth: CGFloat,
        leadingIndent: CGFloat
    ) -> CGFloat {
        let sizingCell = BoostCell(style: .default, reuseIdentifier: nil)
        sizingCell.configure(
            post: post,
            delegate: nil,
            assetBaseURL: api.assetBaseURL,
            contentWidth: max(1, collectionWidth - 24 - leadingIndent)
        )
        return max(1, ceil(sizingCell.systemLayoutSizeFitting(
            CGSize(width: max(1, collectionWidth - leadingIndent), height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height))
    }

    private func findDetailsView(in view: UIView) -> DetailsCardView? {
        if let details = view as? DetailsCardView { return details }
        for subview in view.subviews {
            if let details = findDetailsView(in: subview) { return details }
        }
        return nil
    }

    private func findPollView(in view: UIView) -> PollView? {
        if let poll = view as? PollView { return poll }
        for subview in view.subviews {
            if let poll = findPollView(in: subview) { return poll }
        }
        return nil
    }

    private func invalidateHeightMeasurements(forPostId postId: Int) {
        heightPolicyCache = heightPolicyCache.filter { $0.key.unitId.postId != postId }
        resolvedHeights = resolvedHeights.filter { $0.key.postId != postId }
        pendingDynamicHeights.removeAll(forPostId: postId)
        if let unitIds = preparedLayout?.unitPolicies.keys {
            for id in unitIds where id.postId == postId {
                dynamicStateRevisions[id, default: 0] &+= 1
            }
        }
        preparedLayout = nil
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<Int, VirtualTopicItem> {
        var snapshot = NSDiffableDataSourceSnapshot<Int, VirtualTopicItem>()
        snapshot.appendSections([0])
        var items: [VirtualTopicItem] = []
        unitsById.removeAll(keepingCapacity: true)
        postIdByItem.removeAll(keepingCapacity: true)
        if let topic = viewModel.topic { items.append(.title(topic.id)) }

        let visible = viewModel.visiblePosts
        let blockedUsernames = AppSettings.shared.localBlockedUsernames(for: baseURL)
        var loadsByAnchor: [Int: [PendingChildLoad]] = [:]
        for load in viewModel.pendingChildLoads.values {
            loadsByAnchor[load.anchorPostId, default: []].append(load)
        }
        for post in visible where viewModel.renderDocuments[post.id] != nil {
            if blockedUsernames.contains(post.username.lowercased()) {
                let item = VirtualTopicItem.blocked(post.id)
                items.append(item)
                postIdByItem[item] = post.id
            } else if viewModel.isTreeMode, viewModel.collapsedPostIds.contains(post.id) {
                let item = VirtualTopicItem.collapsed(post.id)
                items.append(item)
                postIdByItem[item] = post.id
            } else if let document = viewModel.renderDocuments[post.id] {
                let header = VirtualTopicItem.header(post.id)
                items.append(header)
                postIdByItem[header] = post.id
                for unit in document.units {
                    unitsById[unit.id] = unit
                    let item = VirtualTopicItem.unit(unit.id)
                    items.append(item)
                    postIdByItem[item] = post.id
                }
                if post.postNumber == 1, let topic = viewModel.topic {
                    for answer in topic.acceptedAnswers
                    where !blockedUsernames.contains(answer.username.lowercased())
                        && solutionDocument(for: answer) != nil {
                        items.append(.acceptedAnswer(answer.postNumber))
                    }
                }
                let footer = VirtualTopicItem.footer(post.id)
                items.append(footer)
                postIdByItem[footer] = post.id
                if viewModel.expandedBoostPostIds.contains(post.id) {
                    let boost = VirtualTopicItem.boosts(post.id)
                    items.append(boost)
                    postIdByItem[boost] = post.id
                }
            }
            for load in loadsByAnchor[post.id] ?? [] {
                let item = VirtualTopicItem.loadMoreChildren(load.parentPostId)
                items.append(item)
            }
        }
        if viewModel.isLoadingMore || viewModel.loadMoreFailed {
            items.append(.paginationStatus)
        }
        snapshot.appendItems(items)
        return snapshot
    }

    private func applySnapshot(reloadVisible: Bool, preserving anchor: (VirtualTopicItem, CGFloat)? = nil) {
        guard !isReloadingTreeMode else { return }
        let isMoving = collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
        if isApplyingSnapshot || isMoving {
            hasPendingSnapshot = true
            pendingSnapshotReloadVisible = pendingSnapshotReloadVisible || reloadVisible
            // A caller may have captured its anchor before an async network
            // request. While the user is still moving, use the live anchor at
            // flush time instead of restoring that stale screen position.
            if isMoving { pendingSnapshotAnchor = nil }
            else if pendingSnapshotAnchor == nil { pendingSnapshotAnchor = anchor }
            return
        }
        prepareCurrentLayout()
        let snapshot = makeSnapshot()
        let current = dataSource.snapshot()
        guard snapshot.itemIdentifiers != current.itemIdentifiers || reloadVisible else {
            commitPendingDynamicHeights()
            return
        }
        isApplyingSnapshot = true
        var applied = snapshot
        if reloadVisible {
            let existing = Set(current.itemIdentifiers)
            let reloadable = applied.itemIdentifiers.filter(existing.contains)
            if !reloadable.isEmpty { applied.reloadItems(reloadable) }
        }
        timelineLayout.reloadAllHeights()
        dataSource.apply(applied, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.isApplyingSnapshot = false
            self.collectionView.layoutIfNeeded()
            if let anchor, let indexPath = self.dataSource.indexPath(for: anchor.0),
               let attributes = self.collectionView.layoutAttributesForItem(at: indexPath)
            {
                self.collectionView.contentOffset.y = attributes.frame.minY - anchor.1
            }
            if self.scrollToTopAfterSnapshot {
                self.scrollToTopAfterSnapshot = false
                self.collectionView.setContentOffset(
                    CGPoint(x: 0, y: -self.collectionView.adjustedContentInset.top),
                    animated: false
                )
            }
            if self.viewIfLoaded?.window != nil { self.resumeReadTracking() }
            if self.flushPendingLoadEarlierIfReady() { return }
            if !self.flushPendingSnapshotIfNeeded() {
                self.commitPendingDynamicHeights()
            }
        }
    }

    /// Applies a canonical-order prepend only after scrolling is fully idle.
    /// The anchor is captured at apply time rather than request time, so both
    /// "network finishes before the bounce" and "bounce finishes before the
    /// network" preserve the item the user is actually looking at.
    private func applyLoadEarlierSnapshot(addedPostIds: [Int]) {
        guard !addedPostIds.isEmpty else {
            isLoadingPage = false
            return
        }
        let isMoving = collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
        guard !isMoving, !isApplyingSnapshot else {
            pendingLoadEarlierPostIds = addedPostIds
            return
        }

        let anchor = capturePostAnchor()
        let oldContentHeight = collectionView.contentSize.height
        let oldContentOffset = collectionView.contentOffset.y
        prepareCurrentLayout()
        let snapshot = makeSnapshot()
        let current = dataSource.snapshot()
        guard snapshot.itemIdentifiers != current.itemIdentifiers else {
            isLoadingPage = false
            return
        }

        isApplyingSnapshot = true
        timelineLayout.reloadAllHeights()
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.collectionView.layoutIfNeeded()

            var restoredAnchor = false
            if let anchor, let indexPath = self.dataSource.indexPath(for: anchor.0) {
                UIView.performWithoutAnimation {
                    // A first placement forces the custom layout to expose the
                    // anchor's post-prepend frame; the second pass absorbs any
                    // collection-view content-size adjustment from the apply.
                    self.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
                    self.collectionView.layoutIfNeeded()
                    self.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
                    self.collectionView.layoutIfNeeded()
                    if let attributes = self.collectionView.layoutAttributesForItem(at: indexPath) {
                        self.collectionView.contentOffset.y = attributes.frame.minY - anchor.1
                        restoredAnchor = true
                    }
                }
            }
            if !restoredAnchor {
                let delta = self.collectionView.contentSize.height - oldContentHeight
                self.collectionView.contentOffset.y = oldContentOffset + max(0, delta)
            }

            self.lastScrollOffset = self.collectionView.contentOffset.y
            self.isApplyingSnapshot = false
            self.isLoadingPage = false
            if self.viewIfLoaded?.window != nil { self.resumeReadTracking() }
            if !self.flushPendingSnapshotIfNeeded() {
                self.commitPendingDynamicHeights()
            }
        }
    }

    @discardableResult
    private func flushPendingLoadEarlierIfReady() -> Bool {
        guard let addedPostIds = pendingLoadEarlierPostIds,
              !isApplyingSnapshot,
              !collectionView.isTracking,
              !collectionView.isDragging,
              !collectionView.isDecelerating
        else { return false }
        pendingLoadEarlierPostIds = nil
        applyLoadEarlierSnapshot(addedPostIds: addedPostIds)
        return true
    }

    @discardableResult
    private func flushPendingSnapshotIfNeeded() -> Bool {
        guard hasPendingSnapshot,
              !isApplyingSnapshot,
              !collectionView.isTracking,
              !collectionView.isDragging,
              !collectionView.isDecelerating
        else { return false }
        let reloadVisible = pendingSnapshotReloadVisible
        let anchor = pendingSnapshotAnchor ?? captureAnchor()
        hasPendingSnapshot = false
        pendingSnapshotReloadVisible = false
        pendingSnapshotAnchor = nil
        readTracker.pause()
        visibleItemCountsByPost.removeAll(keepingCapacity: true)
        applySnapshot(reloadVisible: reloadVisible, preserving: anchor)
        return true
    }

    private func captureAnchor() -> (VirtualTopicItem, CGFloat)? {
        guard let indexPath = collectionView.indexPathsForVisibleItems.sorted().first,
              let item = dataSource.itemIdentifier(for: indexPath),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath)
        else { return nil }
        return (item, attributes.frame.minY - collectionView.contentOffset.y)
    }

    /// The topic title is a collection item in the virtualized renderer, but
    /// it must never own a prepend anchor. Legacy renders it as tableHeaderView
    /// and therefore always anchors a post row when earlier floors are added.
    private func capturePostAnchor() -> (VirtualTopicItem, CGFloat)? {
        let visibleCandidates = collectionView.indexPathsForVisibleItems.sorted().compactMap { indexPath -> (IndexPath, VirtualTopicItem)? in
            guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
            return (indexPath, item)
        }
        if let item = VirtualTopicPrependAnchorSelector.firstPostItem(in: visibleCandidates.map(\.1)),
           let indexPath = visibleCandidates.first(where: { $0.1 == item })?.0,
           let attributes = collectionView.layoutAttributesForItem(at: indexPath)
        {
            return (item, attributes.frame.minY - collectionView.contentOffset.y)
        }

        // A very tall title can temporarily cover the entire viewport. Keep
        // the first loaded post's off-screen distance in that case instead of
        // falling back to the title and revealing the newly prepended batch.
        if let item = VirtualTopicPrependAnchorSelector.firstPostItem(in: dataSource.snapshot().itemIdentifiers),
           let indexPath = dataSource.indexPath(for: item),
           let attributes = collectionView.layoutAttributesForItem(at: indexPath)
        {
            return (item, attributes.frame.minY - collectionView.contentOffset.y)
        }
        return nil
    }

    private func scrollToFloor(_ floor: Int, position: UICollectionView.ScrollPosition) {
        guard let post = viewModel.posts.first(where: { $0.postNumber == floor }),
              let indexPath = dataSource.indexPath(for: .header(post.id))
                ?? dataSource.indexPath(for: .collapsed(post.id))
                ?? dataSource.indexPath(for: .blocked(post.id))
        else { return }
        collectionView.scrollToItem(at: indexPath, at: position, animated: false)
    }

    private func updateEnvironmentIfNeeded() {
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        let backgroundColor = ThemeManager.shared.cardBackgroundColor
        view.backgroundColor = backgroundColor
        collectionView.backgroundColor = backgroundColor
        let environment = RenderEnvironment(
            contentWidth: width,
            displayScale: view.window?.screen.scale ?? UIScreen.main.scale,
            fontRevision: FontManager.shared.revision,
            themeRevision: ThemeManager.shared.revision
        )
        guard environment != lastEnvironment else { return }
        lastEnvironment = environment
        // A mode switch owns the next complete layout. Do not invalidate the
        // still-visible old snapshot against a half-loaded new view-model.
        guard !isReloadingTreeMode else { return }
        preparedLayout = nil
        heightPolicyCache.removeAll(keepingCapacity: true)
        resolvedHeights.removeAll(keepingCapacity: true)
        resolvedBoostHeights.removeAll(keepingCapacity: true)
        pendingDynamicHeights.removeAll(keepingCapacity: true)
        timelineLayout.reloadAllHeights()
        applySnapshot(reloadVisible: true, preserving: captureAnchor())
    }

    @objc private func renderEnvironmentChanged() { updateEnvironmentIfNeeded() }

    @objc private func handlePostLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let indexPath = collectionView.indexPathForItem(at: gesture.location(in: collectionView)),
              let postId = dataSource.itemIdentifier(for: indexPath)?.longPressPostId,
              let post = viewModel.postsById[postId]
        else { return }
        postCell(didLongPressPost: post)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var candidate = touch.view
        while let view = candidate, view !== collectionView {
            if view is UIControl { return false }
            candidate = view.superview
        }
        return true
    }

    private func nextTreeReloadGeneration() -> UInt {
        treeReloadGeneration &+= 1
        return treeReloadGeneration
    }

    private func reloadAllAfterTreeModeChange(
        generation: UInt,
        resetContentOffset: Bool
    ) async -> Bool {
        // A non-animated diffable apply can still be completing when the mode
        // button is tapped. Wait for it before invoking reload-data semantics.
        while isApplyingSnapshot {
            await Task.yield()
            guard generation == treeReloadGeneration else { return false }
        }
        guard generation == treeReloadGeneration else { return false }

        cancelAllImagePrefetches()
        readTracker.pause()
        visibleItemCountsByPost.removeAll(keepingCapacity: true)
        preparedLayout = nil
        heightPolicyCache.removeAll(keepingCapacity: true)
        resolvedHeights.removeAll(keepingCapacity: true)
        resolvedBoostHeights.removeAll(keepingCapacity: true)
        pendingDynamicHeights.removeAll(keepingCapacity: true)
        hasPendingSnapshot = false
        pendingSnapshotReloadVisible = false
        pendingSnapshotAnchor = nil
        pendingLoadEarlierPostIds = nil
        isLoadingPage = false

        // Recompute every height for the new indentation/content width before
        // publishing the new snapshot, then force UICollectionView to discard
        // every existing cell and layout attribute even when IDs are unchanged.
        prepareCurrentLayout()
        let snapshot = makeSnapshot()
        timelineLayout.reloadAllHeights()
        isApplyingSnapshot = true
        await dataSource.applySnapshotUsingReloadData(snapshot)
        isApplyingSnapshot = false

        guard generation == treeReloadGeneration else { return false }
        collectionView.layoutIfNeeded()
        if resetContentOffset {
            collectionView.setContentOffset(
                CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
                animated: false
            )
        }
        readTracker.startSession()
        isReloadingTreeMode = false
        AppSettings.shared.topicTreeMode = viewModel.isTreeMode
        updateTreeModeControls()
        activityIndicator.stopAnimating()
        return true
    }

    private func treeModeBarButtonItem() -> UIBarButtonItem {
        let symbol = UIImage(systemName: viewModel.isTreeMode ? "list.bullet.indent" : "list.bullet")
        if viewModel.isTreeMode {
            let button = UIButton(type: .system)
            button.setImage(symbol, for: .normal)
            button.addTarget(self, action: #selector(toggleTreeMode), for: .touchUpInside)
            button.menu = treeSortMenu()
            button.showsMenuAsPrimaryAction = false
            button.accessibilityLabel = String(localized: "topic_detail.tree_mode")
            return UIBarButtonItem(customView: button)
        }
        let item = UIBarButtonItem(image: symbol, style: .plain, target: self, action: #selector(toggleTreeMode))
        item.accessibilityLabel = String(localized: "topic_detail.tree_mode")
        return item
    }

    private func treeSortMenu() -> UIMenu {
        let options: [(String, String, String)] = [
            ("top", String(localized: "topic_detail.tree_sort.top"), "flame"),
            ("new", String(localized: "topic_detail.tree_sort.new"), "clock"),
            ("old", String(localized: "topic_detail.tree_sort.old"), "clock.arrow.circlepath"),
        ]
        let actions = options.map { value, title, symbol in
            UIAction(
                title: title,
                image: UIImage(systemName: symbol),
                state: viewModel.treeSort == value ? .on : .off
            ) { [weak self] _ in
                self?.applyTreeSort(value)
            }
        }
        return UIMenu(title: String(localized: "topic_detail.tree_sort.title"), children: actions)
    }

    private func updateTreeModeControls() {
        navigationItem.rightBarButtonItem = treeModeBarButtonItem()
        let isTreeMode = viewModel.isTreeMode
        isReturningToTop = false
        bottomBarScrollState.forceExpanded()
        lastBottomBarScrollOffset = nil
        bottomBar.setDisplayMode(.expanded, animated: false)
        bottomBar.hidesFloorControls = isTreeMode
        bottomBar.isHidden = isTreeMode
        floatingReplyButton.isHidden = !isTreeMode
        if isTreeMode, floatingReplyButton.superview != nil {
            view.bringSubviewToFront(floatingReplyButton)
            view.setNeedsLayout()
        }
    }

    private func applyTreeSort(_ sort: String) {
        guard viewModel.isTreeMode, viewModel.treeSort != sort else { return }
        viewModel.treeSort = sort
        AppSettings.shared.topicTreeSort = sort
        navigationItem.rightBarButtonItem = treeModeBarButtonItem()
        let generation = nextTreeReloadGeneration()
        contentOperationGeneration &+= 1
        let anchor = captureAnchor()
        Task {
            await viewModel.loadNestedTopic(id: topicId, sort: sort, containerWidth: view.bounds.width)
            guard generation == treeReloadGeneration, viewModel.isTreeMode else { return }
            resolvedHeights.removeAll()
            resolvedBoostHeights.removeAll()
            applySnapshot(reloadVisible: true, preserving: anchor)
            navigationItem.rightBarButtonItem = treeModeBarButtonItem()
        }
    }

    @objc private func toggleTreeMode() {
        contentOperationGeneration &+= 1
        isReloadingTreeMode = true
        let targetTreeMode = !viewModel.isTreeMode
        viewModel.isTreeMode = targetTreeMode
        AppSettings.shared.topicTreeMode = viewModel.isTreeMode
        updateTreeModeControls()
        let generation = nextTreeReloadGeneration()
        activityIndicator.startAnimating()
        Task {
            if targetTreeMode {
                await viewModel.loadNestedTopic(id: topicId, containerWidth: view.bounds.width)
            } else {
                await viewModel.loadTopic(id: topicId, containerWidth: view.bounds.width)
            }
            guard generation == treeReloadGeneration else { return }
            _ = await reloadAllAfterTreeModeChange(
                generation: generation,
                resetContentOffset: true
            )
        }
    }

    @objc private func floatingReplyTapped() {
        requireAuthentication { [weak self] in self?.presentReplyComposer(for: nil) }
    }

    private func requireAuthentication(_ action: @escaping () -> Void) {
        guard let gate = findAuthGating() else { return }
        gate.requireAuth(then: action)
    }

    private func findAuthGating() -> AuthGating? {
        var controller: UIViewController? = self
        while let parent = controller?.parent {
            if let gate = parent as? AuthGating { return gate }
            for child in parent.children {
                if let gate = child as? AuthGating { return gate }
                for grandchild in child.children {
                    if let gate = grandchild as? AuthGating { return gate }
                }
            }
            controller = parent
        }
        return nil
    }

    private func moreMenu(for post: DiscourseTopicDetail.Post, sourceView: UIView) -> UIMenu {
        var actions: [UIAction] = [
            UIAction(title: String(localized: "post.copy_link"), image: UIImage(systemName: "link")) { [weak self] _ in
                guard let self else { return }
                UIPasteboard.general.string = "\(self.baseURL)/t/\(self.topicId)/\(post.postNumber)"
            },
            UIAction(
                title: post.bookmarked ? String(localized: "post.remove_bookmark") : String(localized: "post.bookmark"),
                image: UIImage(systemName: post.bookmarked ? "bookmark.fill" : "bookmark")
            ) { [weak self] _ in
                self?.postCell(didToggleBookmarkForPost: post, isBookmarked: !post.bookmarked)
            },
        ]
        if post.canFlag {
            actions.append(UIAction(title: String(localized: "post.flag"), image: UIImage(systemName: "flag"), attributes: .destructive) { [weak self, weak sourceView] _ in
                guard let self else { return }
                self.postCell(didTapFlagPost: post, sourceView: sourceView ?? self.view)
            })
        }
        return UIMenu(children: actions)
    }
}

extension VirtualizedTopicDetailViewController: TopicTimelineLayoutDelegate {
    func topicTimelineLayout(_ layout: TopicTimelineLayout, heightForItemAt indexPath: IndexPath, width: CGFloat) -> CGFloat {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return 1 }
        switch item {
        case .title:
            let title = viewModel.topic?.fancyTitle ?? viewModel.topic?.title ?? ""
            return VirtualTopicTitleCell.height(title: title, tags: viewModel.topic?.tags ?? [], width: width)
        case .header: return max(56, FontManager.shared.scaled(32) + 24)
        case .acceptedAnswer(let postNumber):
            return VirtualAcceptedAnswersCell.height(
                naturalBodyHeight: solutionSummaryBodyHeights[postNumber] ?? 1,
                expanded: expandedSolutionPostNumbers.contains(postNumber)
            )
        case .footer: return 50
        case .collapsed: return PostCollapsedCell.cellHeight
        case .blocked: return VirtualBlockedPostCell.cellHeight
        case .loadMoreChildren: return LoadMoreChildrenCell.cellHeight
        case .paginationStatus: return 44
        case .boosts(let postId): return resolvedBoostHeights[postId] ?? 44
        case .unit(let id):
            if let resolved = resolvedHeights[id] { return resolved }
            return preparedLayout?.policy(for: id)?.height ?? 1
        }
    }
}

extension VirtualizedTopicDetailViewController: RenderUnitSizeInvalidating {
    func renderUnitCell(_ cell: VirtualPostBlockCell, didResolveHeight height: CGFloat, for unitId: RenderUnitID) {
        guard preparedLayout?.policy(for: unitId)?.acceptsDynamicUpdates == true,
              height.isFinite, height > 0,
              abs((resolvedHeights[unitId] ?? preparedLayout?.policy(for: unitId)?.height ?? 0) - height) > 1
        else { return }
        pendingDynamicHeights.enqueue(height: height, for: unitId)
        guard !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating else { return }
        commitPendingDynamicHeights()
    }

    private func commitPendingDynamicHeights() {
        guard !pendingDynamicHeights.isEmpty else { return }
        let pending = pendingDynamicHeights.drain()
        let anchor = captureAnchor()
        var updates: [IndexPath: CGFloat] = [:]
        for (unitId, height) in pending {
            guard preparedLayout?.policy(for: unitId)?.acceptsDynamicUpdates == true,
                  let indexPath = dataSource.indexPath(for: .unit(unitId))
            else { continue }
            resolvedHeights[unitId] = height
            updates[indexPath] = height
        }
        guard !updates.isEmpty else { return }

        TopicRenderMetrics.measure("CommitDynamicHeights") {
            timelineLayout.applyHeightUpdates(updates)
            collectionView.layoutIfNeeded()
        }
        if let anchor, let indexPath = dataSource.indexPath(for: anchor.0),
           let attributes = collectionView.layoutAttributesForItem(at: indexPath)
        {
            collectionView.contentOffset.y = attributes.frame.minY - anchor.1
        }
    }
}

extension VirtualizedTopicDetailViewController: UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        if let postId = postIdByItem[item], let post = viewModel.postsById[postId] {
            let count = visibleItemCountsByPost[postId, default: 0]
            visibleItemCountsByPost[postId] = count + 1
            if count == 0 { readTracker.recordVisible(postNumber: post.postNumber) }
        }
        guard indexPath.item >= collectionView.numberOfItems(inSection: 0) - 3,
              !isLoadingPage,
              !viewModel.loadMoreFailed,
              item != .paginationStatus
        else { return }
        isLoadingPage = true
        let operationGeneration = contentOperationGeneration
        Task {
            let anchor = captureAnchor()
            if viewModel.isTreeMode {
                _ = await viewModel.loadMoreNestedRoots()
            } else if viewModel.isReverseOrder {
                _ = await viewModel.loadEarlierPosts(containerWidth: view.bounds.width)
            } else {
                _ = await viewModel.loadMorePosts(containerWidth: view.bounds.width)
            }
            guard operationGeneration == contentOperationGeneration else {
                isLoadingPage = false
                return
            }
            applySnapshot(reloadVisible: false, preserving: anchor)
            handleLoadErrorIfNeeded()
            isLoadingPage = false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath), let postId = postIdByItem[item] else { return }
        let next = max(0, visibleItemCountsByPost[postId, default: 1] - 1)
        visibleItemCountsByPost[postId] = next
        if next == 0, let post = viewModel.postsById[postId] {
            readTracker.recordHidden(postNumber: post.postNumber)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        loadEarlierArmed = true
        lastScrollOffset = scrollView.contentOffset.y
        isReturningToTop = false
        bottomBarScrollState.beginGesture()
        lastBottomBarScrollOffset = boundedBottomBarOffset(for: scrollView)
        cancelPendingReadFlush()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            if flushPendingLoadEarlierIfReady() {
                scheduleDebouncedReadFlush()
                return
            }
            if !flushPendingSnapshotIfNeeded() { commitPendingDynamicHeights() }
            scheduleDebouncedReadFlush()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if flushPendingLoadEarlierIfReady() {
            scheduleDebouncedReadFlush()
            return
        }
        if !flushPendingSnapshotIfNeeded() { commitPendingDynamicHeights() }
        scheduleDebouncedReadFlush()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        finishReturningToTop()
        if flushPendingLoadEarlierIfReady() {
            scheduleDebouncedReadFlush()
            return
        }
        if !flushPendingSnapshotIfNeeded() { commitPendingDynamicHeights() }
        scheduleDebouncedReadFlush()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let currentOffset = scrollView.contentOffset.y
        let isMovingTowardEarlierPosts = currentOffset < lastScrollOffset
        lastScrollOffset = currentOffset
        updateBottomBarForScroll(scrollView)
        if let titlePath = dataSource.indexPath(for: .title(topicId)),
           let attributes = collectionView.layoutAttributesForItem(at: titlePath)
        {
            navigationItem.titleView = scrollView.contentOffset.y + scrollView.adjustedContentInset.top >= attributes.frame.maxY
                ? navTitleLabel
                : nil
        }
        guard (scrollView.isTracking || scrollView.isDragging),
              isMovingTowardEarlierPosts,
              loadEarlierArmed, !isLoadingPage, viewModel.canLoadEarlier, !viewModel.isReverseOrder,
              scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 180
        else { return }
        loadEarlierArmed = false
        isLoadingPage = true
        let operationGeneration = contentOperationGeneration
        Task {
            let addedPostIds = await viewModel.loadEarlierPosts(containerWidth: view.bounds.width)
            guard operationGeneration == contentOperationGeneration else {
                isLoadingPage = false
                return
            }
            handleLoadErrorIfNeeded()
            guard !addedPostIds.isEmpty else {
                isLoadingPage = false
                return
            }
            applyLoadEarlierSnapshot(addedPostIds: addedPostIds)
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let item = dataSource.itemIdentifier(for: indexPath),
                  imagePrefetchTokens[item] == nil,
                  case .unit(let id) = item,
                  let unit = unitsById[id]
            else { continue }
            let annotated = AnnotatedBlock(block: unit.block, sourceHTML: unit.sourceHTML)
            let urls = ImageURLCollector.collectImageURLs(from: [annotated]).compactMap(URL.init(string:))
            guard !urls.isEmpty else { continue }
            if let token = SDWebImagePrefetcher.shared.prefetchURLs(urls) {
                imagePrefetchTokens[item] = token
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for item in indexPaths.compactMap({ dataSource.itemIdentifier(for: $0) }) {
            imagePrefetchTokens.removeValue(forKey: item)?.cancel()
        }
    }

    private func cancelAllImagePrefetches() {
        for token in imagePrefetchTokens.values { token.cancel() }
        imagePrefetchTokens.removeAll(keepingCapacity: true)
    }
}

private extension VirtualizedTopicDetailViewController {
    func handleLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            UIApplication.shared.open(url)
            return
        }
        guard let baseHost = URL(string: baseURL)?.host,
              url.host?.caseInsensitiveCompare(baseHost) == .orderedSame
        else {
            present(SFSafariViewController(url: url), animated: true)
            return
        }

        if let route = ForumTopicLinkParser.parse(url, baseURL: baseURL) {
            navigationController?.pushViewController(
                TopicDetailControllerFactory.make(
                    api: api,
                    topicId: route.topicId,
                    initialFloor: route.floor
                ),
                animated: true
            )
        } else if let (slug, id) = categoryInfo(from: url) {
            let category = DiscourseCategory(id: id, name: slug, slug: slug)
            navigationController?.pushViewController(
                CategoryTopicsViewController(api: api, category: category),
                animated: true
            )
        } else if let tag = tagInfo(from: url) {
            navigationController?.pushViewController(TagTopicsViewController(api: api, tag: tag), animated: true)
        } else if let username = username(from: url) {
            navigationController?.pushViewController(
                UserProfileViewController(api: api, username: username),
                animated: true
            )
        } else {
            present(SFSafariViewController(url: url), animated: true)
        }
    }

    func categoryInfo(from url: URL) -> (String, Int)? {
        let components = url.pathComponents
        guard let index = components.firstIndex(of: "c"), index + 2 < components.count else { return nil }
        let remaining = Array(components[(index + 1)...])
        for candidate in remaining.indices.reversed() {
            let cleaned = remaining[candidate].replacingOccurrences(of: ".json", with: "")
            if let id = Int(cleaned), candidate > 0 { return (remaining[candidate - 1], id) }
        }
        return nil
    }

    func tagInfo(from url: URL) -> DiscourseTopicDetail.Tag? {
        let components = url.pathComponents
        guard let index = components.firstIndex(where: { $0 == "tag" || $0 == "tags" }),
              index + 2 < components.count,
              let id = Int(components[index + 2])
        else { return nil }
        let name = components[index + 1]
        return DiscourseTopicDetail.Tag(id: id, name: name, slug: name)
    }

    func username(from url: URL) -> String? {
        let components = url.pathComponents
        guard let index = components.firstIndex(of: "u"), index + 1 < components.count else { return nil }
        return components[index + 1]
    }
}

extension VirtualizedTopicDetailViewController: TopicDetailBottomBarDelegate {
    var bottomBarIsReverseOrder: Bool { viewModel.isReverseOrder }
    var bottomBarIsSummaryMode: Bool { viewModel.isSummaryMode }

    func bottomBarDidTapOPOnly() {
        viewModel.isFilteringByOP.toggle()
        scrollToTopAfterSnapshot = true
        applySnapshot(reloadVisible: false)
    }

    func bottomBarDidTapJumpToFloor() {
        let sheet = JumpToFloorSheetViewController(
            totalFloors: viewModel.totalFloors,
            currentFloor: currentVisibleFloor(),
            firstUnreadFloor: viewModel.topic?.lastReadPostNumber.map { $0 + 1 },
            isReverseOrder: viewModel.isReverseOrder,
            isSummaryMode: viewModel.isSummaryMode
        )
        sheet.onJump = { [weak self] in self?.performJump(to: $0) }
        sheet.onToggleReverseOrder = { [weak self] in self?.bottomBarDidToggleReverseOrder() }
        sheet.onToggleSummaryMode = { [weak self] in self?.bottomBarDidToggleSummaryMode() }
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium()]
            presentation.prefersGrabberVisible = true
        }
        present(sheet, animated: true)
    }

    func bottomBarDidToggleReverseOrder() {
        contentOperationGeneration &+= 1
        modeGeneration &+= 1
        let generation = modeGeneration
        Task {
            if viewModel.isReverseOrder {
                viewModel.disableReverseOrder()
                await viewModel.loadTopic(id: topicId, containerWidth: view.bounds.width)
            } else {
                await viewModel.enableReverseOrder(containerWidth: view.bounds.width)
            }
            guard generation == modeGeneration else { return }
            resolvedHeights.removeAll()
            resolvedBoostHeights.removeAll()
            scrollToTopAfterSnapshot = true
            applySnapshot(reloadVisible: false)
        }
    }

    func bottomBarDidToggleSummaryMode() {
        contentOperationGeneration &+= 1
        modeGeneration &+= 1
        let generation = modeGeneration
        Task {
            await viewModel.toggleSummaryMode(containerWidth: view.bounds.width)
            guard generation == modeGeneration else { return }
            resolvedHeights.removeAll()
            resolvedBoostHeights.removeAll()
            scrollToTopAfterSnapshot = true
            applySnapshot(reloadVisible: false)
        }
    }

    func bottomBarDidTapReply() {
        requireAuthentication { [weak self] in self?.presentReplyComposer(for: nil) }
    }

    func bottomBarDidTapScrollToTop() {
        scrollToTopicTop()
    }

    func bottomBarDidBeginScrubFromJump(at locationInWindow: CGPoint, buttonFrame: CGRect) {
        let total = viewModel.totalFloors
        guard total > 1, jumpScrubber == nil else { return }
        let startingFloor = currentVisibleFloor()
        jumpScrubStartLocation = view.convert(locationInWindow, from: nil)
        jumpScrubHasMoved = false
        jumpScrubStartFloor = startingFloor

        let safeMargin: CGFloat = 60
        let leftSpace = max(jumpScrubStartLocation.x - safeMargin, 1)
        let rightSpace = max(view.bounds.width - jumpScrubStartLocation.x - safeMargin, 1)
        jumpScrubReferenceDistance = min(leftSpace, rightSpace)

        let barTop = bottomBar.convert(bottomBar.bounds, to: view).minY
        let overlay = JumpScrubberOverlay(
            totalFloors: total,
            startingFloor: startingFloor,
            arcCenter: CGPoint(x: view.bounds.midX, y: barTop - 24),
            radius: 130
        )
        overlay.frame = view.bounds
        view.addSubview(overlay)
        overlay.presentTransitionIn()
        jumpScrubber = overlay
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    func bottomBarDidUpdateScrub(at locationInWindow: CGPoint) {
        guard let overlay = jumpScrubber else { return }
        let location = view.convert(locationInWindow, from: nil)
        if !jumpScrubHasMoved {
            let distance = hypot(
                location.x - jumpScrubStartLocation.x,
                location.y - jumpScrubStartLocation.y
            )
            guard distance >= jumpScrubMoveThreshold else { return }
            jumpScrubHasMoved = true
        }
        let dx = location.x - jumpScrubStartLocation.x
        let normalized = min(abs(dx) / jumpScrubReferenceDistance, 1)
        let delta = Int((pow(normalized, 1.8) * CGFloat(viewModel.totalFloors - 1)).rounded())
        let signedDelta = dx >= 0 ? delta : -delta
        overlay.update(floor: max(1, min(viewModel.totalFloors, jumpScrubStartFloor + signedDelta)))
    }

    func bottomBarDidEndScrub(cancelled: Bool) {
        guard let overlay = jumpScrubber else { return }
        jumpScrubber = nil
        overlay.presentTransitionOut()
        guard !cancelled, jumpScrubHasMoved else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        performJump(to: overlay.currentFloor)
    }

    private func currentVisibleFloor() -> Int {
        for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
            if let item = dataSource.itemIdentifier(for: indexPath),
               let id = postIdByItem[item], let post = viewModel.postsById[id]
            { return post.postNumber }
        }
        return 1
    }

    private func performJump(to floor: Int) {
        guard floor >= 1 else { return }
        contentOperationGeneration &+= 1
        if viewModel.isTreeMode {
            isReloadingTreeMode = true
            viewModel.isTreeMode = false
            updateTreeModeControls()
            let generation = nextTreeReloadGeneration()
            activityIndicator.startAnimating()
            Task {
                await viewModel.loadTopic(id: topicId, containerWidth: view.bounds.width)
                if !viewModel.isFloorLoaded(floor) {
                    _ = await viewModel.jumpToFloor(floor, containerWidth: view.bounds.width)
                }
                guard generation == treeReloadGeneration, !viewModel.isTreeMode else { return }
                guard await reloadAllAfterTreeModeChange(
                    generation: generation,
                    resetContentOffset: false
                ) else { return }
                scrollToFloor(floor, position: .top)
            }
            return
        }
        if viewModel.posts.contains(where: { $0.postNumber == floor }) {
            scrollToFloor(floor, position: .top)
            return
        }
        isPerformingJump = true
        jumpOverlay.isHidden = false
        Task {
            let succeeded = await viewModel.jumpToFloor(floor, containerWidth: view.bounds.width)
            isPerformingJump = false
            jumpOverlay.isHidden = true
            guard succeeded else {
                if let error = viewModel.lastLoadError { handleLoadErrorIfNeeded(); presentError(error) }
                else if let message = viewModel.errorMessage {
                    let error = NSError(domain: "TopicJump", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
                    presentError(error)
                }
                return
            }
            resolvedHeights.removeAll()
            resolvedBoostHeights.removeAll()
            applySnapshot(reloadVisible: false)
            collectionView.layoutIfNeeded()
            scrollToFloor(floor, position: .top)
        }
    }
}

extension VirtualizedTopicDetailViewController: PostCellDelegate {
    func postCell(didTapImageURL url: URL, inPostId postId: Int) {
        let request = TopicImageBrowserRequest.make(
            annotatedBlocks: viewModel.renderDocuments[postId]?.annotatedBlocks ?? [],
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
        let controller = RepliesViewController(api: api, postId: postId, topicId: topicId, validReactions: viewModel.topic?.validReactions ?? [])
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(controller, animated: true)
    }

    func postCell(didTapToggleDetails detailsIndex: Int, postId: Int) {}
    func postCell(didTapReplyToPost post: DiscourseTopicDetail.Post) {
        requireAuthentication { [weak self] in self?.presentReplyComposer(for: post) }
    }

    func postCell(didTapReplyReferenceForPost post: DiscourseTopicDetail.Post) {
        guard let number = post.replyToPostNumber else { return }
        Task {
            let parent: DiscourseTopicDetail.Post
            if let loaded = viewModel.posts.first(where: { $0.postNumber == number }) {
                parent = loaded
            } else if let fetched = try? await api.fetchPostByNumber(topicId: topicId, postNumber: number) {
                parent = fetched
            } else { return }
            let preview = ReplyPreviewViewController(api: api, post: parent, topicId: topicId, validReactions: viewModel.topic?.validReactions ?? [], floorNumber: parent.postNumber)
            present(UINavigationController(rootViewController: preview), animated: true)
        }
    }

    func postCell(didToggleCollapseForPostId postId: Int) {
        let anchor = captureAnchor()
        viewModel.toggleCollapse(postId: postId)
        applySnapshot(reloadVisible: true, preserving: anchor)
    }

    func postCell(didTapLoadMoreChildrenForParentId parentPostId: Int) {
        Task {
            let anchor = captureAnchor()
            _ = await viewModel.loadMoreChildren(forParentId: parentPostId)
            applySnapshot(reloadVisible: true, preserving: anchor)
            handleLoadErrorIfNeeded()
        }
    }

    func postCell(didToggleBookmarkForPost post: DiscourseTopicDetail.Post, isBookmarked: Bool) {
        Task {
            do {
                if isBookmarked { _ = try await api.createBookmark(postId: post.id) }
                else if let id = post.bookmarkId { try await api.deleteBookmark(id: id) }
                if let fresh = try? await api.fetchPost(id: post.id) { await viewModel.replacePost(fresh) }
                applySnapshot(reloadVisible: true)
            } catch {
                if !presentChallengePromptIfNeeded(error: error, on: api) { presentError(error) }
            }
        }
    }

    func postCell(didTapAvatarForUsername username: String) {
        let topicTitle = viewModel.topic?.title
        let prefill = topicTitle.map { "[\($0)](\(baseURL)/t/\(topicId))" }
        let controller = UserProfileViewController(
            api: api,
            username: username,
            messagePrefillTitle: topicTitle,
            messagePrefillBody: prefill
        )
        navigationController?.pushViewController(controller, animated: true)
    }

    func postCell(didTapReaction reactionId: String, forPost post: DiscourseTopicDetail.Post) {
        Task {
            do {
                try await api.toggleReaction(postId: post.id, reactionId: reactionId)
                playReactionSuccessFeedback(
                    forPostId: post.id,
                    animated: post.currentUserReaction?.id != reactionId
                )
                if let fresh = try? await api.fetchPost(id: post.id) {
                    await viewModel.replacePost(fresh)
                    if post.currentUserReaction?.id != reactionId {
                        pendingReactionConfirmationPostIds.insert(post.id)
                    }
                }
                applySnapshot(reloadVisible: true)
            } catch {
                presentChallengePromptIfNeeded(error: error, on: api)
            }
        }
    }

    private func toggleSolution(for post: DiscourseTopicDetail.Post, accepting: Bool) {
        requireAuthentication { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let answers: [DiscourseTopicDetail.AcceptedAnswer]?
                    if accepting {
                        answers = try await self.api.acceptSolution(postId: post.id)
                    } else {
                        answers = try await self.api.unacceptSolution(postId: post.id)
                    }
                    let anchor = self.captureAnchor()
                    self.viewModel.applySolutionMutation(
                        postId: post.id,
                        accepting: accepting,
                        acceptedAnswers: answers
                    )
                    self.applySnapshot(reloadVisible: true, preserving: anchor)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch {
                    // Reconfigure the visible footer so its temporarily
                    // disabled solution button becomes interactive again.
                    self.applySnapshot(reloadVisible: true, preserving: self.captureAnchor())
                    if !self.presentChallengePromptIfNeeded(error: error, on: self.api) {
                        self.presentError(error)
                    }
                }
            }
        }
    }

    func postCell(didToggleLikeForPost post: DiscourseTopicDetail.Post, liked: Bool) {
        Task {
            do {
                if liked { try await api.likePost(postId: post.id) }
                else { try await api.unlikePost(postId: post.id) }
                playReactionSuccessFeedback(forPostId: post.id, animated: liked)
                if let fresh = try? await api.fetchPost(id: post.id) {
                    await viewModel.replacePost(fresh)
                    if liked { pendingReactionConfirmationPostIds.insert(post.id) }
                }
                applySnapshot(reloadVisible: true)
            } catch {
                presentChallengePromptIfNeeded(error: error, on: api)
            }
        }
    }

    private func playReactionSuccessFeedback(forPostId postId: Int, animated: Bool) {
        guard let indexPath = dataSource.indexPath(for: .footer(postId)),
              let cell = collectionView.cellForItem(at: indexPath) as? VirtualPostFooterCell
        else {
            if animated { ReactionFeedback.play(from: nil) }
            return
        }
        cell.playReactionSuccessFeedback(animated: animated)
    }

    func postCell(didTapBoostForPost post: DiscourseTopicDetail.Post) {
        requireAuthentication { [weak self] in self?.presentBoostComposer(for: post) }
    }

    private func presentBoostComposer(for post: DiscourseTopicDetail.Post) {
        let alert = UIAlertController(title: String(localized: "reply.title.to \(post.username)"), message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = String(localized: "reply.placeholder") }
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
                    if AppSettings.shared.boostDisplayMode == .danmaku {
                        self.shootBoostDanmaku([boost], forPostId: post.id)
                    }
                    self.applySnapshot(reloadVisible: true)
                } catch {
                    if self.presentChallengePromptIfNeeded(error: error, on: self.api) { return }
                    self.presentError(error)
                }
            }
        })
        present(alert, animated: true)
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
                    if let postId = self.viewModel.posts.first(where: { post in
                        post.boosts.contains(where: { $0.id == boost.id })
                    })?.id {
                        self.viewModel.removeBoost(boostId: boost.id, fromPostId: postId)
                    }
                    self.applySnapshot(reloadVisible: true)
                } catch {
                    if self.presentChallengePromptIfNeeded(error: error, on: self.api) { return }
                    self.presentError(error)
                }
            }
        })
        present(alert, animated: true)
    }

    func postCell(didTapToggleBoostsForPost post: DiscourseTopicDetail.Post, sourceView: UIView) {
        switch AppSettings.shared.boostDisplayMode {
        case .expand:
            viewModel.toggleBoosts(forPostId: post.id)
            applySnapshot(reloadVisible: false, preserving: captureAnchor())
        case .danmaku:
            shootBoostDanmaku(post.boosts, forPostId: post.id)
        }
    }

    private func shootBoostDanmaku(_ boosts: [DiscourseTopicDetail.Boost], forPostId postId: Int) {
        guard !boosts.isEmpty else { return }
        let topItem: VirtualTopicItem = dataSource.indexPath(for: .header(postId)) != nil ? .header(postId) : .collapsed(postId)
        let bottomItem: VirtualTopicItem = dataSource.indexPath(for: .footer(postId)) != nil ? .footer(postId) : topItem
        guard let topPath = dataSource.indexPath(for: topItem),
              let bottomPath = dataSource.indexPath(for: bottomItem),
              let topAttributes = collectionView.layoutAttributesForItem(at: topPath),
              let bottomAttributes = collectionView.layoutAttributesForItem(at: bottomPath)
        else { return }
        let topRect = collectionView.convert(topAttributes.frame, to: view)
        let bottomRect = collectionView.convert(bottomAttributes.frame, to: view)
        let top = max(view.safeAreaInsets.top, topRect.minY) + 8
        let bottom = min(view.bounds.height - view.safeAreaInsets.bottom, bottomRect.maxY)
        boostDanmaku.shoot(boosts: boosts, assetBaseURL: api.assetBaseURL, top: top, bottom: bottom)
    }

    private func presentError(_ error: Error) {
        let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
        present(alert, animated: true)
    }

    func postCell(didVotePoll pollName: String, options: [String], forPost post: DiscourseTopicDetail.Post) {
        Task {
            do {
                let response = try await api.votePoll(postId: post.id, pollName: pollName, options: options)
                await viewModel.updatePoll(response.poll, votes: response.vote ?? options, forPostId: post.id, pollName: pollName)
                invalidateHeightMeasurements(forPostId: post.id)
                applySnapshot(reloadVisible: true)
            } catch {
                if !presentChallengePromptIfNeeded(error: error, on: api) { presentError(error) }
            }
        }
    }

    func postCell(didRemovePollVote pollName: String, forPost post: DiscourseTopicDetail.Post) {
        Task {
            do {
                let response = try await api.removePollVote(postId: post.id, pollName: pollName)
                await viewModel.updatePoll(response.poll, votes: response.vote ?? [], forPostId: post.id, pollName: pollName)
                invalidateHeightMeasurements(forPostId: post.id)
                applySnapshot(reloadVisible: true)
            } catch {
                if !presentChallengePromptIfNeeded(error: error, on: api) { presentError(error) }
            }
        }
    }

    func postCell(didTapFlagPost post: DiscourseTopicDetail.Post, sourceView: UIView) {
        let alert = UIAlertController(title: String(localized: "post.flag"), message: String(localized: "post.flag.message"), preferredStyle: .actionSheet)
        for (title, type) in [(String(localized: "post.flag.off_topic"), 3), (String(localized: "post.flag.inappropriate"), 4), (String(localized: "post.flag.spam"), 8)] {
            alert.addAction(UIAlertAction(title: title, style: .destructive) { [weak self] _ in
                guard let self else { return }
                self.submitFlag(post: post, type: type, message: nil)
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "post.flag.notify_moderators"), style: .default) { [weak self] _ in
            self?.presentFlagWithMessage(post: post)
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        if let popover = alert.popoverPresentationController { popover.sourceView = sourceView; popover.sourceRect = sourceView.bounds }
        present(alert, animated: true)
    }

    private func presentFlagWithMessage(post: DiscourseTopicDetail.Post) {
        let alert = UIAlertController(title: String(localized: "post.flag.notify_moderators"), message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = String(localized: "post.flag.reason_placeholder") }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "post.flag.send"), style: .destructive) { [weak self, weak alert] _ in
            guard let self,
                  let message = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty
            else { return }
            self.submitFlag(post: post, type: 7, message: message)
        })
        present(alert, animated: true)
    }

    private func submitFlag(post: DiscourseTopicDetail.Post, type: Int, message: String?) {
        Task {
            do {
                try await api.flagPost(postId: post.id, flagTypeId: type, message: message)
                let alert = UIAlertController(title: nil, message: String(localized: "post.flag.sent"), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
                present(alert, animated: true)
            } catch {
                if !presentChallengePromptIfNeeded(error: error, on: api) { presentError(error) }
            }
        }
    }

    func postCell(didLongPressPost post: DiscourseTopicDetail.Post) {
        Task {
            do {
                let detail = try await api.fetchPost(id: post.id)
                guard let raw = detail.raw, !raw.isEmpty else { return }
                let rawController = RawContentViewController(
                    raw: raw,
                    username: post.username,
                    floorNumber: post.postNumber
                )
                let navigationController = UINavigationController(rootViewController: rawController)
                if let sheet = navigationController.sheetPresentationController {
                    sheet.detents = [.medium(), .large()]
                    sheet.prefersGrabberVisible = true
                }
                present(navigationController, animated: true)
            } catch {
                let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func presentReplyComposer(for post: DiscourseTopicDetail.Post?) {
        let composer = ReplyComposerViewController(api: api, topicId: topicId, replyToPost: post, baseURL: baseURL)
        composer.onPostCreated = { [weak self] newPostId, floor in
            guard let self else { return }
            Task {
                if self.viewModel.isTreeMode {
                    let parentId = post?.id
                    var inserted = false
                    if let created = try? await self.api.fetchPost(id: newPostId) {
                        inserted = await self.viewModel.insertReplyIntoTree(created, parentId: parentId)
                    }
                    if !inserted {
                        await self.viewModel.loadNestedTopic(
                            id: self.topicId,
                            sort: self.viewModel.treeSort,
                            containerWidth: self.view.bounds.width
                        )
                        self.viewModel.expandAncestors(ofPostNumber: floor)
                    }
                } else {
                    await self.viewModel.loadTopic(
                        id: self.topicId,
                        containerWidth: self.view.bounds.width,
                        nearPostNumber: floor
                    )
                }
                self.preparedLayout = nil
                self.applySnapshot(reloadVisible: false)
                self.collectionView.layoutIfNeeded()
                self.scrollToFloor(floor, position: .bottom)
            }
        }
        let navigation = UINavigationController(rootViewController: composer)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }
}
