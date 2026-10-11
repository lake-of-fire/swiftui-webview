import XCTest
@testable import SwiftUIWebView

final class LoadingProgressPublicationStateTests: XCTestCase {
    func test_rapidUpdatesInvalidateEarlierDeferredPublication() {
        var state = LoadingProgressPublicationState()
        let first = state.update(isLoading: true, estimatedProgress: 0.1)
        let second = state.update(isLoading: nil, estimatedProgress: 0.2)

        XCTAssertEqual(state.resolve(generation: first.generation), .stale)
        XCTAssertEqual(state.resolve(generation: second.generation), .publish(0.2))
    }

    func test_completionInvalidatesPendingProgressAndPublishesNil() {
        var state = LoadingProgressPublicationState()
        let pending = state.update(isLoading: true, estimatedProgress: 0.7)
        let completion = state.update(isLoading: false, estimatedProgress: 1)

        XCTAssertEqual(state.resolve(generation: pending.generation), .stale)
        XCTAssertEqual(state.resolve(generation: completion.generation), .publish(nil))
    }

    func test_newNavigationCanResetProgressWithoutOldNavigationReappearing() {
        var state = LoadingProgressPublicationState()
        let oldNavigation = state.update(isLoading: true, estimatedProgress: 0.9)
        _ = state.update(isLoading: false, estimatedProgress: nil)
        let newNavigation = state.update(isLoading: true, estimatedProgress: 0.05)

        XCTAssertEqual(state.resolve(generation: oldNavigation.generation), .stale)
        XCTAssertEqual(state.resolve(generation: newNavigation.generation), .publish(0.05))
    }

    func test_progressIsClampedAndNonFiniteValuesAreNeutral() {
        var state = LoadingProgressPublicationState()

        XCTAssertEqual(state.update(isLoading: true, estimatedProgress: -1).progress, 0)
        XCTAssertEqual(state.update(isLoading: nil, estimatedProgress: 2).progress, 1)
        XCTAssertEqual(state.update(isLoading: nil, estimatedProgress: .nan).progress, 0)
    }

    func test_clearInvalidatesPendingGeneration() {
        var state = LoadingProgressPublicationState()
        let pending = state.update(isLoading: true, estimatedProgress: 0.4)

        state.clear()

        XCTAssertEqual(state.resolve(generation: pending.generation), .stale)
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.estimatedProgress, 0)
    }
}
