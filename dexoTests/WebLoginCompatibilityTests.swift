import JavaScriptCore
import UIKit
import WebKit
import XCTest

@testable import dexo

final class WebLoginCompatibilityTests: XCTestCase {
    func testRuntimePolyfillsAreBundledWithTheApp() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "web-login-polyfills", withExtension: "js")
        )
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(source.contains("Generated from core-js 3.49.0"))
        XCTAssertTrue(source.contains("__core-js_shared__"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("eruda"))
    }

    func testRuntimePolyfillsRestoreModernJavaScriptAPIs() async throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "web-login-polyfills", withExtension: "js")
        )
        let source = try String(contentsOf: url, encoding: .utf8)
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)

        var didLoad = false
        for _ in 0..<100 {
            if let state = try? await webView.evaluateJavaScript("document.readyState") as? String,
               state == "complete"
            {
                didLoad = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(didLoad)

        try await webView.evaluateJavaScript(
            """
            Promise.withResolvers = undefined;
            Object.groupBy = undefined;
            Set.prototype.union = undefined;
            Array.prototype.toSorted = undefined;
            """
        )
        try await webView.evaluateJavaScript(source)

        let restored = try await webView.evaluateJavaScript(
                """
                typeof Promise.withResolvers === 'function' &&
                typeof Object.groupBy === 'function' &&
                typeof Set.prototype.union === 'function' &&
                typeof Array.prototype.toSorted === 'function'
                """
        ) as? Bool
        XCTAssertEqual(restored, true)
    }

    func testBrowserGateOverrideIsTemporary() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(
            """
            var window = this;
            var discourseInitCallback;
            var CSS = { supports: function() { return false; } };
            var document = {
                addEventListener: function(name, callback) {
                    if (name === 'discourse-init') discourseInitCallback = callback;
                }
            };
            window.addEventListener = function() {};
            function setTimeout() {}
            """
        )

        context.evaluateScript(WebLoginCompatibility.browserGatePolyfillJS)
        XCTAssertNil(context.exception)
        XCTAssertTrue(
            context.evaluateScript("CSS.supports('(grid-template-rows: subgrid)')").toBool()
        )

        context.evaluateScript("window.unsupportedBrowser = true")
        XCTAssertFalse(context.evaluateScript("window.unsupportedBrowser").toBool())

        context.evaluateScript("discourseInitCallback()")
        XCTAssertFalse(
            context.evaluateScript("CSS.supports('(grid-template-rows: subgrid)')").toBool()
        )
        context.evaluateScript("window.unsupportedBrowser = true")
        XCTAssertTrue(context.evaluateScript("window.unsupportedBrowser").toBool())
    }

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
