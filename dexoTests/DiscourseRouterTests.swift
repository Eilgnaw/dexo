import XCTest
@testable import dexo

final class DiscourseRouterTests: XCTestCase {
    private enum TestFailure: Error {
        case metadata
    }

    private final class TopicEditingAPIMock: TopicEditingAPI {
        var postUpdateCount = 0
        var topicUpdateCount = 0
        var topicError: Error?
        let updatedPost: DiscourseTopicDetail.Post

        init(updatedPost: DiscourseTopicDetail.Post) {
            self.updatedPost = updatedPost
        }

        func updatePost(
            id: Int,
            raw: String,
            originalRaw: String
        ) async throws -> DiscourseTopicDetail.Post {
            postUpdateCount += 1
            return updatedPost
        }

        func updateTopic(
            id: Int,
            title: String,
            originalTitle: String,
            categoryId: Int?,
            tags: [DiscourseEditableTag],
            originalTags: [DiscourseTopicDetail.Tag]
        ) async throws {
            topicUpdateCount += 1
            if let topicError { throw topicError }
        }
    }

    func testEditRoutesUseDiscourseUpdateEndpoints() {
        let post = DiscourseRouter.updatePost(id: 123)
        XCTAssertEqual(post.path, "/posts/123.json")
        XCTAssertEqual(post.method, .put)

        let topic = DiscourseRouter.updateTopic(id: 456)
        XCTAssertEqual(topic.path, "/t/-/456.json")
        XCTAssertEqual(topic.method, .put)
    }

    func testPostEditPermissionsDecodeAndDefaultToDenied() throws {
        let editableData = Data(
            #"{"id":1,"username":"alice","post_number":2,"can_edit":true,"yours":true}"#.utf8
        )
        let editable = try JSONDecoder().decode(DiscourseTopicDetail.Post.self, from: editableData)
        XCTAssertTrue(editable.canEdit)
        XCTAssertTrue(editable.yours)
        XCTAssertTrue(editable.isEditableByCurrentUser)

        let moderatorData = Data(
            #"{"id":2,"username":"bob","post_number":3,"can_edit":true,"yours":false}"#.utf8
        )
        let moderatorEditable = try JSONDecoder().decode(DiscourseTopicDetail.Post.self, from: moderatorData)
        XCTAssertFalse(moderatorEditable.isEditableByCurrentUser)

        let missingData = Data(#"{"id":3,"username":"alice","post_number":4}"#.utf8)
        let missing = try JSONDecoder().decode(DiscourseTopicDetail.Post.self, from: missingData)
        XCTAssertFalse(missing.canEdit)
        XCTAssertFalse(missing.yours)
        XCTAssertFalse(missing.isEditableByCurrentUser)
    }

    func testEditRequestBuildersPreserveConflictAndTagFields() {
        let postPayload = DiscourseEditRequestBuilder.post(
            raw: "new body",
            originalRaw: "old body"
        )
        let post = postPayload["post"] as? [String: String]
        XCTAssertEqual(post?["raw"], "new body")
        XCTAssertEqual(post?["original_text"], "old body")

        let originalTags = [
            DiscourseTopicDetail.Tag(id: 7, name: "swift", slug: "swift"),
        ]
        let topicPayload = DiscourseEditRequestBuilder.topic(
            title: "New title",
            originalTitle: "Old title",
            categoryId: 12,
            tags: [
                DiscourseEditableTag(id: 7, name: "swift"),
                DiscourseEditableTag(name: "ios"),
            ],
            originalTags: originalTags
        )
        XCTAssertEqual(topicPayload["title"] as? String, "New title")
        XCTAssertEqual(topicPayload["original_title"] as? String, "Old title")
        XCTAssertEqual(topicPayload["category_id"] as? Int, 12)
        let tags = topicPayload["tags"] as? [[String: Any]]
        XCTAssertEqual(tags?[0]["id"] as? Int, 7)
        XCTAssertEqual(tags?[0]["name"] as? String, "swift")
        XCTAssertNil(tags?[1]["id"])
        XCTAssertEqual(tags?[1]["name"] as? String, "ios")
        let originals = topicPayload["original_tags"] as? [[String: Any]]
        XCTAssertEqual(originals?[0]["id"] as? Int, 7)
    }

    func testTopicEditStateRequiresARealValidChange() throws {
        let data = Data(
            #"{"id":99,"title":"Original","posts_count":1,"reply_count":0,"category_id":12,"created_at":"2026-08-19T00:00:00Z","tags":[{"id":7,"name":"swift","slug":"swift"},{"id":8,"name":"ios","slug":"ios"}],"post_stream":{"posts":[{"id":100,"username":"alice","post_number":1,"raw":"Original body","can_edit":true,"yours":true}],"stream":[100]}}"#.utf8
        )
        let topic = try JSONDecoder().decode(DiscourseTopicDetail.self, from: data)
        let post = try XCTUnwrap(topic.postStream.posts.first)
        let api = DiscourseAPI(testingBaseURL: "https://example.com") { _ in
            throw CancellationError()
        }
        let viewModel = TopicComposerViewModel(
            api: api,
            mode: .edit(topic: topic, post: post)
        )

        XCTAssertFalse(viewModel.hasUnsavedChanges)
        XCTAssertFalse(viewModel.canSubmit)

        viewModel.selectedTags.reverse()
        XCTAssertFalse(viewModel.hasUnsavedChanges)

        viewModel.body = "Updated body"
        XCTAssertTrue(viewModel.hasUnsavedChanges)
        XCTAssertTrue(viewModel.canSubmit)

        viewModel.body = "   "
        XCTAssertFalse(viewModel.canSubmit)
    }

    func testTopicEditRetriesOnlyMetadataAfterPartialSave() async throws {
        let data = Data(
            #"{"id":99,"title":"Original","posts_count":1,"reply_count":0,"category_id":12,"created_at":"2026-08-19T00:00:00Z","tags":[{"id":7,"name":"swift","slug":"swift"}],"post_stream":{"posts":[{"id":100,"username":"alice","post_number":1,"raw":"Original body","can_edit":true,"yours":true}],"stream":[100]}}"#.utf8
        )
        let topic = try JSONDecoder().decode(DiscourseTopicDetail.self, from: data)
        let post = try XCTUnwrap(topic.postStream.posts.first)
        let editingAPI = TopicEditingAPIMock(updatedPost: post)
        editingAPI.topicError = TestFailure.metadata
        let api = DiscourseAPI(testingBaseURL: "https://example.com") { _ in
            throw CancellationError()
        }
        let viewModel = TopicComposerViewModel(
            api: api,
            mode: .edit(topic: topic, post: post),
            editingAPI: editingAPI
        )
        viewModel.body = "Updated body"
        viewModel.title = "Updated title"

        do {
            _ = try await viewModel.submit()
            XCTFail("Expected metadata update to fail")
        } catch let error as TopicEditSaveError {
            XCTAssertTrue(error.bodyWasSaved)
        }
        XCTAssertEqual(editingAPI.postUpdateCount, 1)
        XCTAssertEqual(editingAPI.topicUpdateCount, 1)
        XCTAssertTrue(viewModel.hasServerChanges)
        XCTAssertTrue(viewModel.hasUnsavedChanges)
        XCTAssertTrue(viewModel.canSubmit)

        do {
            _ = try await viewModel.submit()
            XCTFail("Expected metadata retry to fail")
        } catch let error as TopicEditSaveError {
            XCTAssertTrue(error.bodyWasSaved)
        }
        XCTAssertEqual(editingAPI.postUpdateCount, 1)
        XCTAssertEqual(editingAPI.topicUpdateCount, 2)

        editingAPI.topicError = nil
        _ = try await viewModel.submit()
        XCTAssertEqual(editingAPI.postUpdateCount, 1)
        XCTAssertEqual(editingAPI.topicUpdateCount, 3)
        XCTAssertFalse(viewModel.hasUnsavedChanges)
        XCTAssertFalse(viewModel.canSubmit)
    }

    func testLinuxDoFollowRoutesUsePluginEndpointAndMethods() {
        let list = DiscourseRouter.followedUsers(username: "current-user")
        XCTAssertEqual(list.path, "/u/current-user/follow/following.json")
        XCTAssertEqual(list.method, .get)

        let follow = DiscourseRouter.followUser(username: "undefinedmoe")
        XCTAssertEqual(follow.path, "/follow/undefinedmoe.json")
        XCTAssertEqual(follow.method, .put)

        let unfollow = DiscourseRouter.unfollowUser(username: "undefinedmoe")
        XCTAssertEqual(unfollow.path, "/follow/undefinedmoe.json")
        XCTAssertEqual(unfollow.method, .delete)
    }

    func testUserProfileDecodesFollowPluginState() throws {
        let data = Data(
            #"{"user":{"id":42,"username":"undefinedmoe","can_follow":true,"is_followed":false}}"#.utf8
        )
        let response = try JSONDecoder().decode(DiscourseUserProfileResponse.self, from: data)

        XCTAssertEqual(response.user.canFollow, true)
        XCTAssertEqual(response.user.isFollowed, false)
    }

    func testFollowedUsersDecodeBasicUserArray() throws {
        let data = Data(
            #"[{"id":42,"username":"undefinedmoe","name":"Undefined Moe","avatar_template":"/avatar/{size}.png"}]"#.utf8
        )
        let users = try JSONDecoder().decode([DiscourseFollowedUser].self, from: data)

        XCTAssertEqual(users, [
            DiscourseFollowedUser(
                id: 42,
                username: "undefinedmoe",
                name: "Undefined Moe",
                avatarTemplate: "/avatar/{size}.png"
            ),
        ])
    }

    func testTopicFeedRoutesMapAllModesToServerEndpoints() {
        XCTAssertEqual(
            DiscourseRouter.topicFeed(mode: .activity, page: 0).path,
            "/latest.json?page=0"
        )
        XCTAssertEqual(
            DiscourseRouter.topicFeed(mode: .created, page: 2).path,
            "/latest.json?page=2&order=created"
        )
        XCTAssertEqual(
            DiscourseRouter.topicFeed(mode: .hot, page: 3).path,
            "/hot.json?page=3"
        )
        XCTAssertEqual(
            DiscourseRouter.topicFeed(mode: .top, page: 4).path,
            "/top.json?page=4"
        )
    }

    func testSearchRouteUsesOneBasedPageParameter() {
        XCTAssertEqual(
            DiscourseRouter.search(term: "swift", page: 1).path,
            "/search.json?q=swift&page=1"
        )
        XCTAssertEqual(
            DiscourseRouter.search(term: "swift", page: 2).path,
            "/search.json?q=swift&page=2"
        )
    }

    func testFullPageSearchPaginationDecodesDedicatedFlag() throws {
        let data = Data(
            #"{"grouped_search_result":{"more_posts":null,"more_full_page_results":true,"term":"swift"}}"#.utf8
        )
        let result = try JSONDecoder().decode(DiscourseSearchResult.self, from: data)

        XCTAssertTrue(try XCTUnwrap(result.groupedSearchResult).hasMoreFullPageResults)
    }

    func testSearchPaginationFallsBackToLegacyMorePostsFlag() throws {
        let data = Data(
            #"{"grouped_search_result":{"more_posts":true,"term":"swift"}}"#.utf8
        )
        let result = try JSONDecoder().decode(DiscourseSearchResult.self, from: data)

        XCTAssertTrue(try XCTUnwrap(result.groupedSearchResult).hasMoreFullPageResults)
    }

    func testCreatedFeedKeepsServerOrderOnEveryPage() {
        XCTAssertEqual(
            DiscourseRouter.topicFeed(mode: .created, page: 0).path,
            "/latest.json?page=0&order=created"
        )
        XCTAssertEqual(
            DiscourseRouter.topicFeed(mode: .created, page: 5).path,
            "/latest.json?page=5&order=created"
        )
    }

    func testCategoriesRouteCarriesSubcategoryAndPageParameters() {
        XCTAssertEqual(
            DiscourseRouter.categories(page: 1).path,
            "/categories.json?include_subcategories=true&page=1"
        )
        XCTAssertEqual(
            DiscourseRouter.categories(page: 4).path,
            "/categories.json?include_subcategories=true&page=4"
        )
        XCTAssertEqual(
            DiscourseRouter.categoryChildren(parentCategoryID: 42, page: 2).path,
            "/categories.json?include_subcategories=true&parent_category_id=42&page=2"
        )
    }

    func testCategoryRoutesMapAllFeedModesAndKeepPageParameters() {
        XCTAssertEqual(
            DiscourseRouter.categoryTopics(
                slug: "dev",
                id: 12,
                feedMode: nil,
                page: 0
            ).path,
            "/c/dev/12.json?page=0"
        )
        XCTAssertEqual(
            DiscourseRouter.categoryTopics(
                slug: "dev",
                id: 12,
                feedMode: .activity,
                page: 1
            ).path,
            "/c/dev/12/l/latest.json?page=1"
        )
        XCTAssertEqual(
            DiscourseRouter.categoryTopics(
                slug: "dev",
                id: 12,
                feedMode: .created,
                page: 3
            ).path,
            "/c/dev/12/l/latest.json?page=3&order=created"
        )
        XCTAssertEqual(
            DiscourseRouter.categoryTopics(
                slug: "dev",
                id: 12,
                feedMode: .hot,
                page: 4
            ).path,
            "/c/dev/12/l/hot.json?page=4"
        )
        XCTAssertEqual(
            DiscourseRouter.categoryTopics(
                slug: "dev",
                id: 12,
                feedMode: .top,
                page: 5
            ).path,
            "/c/dev/12/l/top.json?page=5"
        )
    }
}
