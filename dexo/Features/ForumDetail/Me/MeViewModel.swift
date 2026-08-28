import Foundation

import Perception

protocol MeProfileAPIClient: AnyObject {
    var baseURL: String { get }
    var isLinuxDo: Bool { get }
    func fetchCurrentUser() async throws -> DiscourseCurrentUser
    func fetchNotifications(limit: Int?, filter: String?) async throws -> DiscourseNotificationList
    func fetchUserProfile(username: String) async throws -> DiscourseUserProfile
    func fetchUserSummary(username: String) async throws -> DiscourseUserSummary
}

extension DiscourseAPI: MeProfileAPIClient {}

@Perceptible
final class MeViewModel {
    var currentUser: DiscourseCurrentUser?
    var userProfile: DiscourseUserProfile?
    var summary: DiscourseUserSummary?
    var isLoading = false
    var requiresLogin = false
    var errorMessage: String?

    private let api: any MeProfileAPIClient
    private let cacheStore: ProfileCacheStore
    private let usernameProvider: () -> String?
    private let cacheUsername: (String) -> Void
    private var requestGeneration = 0

    init(
        api: any MeProfileAPIClient,
        cacheStore: ProfileCacheStore = .shared,
        usernameProvider: (() -> String?)? = nil,
        cacheUsername: ((String) -> Void)? = nil
    ) {
        self.api = api
        self.cacheStore = cacheStore
        let baseURL = api.baseURL
        self.usernameProvider = usernameProvider ?? { AuthManager.shared.username(for: baseURL) }
        self.cacheUsername = cacheUsername ?? { AuthManager.shared.setCachedUsername($0, for: baseURL) }
    }

    func loadProfile(forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        requestGeneration += 1
        let generation = requestGeneration
        isLoading = true
        errorMessage = nil
        defer {
            if generation == requestGeneration { isLoading = false }
        }

        let cachedEntry = cacheStore.load(for: api.baseURL)
        let cachedUsername = cachedEntry?.username
        let knownUsername = usernameProvider()
        let usernameMatches = knownUsername == nil || knownUsername == cachedUsername

        if let cachedEntry, usernameMatches {
            if currentUser == nil {
                apply(profile: cachedEntry.profile, summary: cachedEntry.summary)
            }
            if !forceRefresh, cachedEntry.isFresh { return }
        }

        do {
            // Prefer the AuthManager cache (populated at login), but fall back
            // to `/session/current.json` when it's empty — `fetchAndCacheUsername`
            // can fail silently (both primary and fallback wrapped in `try?`),
            // leaving the cache unset even though the API key was saved. Without
            // this fallback the profile screen would stay empty after login.
            let username: String
            if let cached = knownUsername {
                username = cached
            } else if let cachedUsername, usernameMatches {
                username = cachedUsername
                cacheUsername(username)
            } else if api.isLinuxDo {
                // linux.do's /session/current.json returns empty; use notifications instead.
                let notifList = try await api.fetchNotifications(limit: nil, filter: nil)
                guard generation == requestGeneration, !Task.isCancelled else { return }
                guard let resolved = notifList.username else {
                    throw DiscourseAPIError(messages: ["Unable to resolve username"], errorType: "not_logged_in")
                }
                username = resolved
                cacheUsername(username)
            } else {
                let current = try await api.fetchCurrentUser()
                guard generation == requestGeneration, !Task.isCancelled else { return }
                username = current.username
                cacheUsername(username)
            }

            async let profileRequest = api.fetchUserProfile(username: username)
            async let summaryRequest = api.fetchUserSummary(username: username)
            let profile = try await profileRequest
            guard generation == requestGeneration, !Task.isCancelled else { return }
            // Identity and background need not wait for the optional statistics.
            let previousSummary = currentUser?.username == profile.username ? summary : nil
            apply(profile: profile, summary: previousSummary)
            let userSummary = try? await summaryRequest
            guard generation == requestGeneration, !Task.isCancelled else { return }
            summary = userSummary
            cacheStore.save(profile: profile, summary: userSummary, for: api.baseURL)
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            if let apiError = error as? DiscourseAPIError, apiError.isNotLoggedIn || apiError.isForbidden {
                requiresLogin = true
            } else if currentUser == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    func reload() async {
        requiresLogin = false
        errorMessage = nil
        await loadProfile(forceRefresh: true)
    }

    func clearCachedProfile() {
        requestGeneration += 1
        isLoading = false
        errorMessage = nil
        cacheStore.remove(for: api.baseURL)
        currentUser = nil
        userProfile = nil
        summary = nil
    }

    private func apply(profile: DiscourseUserProfile, summary: DiscourseUserSummary?) {
        currentUser = DiscourseCurrentUser(
            id: profile.id,
            username: profile.username,
            name: profile.name,
            avatarTemplate: profile.avatarTemplate,
            unreadNotifications: nil,
            unreadPrivateMessages: nil,
            unreadHighPriorityNotifications: nil
        )
        userProfile = profile
        self.summary = summary
    }
}
