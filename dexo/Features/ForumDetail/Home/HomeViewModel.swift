import Foundation

import Perception

protocol HomeFeedAPIClient: AnyObject {
    func fetchTopicFeed(mode: TopicFeedMode, page: Int) async throws -> DiscourseTopicList
    func fetchCategoryTopics(
        slug: String,
        id: Int,
        feedMode: TopicFeedMode?,
        page: Int
    ) async throws -> DiscourseTopicList
    func fetchAllCategories(forceRefresh: Bool) async throws -> DiscourseCategoryList
    func invalidateCategoryCache()
}

extension DiscourseAPI: HomeFeedAPIClient {}

@Perceptible
final class HomeViewModel {
    private(set) var feedMode: TopicFeedMode = .activity
    var topics: [DiscourseTopicList.Topic] = []
    var isLoading = false
    var isLoadingMore = false
    var canLoadMore = false
    var errorMessage: String?
    var requiresLogin = false
    var requiresChallenge = false

    var categories: [DiscourseCategory] = []
    private(set) var selectedCategoryId: Int?

    /// O(1) topic lookup by ID for cell configuration.
    private(set) var topicsById: [Int: DiscourseTopicList.Topic] = [:]

    private let api: any HomeFeedAPIClient
    private var currentPage = 0
    private var requestGeneration = 0
    private var usersById: [Int: DiscourseTopicList.User] = [:]
    private var categoriesById: [Int: DiscourseCategory] = [:]

    init(api: any HomeFeedAPIClient) {
        self.api = api
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

    func category(for topic: DiscourseTopicList.Topic) -> DiscourseCategory? {
        guard let catId = topic.categoryId else { return nil }
        return categoriesById[catId]
    }

    func selectedCategory() -> DiscourseCategory? {
        guard let id = selectedCategoryId else { return nil }
        return categoriesById[id]
    }

    @discardableResult
    func selectFeedMode(_ mode: TopicFeedMode) -> Bool {
        guard feedMode != mode else { return false }
        invalidateRequests()
        clearTopicResults()
        feedMode = mode
        return true
    }

    @discardableResult
    func selectCategory(_ categoryId: Int?) -> Bool {
        guard selectedCategoryId != categoryId else { return false }
        invalidateRequests()
        clearTopicResults()
        selectedCategoryId = categoryId
        return true
    }

    func loadTopics() async {
        invalidateRequests()
        let generation = requestGeneration
        let requestedMode = feedMode
        let requestedCategoryId = selectedCategoryId
        let requestedCategory = selectedCategory()

        isLoading = true
        errorMessage = nil
        requiresLogin = false
        requiresChallenge = false
        defer {
            if isCurrentRequest(
                generation: generation,
                mode: requestedMode,
                categoryId: requestedCategoryId
            ) {
                isLoading = false
            }
        }

        do {
            async let categoriesResult: Void = loadCategoriesIfNeeded(generation: generation)
            let result: DiscourseTopicList
            if let requestedCategory {
                result = try await api.fetchCategoryTopics(
                    slug: requestedCategory.slug,
                    id: requestedCategory.id,
                    feedMode: requestedMode,
                    page: 0
                )
            } else {
                result = try await api.fetchTopicFeed(mode: requestedMode, page: 0)
            }
            _ = await categoriesResult

            guard isCurrentRequest(
                generation: generation,
                mode: requestedMode,
                categoryId: requestedCategoryId
            ) else { return }

            topics = result.topicList.topics
            topicsById = Dictionary(topics.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            canLoadMore = result.topicList.moreTopicsUrl != nil
            indexUsers(result.users)
        } catch {
            guard isCurrentRequest(
                generation: generation,
                mode: requestedMode,
                categoryId: requestedCategoryId
            ) else { return }

            if let apiError = error as? DiscourseAPIError {
                if apiError.isChallengeRequired {
                    requiresChallenge = true
                }
                if apiError.isNotLoggedIn || apiError.isForbidden {
                    requiresLogin = true
                }
            }
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreTopics() async {
        guard canLoadMore, !isLoading, !isLoadingMore else { return }

        let generation = requestGeneration
        let requestedMode = feedMode
        let requestedCategoryId = selectedCategoryId
        let requestedCategory = selectedCategory()
        let nextPage = currentPage + 1

        isLoadingMore = true
        defer {
            if isCurrentRequest(
                generation: generation,
                mode: requestedMode,
                categoryId: requestedCategoryId
            ) {
                isLoadingMore = false
            }
        }

        do {
            let result: DiscourseTopicList
            if let requestedCategory {
                result = try await api.fetchCategoryTopics(
                    slug: requestedCategory.slug,
                    id: requestedCategory.id,
                    feedMode: requestedMode,
                    page: nextPage
                )
            } else {
                result = try await api.fetchTopicFeed(mode: requestedMode, page: nextPage)
            }

            guard isCurrentRequest(
                generation: generation,
                mode: requestedMode,
                categoryId: requestedCategoryId
            ) else { return }

            currentPage = nextPage
            let existingIds = Set(topics.map(\.id))
            let newTopics = result.topicList.topics.filter { !existingIds.contains($0.id) }
            topics.append(contentsOf: newTopics)
            for t in newTopics { topicsById[t.id] = t }
            canLoadMore = result.topicList.moreTopicsUrl != nil
            indexUsers(result.users)
        } catch {
            // Keep ordinary load-more failures silent, but a Cloudflare
            // challenge needs an actionable prompt instead of endless retries.
            if let apiError = error as? DiscourseAPIError, apiError.isChallengeRequired {
                requiresChallenge = true
            }
        }
    }

    private func indexUsers(_ users: [DiscourseTopicList.User]?) {
        guard let users else { return }
        for user in users {
            usersById[user.id] = user
        }
    }

    func reloadCategories() async {
        api.invalidateCategoryCache()
        categoriesById.removeAll()
        categories.removeAll()
        await loadCategoriesIfNeeded(generation: requestGeneration)
    }

    /// Resets every piece of state derived from the previous credential before
    /// loading the forum again. In particular, an anonymous category/topic
    /// response must never survive a successful login.
    func reloadAfterAuthChange() async {
        invalidateRequests()
        api.invalidateCategoryCache()
        topics.removeAll()
        topicsById.removeAll()
        usersById.removeAll()
        categories.removeAll()
        categoriesById.removeAll()
        selectedCategoryId = nil
        errorMessage = nil
        requiresLogin = false
        requiresChallenge = false
        await loadTopics()
    }

    private func loadCategoriesIfNeeded(generation: Int) async {
        guard categoriesById.isEmpty else { return }
        do {
            let list = try await api.fetchAllCategories(forceRefresh: false)
            guard generation == requestGeneration else { return }
            categories = list.categoryList.categories
            indexCategories(list.categoryList.categories)
        } catch {
            // Category names are non-critical, but do not hide a Cloudflare
            // challenge encountered by this parallel homepage request.
            guard generation == requestGeneration else { return }
            if let apiError = error as? DiscourseAPIError, apiError.isChallengeRequired {
                requiresChallenge = true
            }
        }
    }

    private func indexCategories(_ categories: [DiscourseCategory]) {
        for cat in categories {
            categoriesById[cat.id] = cat
            if let subs = cat.subcategoryList {
                indexCategories(subs)
            }
        }
    }

    private func invalidateRequests() {
        requestGeneration &+= 1
        currentPage = 0
        canLoadMore = false
        isLoading = false
        isLoadingMore = false
    }

    private func clearTopicResults() {
        topics.removeAll()
        topicsById.removeAll()
        usersById.removeAll()
        errorMessage = nil
        requiresLogin = false
    }

    private func isCurrentRequest(
        generation: Int,
        mode: TopicFeedMode,
        categoryId: Int?
    ) -> Bool {
        generation == requestGeneration
            && mode == feedMode
            && categoryId == selectedCategoryId
    }
}
