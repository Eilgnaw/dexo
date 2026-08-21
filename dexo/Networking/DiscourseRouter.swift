import Alamofire
import Foundation

/// Which Discourse private-message view to fetch. `inbox` is the default
/// `private-messages` list; `sent` is `private-messages-sent` (messages the
/// user started, including ones the recipient hasn't replied to yet).
enum PrivateMessageFilter {
    case inbox
    case sent

    /// URL path segment Discourse uses for this view.
    var pathSegment: String {
        switch self {
        case .inbox: return "private-messages"
        case .sent: return "private-messages-sent"
        }
    }
}

enum DiscourseRouter {
    case topicFeed(mode: TopicFeedMode, page: Int)
    case readTopics(page: Int)
    case categories(page: Int)
    case categoryChildren(parentCategoryID: Int, page: Int)
    case topic(id: Int, nearPostNumber: Int? = nil, filter: String? = nil)
    case topicPosts(topicId: Int, postIds: [Int])
    /// `GET /n/{slug}/{id}.json` — Discourse's nested-replies view. Each call
    /// returns one page of root-level replies (~20) with their full subtrees;
    /// `has_more_roots` in the response signals whether further `page=N+1`
    /// requests are needed.
    case nestedTopic(id: Int, slug: String?, sort: String?, page: Int)
    /// `GET /n/{slug}/{topicId}/children/{postNumber}.json` — fetches the
    /// direct replies under one post in the nested view. The top-level
    /// `/n/...` payload inlines at most three children per node; this endpoint
    /// returns the full (paginated) direct-reply list so the UI can expand a
    /// "view more replies" affordance. `depth=1` keeps it to direct children.
    case nestedChildren(topicId: Int, postNumber: Int, slug: String?, sort: String?, page: Int)
    case post(id: Int)
    case postByNumber(topicId: Int, postNumber: Int)
    case notifications(limit: Int? = nil, filter: String? = nil)
    case privateMessages(username: String, filter: PrivateMessageFilter)
    case createTopic
    case updateTopic(id: Int)
    case updatePost(id: Int)
    case createBoost(postId: Int)
    case postReplies(postId: Int)
    case categoryTopics(slug: String, id: Int, feedMode: TopicFeedMode?, page: Int)
    case tagTopics(name: String, page: Int)
    case siteInfo
    case siteSettings
    case basicInfo
    case currentUser
    case emojis
    case search(term: String, page: Int)
    case tags
    case tagSearch(query: String, categoryId: Int?)
    case bookmarks(username: String)
    case userSummary(username: String)
    case userProfile(username: String)
    case createBookmark
    case deleteBookmark(id: Int)
    case deleteBoost(id: Int)
    case uploadImage
    case toggleReaction(postId: Int, reactionId: String)
    case likePost
    case unlikePost(postId: Int)
    case acceptSolution
    case unacceptSolution
    case votePoll
    case removePollVote
    case markNotificationRead
    case topicTimings
    case createPrivateMessage
    case flagPost
    case followedUsers(username: String)
    case followUser(username: String)
    case unfollowUser(username: String)
    case messageBusPoll(clientId: String)
    case subscribePush
    case unsubscribePush

    var method: HTTPMethod {
        switch self {
        case .createTopic, .createBookmark, .createBoost, .uploadImage, .topicTimings, .messageBusPoll, .likePost, .acceptSolution, .unacceptSolution, .createPrivateMessage, .flagPost, .subscribePush, .unsubscribePush:
            return .post
        case .updateTopic, .updatePost, .toggleReaction, .votePoll, .markNotificationRead, .followUser:
            return .put
        case .deleteBookmark, .deleteBoost, .removePollVote, .unlikePost, .unfollowUser:
            return .delete
        default:
            return .get
        }
    }

    var path: String {
        switch self {
        case .topicFeed(let mode, let page):
            var path = "/\(mode.listPathComponent).json?page=\(page)"
            if let order = mode.orderQueryValue {
                path += "&order=\(order)"
            }
            return path
        case .readTopics(let page):
            return "/read.json?page=\(page)"
        case .categories(let page):
            return "/categories.json?include_subcategories=true&page=\(page)"
        case .categoryChildren(let parentCategoryID, let page):
            return "/categories.json?include_subcategories=true&parent_category_id=\(parentCategoryID)&page=\(page)"
        case .topic(let id, let nearPostNumber, let filter):
            // `/t/{id}/{N}.json` returns a batch of posts ending at floor N — used
            // for deep-link entry (notification tap, reply jump) so we avoid
            // fetching the OP batch just to throw it away. `track_visit` updates
            // read state; `forceLoad` bypasses cache so a just-created reply shows.
            var params: [String] = []
            let basePath: String
            if let nearPostNumber, nearPostNumber > 1 {
                basePath = "/t/\(id)/\(nearPostNumber).json"
                params.append("track_visit=true")
                params.append("forceLoad=true")
            } else {
                basePath = "/t/\(id).json"
            }
            if let filter, !filter.isEmpty {
                params.append("filter=\(filter)")
            }
            return params.isEmpty ? basePath : basePath + "?" + params.joined(separator: "&")
        case .topicPosts(let topicId, let postIds):
            let ids = postIds.map { "post_ids[]=\($0)" }.joined(separator: "&")
            return "/t/\(topicId)/posts.json?\(ids)"
        case .nestedTopic(let id, let slug, let sort, let page):
            // Discourse accepts `-` as a slug placeholder, so first opens
            // (when we don't have the slug yet) still work.
            let slugComponent = slug.map { $0.isEmpty ? "-" : $0 } ?? "-"
            var params: [String] = []
            if let sort, !sort.isEmpty { params.append("sort=\(sort)") }
            if page > 0 { params.append("page=\(page)") }
            let query = params.isEmpty ? "" : "?" + params.joined(separator: "&")
            return "/n/\(slugComponent)/\(id).json\(query)"
        case .nestedChildren(let topicId, let postNumber, let slug, let sort, let page):
            let slugComponent = slug.map { $0.isEmpty ? "-" : $0 } ?? "-"
            var params: [String] = ["page=\(page)"]
            if let sort, !sort.isEmpty { params.append("sort=\(sort)") }
            params.append("depth=1")
            return "/n/\(slugComponent)/\(topicId)/children/\(postNumber).json?" + params.joined(separator: "&")
        case .post(let id):
            return "/posts/\(id).json"
        case .postByNumber(let topicId, let postNumber):
            return "/posts/by_number/\(topicId)/\(postNumber).json"
        case .notifications(let limit, let filter):
            var path = "/notifications.json"
            var params: [String] = []
            if let limit { params.append("limit=\(limit)") }
            if let filter { params.append("filter=\(filter)") }
            if !params.isEmpty { path += "?" + params.joined(separator: "&") }
            return path
        case .privateMessages(let username, let filter):
            return "/topics/\(filter.pathSegment)/\(username).json"
        case .createTopic:
            return "/posts.json"
        case .updateTopic(let id):
            return "/t/-/\(id).json"
        case .updatePost(let id):
            return "/posts/\(id).json"
        case .createBoost(let postId):
            return "/discourse-boosts/posts/\(postId)/boosts"
        case .postReplies(let postId):
            return "/posts/\(postId)/replies.json"
        case .categoryTopics(let slug, let id, let feedMode, let page):
            guard let feedMode else {
                return "/c/\(slug)/\(id).json?page=\(page)"
            }
            var path = "/c/\(slug)/\(id)/l/\(feedMode.listPathComponent).json?page=\(page)"
            if let order = feedMode.orderQueryValue {
                path += "&order=\(order)"
            }
            return path
        case .tagTopics(let name, let page):
            return "/tag/\(name).json?page=\(page)"
        case .siteInfo:
            return "/site.json"
        case .siteSettings:
            return "/site/settings.json"
        case .basicInfo:
            return "/site/basic-info.json"
        case .currentUser:
            return "/session/current.json"
        case .emojis:
            return "/emojis.json"
        case .search(let term, let page):
            let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
            return "/search.json?q=\(encoded)&page=\(page)"
        case .tags:
            return "/tags.json"
        case .tagSearch(let query, let categoryId):
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            var path = "/tags/filter/search?q=\(encoded)&limit=5"
            if let categoryId {
                path += "&categoryId=\(categoryId)&filterForInput=true"
            }
            return path
        case .bookmarks(let username):
            return "/u/\(username)/bookmarks.json"
        case .userSummary(let username):
            return "/u/\(username)/summary.json"
        case .userProfile(let username):
            return "/u/\(username).json"
        case .createBookmark:
            return "/bookmarks.json"
        case .deleteBookmark(let id):
            return "/bookmarks/\(id).json"
        case .deleteBoost(let id):
            return "/discourse-boosts/boosts/\(id)"
        case .uploadImage:
            return "/uploads.json"
        case .toggleReaction(let postId, let reactionId):
            let encoded = reactionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? reactionId
            return "/discourse-reactions/posts/\(postId)/custom-reactions/\(encoded)/toggle.json"
        case .likePost:
            return "/post_actions"
        case .unlikePost(let postId):
            // post_action_type_id=2 is "like"
            return "/post_actions/\(postId)?post_action_type_id=2"
        case .acceptSolution:
            return "/solution/accept.json"
        case .unacceptSolution:
            return "/solution/unaccept.json"
        case .votePoll:
            return "/polls/vote"
        case .removePollVote:
            return "/polls/vote"
        case .markNotificationRead:
            return "/notifications/mark-read"
        case .topicTimings:
            return "/topics/timings"
        case .createPrivateMessage:
            return "/posts.json"
        case .flagPost:
            return "/post_actions"
        case .followedUsers(let username):
            return "/u/\(username)/follow/following.json"
        case .followUser(let username):
            return "/follow/\(username).json"
        case .unfollowUser(let username):
            return "/follow/\(username).json"
        case .messageBusPoll(let clientId):
            return "/message-bus/\(clientId)/poll"
        case .subscribePush:
            return "/push_notifications/subscribe.json"
        case .unsubscribePush:
            return "/push_notifications/unsubscribe.json"
        }
    }
}
