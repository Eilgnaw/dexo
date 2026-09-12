import XCTest
@testable import dexo

final class AddForumViewModelTests: XCTestCase {
    func testChallengeRequiredIsReturnedForLinuxDo() async {
        let loader: AddForumViewModel.BasicInfoLoader = { _ in
            throw DiscourseAPIError(
                messages: ["Cloudflare challenge required"],
                errorType: "challenge_required"
            )
        }
        let viewModel = AddForumViewModel(basicInfoLoader: loader)
        viewModel.urlString = "https://linux.do"

        let result = await viewModel.addForum()

        guard case .challengeRequired(let baseURL) = result else {
            return XCTFail("Expected a Cloudflare challenge result")
        }
        XCTAssertEqual(baseURL, "https://linux.do")
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(
            viewModel.errorMessage,
            String(localized: "add_forum.error.challenge")
        )
    }

    func testNonLinuxChallengeRemainsAConnectionFailure() async {
        let challengeError = DiscourseAPIError(
            messages: ["Cloudflare challenge required"],
            errorType: "challenge_required"
        )
        let loader: AddForumViewModel.BasicInfoLoader = { _ in
            throw challengeError
        }
        let viewModel = AddForumViewModel(basicInfoLoader: loader)
        viewModel.urlString = "https://example.com"

        let result = await viewModel.addForum()

        guard case .failed = result else {
            return XCTFail("Expected a regular failure for a non-linux.do forum")
        }
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(
            viewModel.errorMessage,
            String(localized: "add_forum.error.connect \(challengeError.localizedDescription)")
        )
    }
}
