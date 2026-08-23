import Foundation

enum SearchSortOrder: String, CaseIterable {
    case relevance
    case latestTopic = "latest_topic"
    case latest
    case likes
    case views
    case read

    var displayName: String {
        switch self {
        case .relevance: String(localized: "search.sort.relevance")
        case .latestTopic: String(localized: "search.sort.latest_topic")
        case .latest: String(localized: "search.sort.latest")
        case .likes: String(localized: "search.sort.most_likes")
        case .views: String(localized: "search.sort.most_views")
        case .read: String(localized: "search.sort.read")
        }
    }
}

import Perception

@Perceptible
final class SearchViewModel {
    private static let firstPage = 1
    private static let lastPage = 10

    var searchResults: [DiscourseSearchResult.SearchPost] = []
    private(set) var topicsById: [Int: DiscourseSearchResult.SearchTopic] = [:]
    var isSearching = false
    var canLoadMore = false
    var hasSearched = false
    var errorMessage: String?

    var categories: [DiscourseCategory] = []
    var selectedCategoryId: Int?
    var selectedTag: String?
    var selectedSortOrder: SearchSortOrder = {
        if let raw = UserDefaults.standard.string(forKey: "searchSortOrder"),
           let order = SearchSortOrder(rawValue: raw) {
            return order
        }
        return .latest
    }() {
        didSet { UserDefaults.standard.set(selectedSortOrder.rawValue, forKey: "searchSortOrder") }
    }

    private let api: DiscourseAPI
    private var currentPage = SearchViewModel.firstPage
    private var currentTerm = ""
    private(set) var categoriesById: [Int: DiscourseCategory] = [:]

    init(api: DiscourseAPI) {
        self.api = api
    }

    func selectedCategory() -> DiscourseCategory? {
        guard let id = selectedCategoryId else { return nil }
        return categoriesById[id]
    }

    func loadCategories() async {
        do {
            let catList = try await api.fetchAllCategories()
            categories = catList.categoryList.categories
            categoriesById.removeAll()
            for cat in categories {
                categoriesById[cat.id] = cat
                if let subs = cat.subcategoryList {
                    for sub in subs {
                        categoriesById[sub.id] = sub
                    }
                }
            }
            if let selectedCategoryId, categoriesById[selectedCategoryId] == nil {
                self.selectedCategoryId = nil
            }
        } catch {}
    }

    func search(term: String) async {
        let query = buildQuery(term: term)
        guard !query.isEmpty else {
            searchResults = []
            hasSearched = false
            return
        }

        isSearching = true
        currentTerm = term
        currentPage = Self.firstPage
        hasSearched = true
        errorMessage = nil

        do {
            let result = try await api.search(term: query, page: Self.firstPage)
            searchResults = result.posts ?? []
            topicsById = Self.buildTopicsMap(from: result)
            canLoadMore = Self.canLoadMore(after: result, page: currentPage)
        } catch {
            searchResults = []
            topicsById = [:]
            canLoadMore = false
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }

    func loadMoreResults() async {
        guard canLoadMore, !isSearching else { return }
        isSearching = true
        let nextPage = currentPage + 1
        let query = buildQuery(term: currentTerm)

        do {
            let result = try await api.search(term: query, page: nextPage)
            let newPosts = result.posts ?? []
            let existingIds = Set(searchResults.map(\.id))
            let filtered = newPosts.filter { !existingIds.contains($0.id) }
            searchResults.append(contentsOf: filtered)
            topicsById.merge(Self.buildTopicsMap(from: result)) { _, new in new }
            currentPage = nextPage
            canLoadMore = Self.canLoadMore(after: result, page: currentPage)
        } catch {
            canLoadMore = false
        }
        isSearching = false
    }

    private static func buildTopicsMap(from result: DiscourseSearchResult) -> [Int: DiscourseSearchResult.SearchTopic] {
        guard let topics = result.topics else { return [:] }
        return Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0) })
    }

    private static func canLoadMore(after result: DiscourseSearchResult, page: Int) -> Bool {
        page < lastPage && (result.groupedSearchResult?.hasMoreFullPageResults ?? false)
    }

    private func buildQuery(term: String) -> String {
        var parts: [String] = []
        if !term.isEmpty {
            parts.append(term)
        }
        if let catId = selectedCategoryId, let slug = categoriesById[catId]?.slug {
            parts.append("category:\(slug)")
        }
        if let tag = selectedTag {
            parts.append("tag:\(tag)")
        }
        if selectedSortOrder != .relevance {
            parts.append("order:\(selectedSortOrder.rawValue)")
        }
        return parts.joined(separator: " ")
    }
}
