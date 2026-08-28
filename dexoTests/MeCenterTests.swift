import UIKit
import SDWebImage
import XCTest
@testable import dexo

@MainActor
final class MeCenterTests: XCTestCase {
    func testCardBackgroundLoadsFromCacheAndClearsOnLogout() async throws {
        let url = "https://example.com/card-background-test-\(UUID().uuidString).png"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
            UIColor.black.setFill()
            context.fill(CGRect(x: 300, y: 0, width: 300, height: 300))
        }
        let cache = ImageCacheManager.shared.contentCache
        cache.store(image, forKey: url, toDisk: false, completion: nil)
        defer { cache.removeImageFromMemory(forKey: url) }
        let data = try JSONSerialization.data(withJSONObject: [
            "id": 1, "username": "lin", "name": "Lin", "card_background_upload_url": url,
            "created_at": "2026-08-27T00:00:00Z",
        ])
        let profile = try JSONDecoder().decode(DiscourseUserProfile.self, from: data)
        let header = ProfileHeaderView()
        header.configure(
            user: nil, profile: nil, summary: nil, isAuthenticated: true,
            fallbackUsername: "lin", assetBaseURL: "https://example.com"
        )
        let heightWithoutImage = fit(header)
        let prepared = expectation(description: "The cached background is blurred and sampled")
        header.onAppearanceChanged = { [weak header] in
            if header?.pagePalette.usesImageColors == true { prepared.fulfill() }
        }
        header.configure(
            user: nil, profile: profile, summary: nil, isAuthenticated: true,
            fallbackUsername: "lin", assetBaseURL: "https://example.com"
        )
        await fulfillment(of: [prepared], timeout: 5)
        header.onAppearanceChanged = nil
        XCTAssertEqual(fit(header), heightWithoutImage, accuracy: 1)
        let background = try XCTUnwrap(descendants(in: header).first {
            $0.accessibilityIdentifier == "me.profile.card_background"
        } as? UIImageView)
        XCTAssertNotNil(background.image)
        XCTAssertFalse(background.isHidden)
        let scrim = try XCTUnwrap(descendants(in: header).first { $0.accessibilityIdentifier == "me.profile.scrim" })
        XCTAssertEqual(scrim.alpha, 0.32, accuracy: 0.001)
        let nameLabel = try XCTUnwrap(labels(in: header).first { $0.accessibilityIdentifier == "me.profile.name" })
        XCTAssertGreaterThan(nameLabel.layer.shadowOpacity, 0)
        XCTAssertTrue(labels(in: header).contains { $0.text == "Lin" })
        let palette = header.pagePalette.header
        for (identifier, expected) in [
            ("me.profile.name", palette.foreground),
            ("me.profile.username", palette.secondaryForeground),
            ("me.profile.joined", palette.secondaryForeground),
        ] {
            let label = try XCTUnwrap(labels(in: header).first { $0.accessibilityIdentifier == identifier })
            for style in [UIUserInterfaceStyle.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: style)
                XCTAssertEqual(label.textColor.resolvedColor(with: traits), expected.resolvedColor(with: traits))
            }
        }

        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: header.bounds).image { context in
            header.layer.render(in: context.cgContext)
        })
        attachment.name = "Card background contrast fixture"
        attachment.lifetime = .keepAlways
        add(attachment)

        header.configure(
            user: nil, profile: nil, summary: nil, isAuthenticated: false,
            fallbackUsername: nil, assetBaseURL: "https://example.com"
        )
        XCTAssertNil(background.image)
        XCTAssertTrue(background.isHidden)
        XCTAssertFalse(header.pagePalette.usesImageColors)
    }

    func testCardBackgroundDecodingResolvesRelativeAndCDNURLsAndCachesTheField() throws {
        let base = "https://forum.example.com/community"
        let cases = [
            ("/uploads/default/card.jpg", "https://forum.example.com/uploads/default/card.jpg"),
            ("uploads/card.jpg", "https://forum.example.com/community/uploads/card.jpg"),
            ("//cdn.example.com/card.jpg", "https://cdn.example.com/card.jpg"),
            ("https://cdn.example.com/card.jpg", "https://cdn.example.com/card.jpg"),
        ]
        for (path, expected) in cases {
            let data = try JSONSerialization.data(withJSONObject: [
                "id": 1, "username": "lin", "card_background_upload_url": path,
            ])
            let profile = try JSONDecoder().decode(DiscourseUserProfile.self, from: data)
            XCTAssertEqual(profile.cardBackgroundURL(relativeTo: base)?.absoluteString, expected)
            let cached = try JSONDecoder().decode(DiscourseUserProfile.self, from: JSONEncoder().encode(profile))
            XCTAssertEqual(cached.cardBackgroundUploadUrl, path)
        }
    }

    func testOldProfilesAndInvalidCardBackgroundsFallBackToTheme() throws {
        for path in [nil, "", "  ", "file:///tmp/card.jpg", "javascript:alert(1)", "https://user:password@example.com/card.jpg"] as [String?] {
            var object: [String: Any] = ["id": 1, "username": "lin"]
            if let path { object["card_background_upload_url"] = path }
            let data = try JSONSerialization.data(withJSONObject: object)
            let profile = try JSONDecoder().decode(DiscourseUserProfile.self, from: data)
            XCTAssertNil(profile.cardBackgroundURL(relativeTo: "https://forum.example.com"))
        }
    }

    func testPhotoScrimPaletteSupportsReadableMaximumContrast() {
        for theme in ThemeDefinition.presets {
            for accent in [theme.lightAccentHex, theme.darkAccentHex] {
                let palette = ProfileHeaderPalette(accent: UIColor(hex: accent)!, background: .white)
                let traits = UITraitCollection(userInterfaceStyle: .light)
                let scrim = palette.imageScrim.resolvedColor(with: traits)
                var alpha: CGFloat = 0
                scrim.getRed(nil, green: nil, blue: nil, alpha: &alpha)
                for photo in [UIColor.white, .black] {
                    let surface = scrim.blended(into: photo, ratio: alpha).withAlphaComponent(1)
                    XCTAssertGreaterThanOrEqual(contrast(palette.foreground.resolvedColor(with: traits), surface), 4.5)
                }
            }
        }
    }

    func testHeaderPaletteFollowsEveryPresetInBothAppearancesWithReadableText() throws {
        for theme in ThemeDefinition.presets {
            let palette = ProfileHeaderPalette(
                accent: UIColor { traits in
                    UIColor(hex: traits.userInterfaceStyle == .dark ? theme.darkAccentHex : theme.lightAccentHex)!
                },
                background: UIColor { traits in
                    UIColor(hex: traits.userInterfaceStyle == .dark ? theme.darkBackgroundHex : theme.lightBackgroundHex)!
                }
            )
            for style in [UIUserInterfaceStyle.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: style)
                let surface = palette.background.resolvedColor(with: traits)
                let foreground = palette.foreground.resolvedColor(with: traits)
                let secondary = palette.secondaryForeground.resolvedColor(with: traits)
                let expected = style == .dark ? theme.darkAccentHex : theme.lightAccentHex
                XCTAssertEqual(surface.hexString, UIColor(hex: expected)!.hexString, "\(theme.id), \(style)")
                XCTAssertGreaterThanOrEqual(contrast(foreground, surface), 4.5, theme.id)
                XCTAssertGreaterThanOrEqual(contrast(secondary, surface), 4.5, theme.id)
            }
        }
    }

    func testCustomWhiteBlackAndTranslucentAccentsRemainReadable() {
        for hex in ["FFFFFF", "000000", "FFFF00", "007AFF", "80A0C060"] {
            let palette = ProfileHeaderPalette(accent: UIColor(hex: hex)!, background: UIColor(hex: "F2F2F7")!)
            let traits = UITraitCollection(userInterfaceStyle: .light)
            let surface = palette.background.resolvedColor(with: traits)
            XCTAssertGreaterThanOrEqual(contrast(palette.foreground.resolvedColor(with: traits), surface), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(palette.secondaryForeground.resolvedColor(with: traits), surface), 4.5)
            var alpha: CGFloat = 0
            surface.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            XCTAssertEqual(alpha, 1)
        }
    }

    func testMenuRetainsEveryActionAndHandlesOptionalForumFeatures() throws {
        let menu = MeMenuView()
        configure(menu, following: false, challenge: false)
        XCTAssertEqual(actionIDs(in: menu), [
            "me.notifications", "me.bookmarks", "me.read",
            "me.local_blocklist", "me.push_notifications", "me.logout",
        ])
        configure(menu, following: true, challenge: true)
        XCTAssertEqual(actionIDs(in: menu), [
            "me.notifications", "me.following", "me.bookmarks", "me.read",
            "me.local_blocklist", "me.push_notifications", "me.challenge", "me.logout",
        ])
        configure(menu, following: false, challenge: false)
        XCTAssertFalse(actionIDs(in: menu).contains("me.following"))
        XCTAssertFalse(actionIDs(in: menu).contains("me.challenge"))

        var selected: MeMenuView.Action?
        menu.onAction = { selected = $0 }
        let bookmarks = try XCTUnwrap(controls(in: menu).first { $0.accessibilityIdentifier == "me.bookmarks" })
        bookmarks.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, .bookmarks)
    }

    func testLoggedOutMenuHasOnlyLoginAndCanReturnToAuthenticatedState() throws {
        let menu = MeMenuView()
        configure(menu, authenticated: false, following: true, challenge: true)
        XCTAssertEqual(actionIDs(in: menu), ["me.login"])
        var selected: MeMenuView.Action?
        menu.onAction = { selected = $0 }
        try XCTUnwrap(controls(in: menu).first).sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, .login)
        configure(menu)
        XCTAssertTrue(actionIDs(in: menu).contains("me.logout"))
        XCTAssertTrue(actionIDs(in: menu).contains("me.bookmarks"))
    }

    func testUnreadBadgesHaveAccessibleValuesAndClearIndependently() throws {
        let menu = MeMenuView()
        let header = ProfileHeaderView()
        configure(menu, notifications: true)
        configure(header, unreadMessages: true)
        let messages = try XCTUnwrap(controls(in: header).first { $0.accessibilityIdentifier == "me.messages" })
        let notifications = try XCTUnwrap(controls(in: menu).first { $0.accessibilityIdentifier == "me.notifications" })
        XCTAssertEqual(messages.accessibilityValue, String(localized: "me.unread"))
        XCTAssertEqual(notifications.accessibilityValue, String(localized: "me.unread"))
        configure(header, unreadMessages: false)
        XCTAssertNil(messages.accessibilityValue)
        XCTAssertEqual(notifications.accessibilityValue, String(localized: "me.unread"))
        let blocklist = try XCTUnwrap(controls(in: menu).first { $0.accessibilityIdentifier == "me.local_blocklist" })
        XCTAssertEqual(blocklist.accessibilityValue, String(localized: "me.local_blocklist.count \(2)"))
    }

    func testHeaderKeepsProfileAndStatisticsAndClearsThemOnLogout() throws {
        let header = ProfileHeaderView()
        configure(header)
        _ = fit(header)
        let texts = labels(in: header).compactMap(\.text)
        XCTAssertTrue(texts.contains("Lin"))
        XCTAssertTrue(texts.contains("@lin"))
        XCTAssertTrue(texts.contains("32"))
        XCTAssertTrue(texts.contains("186"))
        XCTAssertEqual(controls(in: header).count, 5)
        var selected: ProfileHeaderView.StatType?
        header.onStatTapped = { selected = $0 }
        try XCTUnwrap(controls(in: header).first { $0.accessibilityIdentifier == "me.stats.topics" })
            .sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, .topics)

        header.configure(
            user: nil, profile: nil, summary: nil, isAuthenticated: false,
            fallbackUsername: nil, assetBaseURL: "https://example.com"
        )
        _ = fit(header)
        XCTAssertTrue(controls(in: header).isEmpty)
        XCTAssertTrue(labels(in: header).contains { $0.text == String(localized: "me.guest.title") })
        XCTAssertFalse(labels(in: header).contains { $0.text == "32" })
    }

    func testMissingProfileUsesKnownUsernameWithoutShowingGuestPrompt() {
        let header = ProfileHeaderView()
        header.configure(
            user: nil, profile: nil, summary: nil, isAuthenticated: true,
            fallbackUsername: "known-user", assetBaseURL: "https://example.com"
        )
        _ = fit(header)
        XCTAssertTrue(labels(in: header).contains { $0.text == "known-user" })
        XCTAssertFalse(labels(in: header).contains { $0.text == String(localized: "me.login_prompt") })
    }

    func testThemeCanChangeOnExistingHeaderAndMenu() throws {
        let original = AppSettings.shared.selectedThemeId
        defer { ThemeManager.shared.selectTheme(id: original) }
        let header = ProfileHeaderView()
        let menu = MeMenuView()
        for id in ["ocean", "forest", "rose"] {
            ThemeManager.shared.selectTheme(id: id)
            configure(header)
            configure(menu)
            let traits = UITraitCollection(userInterfaceStyle: .light)
            XCTAssertEqual(
                header.backgroundColor?.resolvedColor(with: traits).hexString,
                ThemeManager.shared.accentColor.resolvedColor(with: traits).hexString
            )
            XCTAssertEqual(
                menu.backgroundColor?.resolvedColor(with: traits).hexString,
                ThemeManager.shared.backgroundColor.resolvedColor(with: traits).hexString
            )
        }
    }

    func testNarrowLayoutAndLargeFontsGrowWithoutLosingActions() {
        let settings = AppSettings.shared
        let originalLevel = settings.fontSizeLevel
        let originalFollowSystem = settings.followSystemFontSize
        defer {
            settings.fontSizeLevel = originalLevel
            settings.followSystemFontSize = originalFollowSystem
            FontManager.shared.notifyChange()
        }
        settings.followSystemFontSize = false
        settings.fontSizeLevel = 0
        FontManager.shared.notifyChange()
        let header = ProfileHeaderView()
        let menu = MeMenuView()
        configure(header)
        configure(menu, following: true, challenge: true)
        let smallHeader = fit(header)
        let smallMenu = fit(menu)

        settings.fontSizeLevel = 4
        FontManager.shared.notifyChange()
        configure(header)
        configure(menu, following: true, challenge: true)
        XCTAssertGreaterThan(fit(header), smallHeader)
        XCTAssertGreaterThan(fit(menu), smallMenu)
        for control in controls(in: header) + controls(in: menu) {
            XCTAssertGreaterThanOrEqual(control.bounds.height, 44)
            XCTAssertGreaterThan(control.bounds.width, 0)
        }
        XCTAssertEqual(actionIDs(in: menu).count, 8)
    }

    func testMessagesAreBesideNameAndNotDuplicatedInTheMenu() throws {
        let header = ProfileHeaderView()
        configure(header)
        _ = fit(header)
        let name = try XCTUnwrap(labels(in: header).first { $0.accessibilityIdentifier == "me.profile.name" })
        let avatar = try XCTUnwrap(descendants(in: header).first { $0.accessibilityIdentifier == "me.profile.avatar" })
        let message = try XCTUnwrap(controls(in: header).first { $0.accessibilityIdentifier == "me.messages" })
        let nameFrame = name.convert(name.bounds, to: header)
        let messageFrame = message.convert(message.bounds, to: header)
        XCTAssertGreaterThan(messageFrame.minX, nameFrame.maxX)
        XCTAssertEqual(messageFrame.midY, avatar.convert(avatar.bounds, to: header).midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(messageFrame.width, 44)
        XCTAssertGreaterThanOrEqual(messageFrame.height, 44)
        var openedInbox = false
        header.onMessageTapped = { openedInbox = true }
        message.sendActions(for: .touchUpInside)
        XCTAssertTrue(openedInbox)

        let menu = MeMenuView()
        configure(menu, following: true)
        XCTAssertFalse(actionIDs(in: menu).contains("me.messages"))
    }

    func testNotificationsAndFollowingAreFullWidthListRows() throws {
        let menu = MeMenuView()
        configure(menu, following: true)
        _ = fit(menu)
        let notifications = try XCTUnwrap(controls(in: menu).first { $0.accessibilityIdentifier == "me.notifications" })
        let following = try XCTUnwrap(controls(in: menu).first { $0.accessibilityIdentifier == "me.following" })
        let first = notifications.convert(notifications.bounds, to: menu)
        let second = following.convert(following.bounds, to: menu)
        XCTAssertEqual(first.minX, second.minX, accuracy: 1)
        XCTAssertEqual(first.width, menu.bounds.width - 40, accuracy: 1)
        XCTAssertEqual(first.width, second.width, accuracy: 1)
        XCTAssertGreaterThanOrEqual(second.minY, first.maxY)
        var selected: MeMenuView.Action?
        menu.onAction = { selected = $0 }
        following.sendActions(for: .touchUpInside)
        XCTAssertEqual(selected, .following)
    }

    func testThreeIdentityLinesUseAvatarHeightAtNormalAndLargeFonts() throws {
        let settings = AppSettings.shared
        let originalLevel = settings.fontSizeLevel
        let originalFollowSystem = settings.followSystemFontSize
        defer {
            settings.fontSizeLevel = originalLevel
            settings.followSystemFontSize = originalFollowSystem
            FontManager.shared.notifyChange()
        }
        settings.followSystemFontSize = false
        let profile = try JSONDecoder().decode(DiscourseUserProfile.self, from: Data("""
        {"id":1,"username":"lin","name":"A longer display name","title":"Member","bio_cooked":"<p>A biography below the identity row.</p>","created_at":"2026-08-27T00:00:00Z"}
        """.utf8))
        let header = ProfileHeaderView()
        for level in [0, 4] {
            settings.fontSizeLevel = level
            FontManager.shared.notifyChange()
            header.configure(
                user: nil, profile: profile, summary: nil, isAuthenticated: true,
                fallbackUsername: "lin", assetBaseURL: "https://example.com"
            )
            _ = fit(header)
            let avatar = try XCTUnwrap(descendants(in: header).first { $0.accessibilityIdentifier == "me.profile.avatar" })
            let name = try XCTUnwrap(labels(in: header).first { $0.accessibilityIdentifier == "me.profile.name" })
            let username = try XCTUnwrap(labels(in: header).first { $0.accessibilityIdentifier == "me.profile.username" })
            let joined = try XCTUnwrap(labels(in: header).first { $0.accessibilityIdentifier == "me.profile.joined" })
            let avatarFrame = avatar.convert(avatar.bounds, to: header)
            let nameFrame = name.convert(name.bounds, to: header)
            let usernameFrame = username.convert(username.bounds, to: header)
            let joinedFrame = joined.convert(joined.bounds, to: header)
            XCTAssertEqual(nameFrame.minY, avatarFrame.minY, accuracy: 0.5)
            XCTAssertEqual(joinedFrame.maxY, avatarFrame.maxY, accuracy: 0.5)
            XCTAssertEqual(nameFrame.minX, usernameFrame.minX, accuracy: 0.5)
            XCTAssertEqual(nameFrame.minX, joinedFrame.minX, accuracy: 0.5)
            XCTAssertGreaterThan(joinedFrame.minX, avatarFrame.maxX)
            XCTAssertGreaterThanOrEqual(usernameFrame.minY - nameFrame.maxY, 1.5)
            XCTAssertGreaterThanOrEqual(joinedFrame.minY - usernameFrame.maxY, 1.5)
        }
    }

    func testMenuSymbolsUseDefaultWeightAndOnlyMessagesKeepLightWeight() throws {
        let menu = MeMenuView()
        configure(menu, following: true, challenge: true)
        _ = fit(menu)
        let row = try XCTUnwrap(controls(in: menu).first { $0.accessibilityIdentifier == "me.notifications" })
        let icon = try XCTUnwrap(descendants(in: row).first { $0.accessibilityIdentifier == "me.notifications.icon" } as? UIImageView)
        XCTAssertEqual(icon.superview?.bounds.width ?? 0, FontManager.shared.scaled(18), accuracy: 1)
        XCTAssertTrue(icon.preferredSymbolConfiguration?.isEqual(
            UIImage.SymbolConfiguration(pointSize: FontManager.shared.scaled(18))
        ) == true)
        XCTAssertGreaterThanOrEqual(row.bounds.height, 56)

        for imageView in descendants(in: menu).compactMap({ $0 as? UIImageView }).filter({
            $0.accessibilityIdentifier?.hasSuffix(".icon") == true || $0.accessibilityIdentifier?.hasSuffix(".chevron") == true
        }) {
            let pointSize = imageView.accessibilityIdentifier?.hasSuffix(".icon") == true
                ? FontManager.shared.scaled(18) : CGFloat(11)
            XCTAssertTrue(imageView.preferredSymbolConfiguration?.isEqual(
                UIImage.SymbolConfiguration(pointSize: pointSize)
            ) == true)
        }

        let header = ProfileHeaderView()
        configure(header)
        _ = fit(header)
        let message = try XCTUnwrap(controls(in: header).first { $0.accessibilityIdentifier == "me.messages" } as? UIButton)
        XCTAssertGreaterThanOrEqual(message.bounds.width, 44)
        XCTAssertGreaterThanOrEqual(message.bounds.height, 44)
        XCTAssertTrue(message.configuration?.preferredSymbolConfigurationForImage?.isEqual(
            UIImage.SymbolConfiguration(pointSize: FontManager.shared.scaled(16), weight: .light)
        ) == true)
    }

    func testCompactIdentityFontsAndJoinedDateFitDefaultAvatar() throws {
        let settings = AppSettings.shared
        let originalLevel = settings.fontSizeLevel
        let originalFollowSystem = settings.followSystemFontSize
        defer {
            settings.fontSizeLevel = originalLevel
            settings.followSystemFontSize = originalFollowSystem
            FontManager.shared.notifyChange()
        }
        settings.fontSizeLevel = 0
        settings.followSystemFontSize = false
        FontManager.shared.notifyChange()
        let header = ProfileHeaderView()
        let profile = try JSONDecoder().decode(DiscourseUserProfile.self, from: Data(
            #"{"id":1,"username":"lin","name":"Lin","created_at":"2026-08-27T00:00:00Z"}"#.utf8
        ))
        header.configure(
            user: nil, profile: profile, summary: nil, isAuthenticated: true,
            fallbackUsername: "lin", assetBaseURL: "https://example.com"
        )
        _ = fit(header)
        let avatar = try XCTUnwrap(descendants(in: header).first { $0.accessibilityIdentifier == "me.profile.avatar" })
        let name = try XCTUnwrap(labels(in: header).first { $0.accessibilityIdentifier == "me.profile.name" })
        let username = try XCTUnwrap(labels(in: header).first { $0.accessibilityIdentifier == "me.profile.username" })
        XCTAssertEqual(avatar.bounds.height, 64, accuracy: 0.5)
        XCTAssertEqual(name.font.pointSize, 24)
        XCTAssertEqual(username.font.pointSize, 14)
        let gap = username.convert(username.bounds, to: header).minY - name.convert(name.bounds, to: header).maxY
        XCTAssertGreaterThanOrEqual(gap, 1.5)
        XCTAssertLessThanOrEqual(gap, 4)
    }

    func testCompactStatisticsAndRoundingBoundaries() {
        let examples: [(Int, String)] = [
            (0, "0"), (999, "999"), (1_000, "1k"), (1_234, "1.2k"),
            (1_250, "1.3k"), (12_000, "12k"), (12_345, "12.3k"),
            (999_949, "999.9k"), (999_950, "1M"), (1_250_000, "1.3M"),
            (999_950_000, "1B"), (12_000_000_000, "12B"),
            (1_500_000_000_000, "1.5T"), (-1_234, "-1.2k"),
        ]
        for (value, expected) in examples {
            XCTAssertEqual(ProfileStatFormatter.string(for: value), expected, "\(value)")
        }
        XCTAssertLessThanOrEqual(ProfileStatFormatter.string(for: .max).count, 8)
        XCTAssertLessThanOrEqual(ProfileStatFormatter.string(for: .min).count, 8)
    }

    func testCompactStatisticsFitNarrowColumnsAndKeepExactAccessibilityValues() throws {
        let header = ProfileHeaderView()
        let values: [(String, Int, String)] = [
            ("topics", 1_234, "1.2k"), ("posts", 999_950, "1M"),
            ("likes", 2_345_678, "2.3M"), ("days", 12_345, "12.3k"),
        ]
        header.configure(
            user: nil, profile: nil,
            summary: DiscourseUserSummary(topicCount: 1_234, postCount: 999_950, likesGiven: 0, likesReceived: 2_345_678, daysVisited: 12_345),
            isAuthenticated: true, fallbackUsername: "lin", assetBaseURL: "https://example.com"
        )
        _ = fit(header)
        for (key, exact, compact) in values {
            let label = try XCTUnwrap(labels(in: header).first { $0.accessibilityIdentifier == "me.stats.\(key).value" })
            let control = try XCTUnwrap(controls(in: header).first { $0.accessibilityIdentifier == "me.stats.\(key)" })
            XCTAssertEqual(label.text, compact)
            XCTAssertTrue(control.accessibilityLabel?.contains(exact.formatted()) == true)
            XCTAssertGreaterThan(label.bounds.width, 0)
        }
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: header.bounds).image { context in
            header.layer.render(in: context.cgContext)
        })
        attachment.name = "Compact profile statistics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testProfileLoadingIndicatorStartsAndStops() throws {
        let loading = MeSkeletonView(frame: CGRect(x: 0, y: 0, width: 420, height: 740))
        loading.configureTheme()
        loading.setLoading(true)
        loading.layoutIfNeeded()
        let spinner = try XCTUnwrap(descendants(in: loading).compactMap { $0 as? UIActivityIndicatorView }.first)
        XCTAssertFalse(loading.isHidden)
        XCTAssertTrue(spinner.isAnimating)
        XCTAssertTrue(labels(in: loading).contains { $0.text == String(localized: "me.loading_profile") })
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: loading.bounds).image { context in
            loading.layer.render(in: context.cgContext)
        })
        attachment.name = "Profile loading state"
        attachment.lifetime = .keepAlways
        add(attachment)
        loading.setLoading(false)
        XCTAssertTrue(loading.isHidden)
        XCTAssertFalse(spinner.isAnimating)
    }

    private func configure(
        _ menu: MeMenuView, authenticated: Bool = true, following: Bool = false,
        challenge: Bool = false, notifications: Bool = false
    ) {
        menu.configure(
            isAuthenticated: authenticated, showsFollowing: following, showsChallenge: challenge,
            blockedCount: 2, unreadNotifications: notifications
        )
    }

    private func configure(_ header: ProfileHeaderView, unreadMessages: Bool = false) {
        header.configure(
            user: DiscourseCurrentUser(
                id: 1, username: "lin", name: "Lin", avatarTemplate: nil,
                unreadNotifications: nil, unreadPrivateMessages: nil, unreadHighPriorityNotifications: nil
            ),
            profile: nil,
            summary: DiscourseUserSummary(topicCount: 32, postCount: 186, likesGiven: 12, likesReceived: 1024, daysVisited: 128),
            isAuthenticated: true, fallbackUsername: nil, assetBaseURL: "https://example.com",
            unreadMessages: unreadMessages
        )
    }

    private func fit(_ view: UIView) -> CGFloat {
        let height = view.systemLayoutSizeFitting(
            CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        view.frame = CGRect(x: 0, y: 0, width: 320, height: height)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return height
    }

    private func descendants(in view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func controls(in view: UIView) -> [UIControl] {
        descendants(in: view).compactMap { $0 as? UIControl }
    }

    private func labels(in view: UIView) -> [UILabel] {
        descendants(in: view).compactMap { $0 as? UILabel }
    }

    private func actionIDs(in view: UIView) -> Set<String> {
        Set(controls(in: view).compactMap(\.accessibilityIdentifier))
    }

    private func contrast(_ first: UIColor, _ second: UIColor) -> CGFloat {
        func luminance(_ color: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: nil)
            let values = [r, g, b].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
        }
        let values = [luminance(first), luminance(second)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }
}
