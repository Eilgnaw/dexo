import Foundation

import Perception

enum AddForumResult {
    case added
    case challengeRequired(baseURL: String)
    case failed
}

@Perceptible
final class AddForumViewModel {
    typealias BasicInfoLoader = (String) async throws -> DiscourseBasicInfo

    var urlString = ""
    var isLoading = false
    var errorMessage: String?

    private let basicInfoLoader: BasicInfoLoader?

    init(basicInfoLoader: BasicInfoLoader? = nil) {
        self.basicInfoLoader = basicInfoLoader
    }

    func addForum() async -> AddForumResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = String(localized: "add_forum.error.empty_url")
            return .failed
        }

        let normalized: String
        do {
            normalized = try ForumURLPolicy.normalize(trimmed)
        } catch ForumURLPolicy.ValidationError.insecureScheme {
            errorMessage = String(localized: "add_forum.error.https_required")
            return .failed
        } catch {
            errorMessage = String(localized: "add_forum.error.invalid_url")
            return .failed
        }

        isLoading = true
        errorMessage = nil

        let tempForum = ForumInstance.new(title: "", baseURL: normalized)
        let api = DiscourseAPI(forum: tempForum)

        do {
            let info: DiscourseBasicInfo
            if let basicInfoLoader {
                info = try await basicInfoLoader(normalized)
            } else {
                info = try await api.fetchBasicInfo(includeStoredWebCookies: api.isLinuxDo)
            }

            var forum = ForumInstance.new(
                title: info.title,
                baseURL: normalized,
                iconURL: resolveIconURL(base: normalized, info: info)
            )
            forum.sortOrder = (try? DatabaseManager.shared.nextForumSortOrder()) ?? 0
            try DatabaseManager.shared.saveForum(&forum)
            isLoading = false
            return .added
        } catch {
            if api.isLinuxDo,
               let apiError = error as? DiscourseAPIError,
               apiError.isChallengeRequired
            {
                errorMessage = String(localized: "add_forum.error.challenge")
                isLoading = false
                return .challengeRequired(baseURL: normalized)
            }

            errorMessage = String(localized: "add_forum.error.connect \(error.localizedDescription)")
            isLoading = false
            return .failed
        }
    }

    private func resolveIconURL(base: String, info: DiscourseBasicInfo) -> String? {
        // Prefer apple touch icon (180x180) > logo > favicon
        guard let path = info.appleTouchIconURL ?? info.logoURL ?? info.faviconURL else { return nil }
        if path.hasPrefix("//") {
            return "https:" + path
        }
        if let url = URL(string: path), url.scheme != nil {
            return url.scheme?.lowercased() == "https" ? url.absoluteString : nil
        }
        return path.hasPrefix("/") ? base + path : base + "/" + path
    }
}
