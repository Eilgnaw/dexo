import Foundation

struct DiscourseCurrentUserResponse: Decodable {
    let currentUser: DiscourseCurrentUser

    enum CodingKeys: String, CodingKey {
        case currentUser = "current_user"
    }
}

struct DiscourseCurrentUser: Decodable {
    let id: Int
    let username: String
    let name: String?
    let avatarTemplate: String?
    let unreadNotifications: Int?
    let unreadPrivateMessages: Int?
    let unreadHighPriorityNotifications: Int?

    enum CodingKeys: String, CodingKey {
        case id, username, name
        case avatarTemplate = "avatar_template"
        case unreadNotifications = "unread_notifications"
        case unreadPrivateMessages = "unread_private_messages"
        case unreadHighPriorityNotifications = "unread_high_priority_notifications"
    }
}

struct DiscourseFollowedUser: Decodable, Equatable, Identifiable {
    let id: Int
    let username: String
    let name: String?
    let avatarTemplate: String?

    enum CodingKeys: String, CodingKey {
        case id, username, name
        case avatarTemplate = "avatar_template"
    }
}

struct DiscourseUserProfileResponse: Decodable {
    let user: DiscourseUserProfile
}

struct DiscourseUserProfile: Codable {
    let id: Int
    let username: String
    let name: String?
    let avatarTemplate: String?
    let cardBackgroundUploadUrl: String?
    let title: String?
    let trustLevel: Int?
    let badgeCount: Int?
    let profileViewCount: Int?
    let timeRead: Int?
    let createdAt: String?
    let bioCooked: String?
    let flairName: String?
    let flairUrl: String?
    let canSendPrivateMessageToUser: Bool?
    let canFollow: Bool?
    let isFollowed: Bool?

    enum CodingKeys: String, CodingKey {
        case id, username, name, title
        case avatarTemplate = "avatar_template"
        case cardBackgroundUploadUrl = "card_background_upload_url"
        case trustLevel = "trust_level"
        case badgeCount = "badge_count"
        case profileViewCount = "profile_view_count"
        case timeRead = "time_read"
        case createdAt = "created_at"
        case bioCooked = "bio_cooked"
        case flairName = "flair_name"
        case flairUrl = "flair_url"
        case canSendPrivateMessageToUser = "can_send_private_message_to_user"
        case canFollow = "can_follow"
        case isFollowed = "is_followed"
    }

    /// Discourse returns upload URLs as absolute, protocol-relative, or site-relative paths.
    func cardBackgroundURL(relativeTo assetBaseURL: String) -> URL? {
        guard let path = cardBackgroundUploadUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              let base = URL(string: assetBaseURL.hasSuffix("/") ? assetBaseURL : assetBaseURL + "/"),
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
