import CryptoKit
import Foundation
import WebKit

/// In-memory + persisted cookie store used for web-login sessions.
/// Security-sensitive cookies normalize a leading domain dot so WebKit's
/// host-only/domain representations cannot coexist and both be sent.
final class WebCookieStore {
    static let shared = WebCookieStore()

    private var jar: [String: HTTPCookie] = [:]
    private let lock = NSLock()
    private let filePath: URL

    private var userAgents: [String: String] = [:]
    private let userAgentPath: URL
    /// Session-only tombstones for `cf_clearance` values that Cloudflare has
    /// explicitly rejected. Store hashes, never cookie values.
    private var rejectedClearanceHashesByHost: [String: Set<String>] = [:]

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
        let canonical = canonicalizedCookies(cookies, requestHost: nil)
        for c in canonical.values {
            let storageKey = key(for: c)
            // Drop already-expired cookies instead of letting them overwrite a still-valid entry.
            if let expires = c.expiresDate, expires <= now {
                jar.removeValue(forKey: storageKey)
            } else if isRejectedClearanceLocked(c) {
                continue
            } else {
                // A single Set-Cookie response is authoritative. Canonicalizing
                // the incoming batch above only resolves duplicate variants
                // returned together; a later response must still rotate state.
                jar[storageKey] = c
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
        let matching = jar.values.filter { cookie in
            // Skip expired cookies so a stale/expired `_t` left in the jar never gets sent.
            if let expires = cookie.expiresDate, expires <= now { return false }
            return Self.cookieDomain(cookie.domain, matchesHost: host)
                && path.hasPrefix(cookie.path)
        }
        return selectedCookiesForRequest(matching, host: host)
    }

    func cookieHeader(for url: URL, includeSessionCookies: Bool = true) -> String {
        cookies(for: url)
            .filter { includeSessionCookies || Self.isChallengeCookie($0) }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func isChallengeCookie(_ cookie: HTTPCookie) -> Bool {
        challengeCookieNames.contains(cookie.name)
    }

    private func canonicalizedCookies(
        _ cookies: [HTTPCookie],
        requestHost: String?
    ) -> [String: HTTPCookie] {
        var result: [String: HTTPCookie] = [:]
        for cookie in cookies {
            let storageKey = key(for: cookie)
            guard let existing = result[storageKey] else {
                result[storageKey] = cookie
                continue
            }
            result[storageKey] = preferredCookie(
                cookie,
                over: existing,
                requestHost: requestHost
            ) ? cookie : existing
        }
        return result
    }

    private func selectedCookiesForRequest(
        _ cookies: [HTTPCookie],
        host: String
    ) -> [HTTPCookie] {
        var selectedCritical: [String: HTTPCookie] = [:]
        var regular: [HTTPCookie] = []
        for cookie in cookies {
            guard Self.criticalCookieNames.contains(cookie.name) else {
                regular.append(cookie)
                continue
            }
            if let existing = selectedCritical[cookie.name] {
                if preferredCookie(cookie, over: existing, requestHost: host) {
                    selectedCritical[cookie.name] = cookie
                }
            } else {
                selectedCritical[cookie.name] = cookie
            }
        }
        return (regular + Array(selectedCritical.values)).sorted {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            return $0.name < $1.name
        }
    }

    private func preferredCookie(
        _ candidate: HTTPCookie,
        over existing: HTTPCookie,
        requestHost: String?
    ) -> Bool {
        if let requestHost {
            let candidateScore = Self.domainScore(candidate.domain, for: requestHost)
            let existingScore = Self.domainScore(existing.domain, for: requestHost)
            if candidateScore != existingScore { return candidateScore > existingScore }
        }
        switch (candidate.expiresDate, existing.expiresDate) {
        case let (candidateDate?, existingDate?) where candidateDate != existingDate:
            return candidateDate > existingDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        if candidate.path.count != existing.path.count {
            return candidate.path.count > existing.path.count
        }
        if candidate.isHTTPOnly != existing.isHTTPOnly {
            return candidate.isHTTPOnly
        }
        if candidate.isSecure != existing.isSecure {
            return candidate.isSecure
        }
        // Stable final tie-breaker independent of WebKit enumeration order.
        return Self.cookieValueHash(candidate.value) > Self.cookieValueHash(existing.value)
    }

    private func shouldRejectStaleWebViewCookie(
        _ candidate: HTTPCookie,
        replacing existing: HTTPCookie?
    ) -> Bool {
        guard candidate.name == "cf_clearance",
              let existing,
              candidate.value != existing.value,
              let candidateExpiry = candidate.expiresDate,
              let existingExpiry = existing.expiresDate
        else { return false }
        return candidateExpiry <= existingExpiry
    }

    private func isRejectedClearanceLocked(_ cookie: HTTPCookie) -> Bool {
        guard cookie.name == "cf_clearance" else { return false }
        let hash = Self.cookieValueHash(cookie.value)
        return rejectedClearanceHashesByHost.contains { host, hashes in
            Self.cookieDomain(cookie.domain, matchesHost: host) && hashes.contains(hash)
        }
    }

    static func cookieHeaderValues(named name: String, in header: String) -> [String] {
        header.split(separator: ";").compactMap { component in
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  String(pair[0]).trimmingCharacters(in: .whitespaces) == name
            else { return nil }
            return String(pair[1])
        }
    }

    nonisolated private static func cookieValueHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedCookieDomain(_ domain: String) -> String {
        domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func domainScore(_ domain: String, for host: String) -> Int {
        let normalizedDomain = normalizedCookieDomain(domain)
        let normalizedHost = normalizedCookieDomain(host)
        if normalizedDomain == normalizedHost { return 10_000 + normalizedDomain.count }
        if normalizedHost.hasSuffix("." + normalizedDomain) {
            return 1_000 + normalizedDomain.count
        }
        return normalizedDomain.count
    }

    private static let challengeCookieNames: Set<String> = [
        "cf_clearance", "__cf_bm", "_cfuvid",
    ]
    private static let criticalCookieNames: Set<String> = challengeCookieNames.union([
        "_t", "_forum_session",
    ])

    /// Records the exact clearance sent on a challenged request, removes it
    /// from the native jar, and prevents later WebKit snapshots from reviving
    /// that rejected value during this app session.
    func rejectClearanceSent(with request: URLRequest) {
        guard let url = request.url,
              let host = url.host?.lowercased(),
              let cookieHeader = request.value(forHTTPHeaderField: "Cookie")
        else { return }
        let rejectedHashes = Self.cookieHeaderValues(named: "cf_clearance", in: cookieHeader)
            .map(Self.cookieValueHash)
        guard !rejectedHashes.isEmpty else { return }

        lock.lock()
        rejectedClearanceHashesByHost[host, default: []].formUnion(rejectedHashes)
        jar = jar.filter { _, cookie in
            guard cookie.name == "cf_clearance",
                  Self.cookieDomain(cookie.domain, matchesHost: host)
            else { return true }
            return !rejectedHashes.contains(Self.cookieValueHash(cookie.value))
        }
        lock.unlock()
        save()
    }

    /// Safe diagnostics for validating cookie selection without logging any
    /// authentication value. The clearance identifier is a short SHA-256
    /// prefix used only to correlate duplicate/rejected variants locally.
    func diagnosticSummary(for url: URL) -> String {
        guard let host = url.host?.lowercased() else { return "host=invalid" }
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        let candidates = jar.values.filter { cookie in
            Self.criticalCookieNames.contains(cookie.name)
                && Self.cookieDomain(cookie.domain, matchesHost: host)
                && (cookie.expiresDate.map { $0 > now } ?? true)
        }.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.domain < $1.domain
        }
        let details = candidates.map { cookie in
            let expires = cookie.expiresDate.map {
                String(Int($0.timeIntervalSince1970))
            } ?? "session"
            let id = cookie.name == "cf_clearance"
                ? String(Self.cookieValueHash(cookie.value).prefix(12)) : "hidden"
            let rejected = cookie.name == "cf_clearance"
                && isRejectedClearanceLocked(cookie)
            return "\(cookie.name){domain=\(cookie.domain),path=\(cookie.path),exp=\(expires),id=\(id),rejected=\(rejected)}"
        }
        return "criticalCandidates=\(candidates.count) [\(details.joined(separator: ","))]"
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
            // Preserve WebKit's raw domain variants here so prepareWebView can
            // delete stale host-only/domain duplicates individually.
            result[snapshotKey(for: cookie)] = cookie
        }
        return Snapshot(cookies: result)
    }

    /// Apply only changes made by this browser. Unchanged WebKit cookies must
    /// not roll back a newer Set-Cookie received by the native API meanwhile.
    @discardableResult
    func mergeWebViewCookies(_ cookies: [HTTPCookie], for url: URL, since previous: Snapshot) -> Snapshot {
        let current = snapshot(cookies, for: url)
        lock.lock()
        let previousCanonical = canonicalizedCookies(
            Array(previous.cookies.values),
            requestHost: url.host?.lowercased()
        )
        let currentCanonical = canonicalizedCookies(
            Array(current.cookies.values).filter { !isRejectedClearanceLocked($0) },
            requestHost: url.host?.lowercased()
        )
        for (storageKey, oldCookie) in previousCanonical where currentCanonical[storageKey] == nil {
            if Self.sameCookie(jar[storageKey], oldCookie) {
                jar.removeValue(forKey: storageKey)
            }
        }
        for (storageKey, cookie) in currentCanonical
        where !Self.sameCookie(previousCanonical[storageKey], cookie)
        {
            if shouldRejectStaleWebViewCookie(cookie, replacing: jar[storageKey]) {
                continue
            }
            jar[storageKey] = cookie
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
        for cookie in snapshot(existing, for: url).cookies.values
        where initial.cookies[snapshotKey(for: cookie)] == nil
        {
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
        rejectedClearanceHashesByHost.removeAll()
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
        rejectedClearanceHashesByHost = rejectedClearanceHashesByHost.filter {
            !Self.cookieDomain($0.key, matchesHost: host)
                && !Self.cookieDomain(host, matchesHost: $0.key)
        }
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
        let rawDomain = cookie.domain.lowercased()
        let domain = Self.criticalCookieNames.contains(cookie.name)
            ? Self.normalizedCookieDomain(rawDomain) : rawDomain
        return "\(domain)|\(cookie.name)|\(cookie.path)"
    }

    private func snapshotKey(for cookie: HTTPCookie) -> String {
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
        let canonical = canonicalizedCookies(cookies, requestHost: nil)
        for (storageKey, cookie) in canonical {
            jar[storageKey] = cookie
        }
    }

    private func saveUserAgents() {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(userAgents) {
            try? data.write(to: userAgentPath, options: .atomic)
        }
    }
}
