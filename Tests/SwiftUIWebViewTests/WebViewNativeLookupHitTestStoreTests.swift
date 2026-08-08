import XCTest
#if os(iOS)
import WebKit
#endif
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

    func testActiveTargetMatcherCanRejectTheSameSectionLocalIDFromAnotherDocument() {
        let store = WebViewNativeLookupHitTestStore()
        let firstDocumentURL = URL(string: "ebook://book/chapter-1.xhtml")!
        let secondDocumentURL = URL(string: "ebook://book/chapter-2.xhtml")!
        let firstTarget = WebViewNativeLookupHitTarget(
            elementID: "shared-section-local-id",
            rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
            documentURL: firstDocumentURL
        )
        let secondTarget = WebViewNativeLookupHitTarget(
            elementID: "shared-section-local-id",
            rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
            documentURL: secondDocumentURL
        )
        store.activeLookupElementID = { "shared-section-local-id" }
        store.activeElementID = "shared-section-local-id"
        store.activeLookupTargetMatches = { target in
            target.documentURL == firstDocumentURL
        }

        XCTAssertTrue(store.matchesActiveLookupTarget(firstTarget))
        XCTAssertFalse(store.matchesActiveLookupTarget(secondTarget))
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

    func testLookupInteractionOwnershipRejectsAReplacedLookup() {
        let store = WebViewNativeLookupHitTestStore()
        let firstLookupID = UUID()
        let replacementLookupID = UUID()
        var activeLookupID: UUID? = firstLookupID
        store.activeLookupInteractionID = { activeLookupID }

        let capturedLookupID = store.captureActiveLookupInteractionID()
        XCTAssertTrue(store.isActiveLookupInteractionCurrent(capturedLookupID))

        activeLookupID = replacementLookupID

        XCTAssertFalse(store.isActiveLookupInteractionCurrent(capturedLookupID))
        XCTAssertTrue(store.isActiveLookupInteractionCurrent(replacementLookupID))
    }

    func testLookupInteractionOwnershipRejectsAnOpenAndCloseABASequence() {
        let store = WebViewNativeLookupHitTestStore()
        var interactionGenerationID: UUID? = UUID()
        store.activeLookupInteractionID = { interactionGenerationID }

        let capturedGenerationID = store.captureActiveLookupInteractionID()
        XCTAssertTrue(store.isActiveLookupInteractionCurrent(capturedGenerationID))

        interactionGenerationID = UUID() // A newer lookup opens.
        interactionGenerationID = UUID() // The newer lookup closes before this touch ends.

        XCTAssertFalse(store.isActiveLookupInteractionCurrent(capturedGenerationID))
    }

    func testLookupInteractionOwnershipAllowsUnchangedLookupAndLegacyClients() {
        let store = WebViewNativeLookupHitTestStore()
        let lookupID = UUID()
        store.activeLookupInteractionID = { lookupID }

        XCTAssertTrue(store.isActiveLookupInteractionCurrent(lookupID))
        XCTAssertFalse(store.isActiveLookupInteractionCurrent(nil))

        store.activeLookupInteractionID = nil

        XCTAssertTrue(store.isActiveLookupInteractionCurrent(nil))
    }

    func testHitCarriesExactPublicationIdentityAndReplacementInvalidatesIt() throws {
        let store = WebViewNativeLookupHitTestStore()
        var dispatchedHit: WebViewNativeLookupHit?
        store.onHit = { dispatchedHit = $0 }
        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "segment",
                    rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "frame"
                )
            ],
            replacingNativeLookupFrameKey: "frame",
            publicationSequence: 10
        )

        XCTAssertTrue(store.handleTap(at: CGPoint(x: 10, y: 10)))
        let publicationID = try XCTUnwrap(dispatchedHit?.nativeLookupPublicationID)
        XCTAssertTrue(store.isPublicationCurrent(publicationID))

        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "segment",
                    rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "frame"
                )
            ],
            replacingNativeLookupFrameKey: "frame",
            publicationSequence: 11
        )

        XCTAssertFalse(store.isPublicationCurrent(publicationID))
    }

    func testDirectTapHonorsDisabledNativeLookupHitTesting() {
        let store = WebViewNativeLookupHitTestStore()
        var dispatchedHit = false
        store.onHit = { _ in dispatchedHit = true }
        store.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "segment",
                rects: [CGRect(x: 0, y: 0, width: 20, height: 20)]
            )
        ])
        store.isEnabled = false

        XCTAssertFalse(store.handleTap(at: CGPoint(x: 10, y: 10)))
        XCTAssertFalse(dispatchedHit)
    }

    func testCapturedTapRejectsAReplacedPublicationAndDisabledLegacyTarget() throws {
        let store = WebViewNativeLookupHitTestStore()
        var dispatchedElementIDs = [String]()
        store.onHit = { dispatchedElementIDs.append($0.elementID) }
        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "segment",
                    rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "frame"
                )
            ],
            replacingNativeLookupFrameKey: "frame",
            publicationSequence: 10
        )
        let staleTarget = try XCTUnwrap(store.hitTarget(at: CGPoint(x: 10, y: 10)))

        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "segment",
                    rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "frame"
                )
            ],
            replacingNativeLookupFrameKey: "frame",
            publicationSequence: 11
        )

        XCTAssertFalse(store.handleTap(on: staleTarget, at: CGPoint(x: 10, y: 10)))
        XCTAssertTrue(dispatchedElementIDs.isEmpty)

        let legacyTarget = WebViewNativeLookupHitTarget(
            elementID: "legacy",
            rects: [CGRect(x: 0, y: 0, width: 20, height: 20)]
        )
        store.isEnabled = false

        XCTAssertFalse(store.handleTap(on: legacyTarget, at: CGPoint(x: 10, y: 10)))
        XCTAssertTrue(dispatchedElementIDs.isEmpty)
    }

    func testCapturedTapRebasesChildFrameCoordinatesFromTheOverlayWindowOrigin() throws {
        let store = WebViewNativeLookupHitTestStore()
        var dispatchedHit: WebViewNativeLookupHit?
        store.onHit = { dispatchedHit = $0 }
        store.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "child-segment",
                rects: [CGRect(x: 30, y: 40, width: 20, height: 20)],
                coordinateOriginInWindow: CGPoint(x: 100, y: 200),
                nativeLookupFrameKey: "child-frame"
            )
        ])
        let overlayWindowOrigin = CGPoint(x: 120, y: 230)
        let target = try XCTUnwrap(
            store.hitTarget(
                at: CGPoint(x: 10, y: 10),
                in: CGSize(width: 320, height: 480),
                coordinateViewWindowOrigin: overlayWindowOrigin
            )
        )

        XCTAssertTrue(
            store.handleTap(
                on: target,
                at: CGPoint(x: 12, y: 14),
                in: CGSize(width: 320, height: 480),
                coordinateViewWindowOrigin: overlayWindowOrigin
            )
        )
        XCTAssertEqual(dispatchedHit?.debugHitTestPoint, CGPoint(x: 32, y: 44))
        XCTAssertEqual(dispatchedHit?.debugHitTestRebaseX, 20)
        XCTAssertEqual(dispatchedHit?.debugHitTestRebaseY, 30)
    }

    func testCapturedNativeTouchRequiresTheExactPublicationAndLookupGeneration() throws {
        let store = WebViewNativeLookupHitTestStore()
        var lookupInteractionID: UUID? = UUID()
        store.activeLookupInteractionID = { lookupInteractionID }
        store.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "segment",
                rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                nativeLookupFrameKey: "frame"
            )
        ])
        let target = try XCTUnwrap(store.hitTarget(at: CGPoint(x: 10, y: 10)))
        let capturedLookupInteractionID = store.captureActiveLookupInteractionID()
        store.beginNativeTouchStream(on: target)

        XCTAssertTrue(
            store.isCapturedNativeTouchCurrent(
                target,
                lookupInteractionID: capturedLookupInteractionID
            )
        )

        store.isEnabled = false
        XCTAssertFalse(
            store.isCapturedNativeTouchCurrent(
                target,
                lookupInteractionID: capturedLookupInteractionID
            )
        )
        store.isEnabled = true

        lookupInteractionID = UUID()
        XCTAssertFalse(
            store.isCapturedNativeTouchCurrent(
                target,
                lookupInteractionID: capturedLookupInteractionID
            )
        )

        lookupInteractionID = capturedLookupInteractionID
        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "segment",
                    rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "frame"
                )
            ],
            replacingNativeLookupFrameKey: "frame"
        )
        XCTAssertFalse(
            store.isCapturedNativeTouchCurrent(
                target,
                lookupInteractionID: capturedLookupInteractionID
            )
        )
    }

    func testUnrelatedFrameReplacementPreservesHitPublicationIdentity() throws {
        let store = WebViewNativeLookupHitTestStore()
        var dispatchedHit: WebViewNativeLookupHit?
        store.onHit = { dispatchedHit = $0 }
        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "source",
                    rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "source-frame"
                )
            ],
            replacingNativeLookupFrameKey: "source-frame",
            publicationSequence: 10
        )
        XCTAssertTrue(store.handleTap(at: CGPoint(x: 10, y: 10)))
        let publicationID = try XCTUnwrap(dispatchedHit?.nativeLookupPublicationID)

        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "destination",
                    rects: [CGRect(x: 40, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "destination-frame"
                )
            ],
            replacingNativeLookupFrameKey: "destination-frame",
            publicationSequence: 11
        )

        XCTAssertTrue(store.isPublicationCurrent(publicationID))
    }

    func testStalePublishedTargetCannotRebindTouchToMatchingReplacement() throws {
        let store = WebViewNativeLookupHitTestStore()
        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "segment",
                    rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "frame"
                )
            ],
            replacingNativeLookupFrameKey: "frame",
            publicationSequence: 10
        )
        let staleTarget = try XCTUnwrap(store.hitTarget(at: CGPoint(x: 10, y: 10)))

        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "segment",
                    rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "frame"
                )
            ],
            replacingNativeLookupFrameKey: "frame",
            publicationSequence: 11
        )
        store.beginNativeTouchStream(on: staleTarget)

        XCTAssertFalse(store.isActiveNativeTouchPublicationCurrent)
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

    func testLateBarrierRemovesOnlyOlderFramePublications() {
        let store = WebViewNativeLookupHitTestStore()
        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "source-frame",
                    rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                    lookupPayload: ["surface": "source"],
                    nativeLookupFrameKey: "frame-source"
                )
            ],
            replacingNativeLookupFrameKey: "frame-source",
            publicationSequence: 10
        )
        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "legacy-frame",
                    rects: [CGRect(x: 20, y: 0, width: 20, height: 20)],
                    lookupPayload: ["surface": "legacy"],
                    nativeLookupFrameKey: "frame-legacy"
                )
            ],
            replacingNativeLookupFrameKey: "frame-legacy"
        )
        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "destination-frame",
                    rects: [CGRect(x: 40, y: 0, width: 20, height: 20)],
                    lookupPayload: ["surface": "destination"],
                    nativeLookupFrameKey: "frame-destination"
                )
            ],
            replacingNativeLookupFrameKey: "frame-destination",
            publicationSequence: 20
        )

        XCTAssertEqual(store.removeTargets(publishedAtOrBefore: 15), 2)
        XCTAssertEqual(store.targetCount, 1)
        XCTAssertTrue(store.uiTestTargetProbeText.contains("surfaces=destination"))
        XCTAssertFalse(store.uiTestTargetProbeText.contains("surfaces=source"))
        XCTAssertFalse(store.uiTestTargetProbeText.contains("surfaces=legacy"))
    }


    func testEmptyFramePublicationRemovesOnlyThatFramesTargets() {
        let store = WebViewNativeLookupHitTestStore()
        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "source",
                    rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "frame-source"
                )
            ],
            replacingNativeLookupFrameKey: "frame-source",
            publicationSequence: 10
        )
        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "destination",
                    rects: [CGRect(x: 40, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "frame-destination"
                )
            ],
            replacingNativeLookupFrameKey: "frame-destination",
            publicationSequence: 11
        )

        store.updateTargets(
            [],
            replacingNativeLookupFrameKey: "frame-source",
            publicationSequence: 12
        )

        XCTAssertFalse(store.handleTap(at: CGPoint(x: 10, y: 10)))
        XCTAssertTrue(store.handleTap(at: CGPoint(x: 50, y: 10)))
        XCTAssertEqual(store.targetCount, 1)
    }

    func testSelectivePruningInvalidatesOnlyTouchOwnedByRemovedPublication() throws {
        let store = WebViewNativeLookupHitTestStore()
        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "source",
                    rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "frame-source"
                )
            ],
            replacingNativeLookupFrameKey: "frame-source",
            publicationSequence: 10
        )
        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "destination",
                    rects: [CGRect(x: 40, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "frame-destination"
                )
            ],
            replacingNativeLookupFrameKey: "frame-destination",
            publicationSequence: 20
        )
        let sourceTarget = try XCTUnwrap(store.hitTarget(at: CGPoint(x: 10, y: 10)))
        store.beginNativeTouchStream(on: sourceTarget)
        XCTAssertTrue(store.isActiveNativeTouchPublicationCurrent)

        XCTAssertEqual(store.removeTargets(publishedAtOrBefore: 15), 1)

        XCTAssertFalse(store.isActiveNativeTouchPublicationCurrent)
        XCTAssertEqual(store.targetCount, 1)
        XCTAssertEqual(store.hitTarget(at: CGPoint(x: 50, y: 10))?.elementID, "destination")
    }

    func testSelectivePruningPreservesTouchOwnedByNewerPublication() throws {
        let store = WebViewNativeLookupHitTestStore()
        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "source",
                    rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "frame-source"
                )
            ],
            replacingNativeLookupFrameKey: "frame-source",
            publicationSequence: 10
        )
        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "destination",
                    rects: [CGRect(x: 40, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "frame-destination"
                )
            ],
            replacingNativeLookupFrameKey: "frame-destination",
            publicationSequence: 20
        )
        let destinationTarget = try XCTUnwrap(store.hitTarget(at: CGPoint(x: 50, y: 10)))
        store.beginNativeTouchStream(on: destinationTarget)

        XCTAssertEqual(store.removeTargets(publishedAtOrBefore: 15), 1)

        XCTAssertTrue(store.isActiveNativeTouchPublicationCurrent)
        store.finishNativeTouchStream(reason: "test")
        XCTAssertFalse(store.isActiveNativeTouchPublicationCurrent)
    }

    func testReplacingExactFrameInvalidatesItsActiveTouchPublication() throws {
        let store = WebViewNativeLookupHitTestStore()
        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "segment",
                    rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "frame"
                )
            ],
            replacingNativeLookupFrameKey: "frame",
            publicationSequence: 10
        )
        let originalTarget = try XCTUnwrap(store.hitTarget(at: CGPoint(x: 10, y: 10)))
        store.beginNativeTouchStream(on: originalTarget)

        store.updateTargets(
            [
                WebViewNativeLookupHitTarget(
                    elementID: "segment",
                    rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
                    nativeLookupFrameKey: "frame"
                )
            ],
            replacingNativeLookupFrameKey: "frame",
            publicationSequence: 11
        )

        XCTAssertFalse(store.isActiveNativeTouchPublicationCurrent)
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

    #if os(iOS)
    func testReplacingHostStoreFinishesThePreviousStoreTouch() throws {
        let webView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let host = WebViewController(webView: webView)
        host.loadViewIfNeeded()
        let replacedStore = WebViewNativeLookupHitTestStore()
        let currentStore = WebViewNativeLookupHitTestStore()

        host.setNativeLookupHitTestStore(replacedStore)
        replacedStore.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "replaced-segment",
                rects: [CGRect(x: 0, y: 0, width: 20, height: 20)]
            )
        ])
        let replacedTarget = try XCTUnwrap(
            replacedStore.hitTarget(at: CGPoint(x: 10, y: 10))
        )
        replacedStore.beginNativeTouchStream(on: replacedTarget)
        XCTAssertTrue(replacedStore.isActiveNativeTouchPublicationCurrent)

        host.setNativeLookupHitTestStore(currentStore)

        XCTAssertFalse(replacedStore.isActiveNativeTouchPublicationCurrent)
        XCTAssertNil(replacedStore.activeNativeTouchElementID)
    }

    func testReplacedHostStoreCannotCancelCurrentStoreTouch() throws {
        let webView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let host = WebViewController(webView: webView)
        host.loadViewIfNeeded()
        let replacedStore = WebViewNativeLookupHitTestStore()
        let currentStore = WebViewNativeLookupHitTestStore()

        host.setNativeLookupHitTestStore(replacedStore)
        replacedStore.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "replaced-segment",
                rects: [CGRect(x: 0, y: 0, width: 20, height: 20)]
            )
        ])
        let replacedTarget = try XCTUnwrap(
            replacedStore.hitTarget(at: CGPoint(x: 10, y: 10))
        )
        replacedStore.beginNativeTouchStream(on: replacedTarget)
        XCTAssertTrue(replacedStore.isActiveNativeTouchPublicationCurrent)

        host.setNativeLookupHitTestStore(currentStore)
        XCTAssertFalse(replacedStore.isActiveNativeTouchPublicationCurrent)
        currentStore.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "current-segment",
                rects: [CGRect(x: 0, y: 0, width: 20, height: 20)]
            )
        ])
        let currentTarget = try XCTUnwrap(
            currentStore.hitTarget(at: CGPoint(x: 10, y: 10))
        )
        currentStore.beginNativeTouchStream(on: currentTarget)
        XCTAssertTrue(currentStore.isActiveNativeTouchPublicationCurrent)

        replacedStore.cancelActiveTouchInteraction(reason: "stale-store")

        XCTAssertTrue(currentStore.isActiveNativeTouchPublicationCurrent)
        currentStore.cancelActiveTouchInteraction(reason: "current-store")
        XCTAssertFalse(currentStore.isActiveNativeTouchPublicationCurrent)
    }
    #endif
}
