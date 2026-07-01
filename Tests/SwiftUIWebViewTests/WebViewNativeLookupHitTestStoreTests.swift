import XCTest
@testable import SwiftUIWebView

final class WebViewNativeLookupHitTestStoreTests: XCTestCase {
    func testActiveTextSelectionAlwaysPassesNativeLookupTouchesThrough() {
        let store = WebViewNativeLookupHitTestStore()

        store.updateWebTextSelection(active: true, textLength: 2, source: "test")

        XCTAssertTrue(store.shouldPassThroughForWebTextSelection)
        XCTAssertTrue(store.shouldSuppressScrollForWebTextSelection)
    }

    func testCollapsedTextSelectionImmediatelyRestoresNativeLookupTouches() {
        let store = WebViewNativeLookupHitTestStore()

        store.updateWebTextSelection(active: true, textLength: 4, source: "test")
        XCTAssertTrue(store.shouldPassThroughForWebTextSelection)
        XCTAssertTrue(store.shouldSuppressScrollForWebTextSelection)

        store.updateWebTextSelection(active: false, textLength: 0, source: "test")
        XCTAssertFalse(store.shouldPassThroughForWebTextSelection)
        XCTAssertFalse(store.shouldSuppressScrollForWebTextSelection)
    }

    func testInactiveTextSelectionDoesNotPassNativeLookupTouchesThrough() {
        let store = WebViewNativeLookupHitTestStore()

        store.updateWebTextSelection(active: false, textLength: 0, source: "test")

        XCTAssertFalse(store.shouldPassThroughForWebTextSelection)
        XCTAssertFalse(store.shouldSuppressScrollForWebTextSelection)
    }
}
