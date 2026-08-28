import Foundation

import Perception

protocol UserProfileAPIClient: AnyObject {
    var baseURL: String { get }
    var isLinuxDo: Bool { get }
    func fetchUserProfile(username: String) async throws -> DiscourseUserProfile
    func fetchUserSummary(username: String) async throws -> DiscourseUserSummary
    func followUser(username: String) async throws
    func unfollowUser(username: String) async throws
}

extension DiscourseAPI: UserProfileAPIClient {}

@Perceptible
final class UserProfileViewModel {
    enum LocalBlockToggleResult: Equatable {
        case blocked
        case unblocked
        case limitReached
    }

    var userProfile: DiscourseUserProfile?
    var summary: DiscourseUserSummary?
    var isLoading = false
    var isUpdatingFollow = false
    var isFollowing = false
    var errorMessage: String?

    private let api: any UserProfileAPIClient
    private let currentUsername: () -> String?
    let username: String

    /// Whether the current user is viewing their own profile.
    var isOwnProfile: Bool {
        currentUsername()?.caseInsensitiveCompare(username) == .orderedSame
    }

    var canSendMessage: Bool {
        userProfile?.canSendPrivateMessageToUser == true
    }

    /// The follow plugin is intentionally exposed only for linux.do profiles.
    /// A followed user remains actionable even if `can_follow` is false.
    var showsFollowButton: Bool {
        api.isLinuxDo
            && !isOwnProfile
            && (userProfile?.canFollow == true || isFollowing)
    }

    var showsLocalBlockButton: Bool {
        userProfile != nil && !isOwnProfile
    }

    var isLocallyBlocked: Bool {
        _ = AppSettings.shared.localBlocklistRevision
        return AppSettings.shared.isUserLocallyBlocked(
            username: username,
            baseURL: api.baseURL
        )
    }

    init(api: any UserProfileAPIClient, username: String, currentUsername: (() -> String?)? = nil) {
        self.api = api
        self.username = username
        let baseURL = api.baseURL
        self.currentUsername = currentUsername ?? { AuthManager.shared.username(for: baseURL) }
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let profileRequest = api.fetchUserProfile(username: username)
            async let summaryRequest = api.fetchUserSummary(username: username)
            let profile = try await profileRequest
            guard !Task.isCancelled else { return }
            // Publish identity/background immediately; optional statistics may be slower.
            userProfile = profile
            isFollowing = profile.isFollowed == true
            let userSummary = try? await summaryRequest
            guard !Task.isCancelled else { return }
            summary = userSummary
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func toggleFollow() async throws {
        guard api.isLinuxDo, !isOwnProfile, showsFollowButton, !isUpdatingFollow else { return }

        let wasFollowing = isFollowing
        isUpdatingFollow = true
        defer { isUpdatingFollow = false }

        if wasFollowing {
            try await api.unfollowUser(username: username)
        } else {
            try await api.followUser(username: username)
        }
        isFollowing = !wasFollowing
    }

    func toggleLocalBlock() -> LocalBlockToggleResult {
        if isLocallyBlocked {
            AppSettings.shared.unblockUserLocally(username: username, baseURL: api.baseURL)
            return .unblocked
        }

        switch AppSettings.shared.blockUserLocally(username: username, baseURL: api.baseURL) {
        case .added, .alreadyBlocked:
            return .blocked
        case .limitReached:
            return .limitReached
        }
    }
}
