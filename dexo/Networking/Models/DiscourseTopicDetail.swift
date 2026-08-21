import Foundation

struct DiscourseTopicDetail: Decodable {
    let id: Int
    let title: String
    let fancyTitle: String?
    let postsCount: Int
    let replyCount: Int
    let categoryId: Int?
    let createdAt: String
    let tags: [Tag]
    var postStream: PostStream
    let validReactions: [String]
    /// Solved-plugin summaries rendered below the OP. Modern Discourse
    /// returns an array (and can optionally allow multiple solutions); older
    /// servers expose one `accepted_answer` object instead.
    var acceptedAnswers: [AcceptedAnswer]
    var hasAcceptedAnswer: Bool
    /// Highest post number the authenticated user has read in this topic.
    /// `nil` for anonymous fetches. Used by the jump-to-floor sheet to offer a
    /// "first unread" shortcut.
    let lastReadPostNumber: Int?
    let archetype: String?

    enum CodingKeys: String, CodingKey {
        case id, title, tags, archetype
        case fancyTitle = "fancy_title"
        case postsCount = "posts_count"
        case replyCount = "reply_count"
        case categoryId = "category_id"
        case createdAt = "created_at"
        case postStream = "post_stream"
        case validReactions = "valid_reactions"
        case acceptedAnswers = "accepted_answers"
        case acceptedAnswer = "accepted_answer"
        case hasAcceptedAnswer = "has_accepted_answer"
        case lastReadPostNumber = "last_read_post_number"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        fancyTitle = (try? container.decodeIfPresent(String.self, forKey: .fancyTitle))?.decodingHTMLEntities()
        postsCount = try container.decode(Int.self, forKey: .postsCount)
        replyCount = try container.decode(Int.self, forKey: .replyCount)
        categoryId = try? container.decodeIfPresent(Int.self, forKey: .categoryId)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        tags = (try? container.decodeIfPresent([Tag].self, forKey: .tags)) ?? []
        postStream = try container.decode(PostStream.self, forKey: .postStream)
        validReactions = (try? container.decodeIfPresent([String].self, forKey: .validReactions)) ?? []
        if let answers = try? container.decodeIfPresent([AcceptedAnswer].self, forKey: .acceptedAnswers) {
            acceptedAnswers = answers
        } else if let answer = try? container.decodeIfPresent(AcceptedAnswer.self, forKey: .acceptedAnswer) {
            acceptedAnswers = [answer]
        } else {
            acceptedAnswers = []
        }
        hasAcceptedAnswer =
            (try? container.decodeIfPresent(Bool.self, forKey: .hasAcceptedAnswer))
            ?? !acceptedAnswers.isEmpty
        lastReadPostNumber = try? container.decodeIfPresent(Int.self, forKey: .lastReadPostNumber)
        archetype = try? container.decodeIfPresent(String.self, forKey: .archetype)
    }

    /// Memberwise initializer used to synthesize a `DiscourseTopicDetail` from
    /// the nested-view response. Kept alongside the decoder init so existing
    /// code that depends on the topic shape (tags, validReactions, etc.) keeps
    /// working in tree mode.
    init(
        id: Int,
        title: String,
        fancyTitle: String?,
        postsCount: Int,
        replyCount: Int,
        categoryId: Int?,
        createdAt: String,
        tags: [Tag],
        postStream: PostStream,
        validReactions: [String],
        acceptedAnswers: [AcceptedAnswer] = [],
        hasAcceptedAnswer: Bool? = nil,
        lastReadPostNumber: Int?,
        archetype: String? = nil
    ) {
        self.id = id
        self.title = title
        self.fancyTitle = fancyTitle
        self.postsCount = postsCount
        self.replyCount = replyCount
        self.categoryId = categoryId
        self.createdAt = createdAt
        self.tags = tags
        self.postStream = postStream
        self.validReactions = validReactions
        self.acceptedAnswers = acceptedAnswers
        self.hasAcceptedAnswer = hasAcceptedAnswer ?? !acceptedAnswers.isEmpty
        self.lastReadPostNumber = lastReadPostNumber
        self.archetype = archetype
    }

    struct PostStream: Decodable {
        var posts: [Post]
        let stream: [Int]?
    }

    struct Tag: Decodable {
        let id: Int
        let name: String
        let slug: String
    }

    /// A compact solved-answer entry embedded in a topic response. `cooked`
    /// is an optional server-configured excerpt, not the authoritative post
    /// body; selecting the row always jumps to the real post.
    struct AcceptedAnswer: Decodable {
        let id: Int?
        let name: String?
        let username: String
        let avatarTemplate: String?
        let createdAt: String?
        let cooked: String?
        let postNumber: Int
        let topicId: Int?
        let url: String?
        let accepterName: String?
        let accepterUsername: String?

        enum CodingKeys: String, CodingKey {
            case id, name, username, cooked, url, excerpt
            case avatarTemplate = "avatar_template"
            case createdAt = "created_at"
            case postNumber = "post_number"
            case topicId = "topic_id"
            case accepterName = "accepter_name"
            case accepterUsername = "accepter_username"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decodeIfPresent(Int.self, forKey: .id)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            username = (try? container.decodeIfPresent(String.self, forKey: .username)) ?? ""
            avatarTemplate = try? container.decodeIfPresent(String.self, forKey: .avatarTemplate)
            createdAt = try? container.decodeIfPresent(String.self, forKey: .createdAt)
            cooked =
                (try? container.decodeIfPresent(String.self, forKey: .cooked))
                ?? (try? container.decodeIfPresent(String.self, forKey: .excerpt))
            postNumber = (try? container.decodeIfPresent(Int.self, forKey: .postNumber)) ?? 0
            topicId = try? container.decodeIfPresent(Int.self, forKey: .topicId)
            url = try? container.decodeIfPresent(String.self, forKey: .url)
            accepterName = try? container.decodeIfPresent(String.self, forKey: .accepterName)
            accepterUsername = try? container.decodeIfPresent(String.self, forKey: .accepterUsername)
        }

        init(post: Post) {
            id = post.id
            name = post.name
            username = post.username
            avatarTemplate = post.avatarTemplate
            createdAt = post.createdAt
            cooked = nil
            postNumber = post.postNumber
            topicId = nil
            url = nil
            accepterName = nil
            accepterUsername = nil
        }
    }

    struct ReplyToUser: Decodable {
        let username: String
        let avatarTemplate: String?

        enum CodingKeys: String, CodingKey {
            case username
            case avatarTemplate = "avatar_template"
        }
    }

    struct Reaction: Decodable {
        let id: String
        let type: String
        /// Present in the post's `reactions` array; absent in `current_user_reaction`.
        let count: Int?
        /// Only meaningful on `current_user_reaction` (whether the user can still toggle off).
        let canUndo: Bool?

        enum CodingKeys: String, CodingKey {
            case id, type, count
            case canUndo = "can_undo"
        }
    }

    /// One entry in a post's `actions_summary` array. id 2 = "like" (PostAction).
    struct ActionSummary: Decodable {
        let id: Int
        let count: Int?
        let acted: Bool?
        let canUndo: Bool?
        let canAct: Bool?

        enum CodingKeys: String, CodingKey {
            case id, count, acted
            case canUndo = "can_undo"
            case canAct = "can_act"
        }
    }

    struct BoostUser: Decodable, Sendable {
        let id: Int
        let username: String
        let name: String?
        let avatarTemplate: String?
//        let animatedAvatar: String?

        enum CodingKeys: String, CodingKey {
            case id, username, name
            case avatarTemplate = "avatar_template"
//            case animatedAvatar = "animated_avatar"
        }
    }

    struct Poll: Decodable {
        let name: String
        let type: String          // "regular" or "multiple"
        let status: String        // "open" or "closed"
        let isPublic: Bool
        let results: String       // "always", "on_vote", "on_close", "staff_only"
        let min: Int?
        let max: Int?
        let options: [PollOption]
        let voters: Int
        let chartType: String?
        let title: String?

        enum CodingKeys: String, CodingKey {
            case name, type, status, results, min, max, options, voters, title
            case isPublic = "public"
            case chartType = "chart_type"
        }

        // Custom init so a missing optional-ish field (type / status / results /
        // public / voters) doesn't silently drop the entire post.polls array
        // via `(try? decodeIfPresent([Poll].self, ...)) ?? []`. Only `name` and
        // `options` are truly required to render.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            options = (try? c.decode([PollOption].self, forKey: .options)) ?? []
            type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "regular"
            status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "open"
            isPublic = (try? c.decodeIfPresent(Bool.self, forKey: .isPublic)) ?? false
            results = (try? c.decodeIfPresent(String.self, forKey: .results)) ?? "always"
            min = try? c.decodeIfPresent(Int.self, forKey: .min)
            max = try? c.decodeIfPresent(Int.self, forKey: .max)
            voters = (try? c.decodeIfPresent(Int.self, forKey: .voters)) ?? 0
            chartType = try? c.decodeIfPresent(String.self, forKey: .chartType)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
        }
    }

    struct PollOption: Decodable {
        let id: String
        let html: String
        let votes: Int

        enum CodingKeys: String, CodingKey {
            case id, html, votes
        }

        // Number-type polls and pre-vote `results: "on_close"` responses omit
        // the `votes` field entirely. Default to 0 so the whole poll decode
        // doesn't fall over and leave `post.polls` empty.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            html = try c.decode(String.self, forKey: .html)
            votes = (try? c.decodeIfPresent(Int.self, forKey: .votes)) ?? 0
        }
    }

    struct Boost: Decodable, Identifiable, Sendable {
        let id: Int
        let cooked: String
        let canDelete: Bool?
        let canFlag: Bool
        let user: BoostUser

        enum CodingKeys: String, CodingKey {
            case id, cooked, user
            case canDelete = "can_delete"
            case canFlag = "can_flag"
        }
    }

    struct Post: Decodable, Identifiable {
        let id: Int
        let name: String?
        let username: String
        let avatarTemplate: String?
        let createdAt: String
        let cooked: String
        let raw: String?
        let canEdit: Bool
        let yours: Bool
        let postNumber: Int
        let replyCount: Int
        let replyToPostNumber: Int?
        let replyToUser: ReplyToUser?
        let actionCode: String?
        let userTitle: String?
        let flairUrl: String?
        let flairBgColor: String?
        let bookmarked: Bool
        let bookmarkId: Int?
        let reactions: [Reaction]
        let reactionUsersCount: Int
        let currentUserReaction: Reaction?
        let currentUserUsedMainReaction: Bool
        let actionsSummary: [ActionSummary]
        var acceptedAnswer: Bool
        var canAcceptAnswer: Bool
        var canUnacceptAnswer: Bool
        var topicAcceptedAnswer: Bool

        /// Standard Discourse "like" PostAction state (id == 2 in actions_summary).
        var likeAction: ActionSummary? { actionsSummary.first(where: { $0.id == 2 }) }
        var isLikedByCurrentUser: Bool { likeAction?.acted == true }
        var likeCount: Int { likeAction?.count ?? 0 }
        /// Editing is deliberately limited to the current user's own posts,
        /// even when a moderator account could edit somebody else's content.
        var isEditableByCurrentUser: Bool { canEdit && yours }
        /// Whether the current user can flag/report this post (ids 3,4,7,8).
        var canFlag: Bool { actionsSummary.contains { [3, 4, 7, 8].contains($0.id) && $0.canAct == true } }
        var boosts: [Boost]
        var canBoost: Bool
        var polls: [Poll]
        var pollsVotes: [String: [String]]
        /// Populated only when this post was decoded from the `/n/...` nested
        /// view endpoint; flat-stream fetches leave it nil. The view-model
        /// walks this to build its DFS render order without having to infer
        /// parent/child links from `replyToPostNumber`.
        var children: [Post]?
        /// Number of *direct* replies this post has on the server. In the
        /// nested view the server inlines at most three children per node, so
        /// `directReplyCount > (children?.count ?? 0)` signals there are more
        /// direct replies to fetch via the `/n/.../children/{n}.json` endpoint.
        /// The view-model uses the gap to render a "view N more replies" row.
        var directReplyCount: Int
        /// Total descendants (direct + indirect) under this post per the
        /// server. Decoded for completeness / future use; the view-model keys
        /// the "view more" affordance off `directReplyCount`.
        let totalDescendantCount: Int
        /// True for placeholder entries the nested-replies endpoint inserts
        /// in place of deleted posts. These have empty `cooked`, no author,
        /// and the only meaningful fields are `post_number` + the tree
        /// structure on `children`. The cell renders them as a slim
        /// "(deleted)" marker so connector lines stay intact without
        /// claiming a real author / content.
        let deletedPostPlaceholder: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, username, cooked, raw, yours
            case canEdit = "can_edit"
            case avatarTemplate = "avatar_template"
            case createdAt = "created_at"
            case postNumber = "post_number"
            case replyCount = "reply_count"
            case replyToPostNumber = "reply_to_post_number"
            case replyToUser = "reply_to_user"
            case actionCode = "action_code"
            case userTitle = "user_title"
            case flairUrl = "flair_url"
            case flairBgColor = "flair_bg_color"
            case bookmarked
            case bookmarkId = "bookmark_id"
            case reactions
            case reactionUsersCount = "reaction_users_count"
            case currentUserReaction = "current_user_reaction"
            case currentUserUsedMainReaction = "current_user_used_main_reaction"
            case actionsSummary = "actions_summary"
            case acceptedAnswer = "accepted_answer"
            case canAcceptAnswer = "can_accept_answer"
            case canUnacceptAnswer = "can_unaccept_answer"
            case topicAcceptedAnswer = "topic_accepted_answer"
            case boosts
            case canBoost = "can_boost"
            case polls
            case pollsVotes = "polls_votes"
            case children
            case directReplyCount = "direct_reply_count"
            case totalDescendantCount = "total_descendant_count"
            case deletedPostPlaceholder = "deleted_post_placeholder"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            // Some nested-replies sorts (new/old) include anonymized or
            // deleted authors with the `username` key omitted entirely. Don't
            // hard-fail the whole tree decode in that case — fall back to a
            // placeholder so the post still renders.
            username = (try? container.decodeIfPresent(String.self, forKey: .username)) ?? ""
            name = (try? container.decodeIfPresent(String.self, forKey: .name))
                .flatMap { $0.isEmpty ? nil : $0 } ?? (username.isEmpty ? nil : username)
            avatarTemplate = try? container.decodeIfPresent(String.self, forKey: .avatarTemplate)
            createdAt = (try? container.decodeIfPresent(String.self, forKey: .createdAt)) ?? ""
            cooked = (try? container.decodeIfPresent(String.self, forKey: .cooked)) ?? ""
            raw = try? container.decodeIfPresent(String.self, forKey: .raw)
            canEdit = (try? container.decodeIfPresent(Bool.self, forKey: .canEdit)) ?? false
            yours = (try? container.decodeIfPresent(Bool.self, forKey: .yours)) ?? false
            postNumber = (try? container.decodeIfPresent(Int.self, forKey: .postNumber)) ?? 0
            replyCount = (try? container.decodeIfPresent(Int.self, forKey: .replyCount)) ?? 0
            replyToPostNumber = try? container.decodeIfPresent(Int.self, forKey: .replyToPostNumber)
            replyToUser = try? container.decodeIfPresent(ReplyToUser.self, forKey: .replyToUser)
            actionCode = try? container.decodeIfPresent(String.self, forKey: .actionCode)
            userTitle = try? container.decodeIfPresent(String.self, forKey: .userTitle)
            flairUrl = try? container.decodeIfPresent(String.self, forKey: .flairUrl)
            flairBgColor = try? container.decodeIfPresent(String.self, forKey: .flairBgColor)
            bookmarked = (try? container.decodeIfPresent(Bool.self, forKey: .bookmarked)) ?? false
            bookmarkId = try? container.decodeIfPresent(Int.self, forKey: .bookmarkId)
            reactions = (try? container.decodeIfPresent([Reaction].self, forKey: .reactions)) ?? []
            reactionUsersCount = (try? container.decodeIfPresent(Int.self, forKey: .reactionUsersCount)) ?? 0
            currentUserReaction = try? container.decodeIfPresent(Reaction.self, forKey: .currentUserReaction)
            currentUserUsedMainReaction = (try? container.decodeIfPresent(Bool.self, forKey: .currentUserUsedMainReaction)) ?? false
            actionsSummary = (try? container.decodeIfPresent([ActionSummary].self, forKey: .actionsSummary)) ?? []
            acceptedAnswer = (try? container.decodeIfPresent(Bool.self, forKey: .acceptedAnswer)) ?? false
            canAcceptAnswer = (try? container.decodeIfPresent(Bool.self, forKey: .canAcceptAnswer)) ?? false
            canUnacceptAnswer = (try? container.decodeIfPresent(Bool.self, forKey: .canUnacceptAnswer)) ?? false
            topicAcceptedAnswer = (try? container.decodeIfPresent(Bool.self, forKey: .topicAcceptedAnswer)) ?? false
            boosts = (try? container.decodeIfPresent([Boost].self, forKey: .boosts)) ?? []
            canBoost = (try? container.decodeIfPresent(Bool.self, forKey: .canBoost)) ?? false
            polls = (try? container.decodeIfPresent([Poll].self, forKey: .polls)) ?? []
            pollsVotes = (try? container.decodeIfPresent([String: [String]].self, forKey: .pollsVotes)) ?? [:]
            children = try? container.decodeIfPresent([Post].self, forKey: .children)
            directReplyCount = (try? container.decodeIfPresent(Int.self, forKey: .directReplyCount)) ?? 0
            totalDescendantCount = (try? container.decodeIfPresent(Int.self, forKey: .totalDescendantCount)) ?? 0
            deletedPostPlaceholder = (try? container.decodeIfPresent(Bool.self, forKey: .deletedPostPlaceholder)) ?? false
        }
    }
}

/// Response shape returned by `PUT /posts/{id}.json`.
struct DiscourseUpdatePostResponse: Decodable {
    let post: DiscourseTopicDetail.Post
}

/// Response shape from `GET /n/{slug}/{id}.json` — Discourse's nested-replies
/// view. `roots` holds the top-level replies (each with its full subtree on
/// `children`); the OP itself is delivered separately on `op_post`. Pagination
/// applies to the number of *root* replies returned, signalled by
/// `hasMoreRoots` + `page`.
///
/// `topic` and `opPost` are only sent on the first page; subsequent pages drop
/// them and just deliver more `roots` — both are optional here so paginated
/// requests still decode.
struct DiscourseNestedTopicResponse: Decodable {
    let roots: [DiscourseTopicDetail.Post]
    let hasMoreRoots: Bool
    let page: Int
    let topic: NestedTopicMeta?
    let opPost: DiscourseTopicDetail.Post?
    let sort: String?
    let acceptedAnswers: [DiscourseTopicDetail.AcceptedAnswer]?
    let hasAcceptedAnswer: Bool?
    /// Set when the server returned the standard flat post-stream layout
    /// in response to `/n/.../json` — e.g. private messages, which bypass
    /// the nested view. The caller should fall back to standard topic
    /// rendering when this is non-nil.
    let flatTopic: DiscourseTopicDetail?

    enum CodingKeys: String, CodingKey {
        case roots
        case hasMoreRoots = "has_more_roots"
        case page
        case topic
        case opPost = "op_post"
        case sort
        case acceptedAnswers = "accepted_answers"
        case hasAcceptedAnswer = "has_accepted_answer"
        case postStream = "post_stream"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.roots) {
            roots = (try? c.decode([DiscourseTopicDetail.Post].self, forKey: .roots)) ?? []
            hasMoreRoots = (try? c.decodeIfPresent(Bool.self, forKey: .hasMoreRoots)) ?? false
            page = (try? c.decodeIfPresent(Int.self, forKey: .page)) ?? 0
            topic = try? c.decodeIfPresent(NestedTopicMeta.self, forKey: .topic)
            opPost = try? c.decodeIfPresent(DiscourseTopicDetail.Post.self, forKey: .opPost)
            sort = try? c.decodeIfPresent(String.self, forKey: .sort)
            acceptedAnswers = try? c.decodeIfPresent([DiscourseTopicDetail.AcceptedAnswer].self, forKey: .acceptedAnswers)
            hasAcceptedAnswer = try? c.decodeIfPresent(Bool.self, forKey: .hasAcceptedAnswer)
            flatTopic = nil
        } else if c.contains(.postStream) {
            // Server returned the standard topic layout — decode it off the
            // same payload so the caller can fall back without a second
            // round-trip.
            roots = []
            hasMoreRoots = false
            page = 0
            topic = nil
            opPost = nil
            sort = nil
            acceptedAnswers = nil
            hasAcceptedAnswer = nil
            flatTopic = try DiscourseTopicDetail(from: decoder)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .roots,
                in: c,
                debugDescription: "Nested response missing both `roots` and `post_stream`"
            )
        }
    }

    struct NestedTopicMeta: Decodable {
        let id: Int
        let title: String
        let fancyTitle: String?
        let slug: String?
        let postsCount: Int
        let replyCount: Int
        let categoryId: Int?
        let createdAt: String?
        let tags: [DiscourseTopicDetail.Tag]
        let archetype: String?
        let acceptedAnswers: [DiscourseTopicDetail.AcceptedAnswer]?
        let hasAcceptedAnswer: Bool?

        enum CodingKeys: String, CodingKey {
            case id, title, slug, tags, archetype
            case fancyTitle = "fancy_title"
            case postsCount = "posts_count"
            case replyCount = "reply_count"
            case categoryId = "category_id"
            case createdAt = "created_at"
            case acceptedAnswers = "accepted_answers"
            case hasAcceptedAnswer = "has_accepted_answer"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            fancyTitle = try? container.decodeIfPresent(String.self, forKey: .fancyTitle)
            slug = try? container.decodeIfPresent(String.self, forKey: .slug)
            postsCount = (try? container.decodeIfPresent(Int.self, forKey: .postsCount)) ?? 0
            replyCount = (try? container.decodeIfPresent(Int.self, forKey: .replyCount)) ?? 0
            categoryId = try? container.decodeIfPresent(Int.self, forKey: .categoryId)
            createdAt = try? container.decodeIfPresent(String.self, forKey: .createdAt)
            tags = (try? container.decodeIfPresent([DiscourseTopicDetail.Tag].self, forKey: .tags)) ?? []
            archetype = try? container.decodeIfPresent(String.self, forKey: .archetype)
            acceptedAnswers =
                try? container.decodeIfPresent([DiscourseTopicDetail.AcceptedAnswer].self, forKey: .acceptedAnswers)
            hasAcceptedAnswer = try? container.decodeIfPresent(Bool.self, forKey: .hasAcceptedAnswer)
        }
    }
}

/// Response shape from `GET /n/{slug}/{topicId}/children/{postNumber}.json` —
/// the full direct-reply list under a single post in the nested view. Each
/// entry carries its own (inlined) subtree just like the roots in
/// `DiscourseNestedTopicResponse`. `hasMore` paginates the direct children.
struct DiscourseNestedChildrenResponse: Decodable {
    let children: [DiscourseTopicDetail.Post]
    let hasMore: Bool
    let page: Int

    enum CodingKeys: String, CodingKey {
        case children
        case hasMore = "has_more"
        case page
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        children = (try? c.decode([DiscourseTopicDetail.Post].self, forKey: .children)) ?? []
        hasMore = (try? c.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? false
        page = (try? c.decodeIfPresent(Int.self, forKey: .page)) ?? 0
    }
}

struct DiscourseTopicPostsResponse: Decodable {
    let postStream: PostStreamPosts

    enum CodingKeys: String, CodingKey {
        case postStream = "post_stream"
    }

    struct PostStreamPosts: Decodable {
        let posts: [DiscourseTopicDetail.Post]
    }
}
