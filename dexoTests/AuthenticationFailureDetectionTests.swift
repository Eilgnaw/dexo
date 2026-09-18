import Foundation
import XCTest

@testable import dexo

final class AuthenticationFailureDetectionTests: XCTestCase {
    func testValidJSONQuotingCloudflareMarkupIsNotAChallenge() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "post_stream": ["posts": [["cooked": "<title>Just a moment...</title><script>__cf_chl_</script>"]]],
        ])
        XCTAssertFalse(isCloudflareChallengeResponse(data))
        XCTAssertFalse(isCloudflareChallengeResponse(data, response: response(contentType: "application/json")))
    }

    func testMitigationHeaderIdentifiesChallengeEvenWithoutBody() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://forum.example.com/latest.json")!, statusCode: 403,
            httpVersion: nil, headerFields: ["cf-mitigated": "challenge", "Content-Type": "text/html"]
        ))
        XCTAssertTrue(isCloudflareChallengeResponse(nil, response: response))
    }

    @MainActor
    func testCentralResponseBoundaryRecordsLinuxDoChallengeReason() throws {
        let coordinator = CloudflareChallengeCoordinator.shared
        let originalReasons = coordinator.reasons(for: "https://linux.do")
        defer {
            coordinator.clearAll(for: "https://linux.do")
            coordinator.report(originalReasons, for: "https://linux.do")
        }
        coordinator.clearAll(for: "https://linux.do")
        let api = DiscourseAPI(baseURL: "https://linux.do")
        let url = try XCTUnwrap(URL(string: "https://linux.do/latest.json"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 403,
            httpVersion: nil,
            headerFields: ["cf-mitigated": "challenge"]
        ))

        let error = api.cloudflareChallengeErrorIfNeeded(
            data: nil,
            response: response,
            request: URLRequest(url: url)
        )

        XCTAssertTrue(error?.isChallengeRequired == true)
        XCTAssertEqual(coordinator.reasons(for: "https://linux.do"), .generalRequest)
    }

    func testHTMLChallengeFallbackAndOrdinaryHTML() {
        let challenge = Data("<!doctype html><html><title>Just a moment...</title></html>".utf8)
        XCTAssertTrue(isCloudflareChallengeResponse(challenge))
        XCTAssertTrue(isCloudflareChallengeResponse(challenge, response: response(contentType: "text/html")))
        XCTAssertFalse(isCloudflareChallengeResponse(Data("<html><p>Just a moment...</p></html>".utf8)))
        XCTAssertFalse(isCloudflareChallengeResponse(Data("Just a moment...".utf8)))
    }

    private func response(contentType: String) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://forum.example.com/latest.json")!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": contentType]
        )!
    }

    func testUnauthorizedStatusExpiresAuthenticationWithoutBody() {
        XCTAssertTrue(isDiscourseAuthenticationFailure(statusCode: 401, data: nil))
    }

    func testNotLoggedInResponseExpiresAuthentication() throws {
        let data = try XCTUnwrap(
            #"{"errors":["You need to log in"],"error_type":"not_logged_in"}"#
                .data(using: .utf8)
        )

        XCTAssertTrue(isDiscourseAuthenticationFailure(statusCode: 403, data: data))
    }

    func testInvalidAccessDoesNotExpireAuthentication() throws {
        let data = try XCTUnwrap(
            #"{"errors":["You are not permitted"],"error_type":"invalid_access"}"#
                .data(using: .utf8)
        )

        XCTAssertFalse(isDiscourseAuthenticationFailure(statusCode: 403, data: data))
    }

    func testGenericForbiddenDoesNotExpireAuthentication() throws {
        let data = try XCTUnwrap(#"{"errors":["Forbidden"]}"#.data(using: .utf8))

        XCTAssertFalse(isDiscourseAuthenticationFailure(statusCode: 403, data: data))
    }

    func testBasicInfoProbeDoesNotAttachStoredAuthentication() throws {
        let requestURL = try XCTUnwrap(URL(string: "https://linux.do/site/basic-info.json"))

        XCTAssertFalse(
            shouldAttachStoredForumAuthentication(
                to: requestURL,
                baseURL: "https://linux.do"
            )
        )
    }

    func testBasicInfoProbeSupportsForumSubpaths() throws {
        let requestURL = try XCTUnwrap(
            URL(string: "https://example.com/community/site/basic-info.json")
        )

        XCTAssertFalse(
            shouldAttachStoredForumAuthentication(
                to: requestURL,
                baseURL: "https://example.com/community"
            )
        )
    }

    func testOtherForumRequestsStillAttachStoredAuthentication() throws {
        let requestURL = try XCTUnwrap(URL(string: "https://linux.do/latest.json"))

        XCTAssertTrue(
            shouldAttachStoredForumAuthentication(
                to: requestURL,
                baseURL: "https://linux.do"
            )
        )
    }

    func testCurrentUserProbeIdentifiesGuestButNotMalformedResponse() {
        XCTAssertEqual(assessAuthenticationProbe(
            isLinuxDo: false, statusCode: 200,
            data: Data(#"{"current_user":null}"#.utf8), finalURL: nil
        ), .expired)
        XCTAssertEqual(assessAuthenticationProbe(
            isLinuxDo: false, statusCode: 200,
            data: Data(#"{"current_user":{"username":"alice"}}"#.utf8), finalURL: nil
        ), .authenticated)
        XCTAssertEqual(assessAuthenticationProbe(
            isLinuxDo: false, statusCode: 200,
            data: Data("<html>temporary error</html>".utf8), finalURL: nil
        ), .inconclusive)
    }

    func testLinuxDoProbeUsesAuthenticatedNotificationIdentity() {
        XCTAssertEqual(assessAuthenticationProbe(
            isLinuxDo: true, statusCode: 200,
            data: Data(#"{"notifications":[],"load_more_notifications":"/notifications?username=alice"}"#.utf8),
            finalURL: nil
        ), .authenticated)
        XCTAssertEqual(assessAuthenticationProbe(
            isLinuxDo: true, statusCode: 200,
            data: Data(#"{"notifications":[],"load_more_notifications":"/notifications"}"#.utf8),
            finalURL: nil
        ), .expired)
    }

    func testProbeIgnoresOrdinaryForbiddenAndNetworkFailure() {
        XCTAssertEqual(assessAuthenticationProbe(
            isLinuxDo: false, statusCode: 403,
            data: Data(#"{"errors":["Forbidden"],"error_type":"invalid_access"}"#.utf8),
            finalURL: nil
        ), .inconclusive)
        XCTAssertEqual(assessAuthenticationProbe(
            isLinuxDo: false, statusCode: nil, data: nil, finalURL: nil
        ), .inconclusive)
        XCTAssertEqual(assessAuthenticationProbe(
            isLinuxDo: false, statusCode: 401, data: nil, finalURL: nil
        ), .expired)
    }
}
