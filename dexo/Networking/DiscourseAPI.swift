import Alamofire
import Foundation

struct TopicTimingResponseAssessment: Equatable {
    let outcome: TopicTimingOutcome
    let statusCode: Int?
    let errorSummary: String?
}

struct TopicTimingCircuitBreaker {
    static let maximumFailures = 3

    private(set) var failureCount = 0
    var isTripped: Bool { failureCount >= Self.maximumFailures }

    mutating func record(_ outcome: TopicTimingOutcome) -> Bool {
        if outcome == .success {
            failureCount = 0
        } else {
            failureCount += 1
        }
        return isTripped
    }

    mutating func reset() {
        failureCount = 0
    }
}

enum DiscourseEditRequestBuilder {
    static func post(raw: String, originalRaw: String) -> [String: Any] {
        [
            "post": [
                "raw": raw,
                "original_text": originalRaw,
            ],
        ]
    }

    static func topic(
        title: String,
        originalTitle: String,
        categoryId: Int?,
        tags: [DiscourseEditableTag],
        originalTags: [DiscourseTopicDetail.Tag]
    ) -> [String: Any] {
        let tagParameters: [[String: Any]] = tags.map { tag in
            var value: [String: Any] = ["name": tag.name]
            if let id = tag.id { value["id"] = id }
            return value
        }
        let originalTagParameters: [[String: Any]] = originalTags.map {
            ["id": $0.id, "name": $0.name]
        }
        return [
            "title": title,
            "original_title": originalTitle,
            "category_id": categoryId ?? 0,
            "tags": tagParameters,
            "original_tags": originalTagParameters,
        ]
    }
}

func assessTopicTimingResponse(
    statusCode: Int?,
    data: Data?,
    errorDescription: String?
) -> TopicTimingResponseAssessment {
    if isCloudflareChallengeResponse(data) {
        return TopicTimingResponseAssessment(
            outcome: .cloudflareChallenge,
            statusCode: statusCode,
            errorSummary: "Cloudflare challenge required"
        )
    }
    if let statusCode, (200 ..< 300).contains(statusCode) {
        return TopicTimingResponseAssessment(
            outcome: .success,
            statusCode: statusCode,
            errorSummary: nil
        )
    }
    let summary: String
    if let errorDescription {
        summary = String(
            errorDescription
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .prefix(300)
        )
    } else if let statusCode {
        summary = "HTTP \(statusCode)"
    } else {
        summary = "Network request failed"
    }
    return TopicTimingResponseAssessment(
        outcome: .failure,
        statusCode: statusCode,
        errorSummary: summary
    )
}

/// Normalizes both shapes returned by Discourse's category list endpoint:
/// nested `subcategory_list` responses and lazy-load responses where roots and
/// a small child preview are mixed in one flat array. Root order always follows
/// the server's paginated order.
struct CategoryPageAccumulator {
    private var categoriesByID: [Int: DiscourseCategory] = [:]
    private var rootCategoryIDs: [Int] = []
    private var seenRootCategoryIDs = Set<Int>()
    private var childCategoryIDsByParent: [Int: [Int]] = [:]
    private var expectedChildCategoryIDsByParent: [Int: Set<Int>] = [:]
    private var categoryDiscoveryOrder: [Int] = []
    private var startedChildFetches = Set<Int>()
    private var completedChildFetches = Set<Int>()

    var categories: [DiscourseCategory] {
        rootCategoryIDs.compactMap { materializeCategory(id: $0, ancestors: []) }
    }

    /// Appends one top-level `/categories.json?page=N` response. The return
    /// value follows the public contract: continue while the page contributes
    /// any previously unseen category ID, whether root or lazy child preview.
    mutating func append(_ page: [DiscourseCategory]) -> Bool {
        let previousCategoryCount = categoriesByID.count
        for category in page {
            register(category)
        }

        for category in page where category.parentCategoryId == nil {
            guard seenRootCategoryIDs.insert(category.id).inserted else { continue }
            rootCategoryIDs.append(category.id)
        }
        return categoriesByID.count > previousCategoryCount
    }

    /// Appends a page requested with `parent_category_id`. Only direct
    /// children are accepted, which also makes a misbehaving server that
    /// ignores this parameter terminate safely.
    mutating func appendChildren(_ page: [DiscourseCategory], parentCategoryID: Int) -> Bool {
        let directChildren = page.filter { $0.parentCategoryId == parentCategoryID }
        guard !directChildren.isEmpty else { return false }

        // The root response's child preview is not guaranteed to use the same
        // order as the parent-scoped list. On its first page, replace that
        // preview order, then append subsequent pages in server order.
        if startedChildFetches.insert(parentCategoryID).inserted {
            childCategoryIDsByParent[parentCategoryID] = []
        }
        let previousIDs = Set(childCategoryIDsByParent[parentCategoryID] ?? [])
        for category in directChildren {
            register(category)
        }
        return Set(childCategoryIDsByParent[parentCategoryID] ?? []) != previousIDs
    }

    /// The next category whose `subcategory_ids` promises children that have
    /// not yet arrived as objects. Newly fetched children can themselves add
    /// work here, so this also covers installations allowing deeper nesting.
    var nextParentCategoryIDNeedingFetch: Int? {
        categoryDiscoveryOrder.first { categoryID in
            guard !completedChildFetches.contains(categoryID),
                  let expectedIDs = expectedChildCategoryIDsByParent[categoryID],
                  !expectedIDs.isEmpty
            else { return false }

            let receivedIDs = Set(childCategoryIDsByParent[categoryID] ?? [])
            return !expectedIDs.isSubset(of: receivedIDs)
        }
    }

    func hasAllExpectedChildren(for parentCategoryID: Int) -> Bool {
        guard let expectedIDs = expectedChildCategoryIDsByParent[parentCategoryID] else {
            return true
        }
        return expectedIDs.isSubset(of: Set(childCategoryIDsByParent[parentCategoryID] ?? []))
    }

    mutating func markChildFetchCompleted(for parentCategoryID: Int) {
        completedChildFetches.insert(parentCategoryID)
    }

    private mutating func register(_ category: DiscourseCategory) {
        if categoriesByID[category.id] == nil {
            categoriesByID[category.id] = category
            categoryDiscoveryOrder.append(category.id)
        }

        if let subcategoryIDs = category.subcategoryIds {
            expectedChildCategoryIDsByParent[category.id, default: []]
                .formUnion(subcategoryIDs)
        }

        if let parentCategoryID = category.parentCategoryId {
            appendChildID(category.id, to: parentCategoryID)
        }

        for child in category.subcategoryList ?? [] {
            register(child)
            appendChildID(child.id, to: category.id)
        }
    }

    private mutating func appendChildID(_ childID: Int, to parentCategoryID: Int) {
        var childIDs = childCategoryIDsByParent[parentCategoryID, default: []]
        guard !childIDs.contains(childID) else { return }
        childIDs.append(childID)
        childCategoryIDsByParent[parentCategoryID] = childIDs
    }

    private func materializeCategory(
        id: Int,
        ancestors: Set<Int>
    ) -> DiscourseCategory? {
        guard let category = categoriesByID[id], !ancestors.contains(id) else { return nil }

        var nextAncestors = ancestors
        nextAncestors.insert(id)
        let childIDs = childCategoryIDsByParent[id] ?? []
        let children = childIDs.compactMap {
            materializeCategory(id: $0, ancestors: nextAncestors)
        }
        let hasServerChildShape = category.subcategoryIds != nil || category.subcategoryList != nil
        return category.replacingSubcategoryList(
            hasServerChildShape || !children.isEmpty ? children : nil
        )
    }
}

final class DiscourseAPI {
    typealias CategoryPageLoader = (Int) async throws -> DiscourseCategoryList
    typealias CategoryChildrenLoader = (Int, Int) async throws -> DiscourseCategoryList

    let baseURL: String
    let assetBaseURL: String
    let forumID: Int64?
    private(set) var emojiReady: Bool = false
    private let interceptor: DiscourseAuthInterceptor
    private var cachedCategoryList: DiscourseCategoryList?
    private var categoryFetchTask: Task<DiscourseCategoryList, Error>?
    private var categoryCacheGeneration = 0
    private nonisolated(unsafe) var categoryAuthChangeObserver: (any NSObjectProtocol)?
    private let categoryPageLoader: CategoryPageLoader?
    private let categoryChildrenLoader: CategoryChildrenLoader?

    private lazy var session: Session = DiscourseAPI.makeSession(
        interceptor: interceptor,
        baseURL: baseURL
    )

    init(forum: ForumInstance) {
        self.baseURL = forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.assetBaseURL = forum.assetBaseURL
        self.forumID = forum.id
        self.interceptor = DiscourseAuthInterceptor(baseURL: baseURL)
        self.categoryPageLoader = nil
        self.categoryChildrenLoader = nil
        observeAuthenticationChanges()
    }

    init(baseURL: String) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.assetBaseURL = self.baseURL
        self.forumID = nil
        self.interceptor = DiscourseAuthInterceptor(baseURL: self.baseURL)
        self.categoryPageLoader = nil
        self.categoryChildrenLoader = nil
        observeAuthenticationChanges()
    }

    /// Test seam for category pagination/cache behavior. Production callers
    /// use the normal initializers above and therefore always hit the network.
    init(
        testingBaseURL baseURL: String,
        categoryPageLoader: @escaping CategoryPageLoader,
        categoryChildrenLoader: CategoryChildrenLoader? = nil
    ) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.assetBaseURL = self.baseURL
        self.forumID = nil
        self.interceptor = DiscourseAuthInterceptor(baseURL: self.baseURL)
        self.categoryPageLoader = categoryPageLoader
        self.categoryChildrenLoader = categoryChildrenLoader
        observeAuthenticationChanges()
    }

    deinit {
        if let categoryAuthChangeObserver {
            NotificationCenter.default.removeObserver(categoryAuthChangeObserver)
        }
    }

    /// linux.do's `/session/current.json` returns an empty body, so callers must skip it
    /// and derive the username from `/notifications.json` instead.
    var isLinuxDo: Bool {
        URL(string: baseURL)?.host?.lowercased() == "linux.do"
    }

    private static func makeSession(interceptor: DiscourseAuthInterceptor, baseURL: String) -> Session {
        let config = URLSessionConfiguration.af.default
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        return Session(
            configuration: config,
            interceptor: interceptor,
            redirectHandler: ForumRedirectHandler(baseURL: baseURL)
        )
    }

    // MARK: - Public API

    func fetchTopicFeed(mode: TopicFeedMode, page: Int = 0) async throws -> DiscourseTopicList {
        try await request(route: .topicFeed(mode: mode, page: page))
    }

    func fetchReadTopics(page: Int = 0) async throws -> DiscourseTopicList {
        try await request(route: .readTopics(page: page))
    }

    func fetchCategories(page: Int) async throws -> DiscourseCategoryList {
        if let categoryPageLoader {
            return try await categoryPageLoader(page)
        }
        return try await request(route: .categories(page: page))
    }

    private func fetchChildCategories(
        parentCategoryID: Int,
        page: Int
    ) async throws -> DiscourseCategoryList {
        if let categoryChildrenLoader {
            return try await categoryChildrenLoader(parentCategoryID, page)
        }
        return try await request(
            route: .categoryChildren(parentCategoryID: parentCategoryID, page: page)
        )
    }

    /// Fetches every category page and caches the merged result for all feature
    /// screens sharing this API instance. Discourse can lazy-load root
    /// categories for authenticated users, so a single `/categories.json`
    /// response is not necessarily complete.
    func fetchAllCategories(forceRefresh: Bool = false) async throws -> DiscourseCategoryList {
        if forceRefresh {
            invalidateCategoryCache()
        }

        if let cachedCategoryList {
            return cachedCategoryList
        }
        let generation = categoryCacheGeneration
        if let categoryFetchTask {
            let result = try await categoryFetchTask.value
            guard generation == categoryCacheGeneration else {
                throw CancellationError()
            }
            return result
        }

        let task = Task { [weak self] () throws -> DiscourseCategoryList in
            guard let self else { throw CancellationError() }
            return try await self.fetchAllCategoriesFromServer()
        }
        categoryFetchTask = task

        do {
            let result = try await task.value
            guard generation == categoryCacheGeneration else {
                throw CancellationError()
            }
            cachedCategoryList = result
            categoryFetchTask = nil
            return result
        } catch {
            if generation == categoryCacheGeneration {
                categoryFetchTask = nil
            }
            throw error
        }
    }

    /// Invalidates both the cached result and any anonymous/authenticated fetch
    /// still in flight. The generation check prevents a stale request from
    /// repopulating the cache after an authentication change.
    func invalidateCategoryCache() {
        categoryCacheGeneration += 1
        cachedCategoryList = nil
        categoryFetchTask?.cancel()
        categoryFetchTask = nil
    }

    private func observeAuthenticationChanges() {
        let observedBaseURL = baseURL
        categoryAuthChangeObserver = NotificationCenter.default.addObserver(
            forName: .discourseAuthDidChange,
            object: nil,
            queue: .main
        ) { [weak self, observedBaseURL] notification in
            guard notification.userInfo?["baseURL"] as? String == observedBaseURL else {
                return
            }
            MainActor.assumeIsolated {
                self?.invalidateCategoryCache()
            }
        }
    }

    func fetchCategoryTopics(
        slug: String,
        id: Int,
        feedMode: TopicFeedMode? = nil,
        page: Int = 0
    ) async throws -> DiscourseTopicList {
        try await request(route: .categoryTopics(slug: slug, id: id, feedMode: feedMode, page: page))
    }

    func fetchTagTopics(name: String, page: Int = 0) async throws -> DiscourseTopicList {
        try await request(route: .tagTopics(name: name, page: page))
    }

    func fetchSiteInfo() async throws -> DiscourseSiteInfo {
        try await request(route: .siteInfo)
    }

    func fetchPushSiteSettings() async throws -> DiscoursePushSiteSettings {
        try await request(route: .siteSettings)
    }

    func subscribePush(endpoint: String, p256dh: String, auth: String) async throws {
        let _: EmptyDiscourseResponse = try await request(
            route: .subscribePush,
            parameters: [
                "subscription": [
                    "endpoint": endpoint,
                    "keys": ["p256dh": p256dh, "auth": auth],
                ],
                "send_confirmation": false,
            ]
        )
    }

    func unsubscribePush(endpoint: String, p256dh: String, auth: String) async throws {
        let _: EmptyDiscourseResponse = try await request(
            route: .unsubscribePush,
            parameters: [
                "subscription": [
                    "endpoint": endpoint,
                    "keys": ["p256dh": p256dh, "auth": auth],
                ],
            ]
        )
    }

    func fetchBasicInfo(includeStoredWebCookies: Bool = false) async throws -> DiscourseBasicInfo {
        let route = DiscourseRouter.basicInfo
        var headers = HTTPHeaders()

        // The add-forum probe runs before a ForumInstance or the web-auth
        // sentinel exists in Keychain. Explicitly carry the cookies captured
        // by ChallengeViewController for that first request instead of
        // relying on the authenticated-request interceptor path.
        if includeStoredWebCookies,
           let url = URL(string: baseURL + route.path)
        {
            let cookieHeader = WebCookieStore.shared.cookieHeader(for: url)
            if !cookieHeader.isEmpty {
                headers.add(name: "Cookie", value: cookieHeader)
            }
            if let userAgent = WebCookieStore.shared.userAgent {
                headers.add(name: "User-Agent", value: userAgent)
            }
        }

        return try await request(route: route, headers: headers)
    }

    func fetchNotifications(limit: Int? = nil, filter: String? = nil) async throws -> DiscourseNotificationList {
        try await request(route: .notifications(limit: limit, filter: filter))
    }

    func fetchPrivateMessages(username: String, filter: PrivateMessageFilter = .inbox) async throws -> DiscourseTopicList {
        try await request(route: .privateMessages(username: username, filter: filter))
    }

    func fetchTopic(id: Int, nearPostNumber: Int? = nil, filter: String? = nil) async throws -> DiscourseTopicDetail {
        try await request(route: .topic(id: id, nearPostNumber: nearPostNumber, filter: filter))
    }

    func fetchTopicPosts(topicId: Int, postIds: [Int]) async throws -> DiscourseTopicPostsResponse {
        try await request(route: .topicPosts(topicId: topicId, postIds: postIds))
    }

    /// Fetch a single post (used to refresh state after like/reaction toggle).
    func fetchPost(id: Int) async throws -> DiscourseTopicDetail.Post {
        try await request(route: .post(id: id))
    }

    /// Fetch a single post by its floor (`post_number`) within a topic. Needed
    /// when the only handle is the floor number — `allPostIds` is dense over
    /// the visible stream while `post_number` skips deleted floors, so the
    /// two cannot be mapped by index.
    func fetchPostByNumber(topicId: Int, postNumber: Int) async throws -> DiscourseTopicDetail.Post {
        try await request(route: .postByNumber(topicId: topicId, postNumber: postNumber))
    }

    /// Fetch the entire reply tree for a topic in one request via Discourse's
    /// new `/n/{slug}/{id}.json` endpoint. Use this in tree mode so the tree
    /// is complete regardless of which floors would have been on the current
    /// paginated batch.
    func fetchNestedTopic(id: Int, slug: String? = nil, sort: String? = nil, page: Int = 0) async throws -> DiscourseNestedTopicResponse {
        try await request(route: .nestedTopic(id: id, slug: slug, sort: sort, page: page))
    }

    /// Fetch the full direct-reply list under one post in tree mode. The main
    /// `/n/{slug}/{id}.json` payload inlines only the first few children per
    /// node; call this to expand the rest when the user taps "view more".
    func fetchNestedChildren(topicId: Int, postNumber: Int, slug: String? = nil, sort: String? = nil, page: Int = 0) async throws -> DiscourseNestedChildrenResponse {
        try await request(route: .nestedChildren(topicId: topicId, postNumber: postNumber, slug: slug, sort: sort, page: page))
    }

    func fetchPostReplies(postId: Int) async throws -> [DiscourseTopicDetail.Post] {
        try await request(route: .postReplies(postId: postId))
    }

    func fetchCurrentUser() async throws -> DiscourseCurrentUser {
        let response: DiscourseCurrentUserResponse = try await request(route: .currentUser)
        return response.currentUser
    }

    func createTopic(title: String, categoryId: Int, raw: String, tags: [String] = []) async throws -> DiscourseCreatePostResponse {
        var params: [String: Any] = [
            "title": title,
            "category": categoryId,
            "raw": raw,
        ]
        if !tags.isEmpty {
            params["tags"] = tags
        }
        return try await request(route: .createTopic, parameters: params)
    }

    func uploadImage(data: Data, filename: String) async throws -> DiscourseUploadResponse {
        let url = baseURL + DiscourseRouter.uploadImage.path
        let response = await session.upload(
            multipartFormData: { formData in
                formData.append(Data("composer".utf8), withName: "type")
                formData.append(data, withName: "file", fileName: filename, mimeType: "image/jpeg")
            },
            to: url,
            method: .post
        ).serializingDecodable(DiscourseUploadResponse.self).response

        if let data = response.data, let body = String(data: data, encoding: .utf8) {
            debugLog("[DiscourseAPI] POST \(url)\n\(body)")
        }

        if let newToken = response.response?.value(forHTTPHeaderField: "X-CSRF-Token") {
            interceptor.updateCSRFToken(newToken)
        }

        if let authError = authenticationFailureError(
            statusCode: response.response?.statusCode,
            data: response.data
        ) {
            throw authError
        }

        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            if let data = response.data,
               let errBody = try? JSONDecoder().decode(UploadErrorResponse.self, from: data),
               !errBody.errors.isEmpty
            {
                throw DiscourseAPIError(messages: errBody.errors, errorType: nil)
            }
            throw DiscourseAPIError(messages: ["Image upload failed"], errorType: nil)
        }
        return try response.result.get()
    }

    func createReply(topicId: Int, replyToPostNumber: Int?, raw: String) async throws -> DiscourseCreatePostResponse {
        var params: [String: Any] = [
            "topic_id": topicId,
            "raw": raw,
        ]
        if let replyToPostNumber {
            params["reply_to_post_number"] = replyToPostNumber
        }
        return try await request(route: .createTopic, parameters: params)
    }

    /// Updates a post body while protecting against overwriting a newer edit.
    func updatePost(id: Int, raw: String, originalRaw: String) async throws -> DiscourseTopicDetail.Post {
        let response: DiscourseUpdatePostResponse = try await request(
            route: .updatePost(id: id),
            parameters: DiscourseEditRequestBuilder.post(raw: raw, originalRaw: originalRaw),
            encoding: JSONEncoding.default
        )
        return response.post
    }

    /// Updates all topic-level metadata in one revision. Passing the original
    /// title and tag IDs enables Discourse's edit-conflict protection.
    func updateTopic(
        id: Int,
        title: String,
        originalTitle: String,
        categoryId: Int?,
        tags: [DiscourseEditableTag],
        originalTags: [DiscourseTopicDetail.Tag]
    ) async throws {
        let _: EmptyDiscourseResponse = try await request(
            route: .updateTopic(id: id),
            parameters: DiscourseEditRequestBuilder.topic(
                title: title,
                originalTitle: originalTitle,
                categoryId: categoryId,
                tags: tags,
                originalTags: originalTags
            ),
            encoding: JSONEncoding.default
        )
    }

    /// Flag/report a post.
    /// - `flagTypeId`: 3=off_topic, 4=inappropriate, 7=notify_moderators, 8=spam
    func flagPost(postId: Int, flagTypeId: Int, message: String? = nil) async throws {
        var params: [String: Any] = [
            "id": postId,
            "post_action_type_id": flagTypeId,
        ]
        if let message, !message.isEmpty {
            params["message"] = message
        }
        let _: DiscourseCreatePostResponse = try await request(route: .flagPost, parameters: params)
    }

    func createPrivateMessage(targetRecipients: String, title: String, raw: String) async throws -> DiscourseCreatePostResponse {
        let params: [String: Any] = [
            "archetype": "private_message",
            "target_recipients": targetRecipients,
            "title": title,
            "raw": raw,
        ]
        return try await request(route: .createPrivateMessage, parameters: params)
    }

    func followUser(username: String) async throws {
        guard isLinuxDo else { throw URLError(.unsupportedURL) }
        let _: [String: String] = try await request(route: .followUser(username: username))
    }

    func fetchFollowedUsers(username: String) async throws -> [DiscourseFollowedUser] {
        guard isLinuxDo else { throw URLError(.unsupportedURL) }
        return try await request(route: .followedUsers(username: username))
    }

    func unfollowUser(username: String) async throws {
        guard isLinuxDo else { throw URLError(.unsupportedURL) }
        let _: [String: String] = try await request(route: .unfollowUser(username: username))
    }

    func fetchEmojiCatalog() async -> [DiscourseEmojiGroup] {
        // Ensure the grouped emoji catalog for this forum is loaded.
        if !emojiReady || EmojiStore.loadedBaseURL != baseURL {
            await loadOrFetchEmojiMap()
        }
        guard EmojiStore.loadedBaseURL == baseURL else { return [] }
        return EmojiStore.catalogGroups()
    }

    func search(term: String, page: Int = 0) async throws -> DiscourseSearchResult {
        try await request(route: .search(term: term, page: page))
    }

    func fetchTags() async throws -> DiscourseTagList {
        try await request(route: .tags)
    }

    func searchTags(query: String = "", categoryId: Int? = nil) async throws -> [DiscourseTag] {
        struct TagSearchResponse: Decodable {
            let results: [TagSearchItem]
            struct TagSearchItem: Decodable {
                let name: String
                let count: Int?
            }
        }
        let response: TagSearchResponse = try await request(route: .tagSearch(query: query, categoryId: categoryId))
        return response.results.map { DiscourseTag(text: $0.name, count: $0.count ?? 0) }
    }

    func createBookmark(postId: Int) async throws -> DiscourseCreateBookmarkResponse {
        try await request(route: .createBookmark, parameters: [
            "bookmarkable_id": postId,
            "bookmarkable_type": "Post",
        ])
    }

    func createBoost(postId: Int, raw: String) async throws -> DiscourseTopicDetail.Boost {
        try await request(
            route: .createBoost(postId: postId),
            parameters: ["raw": raw],
            encoding: URLEncoding.httpBody,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                "X-Requested-With": "XMLHttpRequest",
            ]
        )
    }

    func deleteBookmark(id: Int) async throws {
        let route = DiscourseRouter.deleteBookmark(id: id)
        let url = baseURL + route.path
        let response = await session.request(url, method: route.method).serializingData().response
        if let authError = authenticationFailureError(
            statusCode: response.response?.statusCode,
            data: response.data
        ) {
            throw authError
        }
        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            throw DiscourseAPIError(messages: ["Failed to delete bookmark"], errorType: nil)
        }
    }

    func deleteBoost(id: Int) async throws {
        let route = DiscourseRouter.deleteBoost(id: id)
        let url = baseURL + route.path
        let response = await session.request(
            url,
            method: route.method,
            headers: ["X-Requested-With": "XMLHttpRequest"]
        ).serializingData().response
        if isCloudflareChallengeResponse(response.data) {
            throw DiscourseAPIError(messages: ["Cloudflare challenge required"], errorType: "challenge_required")
        }
        if let authError = authenticationFailureError(
            statusCode: response.response?.statusCode,
            data: response.data
        ) {
            throw authError
        }
        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            throw DiscourseAPIError(messages: ["Failed to delete boost"], errorType: nil)
        }
    }

    func toggleReaction(postId: Int, reactionId: String) async throws {
        let route = DiscourseRouter.toggleReaction(postId: postId, reactionId: reactionId)
        let url = baseURL + route.path
        // Discourse rejects state-changing requests without `X-Requested-With:
        // XMLHttpRequest` (CSRF/origin guard) → 403. The web client always
        // sends it; mirror that here.
        let response = await session.request(
            url,
            method: route.method,
            headers: ["X-Requested-With": "XMLHttpRequest"]
        ).serializingData().response
        if isCloudflareChallengeResponse(response.data) {
            throw DiscourseAPIError(messages: ["Cloudflare challenge required"], errorType: "challenge_required")
        }
        if let authError = authenticationFailureError(
            statusCode: response.response?.statusCode,
            data: response.data
        ) {
            throw authError
        }
        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            throw DiscourseAPIError(messages: ["Failed to toggle reaction"], errorType: nil)
        }
    }

    /// Standard Discourse "like" via PostAction (type 2). Used by the heart button.
    func likePost(postId: Int) async throws {
        let route = DiscourseRouter.likePost
        let url = baseURL + route.path
        let parameters: Parameters = [
            "id": postId,
            "post_action_type_id": 2,
            "flag_topic": false,
        ]
        let response = await session.request(
            url,
            method: route.method,
            parameters: parameters,
            encoding: URLEncoding.default,
            headers: ["X-Requested-With": "XMLHttpRequest"]
        ).serializingData().response
        if isCloudflareChallengeResponse(response.data) {
            throw DiscourseAPIError(messages: ["Cloudflare challenge required"], errorType: "challenge_required")
        }
        if let authError = authenticationFailureError(
            statusCode: response.response?.statusCode,
            data: response.data
        ) {
            throw authError
        }
        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            throw DiscourseAPIError(messages: ["Failed to like post"], errorType: nil)
        }
    }

    func unlikePost(postId: Int) async throws {
        let route = DiscourseRouter.unlikePost(postId: postId)
        let url = baseURL + route.path
        let response = await session.request(
            url,
            method: route.method,
            headers: ["X-Requested-With": "XMLHttpRequest"]
        ).serializingData().response
        if isCloudflareChallengeResponse(response.data) {
            throw DiscourseAPIError(messages: ["Cloudflare challenge required"], errorType: "challenge_required")
        }
        if let authError = authenticationFailureError(
            statusCode: response.response?.statusCode,
            data: response.data
        ) {
            throw authError
        }
        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            throw DiscourseAPIError(messages: ["Failed to unlike post"], errorType: nil)
        }
    }

    /// The solved endpoint returns the complete accepted-answer array on
    /// modern Discourse. Older plugin versions return only `{ success: "OK" }`;
    /// `nil` lets the caller apply a compatible optimistic fallback.
    func acceptSolution(postId: Int) async throws -> [DiscourseTopicDetail.AcceptedAnswer]? {
        let response: SolutionMutationResponse = try await request(
            route: .acceptSolution,
            parameters: ["id": postId],
            encoding: URLEncoding.httpBody,
            headers: ["X-Requested-With": "XMLHttpRequest"]
        )
        return response.acceptedAnswers
    }

    func unacceptSolution(postId: Int) async throws -> [DiscourseTopicDetail.AcceptedAnswer]? {
        let response: SolutionMutationResponse = try await request(
            route: .unacceptSolution,
            parameters: ["id": postId],
            encoding: URLEncoding.httpBody,
            headers: ["X-Requested-With": "XMLHttpRequest"]
        )
        return response.acceptedAnswers
    }

    private struct SolutionMutationResponse: Decodable {
        let acceptedAnswers: [DiscourseTopicDetail.AcceptedAnswer]?

        private enum CodingKeys: String, CodingKey {
            case acceptedAnswers = "accepted_answers"
        }

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() {
                acceptedAnswers = []
            } else if let answers = try? single.decode([DiscourseTopicDetail.AcceptedAnswer].self) {
                acceptedAnswers = answers
            } else if let envelope = try? decoder.container(keyedBy: CodingKeys.self) {
                acceptedAnswers = try? envelope.decodeIfPresent(
                    [DiscourseTopicDetail.AcceptedAnswer].self,
                    forKey: .acceptedAnswers
                )
            } else {
                // Legacy `{ success: "OK" }` response.
                acceptedAnswers = nil
            }
        }
    }

    struct PollVoteResponse: Decodable {
        let poll: DiscourseTopicDetail.Poll
        let vote: [String]?
    }

    func votePoll(postId: Int, pollName: String, options: [String]) async throws -> PollVoteResponse {
        try await request(
            route: .votePoll,
            parameters: [
                "post_id": postId,
                "poll_name": pollName,
                "options": options,
            ]
        )
    }

    func removePollVote(postId: Int, pollName: String) async throws -> PollVoteResponse {
        try await request(
            route: .removePollVote,
            parameters: [
                "post_id": postId,
                "poll_name": pollName,
            ]
        )
    }

    /// Mark a single notification as read, or all if `id` is nil.
    func markNotificationRead(id: Int? = nil) async throws {
        let route = DiscourseRouter.markNotificationRead
        let url = baseURL + route.path
        var parameters: Parameters?
        if let id { parameters = ["id": id] }
        let response = await session.request(url, method: route.method, parameters: parameters, encoding: JSONEncoding.default)
            .serializingData().response
        if let authError = authenticationFailureError(
            statusCode: response.response?.statusCode,
            data: response.data
        ) {
            throw authError
        }
        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            throw DiscourseAPIError(messages: ["Failed to mark notification read"], errorType: nil)
        }
    }

    /// Record per-post read durations so Discourse marks posts as read and they
    /// appear in the user's `/read.json` list.
    /// - Parameters:
    ///   - topicId: target topic
    ///   - topicTime: total time spent on the topic in milliseconds
    ///   - timings: per-post duration map (postNumber → milliseconds visible)
    func postTopicTimings(topicId: Int, topicTime: Int, timings: [Int: Int]) async throws {
        if ForumPolicy.isLinuxDoFamily(baseURL: baseURL) {
            let generation = AppSettings.shared.linuxDoReadTimingsActivationGeneration
            if lastTopicTimingsActivationGeneration != generation {
                topicTimingsCircuitBreaker.reset()
                lastTopicTimingsActivationGeneration = generation
            }
        }
        let reportingEnabled = ForumPolicy.tracksReadTimings(baseURL: baseURL)
        if reportingEnabled, lastTopicTimingsReportingEnabled == false {
            // Manual re-enable after an automatic linux.do shutdown starts a
            // fresh circuit-breaker window on existing API instances.
            topicTimingsCircuitBreaker.reset()
        }
        lastTopicTimingsReportingEnabled = reportingEnabled
        guard reportingEnabled else { return }
        // Circuit breaker: a forum where timings reliably fail (anonymous, read-only,
        // server-side disabled, …) keeps failing every visit. Stop the bleeding after
        // a few consecutive misses for the rest of this app session.
        if topicTimingsCircuitBreaker.isTripped {
            debugLog("[DiscourseAPI] timings: skipped (circuit-breaker tripped, \(topicTimingsCircuitBreaker.failureCount) failures)")
            return
        }
        guard !timings.isEmpty else { return }
        let route = DiscourseRouter.topicTimings
        let url = baseURL + route.path
        let stringKeyed = Dictionary(uniqueKeysWithValues: timings.map { (String($0.key), $0.value) })
        let parameters: Parameters = [
            "topic_id": topicId,
            "topic_time": topicTime,
            "timings": stringKeyed,
        ]
        debugLog("[DiscourseAPI] POST /topics/timings topic=\(topicId) topic_time=\(topicTime) posts=\(timings.count)")
        let attemptedAt = Date()
        let requestStart = Date()
        let response = await session.request(url, method: route.method, parameters: parameters, encoding: URLEncoding.default)
            .serializingData().response
        let requestDuration = Int(Date().timeIntervalSince(requestStart) * 1000)
        if let authError = authenticationFailureError(
            statusCode: response.response?.statusCode,
            data: response.data
        ) {
            throw authError
        }
        let assessment = assessTopicTimingResponse(
            statusCode: response.response?.statusCode,
            data: response.data,
            errorDescription: response.error?.localizedDescription
        )
        if assessment.outcome == .success {
            _ = topicTimingsCircuitBreaker.record(.success)
            debugLog("[DiscourseAPI] timings: ok (\(assessment.statusCode ?? 0))")
            persistTopicTimingReport(
                topicId: topicId,
                topicTime: topicTime,
                timings: timings,
                attemptedAt: attemptedAt,
                requestDuration: requestDuration,
                statusCode: assessment.statusCode,
                outcome: .success,
                consecutiveFailureCount: 0,
                trippedBreaker: false,
                errorSummary: nil
            )
        } else {
            let trippedBreaker = topicTimingsCircuitBreaker.record(assessment.outcome)
            let summary = assessment.errorSummary ?? "Network request failed"
            debugLog("[DiscourseAPI] timings: FAILED status=\(assessment.statusCode ?? 0) (consec=\(topicTimingsCircuitBreaker.failureCount))")
            persistTopicTimingReport(
                topicId: topicId,
                topicTime: topicTime,
                timings: timings,
                attemptedAt: attemptedAt,
                requestDuration: requestDuration,
                statusCode: assessment.statusCode,
                outcome: assessment.outcome,
                consecutiveFailureCount: topicTimingsCircuitBreaker.failureCount,
                trippedBreaker: trippedBreaker,
                errorSummary: summary
            )
            if trippedBreaker, ForumPolicy.isLinuxDoFamily(baseURL: baseURL) {
                AppSettings.shared.linuxDoReadTimingsEnabled = false
                lastTopicTimingsReportingEnabled = false
                NotificationCenter.default.post(
                    name: .linuxDoReadTimingsAutoDisabled,
                    object: self
                )
            }
            throw DiscourseAPIError(
                messages: [summary],
                errorType: assessment.outcome == .cloudflareChallenge ? "challenge_required" : nil
            )
        }
    }

    private var topicTimingsCircuitBreaker = TopicTimingCircuitBreaker()
    private var lastTopicTimingsReportingEnabled: Bool?
    private var lastTopicTimingsActivationGeneration: Int?

    private func persistTopicTimingReport(
        topicId: Int,
        topicTime: Int,
        timings: [Int: Int],
        attemptedAt: Date,
        requestDuration: Int,
        statusCode: Int?,
        outcome: TopicTimingOutcome,
        consecutiveFailureCount: Int,
        trippedBreaker: Bool,
        errorSummary: String?
    ) {
        guard let forumID else { return }
        var report = TopicTimingReport(
            forumId: forumID,
            baseURL: baseURL,
            accountName: AuthManager.shared.username(for: baseURL),
            topicId: topicId,
            attemptedAt: attemptedAt,
            topicTime: topicTime,
            postCount: timings.count,
            visibleTime: timings.values.reduce(0, +),
            requestDuration: requestDuration,
            statusCode: statusCode,
            outcome: outcome,
            consecutiveFailureCount: consecutiveFailureCount,
            trippedBreaker: trippedBreaker,
            errorSummary: errorSummary
        )
        do {
            try DatabaseManager.shared.saveTopicTimingReport(&report)
        } catch {
            debugLog("[DiscourseAPI] timings: failed to persist report: \(error)")
        }
    }

    /// Fetch the shared_session_key from the main site HTML meta tag.
    func fetchSharedSessionKey() async -> String? {
        guard let url = URL(string: baseURL) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        let cookieHeader = WebCookieStore.shared.cookieHeader(for: url)
        if !cookieHeader.isEmpty { req.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        if let ua = WebCookieStore.shared.userAgent { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        let response = await session.request(req).serializingData().response
        if authenticationFailureError(
            statusCode: response.response?.statusCode,
            data: response.data
        ) != nil {
            return nil
        }
        guard let data = response.data, let html = String(data: data, encoding: .utf8) else { return nil }
        // Extract <meta name="shared_session_key" content="...">
        guard let range = html.range(of: #"<meta name="shared_session_key" content="([^"]+)""#, options: .regularExpression),
              let contentRange = html[range].range(of: #"content="([^"]+)""#, options: .regularExpression)
        else { return nil }
        let match = html[contentRange]
        let key = match.dropFirst(9).dropLast(1) // drop 'content="' and '"'
        return String(key)
    }

    func pollMessageBus(clientId: String, channels: [String: Int], sharedSessionKey: String? = nil) async throws -> [MessageBusMessage] {
        let route = DiscourseRouter.messageBusPoll(clientId: clientId)
        let mbBase = isLinuxDo ? "https://ping.ldstatic.com" : baseURL
        let url = mbBase + route.path
        debugLog("[MessageBus] POST \(url) channels=\(channels)")
        var headers = HTTPHeaders()
        if let sharedSessionKey {
            headers.add(name: "X-Shared-Session-Key", value: sharedSessionKey)
        }
        let response = await session.request(url, method: route.method, parameters: channels, encoding: URLEncoding.default, headers: headers)
            .serializingData().response
        if let authError = authenticationFailureError(
            statusCode: response.response?.statusCode,
            data: response.data
        ) {
            throw authError
        }
        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            throw DiscourseAPIError(messages: ["MessageBus poll failed"], errorType: nil)
        }
        guard let data = response.data else { return [] }
        debugLog("[MessageBus] \(response.response?.statusCode ?? 0) \(String(data: data, encoding: .utf8) ?? "")")

        // MessageBus returns chunked responses: multiple JSON arrays separated by "|"
        let body = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        var result: [MessageBusMessage] = []
        for chunk in body.split(separator: "|") {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let chunkData = trimmed.data(using: .utf8) else { continue }
            do {
                let messages = try decoder.decode([MessageBusMessage].self, from: chunkData)
                result.append(contentsOf: messages)
            } catch {
                debugLog("[MessageBus] chunk decode error: \(error)")
            }
        }
        return result
    }

    func fetchBookmarks(username: String) async throws -> DiscourseBookmarkList {
        try await request(route: .bookmarks(username: username))
    }

    func fetchUserSummary(username: String) async throws -> DiscourseUserSummary {
        let response: DiscourseUserSummaryResponse = try await request(route: .userSummary(username: username))
        return response.userSummary
    }

    func fetchUserProfile(username: String) async throws -> DiscourseUserProfile {
        let response: DiscourseUserProfileResponse = try await request(route: .userProfile(username: username))
        return response.user
    }

    func loadOrFetchEmojiMap() async {
        if EmojiStore.load(for: baseURL, assetBaseURL: assetBaseURL) {
            emojiReady = true
            return
        }
        do {
            let groups: [String: [DiscourseEmojiEntry]] = try await request(route: .emojis)
            EmojiStore.save(groups, for: baseURL, assetBaseURL: assetBaseURL)
            emojiReady = true
        } catch {
            // Silent failure — reactions won't show emoji images but functionality is unaffected
        }
    }

    func deleteSession(username: String) async {
        let url = baseURL + "/session/\(username)"
        _ = await session.request(url, method: .delete).serializingData().response
    }

    func revokeApiKey(apiKey: String) async {
        let url = baseURL + "/user-api-key/revoke"
        let headers: HTTPHeaders = ["User-Api-Key": apiKey]
        _ = await session.request(url, method: .post, headers: headers).serializingData().response
    }

    // MARK: - Private

    private func fetchAllCategoriesFromServer() async throws -> DiscourseCategoryList {
        var accumulator = CategoryPageAccumulator()
        var page = 1

        while true {
            try Task.checkCancellation()
            let response = try await fetchCategories(page: page)
            try Task.checkCancellation()
            let pageCategories = response.categoryList.categories
            guard !pageCategories.isEmpty else { break }
            guard accumulator.append(pageCategories) else { break }
            page += 1
        }

        // When category lazy loading is enabled, each root page embeds at most
        // five child objects but exposes every visible child ID through
        // `subcategory_ids`. Fetch the missing direct children through the
        // same upstream endpoint scoped by `parent_category_id`. Any children
        // with their own missing descendants are discovered by the accumulator
        // and processed in a later iteration.
        while let parentCategoryID = accumulator.nextParentCategoryIDNeedingFetch {
            var childPage = 1

            while true {
                try Task.checkCancellation()
                let response = try await fetchChildCategories(
                    parentCategoryID: parentCategoryID,
                    page: childPage
                )
                try Task.checkCancellation()
                let pageCategories = response.categoryList.categories
                guard !pageCategories.isEmpty else { break }
                guard accumulator.appendChildren(
                    pageCategories,
                    parentCategoryID: parentCategoryID
                ) else { break }
                guard !accumulator.hasAllExpectedChildren(for: parentCategoryID) else { break }
                childPage += 1
            }

            accumulator.markChildFetchCompleted(for: parentCategoryID)
        }

        return DiscourseCategoryList(categoryList: .init(categories: accumulator.categories))
    }

    private func request<T: Decodable>(route: DiscourseRouter, parameters: Parameters? = nil, encoding: ParameterEncoding? = nil, headers: HTTPHeaders? = nil) async throws -> T {
        let url = baseURL + route.path
        let resolvedEncoding = encoding ?? (route.method == .post ? JSONEncoding.default : URLEncoding.default)
        let response = await session.request(url, method: route.method, parameters: parameters, encoding: resolvedEncoding, headers: headers)
            .serializingDecodable(T.self)
            .response

        if let data = response.data, let body = String(data: data, encoding: .utf8) {
            debugLog("[DiscourseAPI] \(route.method.rawValue) \(url)\n\(body)")
        }

        if let newToken = response.response?.value(forHTTPHeaderField: "X-CSRF-Token") {
            interceptor.updateCSRFToken(newToken)
        }
        // Only merge Set-Cookie on successful responses. On weak networks, error responses
        // (proxy 5xx, partial replies, session-expired 403s) can carry Set-Cookie directives
        // that would clobber the `_t` session cookie and log the user out silently.
        if let httpResponse = response.response, let url = httpResponse.url,
           let statusCode = response.response?.statusCode, (200 ..< 300).contains(statusCode),
           KeychainHelper.getUserApiKey(for: baseURL) == AuthManager.webAuthSentinel
        {
            WebCookieStore.shared.mergeResponseHeaders(httpResponse.allHeaderFields, for: url)
        }

        if isCloudflareChallengeResponse(response.data) {
            throw DiscourseAPIError(messages: ["Cloudflare challenge required"], errorType: "challenge_required")
        }

        if let authError = authenticationFailureError(
            statusCode: response.response?.statusCode,
            data: response.data
        ) {
            throw authError
        }

        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            if statusCode == 403 {
                let data = response.data ?? Data()
                if let errBody = try? JSONDecoder().decode(DiscourseErrorResponse.self, from: data), !errBody.errors.isEmpty {
                    throw DiscourseAPIError(
                        messages: errBody.errors,
                        errorType: errBody.errorType ?? "forbidden"
                    )
                }
                throw DiscourseAPIError(messages: ["Session expired, please log in again"], errorType: "forbidden")
            }
            if let data = response.data {
                if let errBody = try? JSONDecoder().decode(DiscourseErrorResponse.self, from: data), !errBody.errors.isEmpty {
                    throw DiscourseAPIError(messages: errBody.errors, errorType: errBody.errorType)
                }
                if let failBody = try? JSONDecoder().decode(DiscourseFailedResponse.self, from: data), let message = failBody.message {
                    throw DiscourseAPIError(messages: [message], errorType: failBody.failed)
                }
            }
        }

        return try response.result.get()
    }

    private func authenticationFailureError(
        statusCode: Int?,
        data: Data?
    ) -> DiscourseAPIError? {
        guard isDiscourseAuthenticationFailure(statusCode: statusCode, data: data) else {
            return nil
        }
        PushSubscriptionCoordinator(api: self).retireLocalSubscriptions()
        AuthManager.shared.invalidateExpiredAuthentication(for: baseURL)
        let messages = data
            .flatMap { try? JSONDecoder().decode(DiscourseErrorResponse.self, from: $0) }
            .map(\.errors)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? ["Session expired, please log in again"]
        return DiscourseAPIError(messages: messages, errorType: "not_logged_in")
    }
}

extension Notification.Name {
    static let linuxDoReadTimingsAutoDisabled = Notification.Name(
        "linuxDoReadTimingsAutoDisabled"
    )
}

// MARK: - Error Handling

private struct DiscourseErrorResponse: Decodable {
    let errors: [String]
    let errorType: String?

    enum CodingKeys: String, CodingKey {
        case errors
        case errorType = "error_type"
    }
}

func isDiscourseAuthenticationFailure(statusCode: Int?, data: Data?) -> Bool {
    if statusCode == 401 { return true }
    guard statusCode == 403,
          let data,
          let response = try? JSONDecoder().decode(DiscourseErrorResponse.self, from: data)
    else { return false }
    return response.errorType == "not_logged_in"
}

private struct UploadErrorResponse: Decodable {
    let errors: [String]
}

private struct DiscourseFailedResponse: Decodable {
    let failed: String?
    let message: String?
}

struct DiscourseAPIError: LocalizedError {
    let messages: [String]
    let errorType: String?

    var isNotLoggedIn: Bool {
        errorType == "not_logged_in"
    }

    var isForbidden: Bool {
        errorType == "forbidden"
    }

    /// True when the response was a Cloudflare interstitial ("Just a moment...")
    /// rather than a real API response — the caller should prompt the user to
    /// pass the challenge before retrying.
    var isChallengeRequired: Bool {
        errorType == "challenge_required"
    }

    var errorDescription: String? {
        messages.joined(separator: "\n")
    }
}

/// Detects Cloudflare's challenge interstitial in a response body. Cloudflare
/// challenges may arrive with any status code (200, 403, 503), so the body is
/// the only reliable signal.
func isCloudflareChallengeResponse(_ data: Data?) -> Bool {
    guard let data, !data.isEmpty else { return false }
    // Cap the scan — Cloudflare pages are small HTML; real JSON can be huge.
    let prefix = data.prefix(65536)
    guard let snippet = String(data: prefix, encoding: .utf8) else { return false }
    return snippet.contains("Just a moment...")
        || snippet.contains("cf-browser-verification")
        || snippet.contains("cf-challenge-running")
        || snippet.contains("__cf_chl_")
}

// MARK: - Auth Interceptor

/// The basic-info endpoint is used to discover a forum before it has been
/// added. It must not inherit credentials left in Keychain for the same URL:
/// a revoked User API Key turns this otherwise-public request into a 403.
func shouldAttachStoredForumAuthentication(to requestURL: URL, baseURL: String) -> Bool {
    guard let basicInfoURL = URL(string: baseURL + DiscourseRouter.basicInfo.path) else {
        return true
    }
    return requestURL != basicInfoURL
}

private final class DiscourseAuthInterceptor: RequestInterceptor {
    private let baseURL: String
    private nonisolated(unsafe) var csrfToken: String?
    private nonisolated(unsafe) var isFetchingCSRF = false
    private nonisolated(unsafe) var csrfWaiters: [(String?) -> Void] = []
    private let csrfLock = NSLock()

    private nonisolated(unsafe) var authChangeObserver: (any NSObjectProtocol)?

    init(baseURL: String) {
        self.baseURL = baseURL
        self.authChangeObserver = NotificationCenter.default.addObserver(forName: .discourseAuthDidChange, object: nil, queue: nil) { [weak self] notification in
            guard let self,
                  let changedBaseURL = notification.userInfo?["baseURL"] as? String,
                  changedBaseURL == self.baseURL else { return }
            self.invalidateCSRFToken()
        }
    }

    deinit {
        if let observer = authChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func adapt(_ urlRequest: URLRequest, for session: Session, completion: @escaping (Result<URLRequest, Error>) -> Void) {
        // Keep the transport policy at the final networking boundary as well
        // as in the forum-list UI. This prevents legacy HTTP records (or a
        // future non-UI caller) from ever attaching credentials to a request.
        guard let requestURL = urlRequest.url,
              ForumURLPolicy.allowsRequest(requestURL, for: baseURL)
        else {
            completion(.failure(URLError(.appTransportSecurityRequiresSecureConnection)))
            return
        }

        var request = urlRequest
        let shouldAttachStoredAuthentication = shouldAttachStoredForumAuthentication(
            to: requestURL,
            baseURL: baseURL
        )
        if !shouldAttachStoredAuthentication {
            // Also strip an explicitly supplied key so every basic-info probe
            // remains anonymous. Challenge cookies and their matching
            // User-Agent, when requested by fetchBasicInfo, are preserved.
            request.setValue(nil, forHTTPHeaderField: "User-Api-Key")
        }

        if shouldAttachStoredAuthentication,
           let userApiKey = KeychainHelper.getUserApiKey(for: baseURL)
        {
            if userApiKey == AuthManager.webAuthSentinel {
                if let url = request.url {
                    let header = WebCookieStore.shared.cookieHeader(for: url)
                    if !header.isEmpty {
                        request.setValue(header, forHTTPHeaderField: "Cookie")
                    }
                    if let ua = WebCookieStore.shared.userAgent {
                        request.setValue(ua, forHTTPHeaderField: "User-Agent")
                    }
                }
                let isMutating = request.httpMethod == "POST" || request.httpMethod == "PUT" || request.httpMethod == "DELETE"
                if isMutating {
                    if request.value(forHTTPHeaderField: "Accept") == nil {
                        request.setValue("application/json", forHTTPHeaderField: "Accept")
                    }
                    if request.value(forHTTPHeaderField: "Content-Type") == nil {
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    }
                    getOrFetchCSRFToken(session: session) { token in
                        if let token {
                            request.setValue(token, forHTTPHeaderField: "X-CSRF-Token")
                        }
                        completion(.success(request))
                    }
                    return
                }
            } else {
                // Some maintenance calls intentionally carry a captured old
                // key (for example revoking it after an atomic credential
                // switch). Never overwrite an explicit credential snapshot.
                if request.value(forHTTPHeaderField: "User-Api-Key") == nil {
                    request.setValue(userApiKey, forHTTPHeaderField: "User-Api-Key")
                }
            }
        }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if request.httpMethod == "POST", request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        completion(.success(request))
    }

    func retry(_ request: Request, for session: Session, dueTo error: any Error, completion: @escaping (RetryResult) -> Void) {
        guard let userApiKey = KeychainHelper.getUserApiKey(for: baseURL),
              userApiKey == AuthManager.webAuthSentinel,
              request.retryCount == 0,
              let httpMethod = request.request?.httpMethod,
              httpMethod == "POST" || httpMethod == "PUT" || httpMethod == "DELETE"
        else {
            completion(.doNotRetry)
            return
        }
        // Retry on 403/422 (CSRF token invalid or expired)
        let statusCode = request.response?.statusCode
        guard statusCode == 403 || statusCode == 422 || statusCode == nil else {
            completion(.doNotRetry)
            return
        }
        // Invalidate token so next getOrFetchCSRFToken will fetch fresh one.
        // If another retry already reset and is fetching, we just join the waiters.
        csrfLock.lock()
        let wasAlreadyInvalidated = csrfToken == nil
        csrfToken = nil
        if wasAlreadyInvalidated {
            // Another retry already invalidated — just wait for its fetch
            csrfLock.unlock()
        } else {
            // We are the first to invalidate — reset fetch state so a fresh fetch starts
            isFetchingCSRF = false
            csrfWaiters = []
            csrfLock.unlock()
        }
        getOrFetchCSRFToken(session: session) { token in
            completion(token != nil ? .retry : .doNotRetry)
        }
    }

    /// Returns cached CSRF token if available, otherwise fetches one.
    /// Concurrent callers wait for a single in-flight fetch to complete.
    private func getOrFetchCSRFToken(session: Session, completion: @escaping (String?) -> Void) {
        csrfLock.lock()
        if let token = csrfToken {
            csrfLock.unlock()
            completion(token)
            return
        }
        csrfWaiters.append(completion)
        let alreadyFetching = isFetchingCSRF
        isFetchingCSRF = true
        csrfLock.unlock()
        guard !alreadyFetching else { return }
        fetchCSRFToken(session: session) { [weak self] token in
            guard let self else { return }
            self.csrfLock.lock()
            self.csrfToken = token
            self.isFetchingCSRF = false
            let waiters = self.csrfWaiters
            self.csrfWaiters = []
            self.csrfLock.unlock()
            waiters.forEach { $0(token) }
        }
    }

    func invalidateCSRFToken() {
        csrfLock.lock()
        csrfToken = nil
        csrfLock.unlock()
    }

    func updateCSRFToken(_ token: String) {
        csrfLock.lock()
        csrfToken = token
        csrfLock.unlock()
    }

    private func fetchCSRFToken(session: Session, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "\(baseURL)/session/csrf.json") else {
            completion(nil)
            return
        }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let cookieHeader = WebCookieStore.shared.cookieHeader(for: url)
        if !cookieHeader.isEmpty { req.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        if let ua = WebCookieStore.shared.userAgent { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        session.request(req).responseData { response in
            guard let data = response.data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["csrf"] as? String
            else {
                completion(nil)
                return
            }
            completion(token)
        }
    }
}

/// Reject redirects outside the forum origin before URLSession can forward
/// custom authentication headers. The exact linux.do MessageBus host remains
/// on the same allowlist as initial requests.
private final class ForumRedirectHandler: RedirectHandler {
    private let baseURL: String

    init(baseURL: String) {
        self.baseURL = baseURL
    }

    func task(
        _ task: URLSessionTask,
        willBeRedirectedTo request: URLRequest,
        for response: HTTPURLResponse,
        completion: @escaping (URLRequest?) -> Void
    ) {
        guard let targetURL = request.url,
              ForumURLPolicy.allowsRequest(targetURL, for: baseURL)
        else {
            completion(nil)
            return
        }
        completion(request)
    }
}
