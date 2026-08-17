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

    func testRuntimeBundleLowersClassStaticBlocksWithoutTouchingText() async throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "web-login-polyfills", withExtension: "js")
        )
        let compatibilitySource = try String(contentsOf: url, encoding: .utf8)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: compatibilitySource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)

        var didInstallTransformer = false
        for _ in 0..<200 {
            if let transformerType = try? await webView.evaluateJavaScript(
                "typeof window.__dexoTransformModuleSource"
            ) as? String,
               transformerType == "function"
            {
                didInstallTransformer = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(didInstallTransformer)

        XCTAssertTrue(compatibilitySource.contains("__dexoTransformModuleSource"))
        let result = try await webView.evaluateJavaScript(
            #"""
            (function() {
                var input = "class Parent { static value() { return 8; } } " +
                    "class Example extends Parent { " +
                    "static /* keep */ { " +
                    "this.pattern = /[{}]static \\{/; " +
                    "this.text = 'static {'; " +
                    "this.answer = super.value(); " +
                    "this.Nested = class { static { this.ready = true; } }; " +
                    "} }";
                var output = window.__dexoTransformModuleSource(input);
                var value = Function(output +
                    "; return [Example.answer, Example.Nested.ready, Example.text];")();
                return JSON.stringify({ output: output, value: value });
            })()
            """#
        ) as? String
        let data = try XCTUnwrap(result?.data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let output = try XCTUnwrap(object["output"] as? String)
        let value = try XCTUnwrap(object["value"] as? [Any])

        XCTAssertFalse(output.contains("static /* keep */ {"))
        XCTAssertEqual(output.components(separatedBy: "#__dexo_static_block_").count - 1, 2)
        XCTAssertTrue(output.contains("this.text = 'static {'"))
        XCTAssertEqual(value[0] as? Int, 8)
        XCTAssertEqual(value[1] as? Bool, true)
        XCTAssertEqual(value[2] as? String, "static {")
    }

    func testModuleShimUsesSyntaxCompatibilitySourceHook() {
        let bootstrap = WebLoginViewController.moduleShimsBootstrap(source: "/* module shim */")

        XCTAssertTrue(bootstrap.contains("window.__dexoESModuleSourceHook"))
        XCTAssertTrue(bootstrap.contains("window.esmsInitOptions.source"))
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

    func testIOS167KeepsItsRealVersion() {
        let userAgent = WebLoginCompatibility.mobileSafariUserAgent(
            operatingSystemVersion: .init(
                majorVersion: 16,
                minorVersion: 7,
                patchVersion: 1
            ),
            idiom: .phone
        )

        XCTAssertTrue(userAgent.contains("iPhone OS 16_7 like Mac OS X"))
        XCTAssertTrue(userAgent.contains("Version/16.7"))
        XCTAssertFalse(userAgent.contains("iPhone OS 17_"))
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
