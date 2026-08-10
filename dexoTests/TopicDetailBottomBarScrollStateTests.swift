import XCTest
@testable import dexo

final class TopicDetailBottomBarScrollStateTests: XCTestCase {
    func testDownwardMovementCollapsesOnlyAfterThresholdAndAwayFromTop() {
        var state = TopicDetailBottomBarScrollState()

        XCTAssertEqual(update(&state, delta: 12, distanceFromTop: 30), .expanded)
        XCTAssertEqual(update(&state, delta: 12, distanceFromTop: 42), .expanded)
        XCTAssertEqual(update(&state, delta: 1, distanceFromTop: 45), .scrollToTop)
    }

    func testUpwardMovementExpandsAfterShorterThreshold() {
        var state = collapsedState()

        XCTAssertEqual(update(&state, delta: -6, distanceFromTop: 100), .scrollToTop)
        XCTAssertEqual(update(&state, delta: -6, distanceFromTop: 94), .expanded)
    }

    func testDirectionChangeResetsOpposingAccumulator() {
        var state = TopicDetailBottomBarScrollState()

        XCTAssertEqual(update(&state, delta: 20, distanceFromTop: 100), .expanded)
        XCTAssertEqual(update(&state, delta: -6, distanceFromTop: 94), .expanded)
        XCTAssertEqual(update(&state, delta: 5, distanceFromTop: 99), .expanded)
        XCTAssertEqual(update(&state, delta: 19, distanceFromTop: 118), .scrollToTop)
    }

    func testJitterProgrammaticMovementAndRubberBandingAreIgnored() {
        var state = TopicDetailBottomBarScrollState()

        for _ in 0..<100 {
            XCTAssertEqual(update(&state, delta: 0.2, distanceFromTop: 100), .expanded)
        }
        XCTAssertEqual(
            update(&state, delta: 100, distanceFromTop: 200, isUserDriven: false),
            .expanded
        )
        XCTAssertEqual(
            update(&state, delta: 100, distanceFromTop: 200, isWithinScrollBounds: false),
            .expanded
        )
    }

    func testTopAndShortContentForceExpandedEvenForNonUserMovement() {
        var state = collapsedState()

        XCTAssertEqual(
            update(&state, delta: -100, distanceFromTop: 8, isUserDriven: false),
            .expanded
        )

        state = collapsedState()
        XCTAssertEqual(
            update(&state, delta: 0, distanceFromTop: 100, isUserDriven: false, isContentScrollable: false),
            .expanded
        )
    }

    func testBeginningNewGestureClearsPartialMovementWithoutChangingMode() {
        var state = TopicDetailBottomBarScrollState()
        XCTAssertEqual(update(&state, delta: 20, distanceFromTop: 100), .expanded)

        state.beginGesture()

        XCTAssertEqual(update(&state, delta: 4, distanceFromTop: 104), .expanded)
        XCTAssertEqual(update(&state, delta: 20, distanceFromTop: 124), .scrollToTop)
    }

    private func collapsedState() -> TopicDetailBottomBarScrollState {
        var state = TopicDetailBottomBarScrollState()
        XCTAssertEqual(update(&state, delta: 24, distanceFromTop: 100), .scrollToTop)
        return state
    }

    private func update(
        _ state: inout TopicDetailBottomBarScrollState,
        delta: CGFloat,
        distanceFromTop: CGFloat,
        isUserDriven: Bool = true,
        isWithinScrollBounds: Bool = true,
        isContentScrollable: Bool = true
    ) -> TopicDetailBottomBarDisplayMode {
        state.update(
            delta: delta,
            distanceFromTop: distanceFromTop,
            isUserDriven: isUserDriven,
            isWithinScrollBounds: isWithinScrollBounds,
            isContentScrollable: isContentScrollable
        )
    }
}
