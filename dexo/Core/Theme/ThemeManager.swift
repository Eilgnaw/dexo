import UIKit

// MARK: - Theme Definition

struct ThemeDefinition: Equatable, Identifiable {
    let id: String
    let name: String
    /// Accent / tint color hex for light mode
    let lightAccentHex: String
    /// Accent / tint color hex for dark mode
    let darkAccentHex: String
    /// Page background hex for light mode (systemGroupedBackground equivalent)
    let lightBackgroundHex: String
    /// Page background hex for dark mode
    let darkBackgroundHex: String
    /// Card / cell background hex for light mode (secondarySystemGroupedBackground equivalent)
    let lightCardBackgroundHex: String
    /// Card / cell background hex for dark mode
    let darkCardBackgroundHex: String
}

extension ThemeDefinition {
    static let presets: [ThemeDefinition] = [
        ThemeDefinition(
            id: "default",
            name: String(localized: "theme.default"),
            lightAccentHex: "007AFF",
            darkAccentHex: "0A84FF",
            lightBackgroundHex: "F2F2F7",
            darkBackgroundHex: "000000",
            lightCardBackgroundHex: "FFFFFF",
            darkCardBackgroundHex: "1C1C1E"
        ),
        ThemeDefinition(
            id: "forest",
            name: String(localized: "theme.forest"),
            lightAccentHex: "34A853",
            darkAccentHex: "4ECB71",
            lightBackgroundHex: "E3EDE5",
            darkBackgroundHex: "0A1A0F",
            lightCardBackgroundHex: "F0F5F1",
            darkCardBackgroundHex: "1A2E1F"
        ),
        ThemeDefinition(
            id: "ocean",
            name: String(localized: "theme.ocean"),
            lightAccentHex: "0077B6",
            darkAccentHex: "48CAE4",
            lightBackgroundHex: "D6ECF2",
            darkBackgroundHex: "03071E",
            lightCardBackgroundHex: "EDF6F9",
            darkCardBackgroundHex: "14213D"
        ),
        ThemeDefinition(
            id: "sunset",
            name: String(localized: "theme.sunset"),
            lightAccentHex: "E85D04",
            darkAccentHex: "F48C06",
            lightBackgroundHex: "FFE8CC",
            darkBackgroundHex: "1A0A00",
            lightCardBackgroundHex: "FFF3E6",
            darkCardBackgroundHex: "2D1800"
        ),
        ThemeDefinition(
            id: "violet",
            name: String(localized: "theme.violet"),
            lightAccentHex: "7C3AED",
            darkAccentHex: "A78BFA",
            lightBackgroundHex: "E6E0FF",
            darkBackgroundHex: "0D0726",
            lightCardBackgroundHex: "F3F0FF",
            darkCardBackgroundHex: "1E1340"
        ),
        ThemeDefinition(
            id: "rose",
            name: String(localized: "theme.rose"),
            lightAccentHex: "E11D48",
            darkAccentHex: "FB7185",
            lightBackgroundHex: "FFE0E3",
            darkBackgroundHex: "1A0008",
            lightCardBackgroundHex: "FFF1F2",
            darkCardBackgroundHex: "2D0013"
        ),
    ]
}

// MARK: - Custom Theme Scheme

struct CustomThemeScheme: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var lightAccentHex: String
    var darkAccentHex: String
    var lightBackgroundHex: String
    var darkBackgroundHex: String
    var lightCardBackgroundHex: String
    var darkCardBackgroundHex: String

    init(
        id: String = UUID().uuidString,
        name: String = "",
        lightAccentHex: String = "007AFF",
        darkAccentHex: String = "0A84FF",
        lightBackgroundHex: String = "F2F2F7",
        darkBackgroundHex: String = "000000",
        lightCardBackgroundHex: String = "FFFFFF",
        darkCardBackgroundHex: String = "1C1C1E"
    ) {
        self.id = id
        self.name = name
        self.lightAccentHex = lightAccentHex
        self.darkAccentHex = darkAccentHex
        self.lightBackgroundHex = lightBackgroundHex
        self.darkBackgroundHex = darkBackgroundHex
        self.lightCardBackgroundHex = lightCardBackgroundHex
        self.darkCardBackgroundHex = darkCardBackgroundHex
    }

    func toThemeDefinition() -> ThemeDefinition {
        ThemeDefinition(
            id: "custom_\(id)",
            name: name,
            lightAccentHex: lightAccentHex,
            darkAccentHex: darkAccentHex,
            lightBackgroundHex: lightBackgroundHex,
            darkBackgroundHex: darkBackgroundHex,
            lightCardBackgroundHex: lightCardBackgroundHex,
            darkCardBackgroundHex: darkCardBackgroundHex
        )
    }
}

// MARK: - Theme Manager

import Perception

@Perceptible
final class ThemeManager {
    static let shared = ThemeManager()
    static let themeDidChangeNotification = Notification.Name("ThemeDidChange")

    private let settings = AppSettings.shared

    /// Stored property — bumped on every theme change so `withObservationTracking` fires.
    private(set) var revision: Int = 0

    // Caches invalidated by bumping `revision`. `@PerceptionIgnored` keeps these
    // out of observation tracking — otherwise the lazy fill inside a getter
    // would notify observers and re-trigger the very work we're caching.
    @PerceptionIgnored private var _cachedTheme: ThemeDefinition?
    @PerceptionIgnored private var _cachedThemeRevision: Int = -1
    @PerceptionIgnored private var _accentColor: UIColor?
    @PerceptionIgnored private var _backgroundColor: UIColor?
    @PerceptionIgnored private var _cardBackgroundColor: UIColor?
    @PerceptionIgnored private var _codeBackgroundColor: UIColor?
    @PerceptionIgnored private var _quoteBarColor: UIColor?

    var currentTheme: ThemeDefinition {
        _ = revision
        if _cachedThemeRevision == revision, let cached = _cachedTheme {
            return cached
        }
        let computed = computeCurrentTheme()
        invalidateColorCaches()
        _cachedTheme = computed
        _cachedThemeRevision = revision
        return computed
    }

    private func computeCurrentTheme() -> ThemeDefinition {
        let selectedId = settings.selectedThemeId
        if selectedId.hasPrefix("custom_") {
            let schemeId = String(selectedId.dropFirst("custom_".count))
            if let scheme = settings.customThemeScheme(id: schemeId) {
                return scheme.toThemeDefinition()
            }
        }
        return ThemeDefinition.presets.first { $0.id == selectedId }
            ?? ThemeDefinition.presets[0]
    }

    private func invalidateColorCaches() {
        _accentColor = nil
        _backgroundColor = nil
        _cardBackgroundColor = nil
        _codeBackgroundColor = nil
        _quoteBarColor = nil
    }

    // MARK: - Dynamic Colors

    /// Accent / tint color that adapts to light/dark mode
    var accentColor: UIColor {
        _ = revision
        if let c = _accentColor { return c }
        let theme = currentTheme
        let color = dynamicColor(light: theme.lightAccentHex, dark: theme.darkAccentHex)
        _accentColor = color
        return color
    }

    /// Page background (replaces systemGroupedBackground)
    var backgroundColor: UIColor {
        _ = revision
        if let c = _backgroundColor { return c }
        let theme = currentTheme
        let color = dynamicColor(light: theme.lightBackgroundHex, dark: theme.darkBackgroundHex)
        _backgroundColor = color
        return color
    }

    /// Card / cell background (replaces secondarySystemGroupedBackground)
    var cardBackgroundColor: UIColor {
        _ = revision
        if let c = _cardBackgroundColor { return c }
        let theme = currentTheme
        let color = dynamicColor(light: theme.lightCardBackgroundHex, dark: theme.darkCardBackgroundHex)
        _cardBackgroundColor = color
        return color
    }

    /// Code block / quote background — accent at very low opacity over card background
    var codeBackgroundColor: UIColor {
        _ = revision
        if let c = _codeBackgroundColor { return c }
        // Capture the cached accent/card UIColors so the trait-resolved closure
        // doesn't bounce back through ThemeManager getters on every resolve.
        let accent = accentColor
        let card = cardBackgroundColor
        let color = UIColor { traitCollection in
            let a = accent.resolvedColor(with: traitCollection)
            let c = card.resolvedColor(with: traitCollection)
            return a.blended(into: c, ratio: 0.08)
        }
        _codeBackgroundColor = color
        return color
    }

    /// Blockquote / quote left bar — accent at medium opacity
    var quoteBarColor: UIColor {
        _ = revision
        if let c = _quoteBarColor { return c }
        let color = accentColor.withAlphaComponent(0.4)
        _quoteBarColor = color
        return color
    }

    /// A solid accent surface with readable text, including very light custom themes.
    var profileHeaderPalette: ProfileHeaderPalette {
        ProfileHeaderPalette(accent: accentColor, background: backgroundColor)
    }

    /// Image-derived colors are scoped to the personal center, not the global theme.
    func profilePagePalette(imageTint: UIColor? = nil) -> ProfilePagePalette {
        guard let imageTint else {
            return ProfilePagePalette(
                header: profileHeaderPalette, background: backgroundColor,
                cardBackground: cardBackgroundColor, usesImageColors: false
            )
        }
        let page = UIColor { traits in
            let tint = imageTint.resolvedColor(with: traits)
            return tint.blended(into: traits.userInterfaceStyle == .dark ? .black : .white, ratio: 0.20)
        }
        let card = UIColor { traits in
            let tint = imageTint.resolvedColor(with: traits)
            let neutral = traits.userInterfaceStyle == .dark
                ? UIColor.secondarySystemGroupedBackground.resolvedColor(with: traits) : .white
            return tint.blended(into: neutral, ratio: traits.userInterfaceStyle == .dark ? 0.16 : 0.05)
        }
        let header = UIColor { traits in
            imageTint.resolvedColor(with: traits).blended(
                into: .black, ratio: traits.userInterfaceStyle == .dark ? 0.55 : 0.85
            )
        }
        return ProfilePagePalette(
            header: ProfileHeaderPalette(accent: header, background: page),
            background: page, cardBackground: card, usesImageColors: true
        )
    }

    // MARK: - Apply

    func applyToAllWindows() {
        let tint = accentColor
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.tintColor = tint
            }
        }
    }

    func apply(to window: UIWindow) {
        window.tintColor = accentColor
    }

    func selectTheme(id: String) {
        settings.selectedThemeId = id
        invalidateAllCaches()
        revision += 1
        applyToAllWindows()
        NotificationCenter.default.post(name: Self.themeDidChangeNotification, object: nil)
    }

    /// Call after modifying custom color properties on AppSettings.
    func notifyChange() {
        invalidateAllCaches()
        revision += 1
        applyToAllWindows()
        NotificationCenter.default.post(name: Self.themeDidChangeNotification, object: nil)
    }

    /// Color getters short-circuit on their cached UIColor before reading
    /// `currentTheme`, so we must drop both the theme and color caches eagerly
    /// here — lazy invalidation inside `currentTheme` would never fire.
    private func invalidateAllCaches() {
        _cachedTheme = nil
        _cachedThemeRevision = -1
        invalidateColorCaches()
    }

    // MARK: - Helpers

    private func dynamicColor(light lightHex: String, dark darkHex: String) -> UIColor {
        UIColor { traitCollection in
            switch traitCollection.userInterfaceStyle {
            case .dark:
                return UIColor(hex: darkHex) ?? .systemBackground
            default:
                return UIColor(hex: lightHex) ?? .systemBackground
            }
        }
    }
}

struct ProfilePagePalette {
    let header: ProfileHeaderPalette
    let background: UIColor
    let cardBackground: UIColor
    let usesImageColors: Bool
}

struct ProfileHeaderPalette {
    let background: UIColor
    let foreground: UIColor
    let secondaryForeground: UIColor
    let imageScrim: UIColor

    init(accent: UIColor, background: UIColor) {
        let surface = UIColor { traits in
            let base = background.resolvedColor(with: traits)
            let tint = accent.resolvedColor(with: traits)
            var alpha: CGFloat = 0
            tint.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            // Custom accents may include alpha; the header itself must remain opaque.
            return tint.blended(into: base, ratio: alpha).withAlphaComponent(1)
        }
        self.background = surface
        foreground = UIColor { traits in
            Self.textColor(on: surface.resolvedColor(with: traits))
        }
        imageScrim = UIColor { traits in
            let text = Self.textColor(on: surface.resolvedColor(with: traits))
            // Bound the contrast of even an all-white/all-black photo. The
            // gradient then blends this readable image back into the theme.
            return text == .white ? UIColor.black.withAlphaComponent(0.58) : UIColor.white.withAlphaComponent(0.68)
        }
        secondaryForeground = UIColor { traits in
            let resolved = surface.resolvedColor(with: traits)
            let text = Self.textColor(on: resolved)
            // Keep secondary text quieter without dropping below readable contrast.
            for ratio in stride(from: CGFloat(0.78), through: CGFloat(0.98), by: CGFloat(0.02)) {
                let candidate = text.blended(into: resolved, ratio: ratio)
                if Self.contrast(candidate, resolved) >= 4.5 { return candidate }
            }
            return text
        }
    }

    private static func textColor(on background: UIColor) -> UIColor {
        contrast(.white, background) >= contrast(.black, background) ? .white : .black
    }

    private static func contrast(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let a = luminance(first)
        let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func luminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}

// MARK: - UIColor + Hex

extension UIColor {
    /// Accepts 6-char (RRGGBB) or 8-char (RRGGBBAA) hex strings.
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let int = UInt64(hex, radix: 16) else { return nil }
        switch hex.count {
        case 6:
            let r = CGFloat((int >> 16) & 0xFF) / 255
            let g = CGFloat((int >> 8) & 0xFF) / 255
            let b = CGFloat(int & 0xFF) / 255
            self.init(red: r, green: g, blue: b, alpha: 1)
        case 8:
            let r = CGFloat((int >> 24) & 0xFF) / 255
            let g = CGFloat((int >> 16) & 0xFF) / 255
            let b = CGFloat((int >> 8) & 0xFF) / 255
            let a = CGFloat(int & 0xFF) / 255
            self.init(red: r, green: g, blue: b, alpha: a)
        default:
            return nil
        }
    }

    /// Returns RRGGBB when fully opaque, RRGGBBAA when translucent.
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        if a >= 0.999 {
            return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }
        return String(format: "%02X%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
    }

    /// Blend `self` into `base` at the given ratio (0 = all base, 1 = all self).
    func blended(into base: UIColor, ratio: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        base.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(
            red: r1 * ratio + r2 * (1 - ratio),
            green: g1 * ratio + g2 * (1 - ratio),
            blue: b1 * ratio + b2 * (1 - ratio),
            alpha: a1 * ratio + a2 * (1 - ratio)
        )
    }
}
