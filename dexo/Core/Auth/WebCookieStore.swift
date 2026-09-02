import Foundation
import WebKit

/// In-memory + persisted cookie store used for web-login sessions.
/// Cookies are keyed by "domain|name|path" for deduplication.
final class WebCookieStore {
    static let shared = WebCookieStore()

    private var jar: [String: HTTPCookie] = [:]
    private let lock = NSLock()
    private let filePath: URL

    private var userAgents: [String: String] = [:]
    private let userAgentPath: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        filePath = dir.appendingPathComponent("dexo_web_cookies.json")
        userAgentPath = dir.appendingPathComponent("dexo_web_user_agents.json")
        load()
        if let data = try? Data(contentsOf: userAgentPath),
           let saved = try? JSONDecoder().decode([String: String].self, from: data)
        {
            userAgents = saved
        } else if let legacy = try? String(contentsOf: dir.appendingPathComponent("dexo_web_ua.txt"), encoding: .utf8) {
            // Preserve existing sessions, but never let another site's next
            // login replace the User-Agent paired with their clearance.
            for cookie in jar.values {
                userAgents[cookie.domain.lowercased()] = legacy
            }
            saveUserAgents()
        }
    }

    // MARK: - Read / Write

    func userAgent(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let exact = userAgents[host] { return exact }
        // Domain-scoped entries only come from migrating the old UA file.
        return userAgents.keys
            .filter { Self.cookieDomain($0, matchesHost: host) }
            .sorted { $0.count > $1.count }
            .first.flatMap { userAgents[$0] }
    }

    func setUserAgent(_ userAgent: String?, for url: URL) {
        guard let host = url.host?.lowercased(), let userAgent, !userAgent.isEmpty else { return }
        lock.lock()
        let changed = userAgents[host] != userAgent
        userAgents[host] = userAgent
        lock.unlock()
        if changed { saveUserAgents() }
    }

    func setCookies(_ cookies: [HTTPCookie]) {
        let now = Date()
        lock.lock()
        for c in cookies {
            // Drop already-expired cookies instead of letting them overwrite a still-valid entry.
            if let expires = c.expiresDate, expires <= now {
                jar.removeValue(forKey: key(for: c))
            } else {
                jar[key(for: c)] = c
            }
        }
        lock.unlock()
        save()
    }

    func cookies(for url: URL) -> [HTTPCookie] {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        return jar.values.filter { cookie in
            // Skip expired cookies so a stale/expired `_t` left in the jar never gets sent.
            if let expires = cookie.expiresDate, expires <= now { return false }
            return Self.cookieDomain(cookie.domain, matchesHost: host)
                && path.hasPrefix(cookie.path)
        }
    }

    func cookieHeader(for url: URL, includeSessionCookies: Bool = true) -> String {
        cookies(for: url)
            .filter { includeSessionCookies || Self.isChallengeCookie($0) }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func isChallengeCookie(_ cookie: HTTPCookie) -> Bool {
        ["cf_clearance", "__cf_bm", "_cfuvid"].contains(cookie.name)
    }

    func mergeResponseHeaders(_ headers: [AnyHashable: Any], for url: URL, includeSessionCookies: Bool = true) {
        var stringHeaders: [String: String] = [:]
        for (k, v) in headers { stringHeaders["\(k)"] = "\(v)" }
        let newCookies = HTTPCookie.cookies(withResponseHeaderFields: stringHeaders, for: url)
            .filter { includeSessionCookies || Self.isChallengeCookie($0) }
        if !newCookies.isEmpty { setCookies(newCookies) }
    }

    struct Snapshot {
        fileprivate let cookies: [String: HTTPCookie]
    }

    func snapshot(for url: URL) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot(Array(jar.values), for: url)
    }

    private func snapshot(_ cookies: [HTTPCookie], for url: URL) -> Snapshot {
        guard let host = url.host else { return Snapshot(cookies: [:]) }
        let now = Date()
        var result: [String: HTTPCookie] = [:]
        for cookie in cookies where Self.cookieDomain(cookie.domain, matchesHost: host)
            && (cookie.expiresDate.map { $0 > now } ?? true)
        {
            result[key(for: cookie)] = cookie
        }
        return Snapshot(cookies: result)
    }

    /// Apply only changes made by this browser. Unchanged WebKit cookies must
    /// not roll back a newer Set-Cookie received by the native API meanwhile.
    @discardableResult
    func mergeWebViewCookies(_ cookies: [HTTPCookie], for url: URL, since previous: Snapshot) -> Snapshot {
        let current = snapshot(cookies, for: url)
        lock.lock()
        for (key, oldCookie) in previous.cookies where current.cookies[key] == nil {
            if Self.sameCookie(jar[key], oldCookie) {
                jar.removeValue(forKey: key)
            }
        }
        for (key, cookie) in current.cookies where !Self.sameCookie(previous.cookies[key], cookie) {
            jar[key] = cookie
        }
        lock.unlock()
        save()
        return current
    }

    private static func sameCookie(_ lhs: HTTPCookie?, _ rhs: HTTPCookie) -> Bool {
        lhs?.value == rhs.value && lhs?.expiresDate == rhs.expiresDate
            && lhs?.isSecure == rhs.isSecure && lhs?.isHTTPOnly == rhs.isHTTPOnly
    }

    @MainActor
    func prepareWebView(_ dataStore: WKWebsiteDataStore, for url: URL, userAgent: String?) async -> WebViewSession {
        // Seed every path for this host, not just cookies for /challenge or /.
        // Otherwise a later snapshot would incorrectly delete path cookies.
        let initial = snapshot(for: url)
        let cookieStore = dataStore.httpCookieStore
        let existing = await cookieStore.allCookies()
        for cookie in snapshot(existing, for: url).cookies.values where initial.cookies[key(for: cookie)] == nil {
            await cookieStore.deleteCookie(cookie)
        }
        for cookie in initial.cookies.values {
            await cookieStore.setCookie(cookie)
        }
        return WebViewSession(
            store: self, dataStore: dataStore, url: url, userAgent: userAgent,
            snapshot: snapshot(await cookieStore.allCookies(), for: url)
        )
    }

    @MainActor
    final class WebViewSession {
        private let store: WebCookieStore
        private let dataStore: WKWebsiteDataStore
        private let url: URL
        private let userAgent: String?
        private var snapshot: Snapshot
        private var syncTask: Task<Void, Never>?

        fileprivate init(store: WebCookieStore, dataStore: WKWebsiteDataStore, url: URL, userAgent: String?, snapshot: Snapshot) {
            self.store = store
            self.dataStore = dataStore
            self.url = url
            self.userAgent = userAgent
            self.snapshot = snapshot
        }

        func sync(from currentURL: URL?) async {
            // WebKit observers cover the entire data store, including third
            // party pages. Only this forum's top-level page may write back.
            guard let host = currentURL?.host, let forumHost = url.host,
                  host.caseInsensitiveCompare(forumHost) == .orderedSame
            else { return }
            // Cookie notifications and dismissal can overlap. Serialize their
            // snapshots so an older callback cannot undo the final sync.
            let previousTask = syncTask
            let task = Task { @MainActor in
                await previousTask?.value
                let cookies = await dataStore.httpCookieStore.allCookies()
                snapshot = store.mergeWebViewCookies(cookies, for: url, since: snapshot)
                store.setUserAgent(userAgent, for: url)
            }
            syncTask = task
            await task.value
        }
    }

    func clearAll() {
        lock.lock()
        jar.removeAll()
        userAgents.removeAll()
        lock.unlock()
        saveUserAgents()
        try? FileManager.default.removeItem(at: filePath)
    }

    func clearCookies(for baseURL: String) {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return }
        lock.lock()
        jar = jar.filter { _, cookie in
            !Self.cookieDomain(cookie.domain, matchesHost: host)
        }
        userAgents = userAgents.filter { !Self.cookieDomain($0.key, matchesHost: host) }
        lock.unlock()
        save()
        saveUserAgents()
    }

    /// Returns whether a cookie's domain applies to a host. Domain cookies
    /// require a dot boundary, so `.example.com` matches `forum.example.com`
    /// but never `notexample.com`. Host-only cookies remain exact matches.
    static func cookieDomain(_ cookieDomain: String, matchesHost host: String) -> Bool {
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let rawDomain = cookieDomain.lowercased()
        let normalizedDomain = rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedHost.isEmpty, !normalizedDomain.isEmpty else { return false }
        if normalizedHost == normalizedDomain { return true }
        return rawDomain.hasPrefix(".") && normalizedHost.hasSuffix("." + normalizedDomain)
    }

    // MARK: - Persistence

    private func key(for cookie: HTTPCookie) -> String {
        "\(cookie.domain.lowercased())|\(cookie.name)|\(cookie.path)"
    }

    private func save() {
        lock.lock()
        defer { lock.unlock() }
        let serializable: [[String: Any]] = jar.values.compactMap { cookie in
            guard let props = cookie.properties else { return nil }
            var dict: [String: Any] = [:]
            for (k, v) in props {
                if let date = v as? Date {
                    dict[k.rawValue] = date.timeIntervalSinceReferenceDate
                } else {
                    dict[k.rawValue] = v
                }
            }
            return dict
        }
        if let data = try? JSONSerialization.data(withJSONObject: serializable) {
            try? data.write(to: filePath, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: filePath),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        let now = Date()
        let cookies: [HTTPCookie] = array.compactMap { dict in
            var props: [HTTPCookiePropertyKey: Any] = [:]
            for (k, v) in dict {
                let key = HTTPCookiePropertyKey(k)
                if (key == .expires || key == HTTPCookiePropertyKey("Max-Age")),
                   let ti = v as? TimeInterval {
                    props[key] = Date(timeIntervalSinceReferenceDate: ti)
                } else {
                    props[key] = v
                }
            }
            return HTTPCookie(properties: props)
        }.filter {
            $0.expiresDate.map { $0 > now } ?? true
        }
        for c in cookies { jar[key(for: c)] = c }
    }

    private func saveUserAgents() {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(userAgents) {
            try? data.write(to: userAgentPath, options: .atomic)
        }
    }
}
