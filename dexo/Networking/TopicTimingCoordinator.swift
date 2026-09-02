import Foundation

nonisolated enum ForumAuthKind: Equatable, Sendable {
    case anonymous
    case userAPIKey
    case webSession
}

nonisolated struct TopicTimingBatch: Equatable, Sendable {
    let topicId: Int
    let topicTime: Int
    let timings: [Int: Int]
    let accountName: String?

    init(topicId: Int, topicTime: Int, timings: [Int: Int], accountName: String? = nil) {
        self.topicId = topicId
        self.topicTime = max(0, topicTime)
        self.timings = timings.filter { $0.key > 0 && $0.value > 0 }
        self.accountName = accountName
    }
}

nonisolated struct TopicTimingAttempt: Equatable, Sendable {
    enum Result: Equatable, Sendable {
        case success
        case cloudflareChallenge
        case authenticationFailure
        case csrfRejected
        case retryableFailure
        case fatalFailure
        case indeterminate
    }

    let result: Result
    let statusCode: Int?
    let retryAfter: TimeInterval?
    let attemptedAt: Date
    let requestDuration: Int
    let errorSummary: String?

    init(
        result: Result,
        statusCode: Int? = nil,
        retryAfter: TimeInterval? = nil,
        attemptedAt: Date = Date(),
        requestDuration: Int = 0,
        errorSummary: String? = nil
    ) {
        self.result = result
        self.statusCode = statusCode
        self.retryAfter = retryAfter
        self.attemptedAt = attemptedAt
        self.requestDuration = requestDuration
        self.errorSummary = errorSummary
    }
}

/// Serializes and consolidates Discourse `/topics/timings` updates.
///
/// All entry points are MainActor-isolated by the app target's default actor
/// isolation. Network awaits yield the actor, while `workerTask` remains the
/// single owner of queue draining and therefore prevents concurrent uploads.
final class TopicTimingCoordinator {
    struct Configuration: Equatable, Sendable {
        let minimumRequestInterval: TimeInterval
        let retryDelays: [TimeInterval]
        let maximumPendingTopics: Int?
        let maximumPendingAge: TimeInterval?

        static let linuxDo = Configuration(
            minimumRequestInterval: 30,
            retryDelays: [30, 60, 120],
            maximumPendingTopics: 10,
            maximumPendingAge: 5 * 60
        )

        static let standard = Configuration(
            minimumRequestInterval: 0,
            retryDelays: [5, 10, 20, 40],
            maximumPendingTopics: nil,
            maximumPendingAge: nil
        )
    }

    typealias Transport = (TopicTimingBatch) async -> TopicTimingAttempt
    typealias AttemptObserver = (
        _ batch: TopicTimingBatch,
        _ attempt: TopicTimingAttempt,
        _ consecutiveFailureCount: Int,
        _ trippedBreaker: Bool
    ) -> Void

    private struct PendingTopic {
        var topicTime: Int
        var timings: [Int: Int]
        var accountName: String?
        var updatedAt: Date
    }

    private let configuration: Configuration
    private let now: () -> Date
    private let sleep: (TimeInterval) async -> Void
    private let canSend: () -> Bool
    private let transport: Transport
    private let attemptObserver: AttemptObserver
    private let onCloudflareChallenge: () -> Void
    private let onAuthenticationFailure: () -> Void

    private var pendingByTopic: [Int: PendingTopic] = [:]
    private var pendingTopicOrder: [Int] = []
    private var workerTask: Task<Void, Never>?
    private var applicationIsActive: Bool
    private var sessionIsSuspended = false
    private var stateGeneration = 0
    private var lastRequestStartedAt: Date?
    private var consecutiveFailureCount = 0
    private var consecutiveFatalFailureCount = 0
    private var inFlightTopicId: Int?

    init(
        configuration: Configuration,
        applicationIsActive: Bool = true,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async -> Void = { seconds in
            guard seconds > 0 else { return }
            let nanoseconds = UInt64(min(seconds, TimeInterval(UInt64.max) / 1_000_000_000) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        canSend: @escaping () -> Bool,
        transport: @escaping Transport,
        attemptObserver: @escaping AttemptObserver = { _, _, _, _ in },
        onCloudflareChallenge: @escaping () -> Void = {},
        onAuthenticationFailure: @escaping () -> Void = {}
    ) {
        self.configuration = configuration
        self.applicationIsActive = applicationIsActive
        self.now = now
        self.sleep = sleep
        self.canSend = canSend
        self.transport = transport
        self.attemptObserver = attemptObserver
        self.onCloudflareChallenge = onCloudflareChallenge
        self.onAuthenticationFailure = onAuthenticationFailure
    }

    deinit {
        workerTask?.cancel()
    }

    func enqueue(_ batch: TopicTimingBatch) {
        guard !batch.timings.isEmpty, canSend(), !sessionIsSuspended else { return }

        pruneExpiredPendingTopics()
        if var pending = pendingByTopic[batch.topicId] {
            pending.topicTime = saturatedAdd(pending.topicTime, batch.topicTime)
            for (postNumber, duration) in batch.timings {
                pending.timings[postNumber] = saturatedAdd(
                    pending.timings[postNumber, default: 0],
                    duration
                )
            }
            pending.accountName = batch.accountName ?? pending.accountName
            pending.updatedAt = now()
            pendingByTopic[batch.topicId] = pending
        } else {
            evictForCapacityIfNeeded()
            pendingByTopic[batch.topicId] = PendingTopic(
                topicTime: batch.topicTime,
                timings: batch.timings,
                accountName: batch.accountName,
                updatedAt: now()
            )
            pendingTopicOrder.append(batch.topicId)
        }
        startWorkerIfNeeded()
    }

    func suspendForBackground() {
        applicationIsActive = false
    }

    func resumeFromBackground() {
        applicationIsActive = true
        startWorkerIfNeeded()
    }

    /// Authentication and the user-facing setting are both account boundaries.
    /// Never retain timings collected under the previous eligibility state.
    func resetForEligibilityChange(isEligible: Bool) {
        stateGeneration &+= 1
        pendingByTopic.removeAll()
        pendingTopicOrder.removeAll()
        consecutiveFailureCount = 0
        consecutiveFatalFailureCount = 0
        sessionIsSuspended = !isEligible
        if isEligible {
            startWorkerIfNeeded()
        }
    }

    func waitUntilIdleForTesting() async {
        await workerTask?.value
    }

    var pendingTopicIDsForTesting: [Int] { pendingTopicOrder }
    var isSessionSuspendedForTesting: Bool { sessionIsSuspended }

    private func startWorkerIfNeeded() {
        guard workerTask == nil,
              applicationIsActive,
              !sessionIsSuspended,
              canSend(),
              !pendingTopicOrder.isEmpty
        else { return }

        workerTask = Task { [weak self] in
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        defer {
            workerTask = nil
            startWorkerIfNeeded()
        }

        while !Task.isCancelled,
              applicationIsActive,
              !sessionIsSuspended,
              canSend()
        {
            pruneExpiredPendingTopics()
            guard let topicId = pendingTopicOrder.first,
                  let batch = nextBatch(for: topicId)
            else { return }

            let generation = stateGeneration
            let shouldContinue = await process(batch, generation: generation)
            guard shouldContinue else { return }
        }
    }

    private func process(_ batch: TopicTimingBatch, generation: Int) async -> Bool {
        var retryIndex = 0
        var hasRetriedCSRF = false
        var additionalDelay: TimeInterval = 0

        while !Task.isCancelled {
            guard await waitUntilRequestAllowed(additionalDelay: additionalDelay),
                  generation == stateGeneration,
                  applicationIsActive,
                  canSend(),
                  !sessionIsSuspended
            else { return false }

            inFlightTopicId = batch.topicId
            lastRequestStartedAt = now()
            let attempt = await transport(batch)
            inFlightTopicId = nil

            guard generation == stateGeneration else { return false }

            if attempt.result == .success {
                consecutiveFailureCount = 0
                consecutiveFatalFailureCount = 0
                consume(batch)
                attemptObserver(batch, attempt, 0, false)
                return true
            }

            consecutiveFailureCount += 1

            switch attempt.result {
            case .cloudflareChallenge:
                attemptObserver(batch, attempt, consecutiveFailureCount, true)
                suspendAndDiscardPending()
                onCloudflareChallenge()
                return false

            case .authenticationFailure:
                attemptObserver(batch, attempt, consecutiveFailureCount, true)
                suspendAndDiscardPending()
                onAuthenticationFailure()
                return false

            case .csrfRejected where !hasRetriedCSRF:
                hasRetriedCSRF = true
                additionalDelay = max(30, configuration.minimumRequestInterval)
                attemptObserver(batch, attempt, consecutiveFailureCount, false)
                continue

            case .retryableFailure where retryIndex < configuration.retryDelays.count:
                let configuredDelay = configuration.retryDelays[retryIndex]
                retryIndex += 1
                additionalDelay = max(configuredDelay, attempt.retryAfter ?? 0)
                attemptObserver(batch, attempt, consecutiveFailureCount, false)
                continue

            case .retryableFailure:
                attemptObserver(batch, attempt, consecutiveFailureCount, true)
                suspendAndDiscardPending()
                return false

            case .fatalFailure, .csrfRejected:
                consecutiveFatalFailureCount += 1
                consume(batch)
                let shouldTrip = consecutiveFatalFailureCount >= 3
                attemptObserver(batch, attempt, consecutiveFailureCount, shouldTrip)
                if shouldTrip {
                    suspendAndDiscardPending()
                    return false
                }
                return true

            case .indeterminate:
                // `/topics/timings` is additive. When no HTTP response arrives,
                // the server may already have processed the request; retrying
                // the same slice would risk double-counting it.
                consume(batch)
                attemptObserver(batch, attempt, consecutiveFailureCount, false)
                return true

            case .success:
                return true
            }
        }
        return false
    }

    private func waitUntilRequestAllowed(additionalDelay: TimeInterval) async -> Bool {
        let current = now()
        let intervalDelay: TimeInterval
        if let lastRequestStartedAt {
            intervalDelay = max(
                0,
                configuration.minimumRequestInterval
                    - current.timeIntervalSince(lastRequestStartedAt)
            )
        } else {
            intervalDelay = 0
        }
        let delay = max(intervalDelay, additionalDelay)
        if delay > 0 {
            await sleep(delay)
        }
        return !Task.isCancelled && applicationIsActive
    }

    /// Discourse caps every per-post timing and `topic_time` value at 60 s per
    /// request. Keep excess pending rather than letting the server discard it.
    private func nextBatch(for topicId: Int) -> TopicTimingBatch? {
        guard let pending = pendingByTopic[topicId] else { return nil }
        let timings = pending.timings.reduce(into: [Int: Int]()) { result, item in
            if item.value > 0 {
                result[item.key] = min(Self.maximumValuePerRequest, item.value)
            }
        }
        guard !timings.isEmpty else {
            removePendingTopic(topicId)
            return nil
        }
        return TopicTimingBatch(
            topicId: topicId,
            topicTime: min(Self.maximumValuePerRequest, pending.topicTime),
            timings: timings,
            accountName: pending.accountName
        )
    }

    private func consume(_ batch: TopicTimingBatch) {
        guard var pending = pendingByTopic[batch.topicId] else { return }
        pending.topicTime = max(0, pending.topicTime - batch.topicTime)
        for (postNumber, duration) in batch.timings {
            let remaining = max(0, pending.timings[postNumber, default: 0] - duration)
            if remaining == 0 {
                pending.timings.removeValue(forKey: postNumber)
            } else {
                pending.timings[postNumber] = remaining
            }
        }

        if pending.timings.isEmpty {
            removePendingTopic(batch.topicId)
        } else {
            pendingByTopic[batch.topicId] = pending
            // A large topic must not starve later topics while its >60 s
            // remainder is split across multiple requests.
            if pendingTopicOrder.first == batch.topicId {
                pendingTopicOrder.removeFirst()
                pendingTopicOrder.append(batch.topicId)
            }
        }
    }

    private func pruneExpiredPendingTopics() {
        guard let maximumAge = configuration.maximumPendingAge else { return }
        let cutoff = now().addingTimeInterval(-maximumAge)
        let expired = pendingTopicOrder.filter { topicId in
            topicId != inFlightTopicId
                && (pendingByTopic[topicId]?.updatedAt ?? .distantPast) < cutoff
        }
        for topicId in expired {
            removePendingTopic(topicId)
        }
    }

    private func evictForCapacityIfNeeded() {
        guard let maximumPendingTopics = configuration.maximumPendingTopics else { return }
        while pendingTopicOrder.count >= maximumPendingTopics {
            guard let topicId = pendingTopicOrder.first(where: { $0 != inFlightTopicId }) else {
                return
            }
            removePendingTopic(topicId)
        }
    }

    private func removePendingTopic(_ topicId: Int) {
        pendingByTopic.removeValue(forKey: topicId)
        pendingTopicOrder.removeAll { $0 == topicId }
    }

    private func suspendAndDiscardPending() {
        sessionIsSuspended = true
        stateGeneration &+= 1
        pendingByTopic.removeAll()
        pendingTopicOrder.removeAll()
    }

    private func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        guard rhs > 0 else { return lhs }
        return lhs > Int.max - rhs ? Int.max : lhs + rhs
    }

    private static let maximumValuePerRequest = 60 * 1000
}
