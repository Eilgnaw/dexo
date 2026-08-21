import Foundation

struct DiscourseTagList: Decodable {
    let tags: [DiscourseTag]
}

struct DiscourseTag: Decodable, Identifiable {
    var id: String { text }
    let text: String
    let count: Int
}

/// Tag selection used by the topic editor. Existing topic tags retain their
/// numeric ID for conflict checks; search results may only provide a name.
struct DiscourseEditableTag: Equatable {
    let id: Int?
    let name: String

    init(id: Int? = nil, name: String) {
        self.id = id
        self.name = name
    }

    init(_ tag: DiscourseTopicDetail.Tag) {
        id = tag.id
        name = tag.name
    }
}
