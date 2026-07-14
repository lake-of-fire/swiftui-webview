import XCTest
@testable import SwiftUIWebView

final class LoadingProgressPublicationStateTests: XCTestCase {
    func testRapidUpdatesInvalidateEarlierDeferredPublication() {
        var state = LoadingProgressPublicationState()
        let first = state.update(isLoading: true, estimatedProgress: 0.1)
        let second = state.update(isLoading: nil, estimatedProgress: 0.2)

        XCTAssertEqual(state.resolve(generation: first.generation), .stale)
        XCTAssertEqual(state.resolve(generation: second.generation), .publish(0.2))
    }

    func testCompletionAndClearInvalidatePendingProgress() {
        var state = LoadingProgressPublicationState()
        let pending = state.update(isLoading: true, estimatedProgress: 0.7)
        let completion = state.update(isLoading: false, estimatedProgress: 1)

        XCTAssertEqual(state.resolve(generation: pending.generation), .stale)
        XCTAssertEqual(state.resolve(generation: completion.generation), .publish(nil))

        let nextPending = state.update(isLoading: true, estimatedProgress: 0.4)
        state.clear()
        XCTAssertEqual(state.resolve(generation: nextPending.generation), .stale)
    }

    func testProgressIsClampedAndNonFiniteValuesAreNeutral() {
        var state = LoadingProgressPublicationState()

        XCTAssertEqual(state.update(isLoading: true, estimatedProgress: -1).progress, 0)
        XCTAssertEqual(state.update(isLoading: nil, estimatedProgress: 2).progress, 1)
        XCTAssertEqual(state.update(isLoading: nil, estimatedProgress: .nan).progress, 0)
    }
}
