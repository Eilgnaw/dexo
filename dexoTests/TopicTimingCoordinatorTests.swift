import Foundation
import XCTest
@testable import dexo

final class TopicTimingCoordinatorTests: XCTestCase {
    func testMergesSameTopicAndSlicesAtServerLimit() async {
        var currentTime = Date(timeIntervalSince1970: 1_000)
        var attempts: [TopicTimingBatch] = []
        var startTimes: [Date] = []
        let coordinator = makeCoordinator(
            now: { currentTime },
            sleep: { delay in currentTime.addTimeInterval(delay) },
            transport: { batch in
                attempts.append(batch)
                startTimes.append(currentTime)
                return TopicTimingAttempt(result: .success)
            }
        )

        coordinator.enqueue(
            TopicTimingBatch(
                topicId: 42,
                topicTime: 130_000,
                timings: [1: 125_000, 2: 20_000]
            )
        )
        await coordinator.waitUntilIdleForTesting()

        XCTAssertEqual(attempts.count, 3)
        XCTAssertEqual(attempts[0].topicTime, 60_000)
        XCTAssertEqual(attempts[0].timings, [1: 60_000, 2: 20_000])
        XCTAssertEqual(attempts[1].topicTime, 60_000)
        XCTAssertEqual(attempts[1].timings, [1: 60_000])
        XCTAssertEqual(attempts[2].topicTime, 10_000)
        XCTAssertEqual(attempts[2].timings, [1: 5_000])
        XCTAssertEqual(startTimes.map(\.timeIntervalSince1970), [1_000, 1_030, 1_060])
    }

    func testDropsSubsecondRemainderInsteadOfSendingDustRequest() async {
        var attempts: [TopicTimingBatch] = []
        let coordinator = makeCoordinator(
            transport: { batch in
                attempts.append(batch)
                return TopicTimingAttempt(result: .success)
            }
        )

        coordinator.enqueue(
            TopicTimingBatch(
                topicId: 42,
                topicTime: 60_020,
                timings: [1: 60_020]
            )
        )
        await coordinator.waitUntilIdleForTesting()

        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.topicTime, 60_000)
        XCTAssertEqual(attempts.first?.timings, [1: 60_000])
        XCTAssertTrue(coordinator.pendingTopicIDsForTesting.isEmpty)
    }

    func testDifferentTopicsRemainFIFOAndNeverStartMoreOftenThanEveryThirtySeconds() async {
        var currentTime = Date(timeIntervalSince1970: 2_000)
        var topicOrder: [Int] = []
        var startTimes: [Date] = []
        var inFlight = 0
        var maximumInFlight = 0
        let coordinator = makeCoordinator(
            now: { currentTime },
            sleep: { delay in currentTime.addTimeInterval(delay) },
            transport: { batch in
                inFlight += 1
                maximumInFlight = max(maximumInFlight, inFlight)
                topicOrder.append(batch.topicId)
                startTimes.append(currentTime)
                await Task.yield()
                inFlight -= 1
                return TopicTimingAttempt(result: .success)
            }
        )

        for topicId in 1 ... 3 {
            coordinator.enqueue(
                TopicTimingBatch(topicId: topicId, topicTime: 1_000, timings: [1: 1_000])
            )
        }
        await coordinator.waitUntilIdleForTesting()

        XCTAssertEqual(topicOrder, [1, 2, 3])
        XCTAssertEqual(maximumInFlight, 1)
        XCTAssertEqual(startTimes.map(\.timeIntervalSince1970), [2_000, 2_030, 2_060])
        XCTAssertEqual(startTimes.filter { $0 < Date(timeIntervalSince1970: 2_060) }.count, 2)
    }

    func testBackgroundQueuesWithoutSendingAndForegroundResumes() async {
        var attempts = 0
        let coordinator = makeCoordinator(
            applicationIsActive: false,
            transport: { _ in
                attempts += 1
                return TopicTimingAttempt(result: .success)
            }
        )

        coordinator.enqueue(
            TopicTimingBatch(topicId: 1, topicTime: 1_000, timings: [1: 1_000])
        )
        await coordinator.waitUntilIdleForTesting()
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(coordinator.pendingTopicIDsForTesting, [1])

        coordinator.resumeFromBackground()
        await coordinator.waitUntilIdleForTesting()
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(coordinator.pendingTopicIDsForTesting.isEmpty)
    }

    func testEligibilityChangeClearsAccountBoundQueue() async {
        var attempts = 0
        let coordinator = makeCoordinator(
            applicationIsActive: false,
            transport: { _ in
                attempts += 1
                return TopicTimingAttempt(result: .success)
            }
        )
        coordinator.enqueue(
            TopicTimingBatch(topicId: 1, topicTime: 1_000, timings: [1: 1_000])
        )

        coordinator.resetForEligibilityChange(isEligible: false)
        XCTAssertTrue(coordinator.pendingTopicIDsForTesting.isEmpty)
        XCTAssertTrue(coordinator.isSessionSuspendedForTesting)

        coordinator.resumeFromBackground()
        await coordinator.waitUntilIdleForTesting()
        XCTAssertEqual(attempts, 0)
    }

    func testQueueCapsAtTenTopicsAndExpiresAfterFiveMinutes() async {
        var currentTime = Date(timeIntervalSince1970: 3_000)
        var attempts = 0
        let coordinator = makeCoordinator(
            applicationIsActive: false,
            now: { currentTime },
            sleep: { delay in currentTime.addTimeInterval(delay) },
            transport: { _ in
                attempts += 1
                return TopicTimingAttempt(result: .success)
            }
        )

        for topicId in 1 ... 11 {
            coordinator.enqueue(
                TopicTimingBatch(topicId: topicId, topicTime: 1_000, timings: [1: 1_000])
            )
        }
        XCTAssertEqual(coordinator.pendingTopicIDsForTesting, Array(2 ... 11))

        currentTime.addTimeInterval(301)
        coordinator.resumeFromBackground()
        await coordinator.waitUntilIdleForTesting()
        XCTAssertEqual(attempts, 0)
        XCTAssertTrue(coordinator.pendingTopicIDsForTesting.isEmpty)
    }

    func testCloudflareChallengeStopsAfterOneAttemptAndManualResetCanResume() async {
        var attempts = 0
        var challengeCallbacks = 0
        let coordinator = makeCoordinator(
            transport: { _ in
                attempts += 1
                return attempts == 1
                    ? TopicTimingAttempt(result: .cloudflareChallenge, statusCode: 403)
                    : TopicTimingAttempt(result: .success, statusCode: 200)
            },
            onCloudflareChallenge: { challengeCallbacks += 1 }
        )

        coordinator.enqueue(
            TopicTimingBatch(topicId: 1, topicTime: 1_000, timings: [1: 1_000])
        )
        coordinator.enqueue(
            TopicTimingBatch(topicId: 2, topicTime: 1_000, timings: [1: 1_000])
        )
        await coordinator.waitUntilIdleForTesting()

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(challengeCallbacks, 1)
        XCTAssertTrue(coordinator.pendingTopicIDsForTesting.isEmpty)
        XCTAssertTrue(coordinator.isSessionSuspendedForTesting)

        coordinator.resetForEligibilityChange(isEligible: true)
        coordinator.enqueue(
            TopicTimingBatch(topicId: 3, topicTime: 1_000, timings: [1: 1_000])
        )
        await coordinator.waitUntilIdleForTesting()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(challengeCallbacks, 1)
        XCTAssertFalse(coordinator.isSessionSuspendedForTesting)
    }

    func testRetryAfterWinsOverBackoffAndIndeterminateResultIsNotRetried() async {
        var currentTime = Date(timeIntervalSince1970: 4_000)
        var retryStarts: [Date] = []
        var retryAttempt = 0
        let retryingCoordinator = makeCoordinator(
            now: { currentTime },
            sleep: { delay in currentTime.addTimeInterval(delay) },
            transport: { _ in
                retryStarts.append(currentTime)
                defer { retryAttempt += 1 }
                if retryAttempt == 0 {
                    return TopicTimingAttempt(
                        result: .retryableFailure,
                        statusCode: 429,
                        retryAfter: 90
                    )
                }
                return TopicTimingAttempt(result: .success)
            }
        )
        retryingCoordinator.enqueue(
            TopicTimingBatch(topicId: 1, topicTime: 1_000, timings: [1: 1_000])
        )
        await retryingCoordinator.waitUntilIdleForTesting()
        XCTAssertEqual(retryStarts.map(\.timeIntervalSince1970), [4_000, 4_090])

        var indeterminateAttempts = 0
        let indeterminateCoordinator = makeCoordinator(
            transport: { _ in
                indeterminateAttempts += 1
                return TopicTimingAttempt(result: .indeterminate)
            }
        )
        indeterminateCoordinator.enqueue(
            TopicTimingBatch(topicId: 2, topicTime: 1_000, timings: [1: 1_000])
        )
        await indeterminateCoordinator.waitUntilIdleForTesting()
        XCTAssertEqual(indeterminateAttempts, 1)
        XCTAssertTrue(indeterminateCoordinator.pendingTopicIDsForTesting.isEmpty)
    }

    func testCSRFHasOneDelayedRetryAndRetryableFailuresTripAfterThreeRetries() async {
        var currentTime = Date(timeIntervalSince1970: 5_000)
        var csrfStarts: [Date] = []
        let csrfCoordinator = makeCoordinator(
            now: { currentTime },
            sleep: { delay in currentTime.addTimeInterval(delay) },
            transport: { _ in
                csrfStarts.append(currentTime)
                return TopicTimingAttempt(result: .csrfRejected, statusCode: 403)
            }
        )
        csrfCoordinator.enqueue(
            TopicTimingBatch(topicId: 1, topicTime: 1_000, timings: [1: 1_000])
        )
        await csrfCoordinator.waitUntilIdleForTesting()
        XCTAssertEqual(csrfStarts.map(\.timeIntervalSince1970), [5_000, 5_030])
        XCTAssertFalse(csrfCoordinator.isSessionSuspendedForTesting)

        currentTime = Date(timeIntervalSince1970: 6_000)
        var retryStarts: [Date] = []
        let retryCoordinator = makeCoordinator(
            now: { currentTime },
            sleep: { delay in currentTime.addTimeInterval(delay) },
            transport: { _ in
                retryStarts.append(currentTime)
                return TopicTimingAttempt(result: .retryableFailure, statusCode: 503)
            }
        )
        retryCoordinator.enqueue(
            TopicTimingBatch(topicId: 2, topicTime: 1_000, timings: [1: 1_000])
        )
        await retryCoordinator.waitUntilIdleForTesting()
        XCTAssertEqual(
            retryStarts.map(\.timeIntervalSince1970),
            [6_000, 6_030, 6_090, 6_210]
        )
        XCTAssertTrue(retryCoordinator.isSessionSuspendedForTesting)
        XCTAssertTrue(retryCoordinator.pendingTopicIDsForTesting.isEmpty)
    }

    private func makeCoordinator(
        applicationIsActive: Bool = true,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async -> Void = { _ in },
        transport: @escaping TopicTimingCoordinator.Transport,
        onCloudflareChallenge: @escaping () -> Void = {}
    ) -> TopicTimingCoordinator {
        TopicTimingCoordinator(
            configuration: .linuxDo,
            applicationIsActive: applicationIsActive,
            now: now,
            sleep: sleep,
            canSend: { true },
            transport: transport,
            onCloudflareChallenge: onCloudflareChallenge
        )
    }
}

final class TopicTimingRetryAfterTests: XCTestCase {
    func testRetryAfterParsesSecondsAndHTTPDate() throws {
        let url = try XCTUnwrap(URL(string: "https://linux.do/topics/timings"))
        let secondsResponse = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "75"]
            )
        )
        XCTAssertEqual(DiscourseAPI.retryAfterDelay(from: secondsResponse), 75)

        let now = Date(timeIntervalSince1970: 0)
        let dateResponse = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: 503,
                httpVersion: nil,
                headerFields: ["Retry-After": "Thu, 01 Jan 1970 00:02:00 GMT"]
            )
        )
        XCTAssertEqual(DiscourseAPI.retryAfterDelay(from: dateResponse, now: now), 120)
    }
}

final class TopicTimingRequestBuilderTests: XCTestCase {
    func testBuildsBrowserShapedDeterministicFormRequest() throws {
        let batch = TopicTimingBatch(
            topicId: 2_117_030,
            topicTime: 4_001,
            timings: [2: 3_000, 1: 1_001]
        )
        let request = try XCTUnwrap(
            TopicTimingRequestBuilder.makeRequest(
                baseURL: "https://linux.do",
                batch: batch
            )
        )

        XCTAssertEqual(request.url?.absoluteString, "https://linux.do/topics/timings")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) },
            "timings%5B1%5D=1001&timings%5B2%5D=3000&topic_time=4001&topic_id=2117030"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded; charset=UTF-8"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Requested-With"), "XMLHttpRequest")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SILENCE-LOGGER"), "true")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Discourse-Background"), "true")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Discourse-Present"), "true")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Discourse-Logged-In"), "true")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://linux.do")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Referer"),
            "https://linux.do/t/topic/2117030"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Site"), "same-origin")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Mode"), "cors")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-Fetch-Dest"), "empty")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Pragma"), "no-cache")
    }

    func testOriginExcludesForumSubpathButReferrerKeepsIt() throws {
        let request = try XCTUnwrap(
            TopicTimingRequestBuilder.makeRequest(
                baseURL: "https://forum.example.com:8443/community",
                batch: TopicTimingBatch(topicId: 42, topicTime: 1_000, timings: [1: 1_000])
            )
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://forum.example.com:8443")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Referer"),
            "https://forum.example.com:8443/community/t/topic/42"
        )
    }
}
