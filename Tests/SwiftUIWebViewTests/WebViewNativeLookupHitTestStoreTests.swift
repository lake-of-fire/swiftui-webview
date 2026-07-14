import XCTest
@testable import SwiftUIWebView

@MainActor
final class WebViewNativeLookupHitTestStoreTests: XCTestCase {
    func testActiveTextSelectionPassesNativeLookupTouchesThrough() {
        let store = WebViewNativeLookupHitTestStore()
        var dispatchedHit = false
        store.onHit = { _ in dispatchedHit = true }
        store.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "segment",
                rects: [CGRect(x: 0, y: 0, width: 20, height: 20)]
            )
        ])

        store.updateWebTextSelection(active: true)

        XCTAssertTrue(store.hasActiveWebTextSelection)
        XCTAssertFalse(store.handleTap(at: CGPoint(x: 10, y: 10)))
        XCTAssertFalse(dispatchedHit)
    }

    func testCollapsedTextSelectionImmediatelyRestoresNativeLookupTouches() {
        let store = WebViewNativeLookupHitTestStore()
        store.updateWebTextSelection(active: true)

        store.updateWebTextSelection(active: false)

        XCTAssertFalse(store.hasActiveWebTextSelection)
    }

    func testNavigationResetClearsTextSelection() {
        let store = WebViewNativeLookupHitTestStore()
        store.updateWebTextSelection(active: true)

        store.removeAllTargets()

        XCTAssertFalse(store.hasActiveWebTextSelection)
    }

    func testActiveTextSelectionProtectsLookupFromBlankTap() {
        let store = WebViewNativeLookupHitTestStore()
        var closeCount = 0
        store.onActiveLookupBlankTap = { closeCount += 1 }
        store.updateWebTextSelection(active: true)

        store.closeActiveLookupFromBlankTap()
        XCTAssertEqual(closeCount, 0)

        store.updateWebTextSelection(active: false)
        store.closeActiveLookupFromBlankTap()
        XCTAssertEqual(closeCount, 1)
    }
}
