import SDWebImage
import UIKit
import XCTest
@testable import dexo

@MainActor
final class MeImmersiveHeaderTests: XCTestCase {
    func testNavigationOpacityEasesInAndStaysClearOnPullDown() {
        XCTAssertEqual(MeHeaderScrollGeometry(contentOffsetY: -68, topInset: 68, avatarHeight: 64).navigationProgress, 0)
        let pulled = MeHeaderScrollGeometry(contentOffsetY: -148, topInset: 68, avatarHeight: 64)
        XCTAssertEqual(pulled.pullDistance, 80)
        XCTAssertEqual(pulled.navigationProgress, 0)
        let samples: [(distance: CGFloat, opacity: CGFloat)] = [
            (1, 1.0 / 4096), (16, 0.0625), (32, 0.25), (48, 0.5625),
            (63, 3969.0 / 4096), (64, 1), (65, 1), (300, 1),
        ]
        for (distance, opacity) in samples {
            let geometry = MeHeaderScrollGeometry(contentOffsetY: distance - 68, topInset: 68, avatarHeight: 64)
            XCTAssertEqual(geometry.navigationProgress, opacity, accuracy: 0.0001)
            if distance < 64 {
                XCTAssertGreaterThan(geometry.navigationProgress, 0)
                XCTAssertLessThan(geometry.navigationProgress, distance / 64)
            }
        }
        XCTAssertEqual(MeHeaderScrollGeometry(contentOffsetY: -26.5, topInset: 68, avatarHeight: 83).navigationProgress, 0.25)
        XCTAssertEqual(MeHeaderScrollGeometry(contentOffsetY: 0, topInset: 0, avatarHeight: 0).navigationProgress, 0)
        XCTAssertEqual(MeHeaderScrollGeometry(contentOffsetY: 1, topInset: 0, avatarHeight: 0).navigationProgress, 1)
    }

    func testPullPinsImageToScreenTopAndScalesPortraitAndLandscapeImages() {
        let resting = MeHeaderScrollGeometry.backdropFrame(headerSize: CGSize(width: 420, height: 180), topInset: 68, pullDistance: 0)
        let pulled = MeHeaderScrollGeometry.backdropFrame(headerSize: CGSize(width: 420, height: 180), topInset: 68, pullDistance: 80)
        XCTAssertEqual(pulled.minY + 68 + 80, 0)
        XCTAssertEqual(pulled.height, resting.height + 80)
        for size in [CGSize(width: 1200, height: 600), CGSize(width: 600, height: 1200)] {
            let first = MeHeaderScrollGeometry.imageFrame(imageSize: size, viewport: resting.size, pullDistance: 0)
            let second = MeHeaderScrollGeometry.imageFrame(imageSize: size, viewport: pulled.size, pullDistance: 80)
            XCTAssertGreaterThan(second.width, first.width)
            XCTAssertGreaterThan(second.height, first.height)
            XCTAssertEqual(second.minY, 0)
            XCTAssertEqual(second.midX, pulled.width / 2, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(second.height, pulled.height)
        }
    }

    func testImageProcessingSamplesBottomBandAndBoundsDecodedSize() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 800)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 800))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 560, width: 1600, height: 240))
        }
        let prepared = try XCTUnwrap(MeHeaderImageProcessor.prepare(try XCTUnwrap(image.cgImage)))
        XCTAssertLessThanOrEqual(max(prepared.image.width, prepared.image.height), 1024)
        let tint = try XCTUnwrap(prepared.tint)
        XCTAssertGreaterThan(tint.blue, 0.95)
        XCTAssertLessThan(tint.red, 0.05)
        let rotated = try XCTUnwrap(MeHeaderImageProcessor.prepare(try XCTUnwrap(image.cgImage), exifOrientation: 6))
        XCTAssertGreaterThan(rotated.image.height, rotated.image.width)
    }

    func testTransparentImageDoesNotInventAnImagePalette() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in }
        let prepared = try XCTUnwrap(MeHeaderImageProcessor.prepare(try XCTUnwrap(image.cgImage)))
        XCTAssertNil(prepared.tint)
    }

    func testImagePaletteChangesOnlyLocalSurfacesAndAdaptsToAppearance() {
        let theme = ThemeManager.shared
        let selected = AppSettings.shared.selectedThemeId
        let palette = theme.profilePagePalette(imageTint: .red)
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        XCTAssertTrue(palette.usesImageColors)
        XCTAssertEqual(AppSettings.shared.selectedThemeId, selected)
        XCTAssertNotEqual(palette.background.resolvedColor(with: light), palette.background.resolvedColor(with: dark))
        XCTAssertNotEqual(palette.background.resolvedColor(with: light), palette.cardBackground.resolvedColor(with: light))
        XCTAssertFalse(theme.profilePagePalette().usesImageColors)
    }

    func testImmersiveScrollKeepsInsetsStableAndRestoresNavigationForPushedScreens() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let suite = "me-immersive-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let imageURL = "https://example.com/stretchy-profile-\(UUID().uuidString).png"
        let image = makeBackgroundFixture()
        ImageCacheManager.shared.contentCache.store(image, forKey: imageURL, toDisk: false, completion: nil)
        let profile = try JSONDecoder().decode(DiscourseUserProfile.self, from: JSONSerialization.data(withJSONObject: [
            "id": 1, "username": "lin", "name": "Lin", "created_at": "2026-08-27T00:00:00Z",
            "card_background_upload_url": imageURL,
        ]))
        let api = ImmersiveFixtureAPI(profile: profile)
        let cache = ProfileCacheStore(defaults: defaults)
        cache.save(profile: profile, summary: api.summary, for: api.baseURL)
        let model = MeViewModel(api: api, cacheStore: cache, usernameProvider: { "lin" }, cacheUsername: { _ in })
        let gate = ImmersiveFixtureAuthGate()
        let realAPI = DiscourseAPI(forum: ForumInstance.new(title: "Preview", baseURL: api.baseURL))
        let controller = MeViewController(api: realAPI, authGate: gate, viewModel: model)
        let minimizeItem = UIBarButtonItem(image: UIImage(systemName: "smallcircle.filled.circle"), style: .plain, target: nil, action: nil)
        controller.navigationItem.rightBarButtonItem = minimizeItem
        let navigation = UINavigationController(rootViewController: controller)
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
            defaults.removePersistentDomain(forName: suite)
            ImageCacheManager.shared.contentCache.removeImageFromMemory(forKey: imageURL)
        }
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        let header = try XCTUnwrap(descendants(in: controller.view).compactMap { $0 as? ProfileHeaderView }.first)
        if !header.pagePalette.usesImageColors {
            let ready = expectation(description: "Photo and image-derived palette ready")
            let oldCallback = header.onAppearanceChanged
            header.onAppearanceChanged = { [weak header] in
                oldCallback?()
                if header?.pagePalette.usesImageColors == true { ready.fulfill() }
            }
            await fulfillment(of: [ready], timeout: 5)
            header.onAppearanceChanged = oldCallback
        }
        controller.updateUI()
        try await Task.sleep(nanoseconds: 80_000_000)
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(descendants(in: controller.view).compactMap { $0 as? UIScrollView }.first)
        let avatar = try XCTUnwrap(descendants(in: header).first { $0.accessibilityIdentifier == "me.profile.avatar" })
        let photo = try XCTUnwrap(descendants(in: header).first { $0.accessibilityIdentifier == "me.profile.card_background" } as? UIImageView)
        let top = scroll.contentInset.top
        let avatarSize = avatar.bounds.size
        let photoWidth = photo.bounds.width
        let title = try XCTUnwrap(descendants(in: try XCTUnwrap(controller.navigationItem.titleView)).first {
            $0.accessibilityIdentifier == "me.navigation.title"
        } as? UILabel)
        XCTAssertEqual(navigation.navigationBar.alpha, 1, accuracy: 0.01)
        XCTAssertTrue(navigation.navigationBar.isUserInteractionEnabled)
        XCTAssertEqual(title.alpha, 0)
        XCTAssertTrue(controller.navigationItem.rightBarButtonItem === minimizeItem)
        XCTAssertGreaterThanOrEqual(avatar.convert(avatar.bounds, to: window).minY, navigation.navigationBar.convert(navigation.navigationBar.bounds, to: window).maxY + 17)
        attach(window, name: "Immersive profile - resting (test image)")

        scroll.setContentOffset(CGPoint(x: 0, y: -top - 80), animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(avatar.bounds.size, avatarSize)
        XCTAssertGreaterThan(photo.bounds.width, photoWidth)
        XCTAssertEqual(navigation.navigationBar.alpha, 1, accuracy: 0.01)
        XCTAssertEqual(title.alpha, 0)
        XCTAssertEqual(photo.superview!.convert(.zero, to: controller.view).y, 0, accuracy: 1)
        attach(window, name: "Immersive profile - pulled (test image)")

        // Check partial progress with animations enabled, including a reversal.
        // The bar must follow the offset immediately, with no queued animations.
        UIView.setAnimationsEnabled(true)
        for progress: CGFloat in [0.015625, 0.25, 0.5, 0.75, 1, 0.5, 0.25, 0] {
            let offset = -top + header.avatarHeight * progress
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            window.layoutIfNeeded()
            XCTAssertEqual(navigation.navigationBar.alpha, 1, accuracy: 0.0001)
            XCTAssertEqual(title.alpha, progress * progress, accuracy: 0.0001)
            XCTAssertTrue(navigation.navigationBar.isUserInteractionEnabled)
            XCTAssertTrue(controller.navigationItem.rightBarButtonItem === minimizeItem)
            XCTAssertEqual(navigation.navigationBar.transform, .identity)
            XCTAssertFalse(navigation.navigationBar.layer.animationKeys()?.contains("opacity") ?? false)
            XCTAssertEqual(scroll.contentInset.top, top, accuracy: 0.01)
            XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 0.01)
            XCTAssertEqual(avatar.bounds.size, avatarSize)
            if progress == 0.5 { attach(window, name: "Immersive profile - eased fade at half scroll (test image)") }
        }
        UIView.setAnimationsEnabled(false)

        let collapsedOffset = -top + header.avatarHeight + 20
        scroll.setContentOffset(CGPoint(x: 0, y: collapsedOffset), animated: false)
        window.layoutIfNeeded()
        XCTAssertEqual(scroll.contentInset.top, top, accuracy: 0.01)
        XCTAssertEqual(scroll.contentOffset.y, collapsedOffset, accuracy: 0.01)
        XCTAssertEqual(navigation.navigationBar.alpha, 1, accuracy: 0.01)
        XCTAssertTrue(navigation.navigationBar.isUserInteractionEnabled)
        title.overrideUserInterfaceStyle = .dark
        XCTAssertEqual(title.textColor.resolvedColor(with: title.traitCollection), .black)
        title.overrideUserInterfaceStyle = .unspecified
        attach(window, name: "Immersive profile - collapsed (test image)")

        window.overrideUserInterfaceStyle = .dark
        controller.updateUI()
        window.layoutIfNeeded()
        XCTAssertEqual(title.textColor, .white)
        attach(window, name: "Immersive profile - dark collapsed (test image)")
        scroll.setContentOffset(CGPoint(x: 0, y: -top), animated: false)
        window.layoutIfNeeded()
        attach(window, name: "Immersive profile - dark resting (test image)")
        window.overrideUserInterfaceStyle = .light
        controller.updateUI()
        window.layoutIfNeeded()

        scroll.setContentOffset(CGPoint(x: 0, y: -top), animated: false)
        XCTAssertEqual(navigation.navigationBar.alpha, 1, accuracy: 0.01)
        XCTAssertEqual(title.alpha, 0)
        navigation.pushViewController(UIViewController(), animated: false)
        try await Task.sleep(nanoseconds: 80_000_000)
        window.layoutIfNeeded()
        XCTAssertEqual(navigation.navigationBar.alpha, 1, accuracy: 0.01)
        XCTAssertEqual(navigation.navigationBar.transform, .identity)
        navigation.popViewController(animated: false)
        try await Task.sleep(nanoseconds: 80_000_000)
        window.layoutIfNeeded()
        XCTAssertEqual(navigation.navigationBar.alpha, 1, accuracy: 0.01)
        XCTAssertEqual(title.alpha, 0)

        let refresh = try XCTUnwrap(scroll.refreshControl)
        refresh.beginRefreshing()
        refresh.sendActions(for: .valueChanged)
        try await Task.sleep(nanoseconds: 80_000_000)
        window.layoutIfNeeded()
        XCTAssertFalse(refresh.isRefreshing)
        XCTAssertEqual(scroll.contentInset.top, top, accuracy: 0.01)
    }

    private func makeBackgroundFixture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 600)).image { context in
            let colors = [
                UIColor(red: 0.10, green: 0.20, blue: 0.32, alpha: 1).cgColor,
                UIColor(red: 0.28, green: 0.52, blue: 0.60, alpha: 1).cgColor,
                UIColor(red: 0.56, green: 0.67, blue: 0.72, alpha: 1).cgColor,
            ]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.5, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 1000, y: 600), options: [])
        }
    }

    private func descendants(in view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func attach(_ window: UIWindow, name: String) {
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class ImmersiveFixtureAuthGate: AuthGating {
    func requireAuth(then action: @escaping () -> Void) { action() }
    func isAuthenticated() -> Bool { true }
    func currentUsername() -> String? { "lin" }
    func performLogout() {}
}

@MainActor
private final class ImmersiveFixtureAPI: MeProfileAPIClient {
    let baseURL = "https://immersive-tests.example.com"
    let isLinuxDo = false
    let profile: DiscourseUserProfile
    let summary = DiscourseUserSummary(topicCount: 32, postCount: 186, likesGiven: 0, likesReceived: 12345, daysVisited: 128)
    init(profile: DiscourseUserProfile) { self.profile = profile }
    func fetchCurrentUser() async throws -> DiscourseCurrentUser { throw CancellationError() }
    func fetchNotifications(limit: Int?, filter: String?) async throws -> DiscourseNotificationList { throw CancellationError() }
    func fetchUserProfile(username: String) async throws -> DiscourseUserProfile { profile }
    func fetchUserSummary(username: String) async throws -> DiscourseUserSummary { summary }
}
