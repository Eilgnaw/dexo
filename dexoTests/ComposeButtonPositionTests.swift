import XCTest

@testable import dexo

@MainActor
final class ComposeButtonPositionTests: XCTestCase {
    func testPositionPersistsPerForumAcrossSettingsInstances() throws {
        let suite = "dexo-compose-position-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(testingDefaults: defaults)
        let position = AppSettings.ComposeButtonPosition(
            edge: .left,
            verticalFraction: 0.37
        )

        settings.saveComposeButtonPosition(position, for: "https://one.example/forum/")

        let restored = AppSettings(testingDefaults: defaults)
        XCTAssertEqual(
            restored.composeButtonPosition(for: "https://one.example/forum"),
            position
        )
        XCTAssertNil(restored.composeButtonPosition(for: "https://two.example/forum"))
    }

    func testPositionClampsOutOfRangeHeight() throws {
        let suite = "dexo-compose-position-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(testingDefaults: defaults)

        settings.saveComposeButtonPosition(
            .init(edge: .right, verticalFraction: 2),
            for: "https://example.com"
        )

        XCTAssertEqual(
            settings.composeButtonPosition(for: "https://example.com")?.verticalFraction,
            1
        )
    }
}
