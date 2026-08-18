import Security
import UIKit
import XCTest
@testable import dexo

final class FeedbackURLBuilderTests: XCTestCase {
    func testURLContainsExpectedEncodedParametersAndNoUserIdentity() throws {
        let context = FeedbackURLBuilder.Context(
            packageIdentifier: "com.example.dexo beta",
            deviceIdentifier: "device + id",
            appVersion: "1.2 beta&3",
            osVersion: "27.0",
            model: "iPhone 17 Pro / 测试",
            language: "zh",
            theme: .dark
        )

        let url = try FeedbackURLBuilder.makeURL(context: context)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "feedback.umiibo.app")
        XCTAssertEqual(components.path, "/")
        XCTAssertEqual(query["pkg"], "com.example.dexo beta")
        XCTAssertEqual(query["device_id"], "device + id")
        XCTAssertEqual(query["app_version"], "1.2 beta&3")
        XCTAssertEqual(query["os"], "ios")
        XCTAssertEqual(query["os_version"], "27.0")
        XCTAssertEqual(query["model"], "iPhone 17 Pro / 测试")
        XCTAssertEqual(query["lang"], "zh")
        XCTAssertEqual(query["theme"], "dark")
        XCTAssertNil(query["user_id"])
        XCTAssertNil(query["nickname"])
        XCTAssertTrue(url.absoluteString.contains("device_id=device%20%2B%20id"))
    }

    func testLanguageAndThemeMapping() {
        XCTAssertEqual(FeedbackURLBuilder.Context.languageCode(for: "zh-Hans"), "zh")
        XCTAssertEqual(FeedbackURLBuilder.Context.languageCode(for: "zh-CN"), "zh")
        XCTAssertEqual(FeedbackURLBuilder.Context.languageCode(for: "en-US"), "en")
        XCTAssertEqual(FeedbackURLBuilder.Context.languageCode(for: "fr"), "en")
        XCTAssertEqual(FeedbackURLBuilder.Context.theme(for: .dark), .dark)
        XCTAssertEqual(FeedbackURLBuilder.Context.theme(for: .light), .light)
        XCTAssertEqual(FeedbackURLBuilder.Context.theme(for: .unspecified), .light)
    }

    func testDeviceIdentifierPersistsAcrossStoreInstances() {
        let service = "com.eilgnaw.dexo.tests.feedback.\(UUID().uuidString)"
        let account = "device"
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }

        let firstStore = FeedbackDeviceIdentifierStore(
            service: service,
            account: account,
            vendorIdentifierProvider: { nil },
            runtimeFallback: "first-fallback"
        )
        let firstIdentifier = firstStore.deviceIdentifier()

        let secondStore = FeedbackDeviceIdentifierStore(
            service: service,
            account: account,
            vendorIdentifierProvider: { nil },
            runtimeFallback: "second-fallback"
        )
        let secondIdentifier = secondStore.deviceIdentifier()

        XCTAssertNotEqual(firstIdentifier, "first-fallback")
        XCTAssertEqual(secondIdentifier, firstIdentifier)
    }
}
