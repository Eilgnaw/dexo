import XCTest
import WebKit
@testable import dexo

final class WebCookieStoreTests: XCTestCase {
    func testDomainCookieRequiresDotBoundary() {
        XCTAssertTrue(WebCookieStore.cookieDomain(".example.com", matchesHost: "forum.example.com"))
        XCTAssertTrue(WebCookieStore.cookieDomain(".example.com", matchesHost: "example.com"))
        XCTAssertFalse(WebCookieStore.cookieDomain(".example.com", matchesHost: "notexample.com"))
        XCTAssertFalse(WebCookieStore.cookieDomain(".example.com", matchesHost: "example.com.evil.test"))
    }

    func testHostOnlyCookieRequiresExactHost() {
        XCTAssertTrue(WebCookieStore.cookieDomain("forum.example.com", matchesHost: "forum.example.com"))
        XCTAssertFalse(WebCookieStore.cookieDomain("forum.example.com", matchesHost: "sub.forum.example.com"))
    }

    func testDomainMatchingIsCaseInsensitive() {
        XCTAssertTrue(WebCookieStore.cookieDomain(".Example.COM", matchesHost: "Forum.Example.com"))
    }

    func testUserAgentsAreIsolatedAndPersistedPerSite() throws {
        try withStore { store, directory in
            let first = URL(string: "https://forum.example.com")!
            let second = URL(string: "https://another.example.com")!
            store.setUserAgent("First browser", for: first)
            store.setUserAgent("Second browser", for: second)

            let restored = WebCookieStore(directory: directory)
            XCTAssertEqual(restored.userAgent(for: first), "First browser")
            XCTAssertEqual(restored.userAgent(for: second), "Second browser")
            XCTAssertNil(restored.userAgent(for: URL(string: "https://unrelated.test")!))
            restored.clearCookies(for: first.absoluteString)
            XCTAssertNil(restored.userAgent(for: first))
            XCTAssertEqual(restored.userAgent(for: second), "Second browser")
        }
    }

    func testLegacyUserAgentMigrationKeepsExistingSessionsWithoutGlobalFallback() throws {
        try withStore { store, directory in
            let first = URL(string: "https://forum.example.com")!
            let second = URL(string: "https://other.test")!
            store.setCookies([try cookie("cf_clearance", value: "old", domain: ".example.com")])
            try "Legacy browser".write(
                to: directory.appendingPathComponent("dexo_web_ua.txt"), atomically: true, encoding: .utf8
            )
            let migrated = WebCookieStore(directory: directory)
            migrated.setUserAgent("Other browser", for: second)
            XCTAssertEqual(migrated.userAgent(for: first), "Legacy browser")

            migrated.clearAll()
            XCTAssertNil(WebCookieStore(directory: directory).userAgent(for: first))
        }
    }

    func testUnchangedBrowserSnapshotDoesNotRollBackNativeCookieRotation() throws {
        try withStore { store, _ in
            let url = URL(string: "https://forum.example.com")!
            let old = try cookie("cf_clearance", value: "old")
            store.setCookies([old])
            let baseline = store.snapshot(for: url)
            store.setCookies([try cookie("cf_clearance", value: "new-native")])

            store.mergeWebViewCookies([old], for: url, since: baseline)
            XCTAssertEqual(store.cookieHeader(for: url), "cf_clearance=new-native")
        }
    }

    func testCriticalCookieVariantsSendOnlyNewestValueRegardlessOfInputOrder() throws {
        let now = Date()
        for reversed in [false, true] {
            try withStore { store, _ in
                let url = URL(string: "https://forum.example.com/topics/timings")!
                let older = try cookie(
                    "cf_clearance",
                    value: "older",
                    domain: ".forum.example.com",
                    expires: now.addingTimeInterval(60 * 60)
                )
                let newer = try cookie(
                    "cf_clearance",
                    value: "newer",
                    domain: "forum.example.com",
                    expires: now.addingTimeInterval(24 * 60 * 60)
                )
                store.setCookies(reversed ? [newer, older] : [older, newer])

                let header = store.cookieHeader(for: url)
                XCTAssertEqual(
                    WebCookieStore.cookieHeaderValues(named: "cf_clearance", in: header),
                    ["newer"]
                )
                XCTAssertFalse(header.contains("older"))
            }
        }
    }

    func testRejectedClearanceCannotBeRevivedButNewValueIsAccepted() throws {
        try withStore { store, _ in
            let url = URL(string: "https://linux.do/topics/timings")!
            let rejected = try cookie("cf_clearance", value: "rejected", domain: "linux.do")
            store.setCookies([rejected])
            var request = URLRequest(url: url)
            request.setValue("_t=login; cf_clearance=rejected", forHTTPHeaderField: "Cookie")

            store.rejectClearanceSent(with: request)
            XCTAssertFalse(store.cookieHeader(for: url).contains("cf_clearance="))

            store.setCookies([rejected])
            XCTAssertFalse(store.cookieHeader(for: url).contains("cf_clearance="))

            store.setCookies([
                try cookie("cf_clearance", value: "fresh", domain: ".linux.do"),
            ])
            XCTAssertEqual(
                WebCookieStore.cookieHeaderValues(
                    named: "cf_clearance",
                    in: store.cookieHeader(for: url)
                ),
                ["fresh"]
            )
        }
    }

    func testOlderWebViewClearanceCannotOverwriteNewerNativeValue() throws {
        try withStore { store, _ in
            let url = URL(string: "https://linux.do/challenge")!
            let now = Date()
            let initial = try cookie(
                "cf_clearance", value: "initial", domain: "linux.do",
                expires: now.addingTimeInterval(30 * 60)
            )
            store.setCookies([initial])
            let baseline = store.snapshot(for: url)
            store.setCookies([
                try cookie(
                    "cf_clearance", value: "native-new", domain: "linux.do",
                    expires: now.addingTimeInterval(24 * 60 * 60)
                ),
            ])
            let staleWebView = try cookie(
                "cf_clearance", value: "web-stale", domain: ".linux.do",
                expires: now.addingTimeInterval(60 * 60)
            )

            store.mergeWebViewCookies([staleWebView], for: url, since: baseline)
            XCTAssertEqual(
                WebCookieStore.cookieHeaderValues(
                    named: "cf_clearance",
                    in: store.cookieHeader(for: url)
                ),
                ["native-new"]
            )
        }
    }

    func testBrowserRotationAndDeletionApplyOnlyToItsForum() throws {
        try withStore { store, _ in
            let url = URL(string: "https://forum.example.com")!
            let otherURL = URL(string: "https://other.test")!
            let old = try cookie("cf_clearance", value: "old")
            let unrelated = try cookie("cf_clearance", value: "other", domain: "other.test")
            store.setCookies([old, unrelated])
            let baseline = store.snapshot(for: url)
            let rotated = try cookie("cf_clearance", value: "new-browser")
            let next = store.mergeWebViewCookies([rotated, unrelated], for: url, since: baseline)
            XCTAssertEqual(store.cookieHeader(for: url), "cf_clearance=new-browser")

            store.mergeWebViewCookies([unrelated], for: url, since: next)
            XCTAssertTrue(store.cookies(for: url).isEmpty)
            XCTAssertEqual(store.cookieHeader(for: otherURL), "cf_clearance=other")
        }
    }

    func testStaleBrowserDeletionDoesNotDeleteNewNativeCookie() throws {
        try withStore { store, _ in
            let url = URL(string: "https://forum.example.com")!
            store.setCookies([try cookie("cf_clearance", value: "old")])
            let baseline = store.snapshot(for: url)
            store.setCookies([try cookie("cf_clearance", value: "new-native")])

            store.mergeWebViewCookies([], for: url, since: baseline)
            XCTAssertEqual(store.cookieHeader(for: url), "cf_clearance=new-native")
        }
    }

    func testBrowserSnapshotDoesNotDeleteCookiesOnlyReceivedByNativeAPI() throws {
        try withStore { store, _ in
            let url = URL(string: "https://forum.example.com")!
            let baseline = store.snapshot(for: url)
            store.setCookies([try cookie("_t", value: "new-session")])
            store.mergeWebViewCookies([], for: url, since: baseline)
            XCTAssertEqual(store.cookieHeader(for: url), "_t=new-session")
        }
    }

    func testChallengeHeadersExcludeLoginCookiesAndOtherSites() throws {
        try withStore { store, _ in
            let url = URL(string: "https://forum.example.com/latest.json")!
            store.setCookies([
                try cookie("cf_clearance", value: "clearance"),
                try cookie("__cf_bm", value: "bot-session"),
                try cookie("_t", value: "login-secret"),
                try cookie("_forum_session", value: "session-secret"),
                try cookie("cf_clearance", value: "other-secret", domain: "other.test"),
            ])
            XCTAssertEqual(
                Set(store.cookieHeader(for: url, includeSessionCookies: false).components(separatedBy: "; ")),
                ["cf_clearance=clearance", "__cf_bm=bot-session"]
            )
            XCTAssertTrue(store.cookieHeader(for: url).contains("_t=login-secret"))
        }
    }

    func testAPIKeyRequestsDoNotInheritBrowserCookiesOrUserAgent() throws {
        try withStore { store, _ in
            let url = URL(string: "https://forum.example.com/latest.json")!
            store.setCookies([
                try cookie("cf_clearance", value: "clearance"),
                try cookie("_t", value: "login-secret"),
            ])
            store.setUserAgent("Browser UA", for: url)
            var request = URLRequest(url: url)
            request.setValue("Native UA", forHTTPHeaderField: "User-Agent")
            request.setValue("test-api-key", forHTTPHeaderField: "User-Api-Key")

            let adapted = applyingStoredWebSession(to: request, userApiKey: "test-api-key", cookieStore: store)
            XCTAssertNil(adapted.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(adapted.value(forHTTPHeaderField: "User-Agent"), "Native UA")
            XCTAssertEqual(adapted.value(forHTTPHeaderField: "User-Api-Key"), "test-api-key")
        }
    }

    func testAnonymousAndWebLoginRequestsStillReceiveTheirMatchingCookies() throws {
        try withStore { store, _ in
            let url = URL(string: "https://forum.example.com/latest.json")!
            store.setCookies([
                try cookie("cf_clearance", value: "clearance"),
                try cookie("_t", value: "login-secret"),
            ])
            store.setUserAgent("Browser UA", for: url)
            let request = URLRequest(url: url)

            let anonymous = applyingStoredWebSession(to: request, userApiKey: nil, cookieStore: store)
            XCTAssertEqual(anonymous.value(forHTTPHeaderField: "Cookie"), "cf_clearance=clearance")
            XCTAssertEqual(anonymous.value(forHTTPHeaderField: "User-Agent"), "Browser UA")

            let webLogin = applyingStoredWebSession(
                to: request, userApiKey: AuthManager.webAuthSentinel, cookieStore: store
            )
            XCTAssertEqual(
                Set((webLogin.value(forHTTPHeaderField: "Cookie") ?? "").components(separatedBy: "; ")),
                ["cf_clearance=clearance", "_t=login-secret"]
            )
            XCTAssertEqual(webLogin.value(forHTTPHeaderField: "User-Agent"), "Browser UA")
        }
    }

    func testTimingRequestKeepsBrowserHeadersWhenWebSessionIsApplied() throws {
        try withStore { store, _ in
            let url = URL(string: "https://linux.do/topics/timings")!
            store.setCookies([
                try cookie("cf_clearance", value: "clearance", domain: "linux.do"),
                try cookie("_t", value: "login", domain: "linux.do"),
            ])
            store.setUserAgent("Mobile Safari", for: url)
            let baseRequest = try XCTUnwrap(
                TopicTimingRequestBuilder.makeRequest(
                    baseURL: "https://linux.do",
                    batch: TopicTimingBatch(topicId: 42, topicTime: 1_000, timings: [1: 1_000])
                )
            )

            let adapted = applyingStoredWebSession(
                to: baseRequest,
                userApiKey: AuthManager.webAuthSentinel,
                cookieStore: store
            )

            XCTAssertEqual(adapted.value(forHTTPHeaderField: "User-Agent"), "Mobile Safari")
            XCTAssertEqual(
                Set((adapted.value(forHTTPHeaderField: "Cookie") ?? "").components(separatedBy: "; ")),
                ["cf_clearance=clearance", "_t=login"]
            )
            XCTAssertEqual(adapted.value(forHTTPHeaderField: "Origin"), "https://linux.do")
            XCTAssertEqual(adapted.value(forHTTPHeaderField: "Referer"), "https://linux.do/t/topic/42")
            XCTAssertEqual(adapted.value(forHTTPHeaderField: "X-Requested-With"), "XMLHttpRequest")
            XCTAssertEqual(adapted.value(forHTTPHeaderField: "Discourse-Present"), "true")
            XCTAssertEqual(adapted.value(forHTTPHeaderField: "Discourse-Logged-In"), "true")
        }
    }

    func testAnonymousResponsesOnlyUpdateChallengeCookies() throws {
        try withStore { store, _ in
            let url = URL(string: "https://forum.example.com/latest.json")!
            store.mergeResponseHeaders(
                ["Set-Cookie": "cf_clearance=new; Path=/; Secure"], for: url, includeSessionCookies: false
            )
            store.mergeResponseHeaders(
                ["Set-Cookie": "_t=unexpected; Path=/; Secure"], for: url, includeSessionCookies: false
            )
            XCTAssertEqual(store.cookieHeader(for: url), "cf_clearance=new")
        }
    }

    func testWebViewSeedingIncludesAllPathsAndFinalSyncUsesLatestCookies() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WebCookieStore(directory: directory)
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let url = URL(string: "https://forum.example.com/challenge")!
        let pathURL = URL(string: "https://forum.example.com/session/current.json")!
        store.setCookies([
            try cookie("cf_clearance", value: "old"),
            try cookie("_t", value: "login", path: "/session"),
        ])
        let session = await store.prepareWebView(dataStore, for: url, userAgent: "Forum browser")
        let seeded = await dataStore.httpCookieStore.allCookies()
        XCTAssertTrue(seeded.contains { $0.name == "_t" && $0.path == "/session" })

        await dataStore.httpCookieStore.setCookie(try cookie("cf_clearance", value: "passed"))
        await session.sync(from: url)
        XCTAssertEqual(store.cookieHeader(for: url), "cf_clearance=passed")
        XCTAssertTrue(store.cookieHeader(for: pathURL).contains("_t=login"))
        XCTAssertEqual(store.userAgent(for: url), "Forum browser")
    }

    func testExternalPageCookieChangesCannotReplaceForumSession() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WebCookieStore(directory: directory)
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let forumURL = URL(string: "https://forum.example.com")!
        store.setCookies([try cookie("cf_clearance", value: "passed")])
        store.setUserAgent("Verified browser", for: forumURL)
        let session = await store.prepareWebView(dataStore, for: forumURL, userAgent: "Other browser")
        await dataStore.httpCookieStore.setCookie(try cookie("cf_clearance", value: "third-party-state"))

        await session.sync(from: URL(string: "https://external.test"))
        await session.sync(from: nil)
        XCTAssertEqual(store.cookieHeader(for: forumURL), "cf_clearance=passed")
        XCTAssertEqual(store.userAgent(for: forumURL), "Verified browser")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dexo-cookie-tests-\(UUID().uuidString)")
    }

    private func withStore(_ body: (WebCookieStore, URL) throws -> Void) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(WebCookieStore(directory: directory), directory)
    }

    private func cookie(
        _ name: String,
        value: String,
        domain: String = "forum.example.com",
        path: String = "/",
        expires: Date? = nil
    ) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE",
        ]
        if let expires {
            properties[.expires] = expires
        }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }
}
