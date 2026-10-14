import Foundation
import UIKit
import CookedHTML

import Perception

/// Describes a "view N more replies" affordance shown at the tail of a node's
/// loaded children in tree mode. The server inlines only the first few direct
/// replies per post; when `directReplyCount` exceeds what's loaded, the
/// view-model emits one of these so the view-controller can render a tappable
/// row that fetches the remainder via `/n/.../children/{n}.json`.
struct PendingChildLoad {
    /// Post whose extra direct replies this row expands.
    let parentPostId: Int
    /// Visible row (last descendant of `parentPostId`'s loaded subtree, or the
    /// parent itself when nothing is inlined) the row should be inserted after.
    let anchorPostId: Int
    /// How many more direct replies remain to load.
    let remaining: Int
    /// Tree depth the row renders at (parent depth + 1).
    let depth: Int
    /// Connector state so the row slots into the tree spine as the last sibling.
    let treeLineState: TreeLineState
}

@Perceptible
final class TopicDetailViewModel {
    var topic: DiscourseTopicDetail?
    var parsedBlocks: [Int: [AnnotatedBlock]] = [:]
    /// Immutable documents produced off the main actor. The legacy renderer
    /// consumes `annotatedBlocks`; the virtualized renderer consumes `units`.
    private(set) var renderDocuments: [Int: PostRenderDocument] = [:]
    var isLoading = false
    var isReady = false
    var isLoadingMore = false
    var isLoadingEarlier = false
    var isFilteringByOP = false
    var isReverseOrder = false
    var isSummaryMode = false
    var isTreeMode = false
    /// Sort order passed to the nested-replies endpoint when `isTreeMode` is
    /// active. One of "top", "new", "old".
    var treeSort: String = "top"
    /// Posts whose subtree the user has collapsed in tree mode. The collapsed
    /// post itself stays visible; its descendants are skipped during DFS.
    /// Cleared when leaving tree mode would just confuse users on next entry,
    /// so it survives mode toggles.
    var collapsedPostIds: Set<Int> = []
    var expandedBoostPostIds: Set<Int> = []
    var errorMessage: String?
    /// Raw error from the last topic load — surfaced so the VC can route
    /// Cloudflare-challenge cases into the auth prompt instead of just
    /// rendering the message string. Cleared on each new `loadTopic` call.
    var lastLoadError: Error?
    /// True iff the last `loadMorePosts` / `loadMoreNestedRoots` attempt
    /// failed. The view-controller swaps the table footer for a retry button
    /// when this is set and gates automatic load-more triggers until the
    /// user explicitly retries.
    var loadMoreFailed: Bool = false

    private let api: DiscourseAPI
    private(set) var allPostIds: [Int] = []
    private var loadedPostIds: Set<Int> = []
    private(set) var loadedRangeStart: Int = 0
    private(set) var loadedRangeEnd: Int = 0
    /// Cached first post (OP) to preserve across jumpToFloor
    private var firstPost: DiscourseTopicDetail.Post?
    /// Last loaded topic id — needed for summary toggle which has to re-fetch.
    private var lastLoadedTopicId: Int?
    /// Bumped whenever the loaded-post window is reset (loadTopic, jumpToFloor,
    /// enableReverseOrder). In-flight pagination requests captured before the
    /// reset compare against this and discard their response, otherwise stale
    /// posts get inserted into the new window — e.g. after jumping to floor 1
    /// from deep in the topic, an earlier `loadEarlierPosts` would prepend
    /// floors from the prior window in front of the OP.
    private var loadGeneration: UInt = 0
    private var recordedLocalReadTopicId: Int?

    init(api: DiscourseAPI) {
        self.api = api
    }

    private func recordLocalReadIfNeeded(_ detail: DiscourseTopicDetail) {
        guard detail.archetype != "private_message",
              recordedLocalReadTopicId != detail.id,
              let scope = ReadHistoryScope.current(api: api)
        else { return }
        do {
            try LocalReadHistoryStore.shared.record(topic: detail, scope: scope)
            recordedLocalReadTopicId = detail.id
        } catch {
            debugLog("[LocalRead] failed to record topic \(detail.id): \(error)")
        }
    }

    var posts: [DiscourseTopicDetail.Post] {
        topic?.postStream.posts ?? []
    }

    /// O(1) post lookup by ID — rebuilt whenever posts change.
    private(set) var postsById: [Int: DiscourseTopicDetail.Post] = [:]

    func rebuildPostsById() {
        postsById = Dictionary(posts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// OP's username. Topic responses identify the author through
    /// `details.created_by`, including when the loaded window is centered on a
    /// deep floor. `firstPost` remains a fallback for nested/legacy payloads.
    var opUsername: String? {
        topic?.originalPosterUsername ?? firstPost?.username
    }

    var visiblePosts: [DiscourseTopicDetail.Post] {
        var base = posts.filter { ($0.actionCode ?? "").isEmpty }
        if isFilteringByOP, let op = opUsername {
            base = base.filter { $0.username == op }
        }
        if isTreeMode {
            // Prefer the server-supplied tree when it's available — it's
            // guaranteed complete (no "child paginated out of window" gaps).
            if let opPost = nestedTreeOpPost, let roots = nestedTreeRoots {
                return flattenNestedTree(opPost: opPost, roots: roots)
            }
            return treeOrderedPosts(from: base)
        }
        if isReverseOrder {
            // Pin OP at top, then the rest of loaded posts in reverse —
            // newest immediately below OP, oldest non-OP at the bottom.
            let op = base.first(where: { $0.postNumber == 1 })
            let rest = Array(base.filter { $0.postNumber != 1 }.reversed())
            return op.map { [$0] + rest } ?? rest
        }
        return base
    }

    /// Tree depth (0-based) for each loaded post, populated as a side effect
    /// of building the tree-ordered visible list. Read by the cell at render
    /// time to apply leading indent. Empty when `isTreeMode == false`.
    private(set) var postDepths: [Int: Int] = [:]

    /// Tree-line render state per post, populated alongside `postDepths`. The
    /// cell consults this to draw vertical / corner connectors at the right
    /// ancestor columns. Absent for non-tree-mode reads.
    private(set) var postTreeLineStates: [Int: TreeLineState] = [:]

    /// Server-supplied OP + top-level replies (each with full subtree on
    /// `children`). When set, the view-model walks this directly instead of
    /// inferring parent/child links from `replyToPostNumber` — the nested
    /// endpoint already guarantees completeness even when the flat stream
    /// would have paginated out the descendant in question.
    private var nestedTreeOpPost: DiscourseTopicDetail.Post?
    private var nestedTreeRoots: [DiscourseTopicDetail.Post]?
    /// Pagination state for `/n/.../json` — true when more root-level replies
    /// are available on subsequent pages. We don't load further pages yet but
    /// the flag is here so a later "load more roots" can wire in cleanly.
    private(set) var nestedHasMoreRoots: Bool = false
    private(set) var nestedRootsPage: Int = 0

    /// "View more replies" affordances for the current tree flatten, keyed by
    /// `parentPostId`. Recomputed as a side effect of `flattenNestedTree`. The
    /// view-controller interleaves a tappable row after each entry's
    /// `anchorPostId` when building its snapshot.
    private(set) var pendingChildLoads: [Int: PendingChildLoad] = [:]
    /// Parent post IDs with an in-flight `loadMoreChildren` request — guards
    /// against double taps and lets the row show a spinner.
    private(set) var loadingChildrenParentIds: Set<Int> = []
    /// Last children page fetched per parent (for the `has_more` paginated
    /// case). Absent means only the inline preview has loaded so far.
    private var loadedChildPages: [Int: Int] = [:]

    /// DFS-flatten the loaded posts into tree order using `replyToPostNumber`
    /// as the parent edge. OP (postNumber == 1) is the root; replies with
    /// `replyToPostNumber == nil` are treated as direct replies to OP. Posts
    /// whose reply target isn't in the loaded window are demoted to root-level
    /// (under OP) so they remain reachable.
    ///
    /// Siblings keep chronological order via `postNumber` ascending. Depth is
    /// recorded into `postDepths` for the cell-render path.
    private func treeOrderedPosts(from base: [DiscourseTopicDetail.Post]) -> [DiscourseTopicDetail.Post] {
        postDepths = [:]
        postTreeLineStates = [:]
        // The inference path has no server-authoritative child counts, so it
        // never surfaces "view more" rows — clear any from a prior flatten.
        pendingChildLoads = [:]
        guard !base.isEmpty else { return [] }
        let byPostNumber = Dictionary(uniqueKeysWithValues: base.map { ($0.postNumber, $0) })

        var children: [Int: [DiscourseTopicDetail.Post]] = [:]
        var directRepliesToOP: [DiscourseTopicDetail.Post] = []
        for post in base where post.postNumber != 1 {
            if let replyTo = post.replyToPostNumber,
               replyTo != post.postNumber,
               byPostNumber[replyTo] != nil
            {
                children[replyTo, default: []].append(post)
            } else {
                directRepliesToOP.append(post)
            }
        }
        for key in children.keys {
            children[key]?.sort { $0.postNumber < $1.postNumber }
        }
        directRepliesToOP.sort { $0.postNumber < $1.postNumber }

        var out: [DiscourseTopicDetail.Post] = []
        out.reserveCapacity(base.count)

        if let op = byPostNumber[1] {
            postDepths[op.id] = 0
            postTreeLineStates[op.id] = TreeLineState(
                depth: 0,
                isLastSibling: true,
                ancestorTrails: [],
                hasChildren: !directRepliesToOP.isEmpty,
                isCollapsed: false
            )
            out.append(op)
            dfsAppend(directRepliesToOP, depth: 1, children: children, ancestorTrails: [], into: &out)
        } else {
            dfsAppend(directRepliesToOP, depth: 0, children: children, ancestorTrails: [], into: &out)
        }
        return out
    }

    private func dfsAppend(
        _ nodes: [DiscourseTopicDetail.Post],
        depth: Int,
        children: [Int: [DiscourseTopicDetail.Post]],
        ancestorTrails: [Bool],
        into out: inout [DiscourseTopicDetail.Post]
    ) {
        let lastIndex = nodes.count - 1
        for (idx, post) in nodes.enumerated() {
            let isLast = idx == lastIndex
            let kids = children[post.postNumber] ?? []
            let hasKids = !kids.isEmpty
            let collapsed = collapsedPostIds.contains(post.id)
            postDepths[post.id] = depth
            postTreeLineStates[post.id] = TreeLineState(
                depth: depth,
                isLastSibling: isLast,
                ancestorTrails: ancestorTrails,
                hasChildren: hasKids,
                isCollapsed: collapsed
            )
            out.append(post)
            // Skip descending when the user has collapsed this subtree —
            // descendants stay in `postsById` but drop out of the visible list.
            if hasKids, !collapsed {
                var nextTrails = ancestorTrails
                nextTrails.append(!isLast)
                dfsAppend(kids, depth: depth + 1, children: children, ancestorTrails: nextTrails, into: &out)
            }
        }
    }

    func toggleCollapse(postId: Int) {
        if collapsedPostIds.contains(postId) {
            collapsedPostIds.remove(postId)
        } else {
            collapsedPostIds.insert(postId)
        }
    }

    /// DFS-flatten the server-supplied nested tree, simultaneously computing
    /// per-post tree state. Mirrors `dfsAppend` but reads child links from the
    /// post's own `children` array (server-authoritative) instead of inferring
    /// them from `replyToPostNumber`.
    private func flattenNestedTree(
        opPost: DiscourseTopicDetail.Post,
        roots: [DiscourseTopicDetail.Post]
    ) -> [DiscourseTopicDetail.Post] {
        postDepths = [:]
        postTreeLineStates = [:]
        pendingChildLoads = [:]

        var out: [DiscourseTopicDetail.Post] = []
        out.reserveCapacity(roots.count + 1)

        let hasRoots = !roots.isEmpty
        postDepths[opPost.id] = 0
        postTreeLineStates[opPost.id] = TreeLineState(
            depth: 0,
            isLastSibling: true,
            ancestorTrails: [],
            hasChildren: hasRoots,
            isCollapsed: false
        )
        out.append(opPost)

        dfsNested(roots, depth: 1, ancestorTrails: [], into: &out)
        return out
    }

    private func dfsNested(
        _ nodes: [DiscourseTopicDetail.Post],
        depth: Int,
        ancestorTrails: [Bool],
        extraTrailingSibling: Bool = false,
        into out: inout [DiscourseTopicDetail.Post]
    ) {
        let lastIndex = nodes.count - 1
        for (idx, post) in nodes.enumerated() {
            // A trailing "view more" row counts as one more sibling, so the
            // real last child shouldn't terminate the spine when one follows.
            let isLast = idx == lastIndex && !extraTrailingSibling
            let kids = post.children ?? []
            let hasKids = !kids.isEmpty
            let collapsed = collapsedPostIds.contains(post.id)
            // Direct replies the server didn't inline → a "view more" row.
            let remaining = max(0, post.directReplyCount - kids.count)
            postDepths[post.id] = depth
            postTreeLineStates[post.id] = TreeLineState(
                depth: depth,
                isLastSibling: isLast,
                ancestorTrails: ancestorTrails,
                // Draw the outgoing spine when there are loaded children *or*
                // unfetched ones a "view more" row will sit under.
                hasChildren: hasKids || remaining > 0,
                isCollapsed: collapsed
            )
            out.append(post)
            guard !collapsed else { continue }
            var nextTrails = ancestorTrails
            nextTrails.append(!isLast)
            if hasKids {
                dfsNested(
                    kids,
                    depth: depth + 1,
                    ancestorTrails: nextTrails,
                    extraTrailingSibling: remaining > 0,
                    into: &out
                )
            }
            if remaining > 0 {
                let childDepth = depth + 1
                let anchorId = out.last?.id ?? post.id
                pendingChildLoads[post.id] = PendingChildLoad(
                    parentPostId: post.id,
                    anchorPostId: anchorId,
                    remaining: remaining,
                    depth: childDepth,
                    treeLineState: TreeLineState(
                        depth: childDepth,
                        isLastSibling: true,
                        ancestorTrails: nextTrails,
                        hasChildren: false,
                        isCollapsed: false
                    )
                )
            }
        }
    }

    /// Pivot the in-flight `loadNestedTopic` call to a flat-topic load when
    /// the server returned the standard `post_stream` layout (PMs and other
    /// archetypes that aren't tree-rendered). We populate the same state
    /// `loadTopic` would have and flip `isTreeMode` off so the UI follows.
    private func ingestFlatTopic(
        _ response: DiscourseTopicDetail,
        containerWidth: CGFloat,
        expectedGeneration: UInt
    ) async {
        let detail = topicWithSynchronizedSolutionState(response)
        isTreeMode = false
        topic = detail
        recordLocalReadIfNeeded(detail)
        allPostIds = detail.postStream.stream ?? detail.postStream.posts.map(\.id)
        loadedPostIds = Set(detail.postStream.posts.map(\.id))
        if detail.postStream.posts.first?.postNumber == 1 {
            firstPost = detail.postStream.posts.first
        }
        if let firstLoadedId = detail.postStream.posts.first?.id,
           let firstIndex = allPostIds.firstIndex(of: firstLoadedId) {
            loadedRangeStart = firstIndex
        } else {
            loadedRangeStart = 0
        }
        if let lastLoadedId = detail.postStream.posts.last?.id,
           let lastIndex = allPostIds.firstIndex(of: lastLoadedId) {
            loadedRangeEnd = lastIndex + 1
        } else {
            loadedRangeEnd = detail.postStream.posts.count
        }
        await parseAndStore(posts: detail.postStream.posts, expectedGeneration: expectedGeneration)
        guard loadGeneration == expectedGeneration else { return }
        if isReady { isReady = false }
        isReady = true
    }

    /// Some solved-plugin versions expose the accepted answer only through the
    /// topic-level summary. Mirror that canonical metadata onto the loaded
    /// posts so the accepted reply is styled consistently across versions.
    private func topicWithSynchronizedSolutionState(
        _ response: DiscourseTopicDetail
    ) -> DiscourseTopicDetail {
        var detail = response
        let acceptedPostNumbers = Set(detail.acceptedAnswers.map(\.postNumber))
        for index in detail.postStream.posts.indices {
            if !acceptedPostNumbers.isEmpty {
                detail.postStream.posts[index].acceptedAnswer = acceptedPostNumbers.contains(
                    detail.postStream.posts[index].postNumber
                )
            }
            detail.postStream.posts[index].topicAcceptedAnswer =
                detail.hasAcceptedAnswer || detail.postStream.posts[index].topicAcceptedAnswer
        }
        return detail
    }

    /// Recursively collect every post in the nested tree into `postsById` and
    /// `parsedBlocks` so the rest of the view-model (which keys off post IDs)
    /// can find them. Each stored copy has its `children` link cleared to
    /// avoid carrying around two views of the same data — the tree shape lives
    /// in `nestedTreeRoots`, the per-post data lives in `postsById`.
    private func ingestNested(_ post: DiscourseTopicDetail.Post, collected: inout [DiscourseTopicDetail.Post]) {
        var bare = post
        bare.children = nil
        postsById[bare.id] = bare
        collected.append(bare)
        for child in post.children ?? [] {
            ingestNested(child, collected: &collected)
        }
    }

    /// Fetch the next page of root-level replies in tree mode and append them
    /// to the existing tree. Returns the IDs of any new posts ingested so the
    /// view-controller can drive a partial snapshot update.
    @discardableResult
    func loadMoreNestedRoots() async -> [Int] {
        guard isTreeMode, nestedHasMoreRoots, !isLoadingMore,
              let topicId = topic?.id ?? lastLoadedTopicId
        else { return [] }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let nextPage = nestedRootsPage + 1
        let capturedGeneration = loadGeneration

        do {
            let response = try await api.fetchNestedTopic(id: topicId, slug: nil, sort: treeSort, page: nextPage)
            // Bail if the window was reset under us (jumpToFloor, mode flip).
            guard loadGeneration == capturedGeneration else { return [] }

            var added: [Int] = []
            // Drop roots that we somehow already have (shouldn't happen, but
            // defends against duplicates if the server pages overlap).
            let existingIds = Set((nestedTreeRoots ?? []).map(\.id))
            let newRoots = response.roots.filter { !existingIds.contains($0.id) }
            var postsToParse: [DiscourseTopicDetail.Post] = []
            for root in newRoots {
                ingestNested(root, collected: &postsToParse)
                collectIds(in: root, into: &added)
            }
            await parseAndStore(posts: postsToParse)
            nestedTreeRoots = (nestedTreeRoots ?? []) + newRoots
            nestedHasMoreRoots = response.hasMoreRoots
            nestedRootsPage = response.page

            // Refresh the synthesized topic so callers reading topic.postStream
            // (e.g. height precompute via parsedBlocks scan) see the new posts.
            if var existing = topic {
                existing.postStream = DiscourseTopicDetail.PostStream(
                    posts: Array(postsById.values),
                    stream: nil
                )
                topic = existing
            }
            allPostIds = Array(postsById.keys)
            loadedPostIds = Set(postsById.keys)
            loadedRangeEnd = allPostIds.count

            // Re-fire isReady so the VC's withPerceptionTracking re-runs and
            // picks up the new posts even if nothing else observably changed.
            if isReady { isReady = false }
            isReady = true
            return added
        } catch {
            debugLog("[TopicDetail] Load more nested roots failed: \(error)")
            loadMoreFailed = true
            lastLoadError = error
            return []
        }
    }

    /// Recursively collect every post ID in a subtree — used to drive partial
    /// snapshot diff for the "load more roots" path.
    private func collectIds(in post: DiscourseTopicDetail.Post, into out: inout [Int]) {
        out.append(post.id)
        for child in post.children ?? [] {
            collectIds(in: child, into: &out)
        }
    }

    /// Expand the direct replies under `parentId` that the nested view didn't
    /// inline. Fetches the next children page via `/n/.../children/{n}.json`,
    /// merges the returned subtrees into the in-memory tree, and re-fires
    /// `isReady` so the view-controller rebuilds its snapshot — at which point
    /// the "view more" row either disappears (all loaded) or re-anchors after
    /// the newly added replies. Returns the IDs of any newly ingested posts.
    @discardableResult
    func loadMoreChildren(forParentId parentId: Int) async -> [Int] {
        guard isTreeMode, nestedTreeRoots != nil,
              !loadingChildrenParentIds.contains(parentId),
              let parent = postsById[parentId],
              let topicId = topic?.id ?? lastLoadedTopicId
        else { return [] }

        errorMessage = nil
        lastLoadError = nil
        loadingChildrenParentIds.insert(parentId)
        defer { loadingChildrenParentIds.remove(parentId) }

        let nextPage = loadedChildPages[parentId].map { $0 + 1 } ?? 0
        let capturedGeneration = loadGeneration

        do {
            let response = try await api.fetchNestedChildren(
                topicId: topicId,
                postNumber: parent.postNumber,
                slug: nil,
                sort: treeSort,
                page: nextPage
            )
            // Bail if the window was reset under us (jumpToFloor, mode flip).
            guard loadGeneration == capturedGeneration else { return [] }

            var added: [Int] = []
            var postsToParse: [DiscourseTopicDetail.Post] = []
            for child in response.children {
                ingestNested(child, collected: &postsToParse)
                collectIds(in: child, into: &added)
            }
            await parseAndStore(posts: postsToParse)

            var roots = nestedTreeRoots ?? []
            // Page 0 is the authoritative first page (it re-includes the
            // inlined preview), so it replaces the node's children; later
            // pages append beyond what's already shown.
            if mergeChildren(response.children, intoParentId: parentId, replace: nextPage == 0, in: &roots) {
                nestedTreeRoots = roots
            }
            loadedChildPages[parentId] = response.page

            // Keep the id-indexed bookkeeping and synthesized topic in sync.
            if var existing = topic {
                existing.postStream = DiscourseTopicDetail.PostStream(
                    posts: Array(postsById.values),
                    stream: nil
                )
                topic = existing
            }
            allPostIds = Array(postsById.keys)
            loadedPostIds = Set(postsById.keys)
            loadedRangeEnd = allPostIds.count

            if isReady { isReady = false }
            isReady = true
            return added
        } catch {
            debugLog("[TopicDetail] Load more children failed: \(error)")
            lastLoadError = error
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Find `parentId` in the nested tree and set/extend its `children` with
    /// `newChildren`, de-duplicating by post id. Returns true once spliced in.
    private func mergeChildren(
        _ newChildren: [DiscourseTopicDetail.Post],
        intoParentId parentId: Int,
        replace: Bool,
        in nodes: inout [DiscourseTopicDetail.Post]
    ) -> Bool {
        for i in nodes.indices {
            if nodes[i].id == parentId {
                let base = replace ? [] : (nodes[i].children ?? [])
                var seen = Set(base.map(\.id))
                var merged = base
                for child in newChildren where seen.insert(child.id).inserted {
                    merged.append(child)
                }
                nodes[i].children = merged
                return true
            }
            if var kids = nodes[i].children,
               mergeChildren(newChildren, intoParentId: parentId, replace: replace, in: &kids)
            {
                nodes[i].children = kids
                return true
            }
        }
        return false
    }

    /// Load the topic via Discourse's nested-replies endpoint. Replaces the
    /// flat post stream with the server-supplied tree, so opening a tree-mode
    /// topic doesn't suffer the "child paginated out of window" problem the
    /// flat path has.
    func loadNestedTopic(id: Int, sort: String? = nil, containerWidth: CGFloat? = nil) async {
        let effectiveSort = sort ?? treeSort
        let existingTopic = topic?.id == id ? topic : nil
        isLoading = true
        isReady = false
        errorMessage = nil
        lastLoadError = nil
        loadMoreFailed = false
        parsedBlocks = [:]
        renderDocuments = [:]
        postsById = [:]
        let isNewTopic = lastLoadedTopicId != id
        lastLoadedTopicId = id
        loadGeneration &+= 1
        let expectedGeneration = loadGeneration
        if isNewTopic {
            firstPost = nil
        }
        // Wipe any state from a previous flat load — we're switching modes.
        nestedTreeOpPost = nil
        nestedTreeRoots = nil
        nestedHasMoreRoots = false
        nestedRootsPage = 0
        pendingChildLoads = [:]
        loadingChildrenParentIds = []
        loadedChildPages = [:]

        // The router accepts a nil slug and substitutes `-`, which Discourse
        // routes the same way as the real slug. No slug lookup needed.
        do {
            let response = try await api.fetchNestedTopic(id: id, slug: nil, sort: effectiveSort)
            guard loadGeneration == expectedGeneration else { return }
            // Some archetypes (notably private messages) bypass the nested
            // view and return the standard flat post-stream off `/n/...`.
            // Pivot into flat rendering instead of failing the load.
            if let flat = response.flatTopic {
                await ingestFlatTopic(
                    flat,
                    containerWidth: containerWidth ?? 0,
                    expectedGeneration: expectedGeneration
                )
                guard loadGeneration == expectedGeneration else { return }
                isLoading = false
                return
            }
            // First-page response carries the topic metadata and OP; bail if
            // somehow we got a paginated payload here (shouldn't, but be safe).
            guard let opPost = response.opPost, let topicMeta = response.topic else {
                throw DiscourseAPIError(messages: ["Nested topic response missing OP"], errorType: "decode_error")
            }
            nestedTreeOpPost = opPost
            nestedTreeRoots = response.roots
            nestedHasMoreRoots = response.hasMoreRoots
            nestedRootsPage = response.page

            // Cache OP for opUsername resolution.
            firstPost = opPost

            // Walk the tree and stuff every node into `postsById` + parsed
            // blocks so cell render paths key by ID just like flat mode.
            var postsToParse: [DiscourseTopicDetail.Post] = []
            ingestNested(opPost, collected: &postsToParse)
            for root in response.roots {
                ingestNested(root, collected: &postsToParse)
            }
            await parseAndStore(posts: postsToParse, expectedGeneration: expectedGeneration)
            guard loadGeneration == expectedGeneration else { return }

            let derivedAcceptedAnswers = postsToParse
                .filter(\.acceptedAnswer)
                .sorted { $0.postNumber < $1.postNumber }
                .map { DiscourseTopicDetail.AcceptedAnswer(post: $0) }
            let acceptedAnswers =
                response.acceptedAnswers
                ?? topicMeta.acceptedAnswers
                ?? existingTopic?.acceptedAnswers
                ?? derivedAcceptedAnswers
            let hasAcceptedAnswer =
                response.hasAcceptedAnswer
                ?? topicMeta.hasAcceptedAnswer
                ?? existingTopic?.hasAcceptedAnswer
                ?? !acceptedAnswers.isEmpty

            // Synthesize a topic object so consumers that read tags / titles
            // off `viewModel.topic` keep working. `validReactions` isn't on
            // this endpoint — leave it empty in tree mode for now; reactions
            // still work, the list just lacks the picker hint.
            let synthetic = DiscourseTopicDetail(
                id: topicMeta.id,
                title: topicMeta.title,
                fancyTitle: topicMeta.fancyTitle,
                postsCount: topicMeta.postsCount,
                replyCount: topicMeta.replyCount,
                categoryId: topicMeta.categoryId,
                createdAt: topicMeta.createdAt ?? "",
                tags: topicMeta.tags,
                postStream: DiscourseTopicDetail.PostStream(
                    posts: Array(postsById.values),
                    stream: nil
                ),
                validReactions: existingTopic?.validReactions ?? [],
                acceptedAnswers: acceptedAnswers,
                hasAcceptedAnswer: hasAcceptedAnswer,
                lastReadPostNumber: nil,
                archetype: topicMeta.archetype,
                originalPosterUsername: opPost.username
            )
            topic = synthetic
            recordLocalReadIfNeeded(synthetic)

            // Treat the nested response as "the whole window" — no flat-mode
            // pagination state applies.
            allPostIds = Array(postsById.keys)
            loadedPostIds = Set(postsById.keys)
            loadedRangeStart = 0
            loadedRangeEnd = allPostIds.count

            if isReady { isReady = false }
            isReady = true
        } catch {
            guard loadGeneration == expectedGeneration else { return }
            debugLog("[TopicDetail] Nested load failed: \(error)")
            errorMessage = error.localizedDescription
            lastLoadError = error
        }

        guard loadGeneration == expectedGeneration else { return }
        isLoading = false
    }

    var canLoadMore: Bool {
        !allPostIds.isEmpty && loadedRangeEnd < allPostIds.count
    }

    var canLoadEarlier: Bool {
        loadedRangeStart > 0
    }

    var totalFloors: Int {
        allPostIds.count
    }

    /// Check if a floor (1-based) is already loaded
    func isFloorLoaded(_ floor: Int) -> Bool {
        let index = floor - 1
        guard index >= 0, index < allPostIds.count else { return false }
        return loadedPostIds.contains(allPostIds[index])
    }

    /// Find the index in `posts` array for a given floor (1-based)
    func postIndexForFloor(_ floor: Int) -> Int? {
        let index = floor - 1
        guard index >= 0, index < allPostIds.count else { return nil }
        let targetId = allPostIds[index]
        return posts.firstIndex(where: { $0.id == targetId })
    }

    /// Find the row index in `visiblePosts` for a given floor (1-based index
    /// into `allPostIds`). We match by post ID rather than `postNumber` because
    /// the two can diverge — gaps from deletions, action-only posts, or any
    /// stream reordering — and the fast-path scroll only works if it finds the
    /// exact post that lives at `allPostIds[floor - 1]`.
    func visibleRowForFloor(_ floor: Int) -> Int? {
        // Tree mode uses DFS order, not the canonical stream order — and
        // `allPostIds` is a hash-keys array there, so `allPostIds[floor-1]`
        // would address the wrong post entirely. Walk visiblePosts by
        // postNumber instead.
        if isTreeMode {
            return visiblePosts.firstIndex(where: { $0.postNumber == floor })
        }
        let index = floor - 1
        guard index >= 0, index < allPostIds.count else { return nil }
        let targetId = allPostIds[index]
        return visiblePosts.firstIndex(where: { $0.id == targetId })
    }

    /// After a reply lands, walk the server-supplied tree to find the new
    /// post and uncollapse every ancestor on its path. Otherwise a reply made
    /// inside a collapsed subtree would be invisible after the refresh — the
    /// post exists in `postsById` but `visiblePosts` filters it out.
    func expandAncestors(ofPostNumber postNumber: Int) {
        guard let roots = nestedTreeRoots else { return }
        var ancestors: [Int] = []
        _ = findAncestorPostIds(in: roots, targetPostNumber: postNumber, ancestors: &ancestors)
        for id in ancestors { collapsedPostIds.remove(id) }
    }

    private func findAncestorPostIds(
        in nodes: [DiscourseTopicDetail.Post],
        targetPostNumber: Int,
        ancestors: inout [Int]
    ) -> Bool {
        for node in nodes {
            if node.postNumber == targetPostNumber { return true }
            if let kids = node.children {
                ancestors.append(node.id)
                if findAncestorPostIds(in: kids, targetPostNumber: targetPostNumber, ancestors: &ancestors) {
                    return true
                }
                ancestors.removeLast()
            }
        }
        return false
    }

    /// Splice a freshly-created reply into the in-memory nested tree so it shows
    /// up immediately, without refetching the whole `/n/...` payload. `parentId`
    /// is the id of the post that was replied to — `nil` (or the OP's id) makes
    /// it a new top-level reply. Returns false when there's no server tree to
    /// splice into, so the caller can fall back to a full reload.
    ///
    /// Inserting locally (vs. reloading) also guarantees the reply is visible
    /// even when the server's nested view hasn't caught up to it yet or would
    /// have paginated it out of the current root window.
    @discardableResult
    func insertReplyIntoTree(_ post: DiscourseTopicDetail.Post, parentId: Int?) async -> Bool {
        guard isTreeMode, nestedTreeRoots != nil else { return false }

        // Leaf node — store a bare copy in the id-keyed maps, matching how
        // `ingestNested` keeps tree shape out of `postsById`.
        var leaf = post
        leaf.children = nil
        await parseAndStore(posts: [leaf])

        var roots = nestedTreeRoots ?? []
        if let parentId, parentId != nestedTreeOpPost?.id,
           appendChild(leaf, toParentId: parentId, in: &roots)
        {
            nestedTreeRoots = roots
            // Mirror the direct-reply bump onto the id-keyed copy so any reader
            // of `postsById` sees the same count as the tree node.
            if var parent = postsById[parentId] {
                parent.directReplyCount += 1
                postsById[parentId] = parent
            }
        } else {
            // Reply to the OP / topic, or a parent that isn't in the loaded
            // tree: it becomes a new root-level reply (depth 1).
            nestedTreeRoots = roots + [leaf]
        }

        // Keep the id-indexed bookkeeping and synthesized topic in sync.
        allPostIds = Array(postsById.keys)
        loadedPostIds = Set(postsById.keys)
        loadedRangeEnd = allPostIds.count
        if var existing = topic {
            existing.postStream = DiscourseTopicDetail.PostStream(
                posts: Array(postsById.values),
                stream: nil
            )
            topic = existing
        }

        // The reply's ancestors may have been collapsed when the user tapped
        // reply — uncollapse them so the new row is actually visible.
        expandAncestors(ofPostNumber: leaf.postNumber)

        if isReady { isReady = false }
        isReady = true
        return true
    }

    /// Recursively find `parentId` in the nested tree and append `child` to its
    /// `children`. Returns true once spliced in.
    private func appendChild(
        _ child: DiscourseTopicDetail.Post,
        toParentId parentId: Int,
        in nodes: inout [DiscourseTopicDetail.Post]
    ) -> Bool {
        for i in nodes.indices {
            if nodes[i].id == parentId {
                nodes[i].children = (nodes[i].children ?? []) + [child]
                // Bump the server-side direct-reply count too, so the "view N
                // more replies" affordance keeps counting only the *unloaded*
                // replies — without this the locally-inserted child would
                // cannibalise the remaining count (`directReplyCount - loaded`).
                nodes[i].directReplyCount += 1
                return true
            }
            if var kids = nodes[i].children,
               appendChild(child, toParentId: parentId, in: &kids)
            {
                nodes[i].children = kids
                return true
            }
        }
        return false
    }

    /// Loads the topic. When `nearPostNumber > 1` is supplied, the initial batch
    /// returned by Discourse is centered on that floor — saving a second round-trip
    /// for deep-link entries (notification tap, reply link, direct URL).
    /// The caller is responsible for scrolling to `nearPostNumber` after the
    /// returned posts settle.
    func loadTopic(id: Int, containerWidth: CGFloat, nearPostNumber: Int? = nil) async {
        isLoading = true
        isReady = false
        errorMessage = nil
        lastLoadError = nil
        loadMoreFailed = false
        parsedBlocks = [:]
        renderDocuments = [:]
        postsById = [:]
        let isNewTopic = lastLoadedTopicId != id
        lastLoadedTopicId = id
        loadGeneration &+= 1
        let expectedGeneration = loadGeneration
        // Different topic = different OP; drop any cached value so we don't
        // carry the previous topic's OP into this one. Same-topic reloads
        // (summary toggle, post-reply refresh) leave it alone — preserved
        // below if the new batch doesn't itself contain post 1.
        if isNewTopic {
            firstPost = nil
        }
        let filter = isSummaryMode ? "summary" : nil
        do {
            let response = try await api.fetchTopic(id: id, nearPostNumber: nearPostNumber, filter: filter)
            guard loadGeneration == expectedGeneration else { return }
            let detail = topicWithSynchronizedSolutionState(response)
            topic = detail
            recordLocalReadIfNeeded(detail)

            // Save the full stream of post IDs
            allPostIds = detail.postStream.stream ?? detail.postStream.posts.map(\.id)
            loadedPostIds = Set(detail.postStream.posts.map(\.id))

            // Keep the complete OP when post 1 is present; deep-link payloads
            // use `detail.originalPosterUsername` for author identification.
            if let loadedOriginalPoster = detail.postStream.posts.first(where: { $0.postNumber == 1 }) {
                firstPost = loadedOriginalPoster
            }

            // Range tracking — derive from the first/last posts actually returned
            // rather than assuming start = 0. `near_post_number` can return a range
            // that starts mid-stream.
            if let firstLoadedId = detail.postStream.posts.first?.id,
               let firstIndex = allPostIds.firstIndex(of: firstLoadedId) {
                loadedRangeStart = firstIndex
            } else {
                loadedRangeStart = 0
            }
            if let lastLoadedId = detail.postStream.posts.last?.id,
               let lastIndex = allPostIds.firstIndex(of: lastLoadedId) {
                loadedRangeEnd = lastIndex + 1
            } else {
                loadedRangeEnd = detail.postStream.posts.count
            }

            let postsToRender = detail.postStream.posts
            guard !postsToRender.isEmpty else {
                isReady = true
                isLoading = false
                return
            }

            // Parse all posts with annotated blocks
            await parseAndStore(posts: postsToRender, expectedGeneration: expectedGeneration)
            guard loadGeneration == expectedGeneration else { return }

            // Force updateUI to re-run even if isReady was already true.
            // Upstream mutations (topic, parsedBlocks, etc.) only fire the first
            // tracked change per observation cycle; re-assigning isReady guarantees
            // a final fire after all state is settled.
            if isReady {
                isReady = false
            }
            isReady = true
        } catch {
            guard loadGeneration == expectedGeneration else { return }
            debugLog("[TopicDetail] Load failed: \(error)")
            errorMessage = error.localizedDescription
            lastLoadError = error
        }

        guard loadGeneration == expectedGeneration else { return }
        isLoading = false
    }

    /// Flip "by heat" mode and re-fetch the topic with `filter=summary`.
    /// Re-fetch is required because summary view is server-filtered, not a
    /// client-side reorder. Caller is responsible for invalidating its caches.
    func toggleSummaryMode(containerWidth: CGFloat) async {
        guard let topicId = lastLoadedTopicId ?? topic?.id else { return }
        isSummaryMode.toggle()
        await loadTopic(id: topicId, containerWidth: containerWidth)
    }

    /// Switch into reverse-order view. Clears the currently loaded posts,
    /// re-fetches OP + the last batch (so the bottom of the canonical stream
    /// becomes the top of the reversed list, with OP pinned above it). The
    /// user then scrolls down to load progressively older posts via the
    /// existing `loadEarlierPosts` path (the controller swaps the pagination
    /// trigger direction while reverse is on).
    func enableReverseOrder(containerWidth: CGFloat) async {
        guard !allPostIds.isEmpty, let topicId = topic?.id else {
            isReverseOrder = true
            return
        }

        let lastBatchSize = 20
        let lastBatchStart = max(allPostIds.count - lastBatchSize, 0)
        let lastBatchIds = Array(allPostIds[lastBatchStart..<allPostIds.count])
        var batchIds: [Int] = []
        if let opId = allPostIds.first {
            batchIds.append(opId)
        }
        for id in lastBatchIds where !batchIds.contains(id) {
            batchIds.append(id)
        }

        isReverseOrder = true
        loadGeneration &+= 1
        topic?.postStream.posts.removeAll()
        parsedBlocks.removeAll()
        renderDocuments.removeAll()
        postsById.removeAll()
        loadedPostIds.removeAll()

        do {
            let response = try await api.fetchTopicPosts(topicId: topicId, postIds: batchIds)
            let idOrder = Dictionary(uniqueKeysWithValues: allPostIds.enumerated().map { ($1, $0) })
            let sortedPosts = response.postStream.posts.sorted { (idOrder[$0.id] ?? 0) < (idOrder[$1.id] ?? 0) }

            topic?.postStream.posts = sortedPosts
            for post in sortedPosts { loadedPostIds.insert(post.id) }
            await parseAndStore(posts: sortedPosts)
            if let op = sortedPosts.first(where: { $0.postNumber == 1 }) {
                firstPost = op
            }
            // Range tracks the canonical window we've loaded — the last batch.
            // OP being separately included doesn't extend it; loadEarlierPosts
            // will pull in the gap toward post 1 as the user scrolls.
            loadedRangeStart = lastBatchStart
            loadedRangeEnd = allPostIds.count
        } catch {
            errorMessage = error.localizedDescription
        }

        if isReady { isReady = false }
        isReady = true
    }

    func disableReverseOrder() {
        isReverseOrder = false
    }

    /// Appends the next batch of posts at the end of the loaded window.
    /// Returns the IDs of newly inserted posts (empty if no-op / failure /
    /// stale-window discard). The caller can use the returned IDs to drive
    /// height pre-computation and partial snapshot updates.
    @discardableResult
    func loadMorePosts(containerWidth: CGFloat) async -> [Int] {
        guard !isLoadingMore, canLoadMore, let topicId = topic?.id else { return [] }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let capturedGeneration = loadGeneration
        let newEnd = min(loadedRangeEnd + 20, allPostIds.count)
        let batch = Array(allPostIds[loadedRangeEnd..<newEnd])
        guard !batch.isEmpty else { return [] }

        let response: DiscourseTopicPostsResponse
        do {
            response = try await api.fetchTopicPosts(topicId: topicId, postIds: batch)
        } catch {
            loadMoreFailed = true
            lastLoadError = error
            return []
        }

        // Window reset while in flight — discard rather than splice old posts
        // into a fresh window.
        guard loadGeneration == capturedGeneration else { return [] }

        let newPosts = response.postStream.posts.filter { !loadedPostIds.contains($0.id) }
        guard !newPosts.isEmpty else {
            for id in batch { loadedPostIds.insert(id) }
            loadedRangeEnd = newEnd
            return []
        }

        let idOrder = Dictionary(uniqueKeysWithValues: allPostIds.enumerated().map { ($1, $0) })
        let sortedPosts = newPosts.sorted { (idOrder[$0.id] ?? 0) < (idOrder[$1.id] ?? 0) }
        topic?.postStream.posts.append(contentsOf: sortedPosts)
        for post in sortedPosts { loadedPostIds.insert(post.id) }
        await parseAndStore(posts: sortedPosts)
        loadedRangeEnd = newEnd
        return sortedPosts.map(\.id)
    }

    /// Prepends the previous batch of posts at the front of the loaded window.
    /// Returns the IDs of newly inserted posts (in stream order) — the VC uses
    /// these to pre-compute heights synchronously before applying the snapshot,
    /// keeping the user's reading position visually anchored.
    @discardableResult
    func loadEarlierPosts(containerWidth: CGFloat) async -> [Int] {
        guard canLoadEarlier, !isLoadingEarlier, let topicId = topic?.id else { return [] }
        errorMessage = nil
        lastLoadError = nil
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }

        let capturedGeneration = loadGeneration
        let newStart = max(0, loadedRangeStart - 20)
        let batch = Array(allPostIds[newStart..<loadedRangeStart])
        guard !batch.isEmpty else { return [] }

        let response: DiscourseTopicPostsResponse
        do {
            response = try await api.fetchTopicPosts(topicId: topicId, postIds: batch)
        } catch {
            lastLoadError = error
            errorMessage = error.localizedDescription
            return []
        }

        guard loadGeneration == capturedGeneration else { return [] }

        let newPosts = response.postStream.posts.filter { !loadedPostIds.contains($0.id) }
        guard !newPosts.isEmpty else {
            for id in batch { loadedPostIds.insert(id) }
            loadedRangeStart = newStart
            return []
        }

        let idOrder = Dictionary(uniqueKeysWithValues: allPostIds.enumerated().map { ($1, $0) })
        let sortedPosts = newPosts.sorted { (idOrder[$0.id] ?? 0) < (idOrder[$1.id] ?? 0) }

        // In reverse-order mode the OP sits pinned at index 0; everything else
        // gets inserted after it. In canonical mode posts are prepended at 0.
        let insertIndex: Int
        if let fp = firstPost, posts.first?.id == fp.id {
            insertIndex = 1
        } else {
            insertIndex = 0
        }
        topic?.postStream.posts.insert(contentsOf: sortedPosts, at: insertIndex)
        for post in sortedPosts { loadedPostIds.insert(post.id) }
        await parseAndStore(posts: sortedPosts)
        loadedRangeStart = newStart
        return sortedPosts.map(\.id)
    }

    /// Replaces the loaded window with a fresh batch starting at `floor`.
    /// The caller is responsible for scrolling to the target floor once this
    /// returns (or showing/hiding any loading overlay). Returns `true` on
    /// success, `false` if the API call failed.
    @discardableResult
    func jumpToFloor(_ floor: Int, containerWidth: CGFloat) async -> Bool {
        guard !allPostIds.isEmpty, let topicId = topic?.id else { return false }

        let targetIndex = max(0, min(floor - 1, allPostIds.count - 1))
        let endIndex = min(targetIndex + 20, allPostIds.count)
        let batch = Array(allPostIds[targetIndex..<endIndex])
        guard !batch.isEmpty else { return false }

        loadGeneration &+= 1

        // Clear current posts. `isReady` stays `true` through the gap — the VC
        // suppresses snapshot application during a jump via its own
        // PaginationContext, so the brief "empty visiblePosts" state never
        // reaches the table view.
        topic?.postStream.posts.removeAll()
        parsedBlocks.removeAll()
        renderDocuments.removeAll()
        postsById.removeAll()
        loadedPostIds.removeAll()
        // Intentionally keep `firstPost`: the OP doesn't change when jumping
        // within the same topic, and the new batch typically won't contain
        // post 1, so clearing here would make `opUsername` fall back to
        // whoever lands at the top of the centered window — wrongly marking
        // that user's posts as OP after a search/notification entry.

        do {
            let response = try await api.fetchTopicPosts(topicId: topicId, postIds: batch)
            let idOrder = Dictionary(uniqueKeysWithValues: allPostIds.enumerated().map { ($1, $0) })
            let sortedPosts = response.postStream.posts.sorted { (idOrder[$0.id] ?? 0) < (idOrder[$1.id] ?? 0) }
            topic?.postStream.posts = sortedPosts
            for post in sortedPosts { loadedPostIds.insert(post.id) }
            await parseAndStore(posts: sortedPosts)
            // If the jump landed on the very first batch, refresh the cache
            // from the freshly-loaded post 1.
            if let op = sortedPosts.first, op.postNumber == 1 {
                firstPost = op
            }
            loadedRangeStart = targetIndex
            loadedRangeEnd = endIndex
        } catch {
            debugLog("[TopicDetail] Jump failed: \(error)")
            errorMessage = error.localizedDescription
            return false
        }

        // Toggle `isReady` so the VC's updateUI re-fires for any non-jump
        // observers (e.g. title bar) — the actual snapshot apply is driven by
        // the VC's pagination flow after this `await` returns.
        if isReady { isReady = false }
        isReady = true
        return true
    }

    func appendBoost(_ boost: DiscourseTopicDetail.Boost, toPostId postId: Int) {
        guard var topic else { return }
        guard let index = topic.postStream.posts.firstIndex(where: { $0.id == postId }) else { return }
        if !topic.postStream.posts[index].boosts.contains(where: { $0.id == boost.id }) {
            topic.postStream.posts[index].boosts.append(boost)
        }
        topic.postStream.posts[index].canBoost = false
        expandedBoostPostIds.insert(postId)
        self.topic = topic
        postsById[postId] = topic.postStream.posts[index]
    }

    func toggleBoosts(forPostId postId: Int) {
        if expandedBoostPostIds.contains(postId) {
            expandedBoostPostIds.remove(postId)
        } else {
            expandedBoostPostIds.insert(postId)
        }
    }

    func removeBoost(boostId: Int, fromPostId postId: Int) {
        guard var topic else { return }
        guard let index = topic.postStream.posts.firstIndex(where: { $0.id == postId }) else { return }
        topic.postStream.posts[index].boosts.removeAll { $0.id == boostId }
        topic.postStream.posts[index].canBoost = true
        if topic.postStream.posts[index].boosts.isEmpty {
            expandedBoostPostIds.remove(postId)
        }
        self.topic = topic
        postsById[postId] = topic.postStream.posts[index]
    }

    /// Replace a post with a freshly-fetched copy (e.g. after a like/reaction toggle).
    /// Skips re-parsing blocks when `cooked` is unchanged so the VC's content view
    /// cache stays valid. Plugin-only fields that the bare `/posts/{id}.json`
    /// endpoint doesn't return (boosts, polls votes) are carried over from the
    /// existing post so the UI doesn't lose state.
    func replacePost(_ updated: DiscourseTopicDetail.Post) async {
        guard var topic else { return }
        guard let index = topic.postStream.posts.firstIndex(where: { $0.id == updated.id }) else { return }
        let existing = topic.postStream.posts[index]
        let cookedChanged = existing.cooked != updated.cooked

        var merged = updated
        // /posts/{id}.json strips discourse-boosts plugin data — preserve it
        // so the boost button (and any expanded boost list) stays intact.
        merged.boosts = existing.boosts
        merged.canBoost = existing.canBoost
        // Polls and the user's vote selections aren't included either; without
        // this, results would reset visually until the next full topic load.
        merged.polls = existing.polls
        merged.pollsVotes = existing.pollsVotes

        topic.postStream.posts[index] = merged
        self.topic = topic
        postsById[merged.id] = merged
        if cookedChanged {
            await parseAndStore(posts: [merged])
        }
    }

    /// Applies the canonical accepted-answer list returned by Discourse to
    /// every in-memory representation of a post. Tree mode keeps both a nested
    /// graph and id-keyed bare copies, so updating only `topic.postStream`
    /// would leave visible cells stale.
    func applySolutionMutation(
        postId: Int,
        accepting: Bool,
        acceptedAnswers serverAnswers: [DiscourseTopicDetail.AcceptedAnswer]?
    ) {
        guard var topic else { return }
        let target =
            postsById[postId]
            ?? topic.postStream.posts.first(where: { $0.id == postId })

        let acceptedAnswers: [DiscourseTopicDetail.AcceptedAnswer]
        if let serverAnswers {
            acceptedAnswers = serverAnswers
        } else if accepting, let target {
            // Pre-multi-solution plugin versions return only `{success:"OK"}`.
            acceptedAnswers = [DiscourseTopicDetail.AcceptedAnswer(post: target)]
        } else {
            acceptedAnswers = topic.acceptedAnswers.filter {
                $0.id != postId && $0.postNumber != target?.postNumber
            }
        }

        let acceptedPostNumbers = Set(acceptedAnswers.map(\.postNumber))
        let topicHasAcceptedAnswer = !acceptedPostNumbers.isEmpty

        topic.acceptedAnswers = acceptedAnswers
        topic.hasAcceptedAnswer = topicHasAcceptedAnswer
        for index in topic.postStream.posts.indices {
            applySolutionState(
                to: &topic.postStream.posts[index],
                acceptedPostNumbers: acceptedPostNumbers,
                topicHasAcceptedAnswer: topicHasAcceptedAnswer
            )
        }
        self.topic = topic

        for id in Array(postsById.keys) {
            guard var post = postsById[id] else { continue }
            applySolutionState(
                to: &post,
                acceptedPostNumbers: acceptedPostNumbers,
                topicHasAcceptedAnswer: topicHasAcceptedAnswer
            )
            postsById[id] = post
        }

        if var opPost = nestedTreeOpPost {
            applySolutionState(
                to: &opPost,
                acceptedPostNumbers: acceptedPostNumbers,
                topicHasAcceptedAnswer: topicHasAcceptedAnswer
            )
            nestedTreeOpPost = opPost
        }
        if var roots = nestedTreeRoots {
            for index in roots.indices {
                applySolutionState(
                    to: &roots[index],
                    acceptedPostNumbers: acceptedPostNumbers,
                    topicHasAcceptedAnswer: topicHasAcceptedAnswer
                )
            }
            nestedTreeRoots = roots
        }
        if var cachedFirstPost = firstPost {
            applySolutionState(
                to: &cachedFirstPost,
                acceptedPostNumbers: acceptedPostNumbers,
                topicHasAcceptedAnswer: topicHasAcceptedAnswer
            )
            firstPost = cachedFirstPost
        }
    }

    private func applySolutionState(
        to post: inout DiscourseTopicDetail.Post,
        acceptedPostNumbers: Set<Int>,
        topicHasAcceptedAnswer: Bool
    ) {
        post.acceptedAnswer = acceptedPostNumbers.contains(post.postNumber)
        post.topicAcceptedAnswer = topicHasAcceptedAnswer
        guard var children = post.children else { return }
        for index in children.indices {
            applySolutionState(
                to: &children[index],
                acceptedPostNumbers: acceptedPostNumbers,
                topicHasAcceptedAnswer: topicHasAcceptedAnswer
            )
        }
        post.children = children
    }

    func updatePoll(_ updatedPoll: DiscourseTopicDetail.Poll, votes: [String], forPostId postId: Int, pollName: String) async {
        guard var topic else { return }
        guard let postIndex = topic.postStream.posts.firstIndex(where: { $0.id == postId }) else { return }
        if let pollIndex = topic.postStream.posts[postIndex].polls.firstIndex(where: { $0.name == pollName }) {
            topic.postStream.posts[postIndex].polls[pollIndex] = updatedPoll
        }
        topic.postStream.posts[postIndex].pollsVotes[pollName] = votes
        self.topic = topic
        // Re-parse to trigger UI update
        await parseAndStore(posts: [topic.postStream.posts[postIndex]])
    }

    // MARK: - Private

    private func parseAndStore(posts: [DiscourseTopicDetail.Post], expectedGeneration: UInt? = nil) async {
        guard !posts.isEmpty else { return }
        let inputs = posts.map { PostRenderInput(postId: $0.id, cookedHTML: $0.cooked) }
        let documents = await TopicRenderPipeline.shared.renderDocuments(inputs: inputs, baseURL: api.baseURL)
        if let expectedGeneration, loadGeneration != expectedGeneration { return }
        for post in posts {
            guard let document = documents[post.id] else { continue }
            parsedBlocks[post.id] = document.annotatedBlocks
            renderDocuments[post.id] = document
            postsById[post.id] = post
        }
    }
}
