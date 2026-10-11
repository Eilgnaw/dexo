import Foundation
import XCTest
@testable import dexo

final class TopicListModelTests: XCTestCase {
    func testTagDecodesLegacyStringRepresentation() throws {
        let tag = try JSONDecoder().decode(
            TopicListTag.self,
            from: Data(#""swift""#.utf8)
        )

        XCTAssertNil(tag.id)
        XCTAssertEqual(tag.name, "swift")
        XCTAssertEqual(tag.slug, "swift")
    }

    func testTagDecodesObjectRepresentation() throws {
        let tag = try JSONDecoder().decode(
            TopicListTag.self,
            from: Data(#"{"id":42,"name":"Swift 语言","slug":"swift-lang"}"#.utf8)
        )

        XCTAssertEqual(tag.id, 42)
        XCTAssertEqual(tag.name, "Swift 语言")
        XCTAssertEqual(tag.slug, "swift-lang")
    }

    func testTagObjectFallsBackToNameWhenSlugIsMissing() throws {
        let tag = try JSONDecoder().decode(
            TopicListTag.self,
            from: Data(#"{"name":"ios"}"#.utf8)
        )

        XCTAssertEqual(tag.name, "ios")
        XCTAssertEqual(tag.slug, "ios")
    }

    func testTopicDecodesMixedTagRepresentations() throws {
        let topic = try decodeTopic(
            tagsJSON: #"["legacy",{"id":7,"name":"Modern","slug":"modern"}]"#
        )

        XCTAssertEqual(
            topic.tags,
            [
                TopicListTag(name: "legacy"),
                TopicListTag(id: 7, name: "Modern", slug: "modern"),
            ]
        )
    }

    func testTopicUsesEmptyTagsWhenFieldIsMissing() throws {
        let topic = try decodeTopic(tagsJSON: nil)

        XCTAssertTrue(topic.tags.isEmpty)
    }

    func testActivityTimestampPrefersBumpedAt() throws {
        let topic = try decodeTopic(
            tagsJSON: nil,
            bumpedAt: "2026-07-10T03:00:00.000Z",
            lastPostedAt: "2026-07-09T02:00:00.000Z"
        )

        XCTAssertEqual(
            TopicTimestampKind.activity.dateString(for: topic),
            "2026-07-10T03:00:00.000Z"
        )
    }

    func testActivityTimestampFallsBackToLastPostThenCreation() throws {
        let topicWithLastPost = try decodeTopic(
            tagsJSON: nil,
            lastPostedAt: "2026-07-09T02:00:00.000Z"
        )
        let topicWithCreationOnly = try decodeTopic(tagsJSON: nil)

        XCTAssertEqual(
            TopicTimestampKind.activity.dateString(for: topicWithLastPost),
            "2026-07-09T02:00:00.000Z"
        )
        XCTAssertEqual(
            TopicTimestampKind.activity.dateString(for: topicWithCreationOnly),
            "2026-07-08T01:00:00.000Z"
        )
    }

    func testCreatedTimestampAlwaysUsesCreationDate() throws {
        let topic = try decodeTopic(
            tagsJSON: nil,
            bumpedAt: "2026-07-10T03:00:00.000Z",
            lastPostedAt: "2026-07-09T02:00:00.000Z"
        )

        XCTAssertEqual(
            TopicTimestampKind.created.dateString(for: topic),
            "2026-07-08T01:00:00.000Z"
        )
    }

    func testTopicDecodesReadPositionAndResumesAtFirstUnreadPost() throws {
        let topic = try decodeTopic(
            tagsJSON: nil,
            lastReadPostNumber: 7,
            highestPostNumber: 12
        )

        XCTAssertEqual(topic.lastReadPostNumber, 7)
        XCTAssertEqual(topic.highestPostNumber, 12)
        XCTAssertEqual(topic.resumePostNumber, 8)
    }

    func testFullyReadTopicResumesAtLastPost() throws {
        let topic = try decodeTopic(
            tagsJSON: nil,
            lastReadPostNumber: 12,
            highestPostNumber: 12
        )

        XCTAssertEqual(topic.resumePostNumber, 12)
    }

    func testNewTopicStillOpensFromOriginalPost() throws {
        let topic = try decodeTopic(
            tagsJSON: nil,
            highestPostNumber: 12
        )

        XCTAssertNil(topic.resumePostNumber)
    }

    private func decodeTopic(
        tagsJSON: String?,
        bumpedAt: String? = nil,
        lastPostedAt: String? = nil,
        lastReadPostNumber: Int? = nil,
        highestPostNumber: Int? = nil
    ) throws -> DiscourseTopicList.Topic {
        var fields = [
            #""id":1"#,
            #""fancy_title":"A topic""#,
            #""title":"A topic""#,
            #""posts_count":3"#,
            #""reply_count":2"#,
            #""views":10"#,
            #""created_at":"2026-07-08T01:00:00.000Z""#,
        ]
        if let lastPostedAt {
            fields.append(#""last_posted_at":"\#(lastPostedAt)""#)
        }
        if let bumpedAt {
            fields.append(#""bumped_at":"\#(bumpedAt)""#)
        }
        if let lastReadPostNumber {
            fields.append(#""last_read_post_number":\#(lastReadPostNumber)"#)
        }
        if let highestPostNumber {
            fields.append(#""highest_post_number":\#(highestPostNumber)"#)
        }
        if let tagsJSON {
            fields.append(#""tags":\#(tagsJSON)"#)
        }

        let json = "{" + fields.joined(separator: ",") + "}"
        return try JSONDecoder().decode(
            DiscourseTopicList.Topic.self,
            from: Data(json.utf8)
        )
    }
}
