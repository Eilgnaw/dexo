import Foundation

enum TopicComposerMode {
    case create
    case edit(topic: DiscourseTopicDetail, post: DiscourseTopicDetail.Post)
}

enum TopicComposerSubmissionResult {
    case created(topicId: Int)
    case updated
}

struct TopicEditSaveError: LocalizedError {
    let underlyingError: Error
    let bodyWasSaved: Bool

    var errorDescription: String? { underlyingError.localizedDescription }
}

struct TopicDraft: Codable {
    var title: String
    var body: String
    var categoryId: Int?
    var tags: [String]

    var isEmpty: Bool {
        title.isEmpty && body.isEmpty && categoryId == nil && tags.isEmpty
    }
}

enum TopicDraftStore {
    private static func key(for baseURL: String) -> String {
        "compose.draft.\(baseURL)"
    }

    static func load(baseURL: String) -> TopicDraft? {
        guard let data = UserDefaults.standard.data(forKey: key(for: baseURL)),
              let draft = try? JSONDecoder().decode(TopicDraft.self, from: data),
              !draft.isEmpty
        else { return nil }
        return draft
    }

    static func save(_ draft: TopicDraft, baseURL: String) {
        guard !draft.isEmpty,
              let data = try? JSONEncoder().encode(draft)
        else {
            clear(baseURL: baseURL)
            return
        }
        UserDefaults.standard.set(data, forKey: key(for: baseURL))
    }

    static func clear(baseURL: String) {
        UserDefaults.standard.removeObject(forKey: key(for: baseURL))
    }
}

import Perception

protocol TopicEditingAPI: AnyObject {
    func updatePost(
        id: Int,
        raw: String,
        originalRaw: String
    ) async throws -> DiscourseTopicDetail.Post

    func updateTopic(
        id: Int,
        title: String,
        originalTitle: String,
        categoryId: Int?,
        tags: [DiscourseEditableTag],
        originalTags: [DiscourseTopicDetail.Tag]
    ) async throws
}

extension DiscourseAPI: TopicEditingAPI {}

@Perceptible
final class TopicComposerViewModel {
    var title: String = ""
    var body: String = ""
    var selectedCategory: DiscourseCategory?
    var selectedTags: [String] = []
    var categories: [DiscourseCategory] = []
    var tagSuggestions: [DiscourseTag] = []
    var isSubmitting = false
    var isUploadingImage = false
    var errorMessage: String?

    let mode: TopicComposerMode
    private(set) var hasServerChanges = false
    private var bodyHasBeenSaved = false

    private var originalTitle: String?
    private var originalBody: String?
    private var originalCategoryId: Int?
    private var originalTags: [DiscourseTopicDetail.Tag] = []
    private var originalTagNames: [String] = []

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var currentCategoryId: Int? {
        selectedCategory?.id ?? originalCategoryId
    }

    var canSubmit: Bool {
        let hasRequiredContent =
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEditing {
            return hasRequiredContent && hasUnsavedChanges && !isSubmitting
        }
        return hasRequiredContent && selectedCategory != nil && !isSubmitting
    }

    var hasUnsavedChanges: Bool {
        if isEditing {
            return body != originalBody
                || title.trimmingCharacters(in: .whitespacesAndNewlines) != originalTitle
                || currentCategoryId != originalCategoryId
                || Self.normalizedTagNames(selectedTags) != Self.normalizedTagNames(originalTagNames)
        }
        return !title.isEmpty || !body.isEmpty || selectedCategory != nil || !selectedTags.isEmpty
    }

    private let api: DiscourseAPI
    private let editingAPI: any TopicEditingAPI

    init(
        api: DiscourseAPI,
        mode: TopicComposerMode = .create,
        editingAPI: (any TopicEditingAPI)? = nil
    ) {
        self.api = api
        self.mode = mode
        self.editingAPI = editingAPI ?? api
        if case .edit(let topic, let post) = mode {
            title = topic.title
            body = post.raw ?? ""
            selectedTags = topic.tags.map(\.name)
            originalTitle = topic.title
            originalBody = post.raw ?? ""
            originalCategoryId = topic.categoryId
            originalTags = topic.tags
            originalTagNames = topic.tags.map(\.name)
        }
    }

    func loadCategories() async {
        do {
            let list = try await api.fetchAllCategories()
            categories = list.categoryList.categories
            if selectedCategory == nil,
               let originalCategoryId,
               let category = findCategory(id: originalCategoryId)
            {
                selectedCategory = category
            }
        } catch {
            // Non-critical — user can retry
        }
    }

    func searchTags(query: String) async {
        let categoryId = selectedCategory?.id
        do {
            tagSuggestions = try await api.searchTags(query: query, categoryId: categoryId)
        } catch {
            tagSuggestions = []
        }
    }

    func submit() async throws -> TopicComposerSubmissionResult {
        let raw = body
        let topicTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        isSubmitting = true
        defer { isSubmitting = false }

        switch mode {
        case .create:
            guard let categoryId = selectedCategory?.id else {
                throw DiscourseAPIError(
                    messages: [String(localized: "compose.category.required")],
                    errorType: nil
                )
            }
            let response = try await api.createTopic(
                title: topicTitle,
                categoryId: categoryId,
                raw: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                tags: selectedTags
            )
            return .created(topicId: response.id)

        case .edit(let topic, let post):
            if raw != originalBody {
                guard let originalBody else { throw CancellationError() }
                _ = try await editingAPI.updatePost(id: post.id, raw: raw, originalRaw: originalBody)
                self.originalBody = raw
                bodyHasBeenSaved = true
                hasServerChanges = true
            }

            let metadataChanged =
                topicTitle != originalTitle
                || currentCategoryId != originalCategoryId
                || Self.normalizedTagNames(selectedTags) != Self.normalizedTagNames(originalTagNames)
            if metadataChanged {
                let editableTags = selectedTags.map { name in
                    originalTags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                        .map(DiscourseEditableTag.init)
                        ?? DiscourseEditableTag(name: name)
                }
                do {
                    try await editingAPI.updateTopic(
                        id: topic.id,
                        title: topicTitle,
                        originalTitle: originalTitle ?? topic.title,
                        categoryId: currentCategoryId,
                        tags: editableTags,
                        originalTags: originalTags
                    )
                } catch {
                    throw TopicEditSaveError(
                        underlyingError: error,
                        bodyWasSaved: bodyHasBeenSaved
                    )
                }
                originalTitle = topicTitle
                originalCategoryId = currentCategoryId
                originalTagNames = selectedTags
                hasServerChanges = true
            }
            return .updated
        }
    }

    func uploadImage(data: Data, filename: String) async throws -> DiscourseUploadResponse {
        isUploadingImage = true
        defer { isUploadingImage = false }
        return try await api.uploadImage(data: data, filename: filename)
    }

    // MARK: - Draft

    func currentDraft() -> TopicDraft {
        TopicDraft(
            title: title,
            body: body,
            categoryId: selectedCategory?.id,
            tags: selectedTags
        )
    }

    func loadDraft() -> TopicDraft? {
        guard !isEditing else { return nil }
        return TopicDraftStore.load(baseURL: api.baseURL)
    }

    func saveDraft() {
        guard !isEditing else { return }
        TopicDraftStore.save(currentDraft(), baseURL: api.baseURL)
    }

    func clearDraft() {
        guard !isEditing else { return }
        TopicDraftStore.clear(baseURL: api.baseURL)
    }

    /// Recursively searches loaded `categories` (and their subcategories) for an id.
    func findCategory(id: Int) -> DiscourseCategory? {
        for cat in categories {
            if cat.id == id { return cat }
            if let subs = cat.subcategoryList {
                for sub in subs where sub.id == id { return sub }
            }
        }
        return nil
    }

    private static func normalizedTagNames(_ tags: [String]) -> [String] {
        tags.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }.sorted()
    }
}
