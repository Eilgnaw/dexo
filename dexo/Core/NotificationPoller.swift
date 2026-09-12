import UIKit

/// Polls for unread notification / PM status via MessageBus long-polling.
///
/// Strategy:
/// - First poll: `/session/current.json` for initial state + user ID,
///   plus a MessageBus poll with -1 to seed channel positions.
/// - Subsequent polls: continuous long-poll loop (request immediately after response).
/// - 3 s delay before first poll on start / foreground resume.
import Perception

@Perceptible
final class NotificationPoller {
    var hasUnreadNotifications = false
    var hasUnreadMessages = false

    var hasAnyUnread: Bool { hasUnreadNotifications || hasUnreadMessages }

    private let api: DiscourseAPI
    private let usernameProvider: () -> String?
    private let challengeCoordinator: CloudflareChallengeCoordinator
    private var isActive = false
    private var pollTask: Task<Void, Never>?

    // MessageBus state
    private let clientId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var userId: Int?
    private var lastMessageIds: [String: Int] = [:]
    private var sharedSessionKey: String?
    private var seeded = false

    // Circuit breaker: stop polling after repeated failures (e.g. TLS errors on
    // the MessageBus host) so a broken endpoint doesn't keep burning requests.
    // Reset when the app returns to the foreground.
    private var consecutiveFailures = 0
    private var circuitOpen = false
    private static let maxConsecutiveFailures = 5

    private static let initialDelay: TimeInterval = 3

    init(
        api: DiscourseAPI,
        usernameProvider: @escaping () -> String?,
        challengeCoordinator: CloudflareChallengeCoordinator = .shared
    ) {
        self.api = api
        self.usernameProvider = usernameProvider
        self.challengeCoordinator = challengeCoordinator
    }

    func start() {
        guard !isActive else { return }
        isActive = true

        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIScene.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudflareChallengeStateDidChange(_:)),
            name: .cloudflareChallengeStateDidChange,
            object: challengeCoordinator
        )

        startPolling(delay: Self.initialDelay)
    }

    func stop() {
        isActive = false
        pollTask?.cancel()
        pollTask = nil
        NotificationCenter.default.removeObserver(self)
    }

    func clearNotifications() {
        hasUnreadNotifications = false
    }

    func clearMessages() {
        hasUnreadMessages = false
    }

    // MARK: - Foreground / Background

    @objc private func appDidBecomeActive() {
        // Give the tripped circuit another chance when the user returns —
        // network conditions may have changed (e.g. proxy reconfigured).
        circuitOpen = false
        consecutiveFailures = 0
        startPolling(delay: Self.initialDelay)
    }

    @objc private func appDidEnterBackground() {
        pollTask?.cancel()
        pollTask = nil
    }

    @objc private func cloudflareChallengeStateDidChange(_ notification: Notification) {
        guard CloudflareChallengeCoordinator.normalizedSite(for: api.baseURL)
                == (notification.userInfo?["baseURL"] as? String)
        else { return }

        if challengeCoordinator.requiresVerification(for: api.baseURL) {
            pollTask?.cancel()
            pollTask = nil
            seeded = false
            sharedSessionKey = nil
        } else if isActive {
            circuitOpen = false
            consecutiveFailures = 0
            startPolling(delay: Self.initialDelay)
        }
    }

    // MARK: - Long-poll loop

    private func startPolling(delay: TimeInterval) {
        pollTask?.cancel()
        guard challengeCoordinator.allowsAutomaticRequests(for: api.baseURL) else {
            pollTask = nil
            return
        }
        pollTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }

            if !seeded {
                await seedInitialState()
            }

            guard self.userId != nil else { return }

            // Continuous long-poll: the server holds each request open until
            // there's data (or its long-poll timeout), so re-issue immediately
            // on return instead of sleeping. A fixed delay between polls just
            // adds a blind window where new notifications go unseen.
            while !Task.isCancelled, self.isActive, !self.circuitOpen {
                await self.pollMessageBus()
            }
        }
    }

    /// First poll: fetch current user for initial unread state + user ID,
    /// then seed MessageBus channel positions with -1.
    private func seedInitialState() async {
        guard challengeCoordinator.allowsAutomaticRequests(for: api.baseURL) else { return }
        // linux.do's /session/current.json returns empty, so skip it entirely there.
        if !api.isLinuxDo, let user = try? await api.fetchCurrentUser() {
            userId = user.id
            // Apply initial unread state from session
            let total = (user.unreadNotifications ?? 0) + (user.unreadHighPriorityNotifications ?? 0)
            hasUnreadNotifications = total > 0
            hasUnreadMessages = (user.unreadPrivateMessages ?? 0) > 0
        } else if let username = usernameProvider(), !username.isEmpty,
                  let profile = try? await api.fetchUserProfile(username: username)
        {
            userId = profile.id
            // currentUser returned empty — seed unread state from notifications list
            if let list = try? await api.fetchNotifications() {
                hasUnreadNotifications = list.notifications.contains { !$0.read }
                hasUnreadMessages = list.notifications.contains { !$0.read && $0.notificationType == 6 }
            }
        }
        guard userId != nil else {
            seeded = true
            return
        }

        // linux.do uses the dedicated ping.ldstatic.com MessageBus origin and
        // requires a shared session key for cookie-based authentication.
        // Only needed for web-based login (cookie auth), not User API Key auth.
        if api.isLinuxDo,
           KeychainHelper.getUserApiKey(for: api.baseURL) == AuthManager.webAuthSentinel
        {
            sharedSessionKey = await api.fetchSharedSessionKey()
        }
        guard !Task.isCancelled,
              challengeCoordinator.allowsAutomaticRequests(for: api.baseURL)
        else { return }

        // Seed MessageBus channel positions from /__status response
        let channels: [String: Int] = ["/notification/\(userId!)": -1]
        if let msgs = try? await api.pollMessageBus(clientId: clientId, channels: channels, sharedSessionKey: sharedSessionKey) {
            for msg in msgs {
                if let positions = msg.statusChannelPositions {
                    for (ch, pos) in positions {
                        lastMessageIds[ch] = pos
                    }
                } else {
                    lastMessageIds[msg.channel] = msg.messageId
                }
            }
        }

        // Default to 0 for channels not included in __status so we don't keep sending -1
        for ch in channels.keys where lastMessageIds[ch] == nil {
            lastMessageIds[ch] = 0
        }

        seeded = true
    }

    /// Long-poll: send request, server holds until new data or timeout, then return immediately for next round.
    @discardableResult
    private func pollMessageBus() async -> Bool {
        guard let userId else { return false }

        let channel = "/notification/\(userId)"
        let pollChannels = [channel: lastMessageIds[channel] ?? -1]

        let messages: [MessageBusMessage]
        do {
            messages = try await api.pollMessageBus(clientId: clientId, channels: pollChannels, sharedSessionKey: sharedSessionKey)
        } catch {
            consecutiveFailures += 1
            debugLog("[MessageBus] poll failed (\(consecutiveFailures)/\(Self.maxConsecutiveFailures)): \(error)")
            if consecutiveFailures >= Self.maxConsecutiveFailures {
                circuitOpen = true
                debugLog("[MessageBus] circuit opened — pausing polling until next foreground")
            }
            return false
        }
        consecutiveFailures = 0

        for msg in messages {
            if let positions = msg.statusChannelPositions {
                for (ch, pos) in positions {
                    lastMessageIds[ch] = pos
                }
            } else {
                if msg.messageId > (lastMessageIds[msg.channel] ?? -1) {
                    lastMessageIds[msg.channel] = msg.messageId
                }
                if msg.channel == channel, let data = msg.data {
                    let total = data.allUnreadNotificationsCount
                        ?? ((data.unreadNotifications ?? 0) + (data.unreadHighPriorityNotifications ?? 0))
                    let pm = data.groupedUnreadNotifications?["6"] ?? data.newPersonalMessagesNotificationsCount ?? 0
                    hasUnreadNotifications = total > 0
                    hasUnreadMessages = pm > 0
                }
            }
        }

        return true
    }

    deinit {
        stop()
    }

    #if DEBUG
    var hasScheduledPollForTesting: Bool { pollTask != nil }
    #endif
}
