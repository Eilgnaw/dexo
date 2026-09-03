import UIKit

import Perception

@Perceptible
final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    private init() {
        defaults = .standard
    }

    init(testingDefaults defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - Appearance

    enum AppearanceMode: Int, CaseIterable {
        case system = 0
        case light = 1
        case dark = 2

        var title: String {
            switch self {
            case .system: return String(localized: "appearance.system")
            case .light: return String(localized: "appearance.light")
            case .dark: return String(localized: "appearance.dark")
            }
        }

        var userInterfaceStyle: UIUserInterfaceStyle {
            switch self {
            case .system: return .unspecified
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.integer(forKey: "appearanceMode")) ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "appearanceMode")
            applyAppearance()
        }
    }

    func applyAppearance() {
        let style = appearanceMode.userInterfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    // MARK: - General

    var autoOpenLastForum: Bool {
        get { defaults.bool(forKey: "autoOpenLastForum") }
        set { defaults.set(newValue, forKey: "autoOpenLastForum") }
    }

    var lastOpenedForumId: Int64? {
        get {
            guard defaults.object(forKey: "lastOpenedForumId") != nil else { return nil }
            return Int64(defaults.integer(forKey: "lastOpenedForumId"))
        }
        set {
            if let value = newValue {
                defaults.set(Int(value), forKey: "lastOpenedForumId")
            } else {
                defaults.removeObject(forKey: "lastOpenedForumId")
            }
        }
    }

    var hasShownAutoOpenPrompt: Bool {
        get { defaults.bool(forKey: "hasShownAutoOpenPrompt") }
        set { defaults.set(newValue, forKey: "hasShownAutoOpenPrompt") }
    }

    // MARK: - Local User Blocklist

    static let maximumLocalBlockedUsers = 50

    struct LocalBlockedUser: Codable, Equatable, Identifiable {
        let forumBaseURL: String
        let username: String

        var id: String {
            "\(forumBaseURL)|\(username.lowercased())"
        }
    }

    enum LocalBlockResult: Equatable {
        case added
        case alreadyBlocked
        case limitReached
    }

    /// Observable in-memory generation for screens that need to rebuild their
    /// local content snapshots when the persisted blocklist changes.
    private(set) var localBlocklistRevision = 0

    private(set) var localBlockedUsers: [LocalBlockedUser] {
        get {
            guard let data = defaults.data(forKey: "localBlockedUsers"),
                  let users = try? JSONDecoder().decode([LocalBlockedUser].self, from: data)
            else { return [] }
            return Self.sanitizedLocalBlockedUsers(users)
        }
        set {
            let users = Self.sanitizedLocalBlockedUsers(newValue)
            if let data = try? JSONEncoder().encode(users) {
                defaults.set(data, forKey: "localBlockedUsers")
            }
        }
    }

    func localBlockedUsers(for baseURL: String) -> [LocalBlockedUser] {
        let forum = Self.normalizedForumBaseURL(baseURL)
        return localBlockedUsers.filter { $0.forumBaseURL == forum }
    }

    func localBlockedUsernames(for baseURL: String) -> Set<String> {
        Set(localBlockedUsers(for: baseURL).map { $0.username.lowercased() })
    }

    func isUserLocallyBlocked(username: String, baseURL: String) -> Bool {
        localBlockedUsernames(for: baseURL).contains(username.lowercased())
    }

    @discardableResult
    func blockUserLocally(username: String, baseURL: String) -> LocalBlockResult {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else { return .alreadyBlocked }

        let forum = Self.normalizedForumBaseURL(baseURL)
        var users = localBlockedUsers
        if users.contains(where: {
            $0.forumBaseURL == forum
                && $0.username.caseInsensitiveCompare(trimmedUsername) == .orderedSame
        }) {
            return .alreadyBlocked
        }
        guard users.count < Self.maximumLocalBlockedUsers else { return .limitReached }

        users.append(LocalBlockedUser(forumBaseURL: forum, username: trimmedUsername))
        localBlockedUsers = users
        localBlocklistRevision &+= 1
        return .added
    }

    @discardableResult
    func unblockUserLocally(username: String, baseURL: String) -> Bool {
        let forum = Self.normalizedForumBaseURL(baseURL)
        var users = localBlockedUsers
        let originalCount = users.count
        users.removeAll {
            $0.forumBaseURL == forum
                && $0.username.caseInsensitiveCompare(username) == .orderedSame
        }
        guard users.count != originalCount else { return false }

        localBlockedUsers = users
        localBlocklistRevision &+= 1
        return true
    }

    private static func normalizedForumBaseURL(_ baseURL: String) -> String {
        guard let url = URL(string: baseURL),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else {
            return baseURL
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .lowercased()
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func sanitizedLocalBlockedUsers(
        _ users: [LocalBlockedUser]
    ) -> [LocalBlockedUser] {
        var result: [LocalBlockedUser] = []
        var seen: Set<String> = []
        for user in users {
            let username = user.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else { continue }
            let forum = normalizedForumBaseURL(user.forumBaseURL)
            let entry = LocalBlockedUser(forumBaseURL: forum, username: username)
            guard seen.insert(entry.id).inserted else { continue }
            result.append(entry)
            if result.count == maximumLocalBlockedUsers { break }
        }
        return result
    }

    // MARK: - Theme

    var selectedThemeId: String {
        get { defaults.string(forKey: "selectedThemeId") ?? "default" }
        set { defaults.set(newValue, forKey: "selectedThemeId") }
    }

    var customThemeSchemes: [CustomThemeScheme] {
        get {
            guard let data = defaults.data(forKey: "customThemeSchemes"),
                  let schemes = try? JSONDecoder().decode([CustomThemeScheme].self, from: data)
            else { return [] }
            return schemes
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "customThemeSchemes")
            }
        }
    }

    func customThemeScheme(id: String) -> CustomThemeScheme? {
        customThemeSchemes.first { $0.id == id }
    }

    func saveCustomThemeScheme(_ scheme: CustomThemeScheme) {
        var schemes = customThemeSchemes
        if let idx = schemes.firstIndex(where: { $0.id == scheme.id }) {
            schemes[idx] = scheme
        } else {
            schemes.append(scheme)
        }
        customThemeSchemes = schemes
    }

    func deleteCustomThemeScheme(id: String) {
        var schemes = customThemeSchemes
        schemes.removeAll { $0.id == id }
        customThemeSchemes = schemes
    }

    // MARK: - Font Size

    /// Whether to follow the system Dynamic Type setting.
    var followSystemFontSize: Bool {
        get {
            // Default to true if key has never been set
            if defaults.object(forKey: "followSystemFontSize") == nil { return true }
            return defaults.bool(forKey: "followSystemFontSize")
        }
        set { defaults.set(newValue, forKey: "followSystemFontSize") }
    }

    /// Font size level: -3 … +4, where 0 is the default.
    var fontSizeLevel: Int {
        get { defaults.integer(forKey: "fontSizeLevel") }
        set { defaults.set(newValue, forKey: "fontSizeLevel") }
    }

    /// Scale factor derived from the app-level font size setting.
    var appFontScale: CGFloat {
        switch fontSizeLevel {
        case -3: return 0.82
        case -2: return 0.88
        case -1: return 0.94
        case  0: return 1.0
        case  1: return 1.08
        case  2: return 1.16
        case  3: return 1.25
        case  4: return 1.35
        default: return 1.0
        }
    }

    // MARK: - Boost Display

    enum BoostDisplayMode: Int, CaseIterable {
        case danmaku = 0
        case expand = 1

        var title: String {
            switch self {
            case .expand: return String(localized: "settings.boost_display.expand")
            case .danmaku: return String(localized: "settings.boost_display.danmaku")
            }
        }
    }

    /// Whether the topic detail page should default to the indented tree
    /// rendering. Persisted between launches so the user doesn't have to flip
    /// the nav-bar toggle every time they open a topic.
    var topicTreeMode: Bool {
        get { defaults.bool(forKey: "topicTreeMode") }
        set { defaults.set(newValue, forKey: "topicTreeMode") }
    }

    /// Sort order for the nested tree endpoint. One of "top", "new", "old".
    /// Persists the user's last choice across topic opens.
    var topicTreeSort: String {
        get { defaults.string(forKey: "topicTreeSort") ?? "top" }
        set { defaults.set(newValue, forKey: "topicTreeSort") }
    }

    var boostDisplayMode: BoostDisplayMode {
        get { BoostDisplayMode(rawValue: defaults.integer(forKey: "boostDisplayMode")) ?? .danmaku }
        set { defaults.set(newValue.rawValue, forKey: "boostDisplayMode") }
    }

    // MARK: - Read Tracking

    /// linux.do timing uploads default on for browser-authenticated accounts.
    /// Checking `object(forKey:)` preserves an explicit off value written by
    /// the user, including the choice made after a Cloudflare challenge.
    var linuxDoReadTimingsEnabled: Bool {
        get {
            guard defaults.object(forKey: "linuxDoReadTimingsEnabled") != nil else {
                return true
            }
            return defaults.bool(forKey: "linuxDoReadTimingsEnabled")
        }
        set {
            let wasEnabled = linuxDoReadTimingsEnabled
            let neededVerification = linuxDoReadTimingsNeedsVerification
            defaults.set(newValue, forKey: "linuxDoReadTimingsEnabled")
            if !newValue {
                defaults.set(false, forKey: "linuxDoReadTimingsNeedsVerification")
            }
            if newValue != wasEnabled
                || neededVerification != linuxDoReadTimingsNeedsVerification
            {
                notifyLinuxDoReadTimingsSettingDidChange()
            }
        }
    }

    /// Persisted circuit-breaker state. Keeping it separate from the user's
    /// switch lets the UI explain that reporting is paused rather than off,
    /// and prevents a relaunch from immediately hitting Cloudflare again.
    var linuxDoReadTimingsNeedsVerification: Bool {
        get { defaults.bool(forKey: "linuxDoReadTimingsNeedsVerification") }
        set {
            let normalizedValue = newValue && linuxDoReadTimingsEnabled
            guard normalizedValue != linuxDoReadTimingsNeedsVerification else { return }
            defaults.set(normalizedValue, forKey: "linuxDoReadTimingsNeedsVerification")
            notifyLinuxDoReadTimingsSettingDidChange()
        }
    }

    private func notifyLinuxDoReadTimingsSettingDidChange() {
        NotificationCenter.default.post(
            name: .linuxDoReadTimingsSettingDidChange,
            object: self
        )
    }

    // MARK: - DNS over HTTPS

    struct DoHServer: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        var name: String
        var urlString: String

        init(id: UUID = UUID(), name: String, urlString: String) {
            self.id = id
            self.name = name
            self.urlString = urlString
        }
    }

    var dohEnabled: Bool {
        get { defaults.bool(forKey: "dohEnabled") }
        set { defaults.set(newValue, forKey: "dohEnabled") }
    }

    /// All resolvers explicitly configured by the user.
    var dohServers: [DoHServer] {
        get {
            if let data = defaults.data(forKey: "dohServers"),
               let servers = try? JSONDecoder().decode([DoHServer].self, from: data)
            {
                return servers
            }
            return []
        }
        set {
            persistDoHServers(newValue)
            if let currentID = storedDefaultDoHServerID,
               newValue.contains(where: { $0.id == currentID })
            {
                return
            }
            if let first = newValue.first {
                defaults.set(first.id.uuidString, forKey: "defaultDoHServerID")
            } else {
                defaults.removeObject(forKey: "defaultDoHServerID")
            }
        }
    }

    var defaultDoHServerID: UUID? {
        get {
            let servers = dohServers
            if let stored = storedDefaultDoHServerID,
               servers.contains(where: { $0.id == stored })
            {
                return stored
            }
            return servers.first?.id
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: "defaultDoHServerID")
                return
            }
            guard dohServers.contains(where: { $0.id == newValue }) else { return }
            defaults.set(newValue.uuidString, forKey: "defaultDoHServerID")
        }
    }

    var defaultDoHServer: DoHServer? {
        let servers = dohServers
        guard let id = defaultDoHServerID else { return servers.first }
        return servers.first { $0.id == id } ?? servers.first
    }

    func saveDoHServer(_ server: DoHServer) {
        var servers = dohServers
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        dohServers = servers
    }

    func deleteDoHServer(id: UUID) {
        var servers = dohServers
        servers.removeAll { $0.id == id }
        dohServers = servers
    }

    private var storedDefaultDoHServerID: UUID? {
        defaults.string(forKey: "defaultDoHServerID").flatMap(UUID.init(uuidString:))
    }

    private func persistDoHServers(_ servers: [DoHServer]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: "dohServers")
    }
}

extension Notification.Name {
    static let linuxDoReadTimingsSettingDidChange = Notification.Name(
        "linuxDoReadTimingsSettingDidChange"
    )
}
