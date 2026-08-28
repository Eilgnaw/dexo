import SDWebImage
import UIKit
import XCTest
@testable import dexo

@MainActor
final class UserProfilePresentationTests: XCTestCase {
    func testIdentityPublishesBeforeSlowSummary() async throws {
        let api = try PublicProfileFixtureAPI()
        api.delayProfile = true
        api.delaySummary = true
        let model = UserProfileViewModel(api: api, username: "lin", currentUsername: { "me" })
        let task = Task { await model.load() }
        await waitUntil { api.profileContinuation != nil && api.summaryContinuation != nil }
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.userProfile)
        api.finishProfile()
        await waitUntil { model.userProfile != nil }
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.summary)
        XCTAssertEqual(model.userProfile?.name, "Lin")
        api.finishSummary()
        await task.value
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.summary?.likesReceived, 12345)
    }

    func testFailureAllowsRetryAndMissingSummaryKeepsProfile() async throws {
        let api = try PublicProfileFixtureAPI()
        api.failProfile = true
        let model = UserProfileViewModel(api: api, username: "lin")
        await model.load()
        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.errorMessage)
        api.failProfile = false
        api.failSummary = true
        await model.load()
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.userProfile)
        XCTAssertNil(model.summary)
    }

    func testFollowStateAndOwnProfileRulesRemainIntact() async throws {
        let api = try PublicProfileFixtureAPI()
        let model = UserProfileViewModel(api: api, username: "lin", currentUsername: { "me" })
        await model.load()
        XCTAssertTrue(model.showsFollowButton)
        XCTAssertTrue(model.showsLocalBlockButton)
        try await model.toggleFollow()
        XCTAssertTrue(model.isFollowing)
        XCTAssertEqual(api.followCalls, 1)
        try await model.toggleFollow()
        XCTAssertFalse(model.isFollowing)
        XCTAssertEqual(api.unfollowCalls, 1)
        api.failFollow = true
        do { try await model.toggleFollow(); XCTFail("Expected the controlled failure") } catch {}
        XCTAssertFalse(model.isFollowing)
        XCTAssertFalse(model.isUpdatingFollow)

        let own = UserProfileViewModel(api: api, username: "lin", currentUsername: { "LIN" })
        await own.load()
        XCTAssertTrue(own.isOwnProfile)
        XCTAssertFalse(own.showsFollowButton)
        XCTAssertFalse(own.showsLocalBlockButton)
        api.isLinuxDo = false
        XCTAssertFalse(model.showsFollowButton)
        XCTAssertTrue(model.showsLocalBlockButton)
    }

    func testPublicMenuUsesSharedRowsAndDoesNotExposeAccountSettings() throws {
        let menu = UserProfileMenuView()
        let palette = ThemeManager.shared.profilePagePalette(imageTint: .cyan)
        menu.configure(hasProfile: true, showsFollow: true, isFollowing: false, isFollowLoading: false,
                       showsLocalBlock: true, isLocallyBlocked: false, errorMessage: nil, palette: palette)
        fit(menu)
        let rows = descendants(menu).compactMap { $0 as? ProfileMenuControl }
        XCTAssertEqual(Set(rows.compactMap(\.accessibilityIdentifier)), ["user.follow", "user.local_block", "user.topics", "user.posts"])
        for row in rows {
            XCTAssertGreaterThanOrEqual(row.bounds.height, 56)
            let icon = try XCTUnwrap(descendants(row).first { $0.accessibilityIdentifier?.hasSuffix(".icon") == true } as? UIImageView)
            XCTAssertTrue(icon.preferredSymbolConfiguration?.isEqual(UIImage.SymbolConfiguration(pointSize: FontManager.shared.scaled(18))) == true)
        }
        var selected: UserProfileMenuView.Action?
        menu.onAction = { selected = $0 }
        let follow = try XCTUnwrap(rows.first { $0.accessibilityIdentifier == "user.follow" })
        follow.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, .follow)
        menu.configure(hasProfile: true, showsFollow: true, isFollowing: true, isFollowLoading: true,
                       showsLocalBlock: true, isLocallyBlocked: true, errorMessage: nil, palette: palette)
        XCTAssertFalse(follow.isEnabled)
        XCTAssertTrue(follow.accessibilityTraits.contains(.selected))
        XCTAssertEqual(follow.accessibilityLabel, String(localized: "user.unfollow"))
        menu.configure(hasProfile: true, showsFollow: false, isFollowing: false, isFollowLoading: false,
                       showsLocalBlock: false, isLocallyBlocked: false, errorMessage: nil, palette: palette)
        XCTAssertEqual(Set(descendants(menu).compactMap { ($0 as? ProfileMenuControl)?.accessibilityIdentifier }), ["user.topics", "user.posts"])
        menu.configure(hasProfile: false, showsFollow: false, isFollowing: false, isFollowLoading: false,
                       showsLocalBlock: false, isLocallyBlocked: false, errorMessage: "Fixture error", palette: palette)
        XCTAssertEqual(descendants(menu).compactMap { ($0 as? ProfileMenuControl)?.accessibilityIdentifier }, ["user.retry"])
    }

    func testPublicProfileSharesHeaderAndStretchButKeepsBackVisible() async throws {
        let imagePath = try XCTUnwrap(Bundle(for: Self.self).path(forResource: "ProfileBackground", ofType: "png"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: imagePath))
        let imageURL = "https://example.com/public-profile-\(UUID().uuidString).png"
        ImageCacheManager.shared.contentCache.storeImage(toMemory: image, forKey: imageURL)
        defer { ImageCacheManager.shared.contentCache.removeImageFromMemory(forKey: imageURL) }
        let api = try PublicProfileFixtureAPI(imageURL: imageURL)
        let model = UserProfileViewModel(api: api, username: "lin", currentUsername: { "me" })
        await model.load()
        let routingAPI = DiscourseAPI(forum: ForumInstance.new(title: "Fixture", baseURL: api.baseURL))
        let controller = UserProfileViewController(api: routingAPI, username: "lin", messagePrefillTitle: "Topic context", messagePrefillBody: "Topic URL", viewModel: model)
        let navigation = UINavigationController(rootViewController: UIViewController())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 420, height: 912)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = navigation
        let animations = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer {
            UIView.setAnimationsEnabled(animations)
            window.isHidden = true
            window.rootViewController = nil
        }
        window.makeKeyAndVisible()
        navigation.pushViewController(controller, animated: false)
        try await Task.sleep(nanoseconds: 80_000_000)
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        let header = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? ProfileHeaderView }.first)
        await waitUntil { header.pagePalette.usesImageColors }
        controller.updateUI()
        window.layoutIfNeeded()
        let scroll = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIScrollView }.first)
        let photo = try XCTUnwrap(descendants(header).first { $0.accessibilityIdentifier == "me.profile.card_background" } as? UIImageView)
        let avatar = try XCTUnwrap(descendants(header).first { $0.accessibilityIdentifier == "me.profile.avatar" })
        let message = try XCTUnwrap(descendants(header).first { $0.accessibilityIdentifier == "me.messages" } as? UIButton)
        XCTAssertEqual(message.accessibilityLabel, String(localized: "user.send_message"))
        XCTAssertTrue(descendants(header).compactMap { $0 as? UILabel }.contains { $0.text == "12.3k" })
        XCTAssertEqual(navigation.viewControllers.count, 2)
        XCTAssertEqual(navigation.navigationBar.alpha, 1)
        XCTAssertTrue(navigation.navigationBar.isUserInteractionEnabled)
        let navigationTitle = try XCTUnwrap(descendants(try XCTUnwrap(controller.navigationItem.titleView)).first {
            $0.accessibilityIdentifier == "user.navigation.title"
        })
        XCTAssertEqual(navigationTitle.alpha, 0)
        attach(window, name: "Public profile - shared header and clear background")
        let top = scroll.contentInset.top
        let originalSize = avatar.bounds.size
        let originalImageWidth = photo.bounds.width
        scroll.setContentOffset(CGPoint(x: 0, y: -top - 80), animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(avatar.bounds.size, originalSize)
        XCTAssertGreaterThan(photo.bounds.width, originalImageWidth)
        XCTAssertEqual(photo.superview!.convert(CGPoint.zero, to: controller.view).y, 0, accuracy: 1)
        attach(window, name: "Public profile - pulled background")
        for fraction: CGFloat in [0.25, 0.5, 1, 2, 0] {
            scroll.setContentOffset(CGPoint(x: 0, y: -top + header.avatarHeight * fraction), animated: false)
            window.layoutIfNeeded()
            XCTAssertEqual(scroll.contentInset.top, top, accuracy: 0.01)
            XCTAssertEqual(navigation.navigationBar.alpha, 1)
            XCTAssertTrue(navigation.navigationBar.isUserInteractionEnabled)
            XCTAssertEqual(navigationTitle.alpha, min(1, fraction * fraction), accuracy: 0.001)
        }
        window.overrideUserInterfaceStyle = .dark
        controller.updateUI()
        window.layoutIfNeeded()
        attach(window, name: "Public profile - dark appearance")
        navigation.pushViewController(UIViewController(), animated: false)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(navigation.navigationBar.alpha, 1)
        navigation.popViewController(animated: false)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(navigation.navigationBar.alpha, 1)
        let refresh = try XCTUnwrap(scroll.refreshControl)
        refresh.beginRefreshing()
        refresh.sendActions(for: .valueChanged)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(refresh.isRefreshing)
    }

    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func fit(_ view: UIView) {
        let size = view.systemLayoutSizeFitting(CGSize(width: 320, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
    }
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }
    private func attach(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class PublicProfileFixtureAPI: UserProfileAPIClient {
    enum Failure: Error { case requested }
    let baseURL = "https://public-profile-tests.example.com"
    var isLinuxDo = true
    let profile: DiscourseUserProfile
    let summary = DiscourseUserSummary(topicCount: 32, postCount: 186, likesGiven: 10, likesReceived: 12345, daysVisited: 128)
    var delayProfile = false
    var delaySummary = false
    var failProfile = false
    var failSummary = false
    var failFollow = false
    var followCalls = 0
    var unfollowCalls = 0
    var profileContinuation: CheckedContinuation<DiscourseUserProfile, Error>?
    var summaryContinuation: CheckedContinuation<DiscourseUserSummary, Error>?
    init(imageURL: String? = nil) throws {
        var values: [String: Any] = ["id": 1, "username": "lin", "name": "Lin", "created_at": "2026-08-27T00:00:00Z", "can_follow": true, "can_send_private_message_to_user": true]
        if let imageURL { values["card_background_upload_url"] = imageURL }
        profile = try JSONDecoder().decode(DiscourseUserProfile.self, from: JSONSerialization.data(withJSONObject: values))
    }
    func fetchUserProfile(username: String) async throws -> DiscourseUserProfile {
        if failProfile { throw Failure.requested }
        if delayProfile { return try await withCheckedThrowingContinuation { profileContinuation = $0 } }
        return profile
    }
    func fetchUserSummary(username: String) async throws -> DiscourseUserSummary {
        if failSummary { throw Failure.requested }
        if delaySummary { return try await withCheckedThrowingContinuation { summaryContinuation = $0 } }
        return summary
    }
    func followUser(username: String) async throws {
        if failFollow { throw Failure.requested }
        followCalls += 1
    }
    func unfollowUser(username: String) async throws {
        if failFollow { throw Failure.requested }
        unfollowCalls += 1
    }
    func finishProfile() { profileContinuation?.resume(returning: profile); profileContinuation = nil }
    func finishSummary() { summaryContinuation?.resume(returning: summary); summaryContinuation = nil }
}
