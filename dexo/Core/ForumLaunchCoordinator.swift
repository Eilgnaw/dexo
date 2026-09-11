import Foundation

/// Resolves the launch screen from local state, without waiting for the network.
@MainActor
struct ForumLaunchCoordinator {
    static let defaultForumBaseURL = "https://discuss.python.org"
    static let defaultForumIconURL = "https://us1.discourse-cdn.com/flex002/uploads/python1/optimized/1X/4c06143de7870c35963b818b15b395092a434991_2_180x180.png"

    let database: DatabaseManager
    let settings: AppSettings

    func initializeDefaultForum() throws {
        if settings.defaultForumInitialization == nil {
            settings.defaultForumInitialization = database.wasCreatedOnOpen ? .pending : .completed
        }
        guard settings.defaultForumInitialization == .pending else { return }

        let forums = try database.fetchAllForums()
        let forum: ForumInstance
        if let existing = forums.first(where: { $0.baseURL == Self.defaultForumBaseURL }) {
            // Resume if the process ended after saving the forum but before saving preferences.
            forum = existing
        } else if forums.isEmpty {
            var newForum = ForumInstance.new(
                title: String(localized: "forum.default.python.title"),
                baseURL: Self.defaultForumBaseURL,
                iconURL: Self.defaultForumIconURL
            )
            forum = try database.saveForum(&newForum)
        } else {
            // The user has already configured a forum after an earlier initialization failure.
            settings.defaultForumInitialization = .completed
            return
        }

        settings.lastOpenedForumId = forum.id
        settings.autoOpenLastForum = true
        settings.hasShownAutoOpenPrompt = true
        settings.defaultForumInitialization = .completed
    }

    func startupForum(hasPendingNotification: Bool = false) throws -> ForumInstance? {
        guard !hasPendingNotification,
              settings.autoOpenLastForum,
              let lastID = settings.lastOpenedForumId else { return nil }
        return try database.fetchAllForums().first {
            $0.id == lastID && ForumURLPolicy.isSecure($0.baseURL)
        }
    }
}
