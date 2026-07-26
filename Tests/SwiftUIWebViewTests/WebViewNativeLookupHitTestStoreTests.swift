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

    func testTargetPublicationProbeDoesNotNotifyForRedundantEmptyClear() {
        let store = WebViewNativeLookupHitTestStore()
        var notificationCount = 0
        store.onTargetsChanged = {
            notificationCount += 1
        }

        store.removeAllTargets()
        XCTAssertEqual(notificationCount, 0)

        store.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "segment",
                rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                lookupPayload: ["surface": "猫"]
            )
        ])
        XCTAssertEqual(notificationCount, 1)
        XCTAssertTrue(store.uiTestTargetProbeText.contains("revision=1"))
        XCTAssertTrue(store.uiTestTargetProbeText.contains("targetCount=1"))
        XCTAssertTrue(store.uiTestTargetProbeText.contains("surfaces=猫"))

        store.removeAllTargets()
        store.removeAllTargets()
        XCTAssertEqual(notificationCount, 2)
        XCTAssertTrue(store.uiTestTargetProbeText.contains("revision=2"))
        XCTAssertTrue(store.uiTestTargetProbeText.contains("targetCount=0"))
    }

    func testUITestTapDispatchesFirstPayloadBackedTarget() {
        let store = WebViewNativeLookupHitTestStore()
        var dispatchedHit: WebViewNativeLookupHit?
        store.onHit = {
            dispatchedHit = $0
        }
        store.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "without-payload",
                rects: [CGRect(x: 0, y: 0, width: 10, height: 10)]
            ),
            WebViewNativeLookupHitTarget(
                elementID: "lookup-target",
                rects: [CGRect(x: 40, y: 60, width: 20, height: 30)],
                lookupPayload: ["surface": "読む"]
            )
        ])

        XCTAssertTrue(store.handleUITestTapOnFirstLookupTarget())
        XCTAssertEqual(dispatchedHit?.elementID, "lookup-target")
        XCTAssertEqual(dispatchedHit?.point, CGPoint(x: 50, y: 75))
        XCTAssertEqual(dispatchedHit?.lookupPayload?["surface"] as? String, "読む")
    }
}
