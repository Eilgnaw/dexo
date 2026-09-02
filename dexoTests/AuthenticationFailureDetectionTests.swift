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
}
