import UIKit
import XCTest

@testable import dexo

final class WebLoginCompatibilityTests: XCTestCase {
    func testImportMapShimIsBundledWithTheApp() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "es-module-shims", withExtension: "js")
        )
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(source.contains("ES Module Shims @version 2.8.4"))
    }

    func testOlderIOSAdvertisesMinimumSupportedVersion() {
        let userAgent = WebLoginCompatibility.mobileSafariUserAgent(
            operatingSystemVersion: .init(
                majorVersion: 16,
                minorVersion: 3,
                patchVersion: 1
            ),
            idiom: .phone
        )

        XCTAssertTrue(userAgent.contains("iPhone OS 16_7"))
        XCTAssertTrue(userAgent.contains("Version/16.7"))
        XCTAssertFalse(userAgent.contains("16_3"))
    }

    func testSupportedIOSKeepsItsRealVersion() {
        let userAgent = WebLoginCompatibility.mobileSafariUserAgent(
            operatingSystemVersion: .init(
                majorVersion: 17,
                minorVersion: 2,
                patchVersion: 1
            ),
            idiom: .phone
        )

        XCTAssertTrue(userAgent.contains("iPhone OS 17_2"))
        XCTAssertTrue(userAgent.contains("Version/17.2"))
    }

    func testIPadUsesSafariIPadCPUToken() {
        let userAgent = WebLoginCompatibility.mobileSafariUserAgent(
            operatingSystemVersion: .init(
                majorVersion: 16,
                minorVersion: 0,
                patchVersion: 0
            ),
            idiom: .pad
        )

        XCTAssertTrue(userAgent.contains("iPad; CPU OS 16_7"))
        XCTAssertFalse(userAgent.contains("CPU iPad OS"))
    }
}
