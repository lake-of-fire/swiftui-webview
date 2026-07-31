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

    func testBlankTapDismissesOnlyAnActiveLookupWithoutTextSelection() {
        let store = WebViewNativeLookupHitTestStore()
        var closeCount = 0
        store.activeLookupElementID = { nil }
        store.onActiveLookupBlankTap = { closeCount += 1 }

        XCTAssertFalse(store.closeActiveLookupFromBlankTapIfNeeded())

        store.activeLookupElementID = { "segment" }
        XCTAssertTrue(store.closeActiveLookupFromBlankTapIfNeeded())
        XCTAssertEqual(closeCount, 1)

        store.updateWebTextSelection(active: true)
        XCTAssertFalse(store.closeActiveLookupFromBlankTapIfNeeded())
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

    func testTargetPublicationProbeSupportsIndependentObservers() {
        let store = WebViewNativeLookupHitTestStore()
        var firstCount = 0
        var secondCount = 0
        let firstID = store.addTargetsChangedObserver {
            firstCount += 1
        }
        _ = store.addTargetsChangedObserver {
            secondCount += 1
        }

        store.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "segment",
                rects: [CGRect(x: 0, y: 0, width: 20, height: 20)]
            )
        ])
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 1)

        store.removeTargetsChangedObserver(firstID)
        store.removeAllTargets()
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 2)
    }

    func testUITestTapDispatchesFirstGeometryTargetWithoutRequiringEagerPayload() {
        let store = WebViewNativeLookupHitTestStore()
        var dispatchedHit: WebViewNativeLookupHit?
        store.onHit = {
            dispatchedHit = $0
        }
        store.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "without-payload",
                rects: [CGRect(x: 0, y: 0, width: 10, height: 10)],
                documentURL: URL(string: "ebook://book/chapter.xhtml")
            ),
            WebViewNativeLookupHitTarget(
                elementID: "lookup-target",
                rects: [CGRect(x: 40, y: 60, width: 20, height: 30)],
                lookupPayload: ["surface": "読む"]
            )
        ])

        XCTAssertTrue(store.handleUITestTapOnFirstLookupTarget())
        XCTAssertEqual(dispatchedHit?.elementID, "without-payload")
        XCTAssertEqual(dispatchedHit?.point, CGPoint(x: 5, y: 5))
        XCTAssertNil(dispatchedHit?.lookupPayload)
        XCTAssertEqual(dispatchedHit?.documentURL, URL(string: "ebook://book/chapter.xhtml"))
    }

    func testUITestTapCanRetargetToDifferentElementWhileLookupIsActive() {
        let store = WebViewNativeLookupHitTestStore()
        var dispatchedElementIDs = [String]()
        store.onHit = {
            dispatchedElementIDs.append($0.elementID)
        }
        store.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "first",
                rects: [CGRect(x: 0, y: 0, width: 10, height: 10)]
            ),
            WebViewNativeLookupHitTarget(
                elementID: "second",
                rects: [CGRect(x: 20, y: 0, width: 10, height: 10)]
            ),
        ])

        XCTAssertTrue(store.handleUITestTapOnFirstLookupTarget())
        XCTAssertTrue(store.handleUITestTapOnLookupTarget(differentFrom: "first"))
        XCTAssertEqual(dispatchedElementIDs, ["first", "second"])
    }

    func testUITestTapCanSelectLastVisibleTargetForBoundaryNavigation() {
        let store = WebViewNativeLookupHitTestStore()
        var dispatchedHit: WebViewNativeLookupHit?
        store.onHit = { dispatchedHit = $0 }
        store.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "first",
                rects: [CGRect(x: 0, y: 0, width: 10, height: 10)]
            ),
            WebViewNativeLookupHitTarget(
                elementID: "last",
                rects: [CGRect(x: 40, y: 60, width: 20, height: 30)]
            ),
        ])

        XCTAssertTrue(store.handleUITestTapOnLastLookupTarget())
        XCTAssertEqual(dispatchedHit?.elementID, "last")
        XCTAssertEqual(dispatchedHit?.point, CGPoint(x: 50, y: 75))
    }

    func testWrappedSegmentDoesNotClaimBlankSpaceBetweenComponentRects() {
        let store = WebViewNativeLookupHitTestStore()
        var dispatchedHit = false
        store.onHit = { _ in dispatchedHit = true }
        store.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "wrapped-segment",
                rects: [
                    CGRect(x: 0, y: 0, width: 20, height: 10),
                    CGRect(x: 40, y: 20, width: 20, height: 10),
                ]
            )
        ])
        let blankPointWithinHitSlop = CGPoint(x: 25, y: 5)

        XCTAssertNil(store.hitTarget(at: blankPointWithinHitSlop))
        XCTAssertFalse(store.containsClaimableTarget(at: blankPointWithinHitSlop))
        XCTAssertFalse(store.handleTap(at: blankPointWithinHitSlop))
        XCTAssertFalse(dispatchedHit)
    }

    func testExpandedHitTargetIsExplicitAndDoesNotChangeClaimableArea() {
        let store = WebViewNativeLookupHitTestStore()
        store.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "segment",
                rects: [CGRect(x: 0, y: 0, width: 20, height: 10)]
            )
        ])
        let nearbyPoint = CGPoint(x: 25, y: 5)

        XCTAssertNil(store.hitTarget(at: nearbyPoint))
        XCTAssertFalse(store.containsClaimableTarget(at: nearbyPoint))
        XCTAssertEqual(store.expandedHitTarget(at: nearbyPoint)?.elementID, "segment")
        XCTAssertTrue(store.containsExpandedTarget(at: nearbyPoint))
    }

    func testExactComponentRectStillDispatchesWrappedSegment() {
        let store = WebViewNativeLookupHitTestStore()
        var dispatchedElementID: String?
        store.onHit = { dispatchedElementID = $0.elementID }
        store.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "wrapped-segment",
                rects: [
                    CGRect(x: 0, y: 0, width: 20, height: 10),
                    CGRect(x: 40, y: 20, width: 20, height: 10),
                ]
            )
        ])
        let secondLinePoint = CGPoint(x: 50, y: 25)

        XCTAssertEqual(store.hitTarget(at: secondLinePoint)?.elementID, "wrapped-segment")
        XCTAssertTrue(store.containsClaimableTarget(at: secondLinePoint))
        XCTAssertTrue(store.handleTap(at: secondLinePoint))
        XCTAssertEqual(dispatchedElementID, "wrapped-segment")
    }

    func testReaderInteractionCallbacksRemainAvailableAcrossTargetReset() {
        let store = WebViewNativeLookupHitTestStore()
        var cancellationReason: String?
        var swipe: CGPoint?
        var completedHandoffElementID: String?
        store.onExternalTouchInteractionCancelled = {
            cancellationReason = $0
        }
        store.onSegmentSwipe = { dx, dy in
            swipe = CGPoint(x: dx, y: dy)
        }
        store.onPressedTargetHandoffCompleted = {
            completedHandoffElementID = $0
        }

        store.updateWebTextSelection(
            active: true,
            textLength: 2,
            source: "test"
        )
        store.cancelActiveTouchInteraction(reason: "page-turn")
        store.dispatchSegmentSwipe(dx: -30, dy: 4)
        store.completePressedTargetHandoff(elementID: "segment")
        XCTAssertTrue(store.shouldPassThroughForWebTextSelection)
        store.removeAllTargets()

        XCTAssertEqual(cancellationReason, "page-turn")
        XCTAssertEqual(swipe, CGPoint(x: -30, y: 4))
        XCTAssertEqual(completedHandoffElementID, "segment")
        XCTAssertFalse(store.shouldPassThroughForWebTextSelection)
    }
}
