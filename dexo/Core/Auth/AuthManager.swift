import AuthenticationServices
import Foundation
import Perception

@Perceptible
final class AuthManager: @unchecked Sendable {
    static let shared = AuthManager()

    // Per-baseURL username cache (populated from DB or after login)
    private var usernameCache: [String: String] = [:]

    private init() {}

    // MARK: - Public API

    func isAuthenticated(for baseURL: String) -> Bool {
        KeychainHelper.getUserApiKey(for: baseURL) != nil
    }

    func authenticationKind(for baseURL: String) -> ForumAuthKind {
        guard let credential = KeychainHelper.getUserApiKey(for: baseURL) else {
            return .anonymous
        }
        return credential == Self.webAuthSentinel ? .webSession : .userAPIKey
    }

    func username(for baseURL: String) -> String? {
        let normalized = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return usernameCache[normalized]
    }

    /// Backfill the username cache for a baseURL when a call site discovered
    /// the current user's identity through another path (e.g., `MeViewModel`
    /// falling back to `/session/current.json` because the login-time fetch
    /// failed silently).
    func setCachedUsername(_ username: String, for baseURL: String) {
        let normalized = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        usernameCache[normalized] = username
    }

    func login(forum: ForumInstance, presentationAnchor: ASPresentationAnchor) async throws {
        let baseURL = forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // 1. Generate RSA key pair
        let privateKey: SecKey
        do {
            privateKey = try KeychainHelper.generateAndStoreRSAKeyPair(for: baseURL)
        } catch {
            throw AuthError.keyGenerationFailed(error)
        }

        // 2. Export public key PEM
        let pem: String
        do {
            pem = try KeychainHelper.exportPublicKeyPEM(from: privateKey)
        } catch {
            KeychainHelper.deleteRSAKeyPair(for: baseURL)
            throw AuthError.keyGenerationFailed(error)
        }

        // 3. Build auth URL (match Python urllib.parse.quote per-value encoding)
        let clientId = UUID().uuidString
        // Equivalent to Python's secrets.token_urlsafe(32)
        var nonceBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        let nonce = Data(nonceBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let normalizedPem = pem
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Equivalent to Python's urllib.parse.quote (safe='/')
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")

        let params: [(String, String)] = [
            ("application_name", "Dexo iOS"),
            ("client_id", clientId),
            ("scopes", "read,write"),
            ("public_key", normalizedPem),
            ("nonce", nonce),
            ("auth_redirect", "discourse://auth_redirect"),
        ]
        let queryString = params
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&")
        let authURLString = "\(baseURL)/user-api-key/new?\(queryString)"

        guard let authURL = URL(string: authURLString) else {
            KeychainHelper.deleteRSAKeyPair(for: baseURL)
            throw AuthError.invalidURL
        }

        debugLog("[AuthManager] Auth URL: \(authURL.absoluteString)")

        // 4. Launch browser auth session
        let callbackURL: URL
        let contextProvider = PresentationContextProvider(anchor: presentationAnchor)
        do {
            callbackURL = try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: "discourse"
                ) { url, error in
                    // Keep contextProvider alive until callback completes
                    _ = contextProvider
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: AuthError.unknownError)
                    }
                }
                session.presentationContextProvider = contextProvider
                session.prefersEphemeralWebBrowserSession = false
                session.start()
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Cancellation is not a successful login. Preserve any existing
            // credential and let callers keep the auth gate closed.
            KeychainHelper.deleteRSAKeyPair(for: baseURL)
            throw AuthError.cancelled
        } catch {
            KeychainHelper.deleteRSAKeyPair(for: baseURL)
            throw AuthError.browserSessionFailed(error)
        }

        // 5. Extract payload from callback URL
        debugLog("[AuthManager] Callback URL: \(callbackURL.absoluteString)")
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let payload = components.queryItems?.first(where: { $0.name == "payload" })?.value
        else {
            debugLog("[AuthManager] ERROR: Missing payload in callback URL")
            KeychainHelper.deleteRSAKeyPair(for: baseURL)
            throw AuthError.missingPayload
        }

        debugLog("[AuthManager] Payload length: \(payload.count)")

        // 6. Decrypt payload
        let authPayload: RSACrypto.AuthPayload
        do {
            authPayload = try RSACrypto.decryptPayload(payload, with: privateKey)
        } catch {
            debugLog("[AuthManager] ERROR: Decryption failed: \(error)")
            KeychainHelper.deleteRSAKeyPair(for: baseURL)
            throw AuthError.decryptionFailed(error)
        }

        debugLog("[AuthManager] Decrypted nonce: \(authPayload.nonce)")
        debugLog("[AuthManager] Expected nonce: \(nonce)")

        // 7. Verify nonce
        guard authPayload.nonce == nonce else {
            debugLog("[AuthManager] ERROR: Nonce mismatch")
            KeychainHelper.deleteRSAKeyPair(for: baseURL)
            throw AuthError.nonceMismatch
        }

        debugLog("[AuthManager] Auth success! Key length: \(authPayload.key.count)")

        // 8. Store API key in Keychain. Capture the old state first, but do
        // not clear or revoke it until the new credential is safely persisted.
        let previousCredential = KeychainHelper.getUserApiKey(for: baseURL)
        let previousWebSession = previousCredential == AuthManager.webAuthSentinel
            ? webSessionSnapshot(baseURL: baseURL, username: usernameCache[baseURL] ?? forum.username)
            : nil
        do {
            try KeychainHelper.saveUserApiKey(authPayload.key, for: baseURL)
        } catch {
            KeychainHelper.deleteRSAKeyPair(for: baseURL)
            throw error
        }
        // The new credential may belong to another account. Do not let an
        // identity fetch failure fall back to the previous account name.
        usernameCache.removeValue(forKey: baseURL)

        if let previousCredential {
            if previousCredential == AuthManager.webAuthSentinel {
                if let previousWebSession {
                    endWebSession(previousWebSession)
                }
            } else if previousCredential != authPayload.key {
                revokeApiKey(previousCredential, baseURL: baseURL)
            }
        }
        if previousCredential == AuthManager.webAuthSentinel
            || URL(string: baseURL)?.host?.lowercased() == "linux.do" {
            Self.clearWebSession(for: baseURL)
        }

        // Clean up RSA key pair (no longer needed)
        KeychainHelper.deleteRSAKeyPair(for: baseURL)

        // 9. Fetch current user to get username
        if let username = await fetchAndCacheUsername(baseURL: baseURL, forum: forum) {
            await PushSubscriptionCoordinator(api: DiscourseAPI(forum: forum))
                .rotateSubscriptionsAfterLogin(username: username)
        }
        postAuthChange(for: baseURL)
    }

    static let webAuthSentinel = "__web__"

    /// Called after WebLoginViewController successfully captures cookies.
    /// Saves the sentinel key so isAuthenticated returns true, then fetches the username.
    func loginViaWeb(forum: ForumInstance, cookies: [HTTPCookie], userAgent: String?) async throws {
        let baseURL = forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let webSessionURL = URL(string: baseURL), let baseHost = webSessionURL.host,
              cookies.contains(where: {
                  $0.name == "_t"
                      && ($0.expiresDate.map { $0 > Date() } ?? true)
                      && WebCookieStore.cookieDomain($0.domain, matchesHost: baseHost)
              })
        else {
            throw AuthError.missingWebSession
        }

        let previousCredential = KeychainHelper.getUserApiKey(for: baseURL)
        let previousWebSession = previousCredential == AuthManager.webAuthSentinel
            ? webSessionSnapshot(baseURL: baseURL, username: usernameCache[baseURL] ?? forum.username)
            : nil

        // Persist the new auth marker before touching either the previous API
        // key or the previous web session.
        try KeychainHelper.saveUserApiKey(AuthManager.webAuthSentinel, for: baseURL)
        usernameCache.removeValue(forKey: baseURL)

        if let previousCredential, previousCredential != AuthManager.webAuthSentinel {
            revokeApiKey(previousCredential, baseURL: baseURL)
        } else if let previousWebSession,
                  !Self.sameWebSession(previousWebSession.cookies, cookies)
        {
            endWebSession(previousWebSession)
        }

        Self.clearWebSession(for: baseURL)
        WebCookieStore.shared.setCookies(cookies)
        WebCookieStore.shared.setUserAgent(userAgent ?? previousWebSession?.userAgent, for: webSessionURL)
        KeychainHelper.deleteRSAKeyPair(for: baseURL)

        if let username = await fetchAndCacheUsername(baseURL: baseURL, forum: forum) {
            await PushSubscriptionCoordinator(api: DiscourseAPI(forum: forum))
                .rotateSubscriptionsAfterLogin(username: username)
        }
        postAuthChange(for: baseURL)
    }

    // MARK: - Username Fetching

    /// Fetches the current user's username via `/session/current.json`, falling back to `/notifications.json`.
    /// For linux.do, skip `/session/current.json` and go straight to `/notifications.json`.
    private func fetchAndCacheUsername(baseURL: String, forum: ForumInstance) async -> String? {
        let api = DiscourseAPI(baseURL: baseURL)
        var username: String?

        if !api.isLinuxDo {
            // Primary: /session/current.json
            if let currentUser = try? await api.fetchCurrentUser() {
                username = currentUser.username
            }
        }

        // Fallback: extract from /notifications.json pagination URL
        if username == nil, let notifList = try? await api.fetchNotifications() {
            username = notifList.username
        }

        guard let username else { return nil }
        usernameCache[baseURL] = username
        var forumToUpdate = forum
        forumToUpdate.username = username
        _ = try? DatabaseManager.shared.saveForum(&forumToUpdate)
        return username
    }

    // MARK: - Auth Isolation Helpers

    private struct WebSessionSnapshot {
        let baseURL: String
        let cookies: [HTTPCookie]
        let userAgent: String?
        let username: String?
    }

    private func webSessionSnapshot(baseURL: String, username: String?) -> WebSessionSnapshot? {
        guard let url = URL(string: baseURL)?
            .appendingPathComponent("session")
            .appendingPathComponent("csrf.json")
        else {
            return nil
        }
        return WebSessionSnapshot(
            baseURL: baseURL,
            cookies: WebCookieStore.shared.cookies(for: url),
            userAgent: WebCookieStore.shared.userAgent(for: url),
            username: username
        )
    }

    private static func sameWebSession(_ lhs: [HTTPCookie], _ rhs: [HTTPCookie]) -> Bool {
        let lhsTokens = Set(lhs.filter { $0.name == "_t" }.map(\.value))
        let rhsTokens = Set(rhs.filter { $0.name == "_t" }.map(\.value))
        return !lhsTokens.isEmpty && !lhsTokens.isDisjoint(with: rhsTokens)
    }

    private func endWebSession(_ snapshot: WebSessionSnapshot) {
        Task { await Self.deleteWebSession(snapshot) }
    }

    private func revokeApiKey(_ apiKey: String, baseURL: String) {
        Task { await Self.revokeApiKeyOnServer(apiKey, baseURL: baseURL) }
    }

    static func clearWebSession(for baseURL: String, cookieStore: WebCookieStore = .shared) {
        cookieStore.clearCookies(for: baseURL)
        if URL(string: baseURL)?.host?.lowercased() == "linux.do" {
            // Connect has its own SSO session. Drop it whenever the forum
            // credential changes; browser preparation clears stale WebKit copies.
            cookieStore.clearCookies(for: ForumWebViewController.SessionScope.connectURL.absoluteString)
        }
    }

    func logout(forum: ForumInstance) {
        let baseURL = forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if let apiKey = KeychainHelper.getUserApiKey(for: baseURL) {
            if apiKey == AuthManager.webAuthSentinel {
                // Snapshot Cookie and UA before clearing local state so the
                // asynchronous server logout cannot race with that cleanup.
                if let snapshot = webSessionSnapshot(
                    baseURL: baseURL,
                    username: usernameCache[baseURL] ?? forum.username
                ) {
                    endWebSession(snapshot)
                }
            } else {
                revokeApiKey(apiKey, baseURL: baseURL)
            }
        }

        KeychainHelper.deleteUserApiKey(for: baseURL)
        KeychainHelper.deleteRSAKeyPair(for: baseURL)
        Self.clearWebSession(for: baseURL)
        usernameCache.removeValue(forKey: baseURL)

        // Clear username from DB
        var forumToUpdate = forum
        forumToUpdate.username = nil
        _ = try? DatabaseManager.shared.saveForum(&forumToUpdate)
        postAuthChange(for: baseURL)
    }

    /// Removes credentials for a saved URL without contacting that forum.
    /// Used when migrating a legacy HTTP record, since attempting server-side
    /// revocation would itself make a request to an address that is no longer
    /// allowed by the app's transport policy.
    func clearLocalAuthentication(for baseURL: String) {
        let normalized = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let credentialKeys = Set([baseURL, normalized])
        for key in credentialKeys {
            KeychainHelper.deleteUserApiKey(for: key)
            KeychainHelper.deleteRSAKeyPair(for: key)
            usernameCache.removeValue(forKey: key)
        }
        Self.clearWebSession(for: normalized)
        postAuthChange(for: normalized)
    }

    /// Clears a credential that the forum has explicitly rejected. Unlike a
    /// user-initiated logout, this never attempts to revoke the already-invalid
    /// server credential.
    func invalidateExpiredAuthentication(for baseURL: String) {
        let normalized = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard KeychainHelper.getUserApiKey(for: normalized) != nil else { return }

        clearLocalAuthentication(for: normalized)

        guard var forum = (try? DatabaseManager.shared.fetchAllForums())?
            .first(where: {
                $0.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normalized
            })
        else { return }
        forum.username = nil
        _ = try? DatabaseManager.shared.saveForum(&forum)
    }

    func restoreAuthState(for forum: ForumInstance) {
        let baseURL = forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let username = forum.username, isAuthenticated(for: baseURL) {
            usernameCache[baseURL] = username
        }
    }

    private func postAuthChange(for baseURL: String) {
        NotificationCenter.default.post(
            name: .discourseAuthDidChange,
            object: nil,
            userInfo: ["baseURL": baseURL]
        )
    }

    private static func revokeApiKeyOnServer(_ apiKey: String, baseURL: String) async {
        guard ForumURLPolicy.isSecure(baseURL),
              let url = URL(string: baseURL)?
              .appendingPathComponent("user-api-key")
              .appendingPathComponent("revoke")
        else { return }

        let session = ephemeralAuthSession()
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "User-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try? await session.data(for: request)
    }

    private static func deleteWebSession(_ snapshot: WebSessionSnapshot) async {
        guard ForumURLPolicy.isSecure(snapshot.baseURL),
              let rootURL = URL(string: snapshot.baseURL),
              !snapshot.cookies.isEmpty
        else { return }

        let session = ephemeralAuthSession()
        defer { session.finishTasksAndInvalidate() }

        var username = snapshot.username
        if username == nil {
            let currentURL = rootURL
                .appendingPathComponent("session")
                .appendingPathComponent("current.json")
            if let (data, response) = try? await session.data(
                for: webRequest(url: currentURL, snapshot: snapshot)
            ),
                (response as? HTTPURLResponse).map({ 200 ..< 300 ~= $0.statusCode }) == true
            {
                username = (try? JSONDecoder().decode(CurrentSessionEnvelope.self, from: data))?
                    .currentUser?.username
            }
        }
        guard let username, !username.isEmpty else { return }

        let csrfURL = rootURL
            .appendingPathComponent("session")
            .appendingPathComponent("csrf.json")
        guard let (csrfData, csrfResponse) = try? await session.data(
            for: webRequest(url: csrfURL, snapshot: snapshot)
        ),
            (csrfResponse as? HTTPURLResponse).map({ 200 ..< 300 ~= $0.statusCode }) == true,
            let csrf = try? JSONDecoder().decode(CSRFEnvelope.self, from: csrfData).csrf,
            !csrf.isEmpty
        else { return }

        let logoutURL = rootURL
            .appendingPathComponent("session")
            .appendingPathComponent(username)
        var request = webRequest(url: logoutURL, snapshot: snapshot)
        request.httpMethod = "DELETE"
        request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await session.data(for: request)
    }

    private static func webRequest(url: URL, snapshot: WebSessionSnapshot) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            snapshot.cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
            forHTTPHeaderField: "Cookie"
        )
        if let userAgent = snapshot.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    private static func ephemeralAuthSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(
            configuration: configuration,
            delegate: RejectRedirectsDelegate(),
            delegateQueue: nil
        )
    }

    private struct CSRFEnvelope: Decodable {
        let csrf: String
    }

    private struct CurrentSessionEnvelope: Decodable {
        struct CurrentUser: Decodable {
            let username: String
        }

        let currentUser: CurrentUser?

        enum CodingKeys: String, CodingKey {
            case currentUser = "current_user"
        }
    }
}

private final class RejectRedirectsDelegate: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when auth method changes for a forum, so interceptors can reset cached state (e.g. CSRF token).
    static let discourseAuthDidChange = Notification.Name("discourseAuthDidChange")
}

// MARK: - Errors

enum AuthError: Error, LocalizedError {
    case cancelled
    case keyGenerationFailed(Error)
    case invalidURL
    case browserSessionFailed(Error)
    case missingPayload
    case decryptionFailed(Error)
    case nonceMismatch
    case missingWebSession
    case unknownError

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Authentication was cancelled"
        case .keyGenerationFailed(let error):
            return "Key generation failed: \(error.localizedDescription)"
        case .invalidURL:
            return "Invalid authentication URL"
        case .browserSessionFailed(let error):
            return "Browser session failed: \(error.localizedDescription)"
        case .missingPayload:
            return "Missing payload in callback"
        case .decryptionFailed(let error):
            return "Decryption failed: \(error.localizedDescription)"
        case .nonceMismatch:
            return "Nonce mismatch — possible replay attack"
        case .missingWebSession:
            return "No valid web session cookie was found"
        case .unknownError:
            return "Unknown authentication error"
        }
    }
}

// MARK: - Presentation Context Provider

private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor }
    }
}
