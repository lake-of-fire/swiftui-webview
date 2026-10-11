import SwiftUI
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
final class WebViewPoolTests: XCTestCase {
    func testWarmsReusesCapsAndRemovesWebViews() {
        let pool = WebViewPool(warmUpCount: 1, keepAliveCount: 0)
        var createdCount = 0
        var enqueuedCount = 0
        var dequeuedCount = 0
        pool.onEnqueue = { _ in enqueuedCount += 1 }
        pool.onDequeue = { _ in dequeuedCount += 1 }

        pool.setCreationClosureIfNeeded {
            createdCount += 1
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        XCTAssertEqual(createdCount, 1)
        XCTAssertEqual(pool.retainedCount, 1)
        XCTAssertEqual(enqueuedCount, 1)

        let first = pool.dequeue {
            XCTFail("Expected a warmed web view")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        XCTAssertEqual(pool.retainedCount, 0)
        XCTAssertEqual(dequeuedCount, 1)

        pool.enqueue(first)
        XCTAssertEqual(pool.retainedCount, 1)
        XCTAssertEqual(enqueuedCount, 2)

        let second = pool.dequeue {
            XCTFail("Expected the original web view to be reused")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        XCTAssertTrue(first === second)

        pool.enqueue(second)
        let overflow = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        pool.enqueue(overflow)
        XCTAssertEqual(pool.retainedCount, 1)

        pool.removeAll()
        XCTAssertEqual(pool.retainedCount, 0)
        XCTAssertGreaterThanOrEqual(dequeuedCount, 3)
    }

    func testLegacyRetainedTargetRebalancesWhenCountsDecrease() {
        let pool = WebViewPool(warmUpCount: 2, keepAliveCount: 1)
        var createdCount = 0
        var releasedCount = 0
        pool.onEnqueue = { _ in }
        pool.onDequeue = { _ in releasedCount += 1 }
        pool.setCreationClosureIfNeeded {
            createdCount += 1
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        XCTAssertEqual(pool.retainedCount, 3)
        XCTAssertEqual(createdCount, 3)

        pool.warmUpCount = 1
        XCTAssertEqual(pool.retainedCount, 2)
        XCTAssertEqual(releasedCount, 1)

        pool.keepAliveCount = 0
        XCTAssertEqual(pool.retainedCount, 1)
        XCTAssertEqual(releasedCount, 2)

        pool.warmUpCount = 2
        XCTAssertEqual(pool.retainedCount, 2)
        XCTAssertEqual(createdCount, 4)

        pool.warmUpCount = -1
        XCTAssertEqual(pool.retainedCount, 0)
        XCTAssertEqual(releasedCount, 4)
    }

    func testTotalCountTargetIncludesCheckedOutAndRetainedWebViews() {
        let pool = WebViewPool()
        var createdCount = 0
        pool.setCreationClosureIfNeeded {
            createdCount += 1
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        pool.totalCountTarget = 4
        XCTAssertEqual(createdCount, 4)
        XCTAssertEqual(pool.totalCount, 4)
        XCTAssertEqual(pool.retainedCount, 4)

        let first = pool.dequeue {
            XCTFail("Expected a retained web view")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        let second = pool.dequeue {
            XCTFail("Expected a retained web view")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        XCTAssertEqual(pool.totalCount, 4)
        XCTAssertEqual(pool.retainedCount, 2)

        pool.totalCountTarget = 2
        XCTAssertEqual(pool.totalCount, 2)
        XCTAssertEqual(pool.retainedCount, 0)

        pool.enqueue(first)
        XCTAssertEqual(pool.totalCount, 2)
        XCTAssertEqual(pool.retainedCount, 1)

        pool.totalCountTarget = 0
        XCTAssertEqual(pool.totalCount, 1)
        XCTAssertEqual(pool.retainedCount, 0)

        pool.enqueue(second)
        XCTAssertEqual(pool.totalCount, 0)
        XCTAssertEqual(pool.retainedCount, 0)
    }

    func testTotalCountTargetClampsNegativeValues() {
        let pool = WebViewPool()
        pool.totalCountTarget = -4
        XCTAssertEqual(pool.totalCountTarget, 0)
    }

    func testDequeueFallbackFactoryIsNotRetainedByPool() {
        final class Owner {}

        let pool = WebViewPool()
        weak var weakOwner: Owner?

        autoreleasepool {
            var owner: Owner? = Owner()
            weakOwner = owner
            let webView = pool.dequeue { [owner] in
                _ = owner
                return EnhancedWKWebView(
                    frame: .zero,
                    configuration: WKWebViewConfiguration()
                )
            }
            pool.enqueue(webView)
            owner = nil
        }

        XCTAssertNil(weakOwner)

        // A checkout fallback is not silently promoted into the pool's long-lived
        // warming factory. Explicit factory registration remains the only way to
        // create retained views without another checkout.
        pool.totalCountTarget = 1
        XCTAssertEqual(pool.retainedCount, 0)
    }

    func testDequeueUsesCurrentCheckoutFactoryWhenNoRetainedViewExists() {
        let pool = WebViewPool()
        var warmingFactoryCalls = 0
        var checkoutFactoryCalls = 0

        pool.setCreationClosureIfNeeded {
            warmingFactoryCalls += 1
            return EnhancedWKWebView(
                frame: .zero,
                configuration: WKWebViewConfiguration()
            )
        }

        let webView = pool.dequeue {
            checkoutFactoryCalls += 1
            return EnhancedWKWebView(
                frame: .zero,
                configuration: WKWebViewConfiguration()
            )
        }

        XCTAssertEqual(warmingFactoryCalls, 0)
        XCTAssertEqual(checkoutFactoryCalls, 1)
        pool.enqueue(webView)
    }

    func testDequeueUsesCurrentCheckoutFactoryWhenProactiveTopUpIsNeeded() {
        let pool = WebViewPool(warmUpCount: 1)
        var warmingFactoryCalls = 0
        var checkoutFactoryCalls = 0

        pool.setCreationClosureIfNeeded {
            warmingFactoryCalls += 1
            return EnhancedWKWebView(
                frame: .zero,
                configuration: WKWebViewConfiguration()
            )
        }

        let first = pool.dequeue {
            XCTFail("Expected the initially warmed WebView")
            return EnhancedWKWebView(
                frame: .zero,
                configuration: WKWebViewConfiguration()
            )
        }
        XCTAssertEqual(warmingFactoryCalls, 1)
        XCTAssertEqual(pool.retainedCount, 0)

        let second = pool.dequeue {
            checkoutFactoryCalls += 1
            return EnhancedWKWebView(
                frame: .zero,
                configuration: WKWebViewConfiguration()
            )
        }

        XCTAssertEqual(warmingFactoryCalls, 1)
        XCTAssertEqual(checkoutFactoryCalls, 1)
        XCTAssertFalse(first === second)
        pool.enqueue(first)
        pool.enqueue(second)
    }

    func testDetachedFactoryAppliesMediaPlaybackUserActionPolicy() {
        let config = WebViewConfig(
            mediaTypesRequiringUserActionForPlayback: [.audio]
        )
        let sourceView = WebView(
            config: config,
            navigator: WebViewNavigator(),
            state: .constant(.empty)
        )

        let webView = sourceView.makeDetachedWebViewFactory(config: config)()

        XCTAssertEqual(
            webView.configuration.mediaTypesRequiringUserActionForPlayback.rawValue,
            WKAudiovisualMediaTypes.audio.rawValue
        )
    }

    func testDetachedProductionFactoryDoesNotRetainSourceNavigatorOrPrewarmer() {
        weak var weakNavigator: WebViewNavigator?
        weak var weakPrewarmer: WebViewPrewarmer?
        var retainedPool: WebViewPool?

        autoreleasepool {
            var navigator: WebViewNavigator? = WebViewNavigator()
            var prewarmer: WebViewPrewarmer? = WebViewPrewarmer()
            weakNavigator = navigator
            weakPrewarmer = prewarmer
            retainedPool = prewarmer?.pool

            var sourceView: SwiftUIWebView.WebView? = SwiftUIWebView.WebView(
                navigator: navigator!,
                state: .constant(.empty),
                webViewPrewarmer: prewarmer
            )
            let factory = sourceView!.makeDetachedWebViewFactory(config: .default)
            retainedPool?.setCreationClosureIfNeeded(factory)

            sourceView = nil
            navigator = nil
            prewarmer = nil
        }

        XCTAssertNil(weakNavigator)
        XCTAssertNil(weakPrewarmer)

        // The detached factory remains usable after the source SwiftUI value and
        // its owners are gone.
        retainedPool?.totalCountTarget = 1
        XCTAssertEqual(retainedPool?.retainedCount, 1)
        retainedPool?.invalidate()
    }

    func testInvalidateBreaksCreationClosureRetainCycle() {
        weak var weakPool: WebViewPool?

        autoreleasepool {
            var pool: WebViewPool? = WebViewPool()
            weakPool = pool
            pool?.totalCountTarget = 1
            pool?.setCreationClosureIfNeeded { [pool] in
                _ = pool
                return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            }
            XCTAssertEqual(pool?.totalCount, 1)

            pool?.invalidate()
            XCTAssertEqual(pool?.totalCount, 0)
            let lateView = pool?.dequeue {
                EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            }
            XCTAssertEqual(pool?.totalCount, 0)
            if let lateView {
                pool?.enqueue(lateView)
            }
            XCTAssertEqual(pool?.totalCount, 0)
            pool = nil
        }

        XCTAssertNil(weakPool)
    }

    func testInvalidatedPoolCannotBeReactivatedByLaterTargetUpdates() {
        let pool = WebViewPool(warmUpCount: 1, keepAliveCount: 0)
        pool.setCreationClosureIfNeeded {
            EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        let leased = pool.dequeue {
            XCTFail("Expected the warmed web view")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        pool.invalidate()

        // Permanent invalidation must outrank late configuration updates and
        // the later return of a WebView that was leased before teardown.
        pool.totalCountTarget = nil
        pool.warmUpCount = 2
        pool.keepAliveCount = 2
        XCTAssertEqual(pool.totalCountTarget, 0)

        pool.enqueue(leased)

        XCTAssertEqual(pool.retainedCount, 0)
        XCTAssertEqual(pool.leasedCount, 0)
        XCTAssertEqual(pool.totalCount, 0)
    }

    func testDequeuePrefersRetainedViewWithMatchingContentID() {
        let pool = WebViewPool()
        pool.totalCountTarget = 2
        pool.setCreationClosureIfNeeded {
            EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        let first = pool.dequeue { fatalError("Expected retained view") }
        let second = pool.dequeue { fatalError("Expected retained view") }
        first.poolReadyContentID = WebViewPoolContentID("page-1")
        second.poolReadyContentID = WebViewPoolContentID("page-2")
        pool.enqueue(first)
        pool.enqueue(second)

        let reused = pool.dequeue(preferredContentID: WebViewPoolContentID("page-2")) {
            fatalError("Expected matching retained view")
        }

        XCTAssertTrue(reused === second)
        XCTAssertEqual(reused.poolReadyContentID, WebViewPoolContentID("page-2"))
    }

    func testDequeueUsesCurrentWebViewContentIdentityInsteadOfEnqueueSnapshot() {
        let pool = WebViewPool()
        pool.totalCountTarget = 2
        pool.setCreationClosureIfNeeded {
            EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        let first = pool.dequeue { fatalError("Expected retained view") }
        let second = pool.dequeue { fatalError("Expected retained view") }
        let preferredContentID = WebViewPoolContentID("preferred")
        first.poolReadyContentID = preferredContentID
        second.poolReadyContentID = WebViewPoolContentID("other")
        pool.enqueue(first)
        pool.enqueue(second)

        // Retained WebViews own their exact navigation/content state. If that
        // state changes while pooled, selection must not use an enqueue-time copy.
        first.poolReadyContentID = nil
        second.poolReadyContentID = preferredContentID

        let reused = pool.dequeue(preferredContentID: preferredContentID) {
            fatalError("Expected matching retained view")
        }

        XCTAssertTrue(reused === second)
        XCTAssertEqual(reused.poolReadyContentID, preferredContentID)
    }

    func testDequeueFallsBackToFIFOWhenNoContentMatches() {
        let pool = WebViewPool()
        pool.totalCountTarget = 2
        pool.setCreationClosureIfNeeded {
            EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        let first = pool.dequeue { fatalError("Expected retained view") }
        let second = pool.dequeue { fatalError("Expected retained view") }
        first.poolReadyContentID = WebViewPoolContentID("page-1")
        second.poolReadyContentID = WebViewPoolContentID("page-2")
        pool.enqueue(first)
        pool.enqueue(second)

        let reused = pool.dequeue(preferredContentID: WebViewPoolContentID("page-3")) {
            fatalError("Expected FIFO retained view")
        }

        XCTAssertTrue(reused === first)
    }

    func testMatchingHTMLContentIDDoesNotReloadAttachedWebView() {
        let contentID = WebViewPoolContentID("page-1")
        let webView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.poolReadyContentID = contentID
        let navigator = WebViewNavigator()
        navigator.webView = webView

        navigator.loadHTML("<html>different bytes</html>", contentID: contentID)

        XCTAssertEqual(webView.poolReadyContentID, contentID)
        XCTAssertNil(webView.poolPendingContentID)
    }

    func testNewHTMLContentIDReplacesReadyIdentityUntilNavigationFinishes() {
        let oldID = WebViewPoolContentID("page-1")
        let newID = WebViewPoolContentID("page-2")
        let webView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.poolReadyContentID = oldID
        let navigator = WebViewNavigator()
        navigator.webView = webView

        navigator.loadHTML("<html>new page</html>", contentID: newID)

        XCTAssertNil(webView.poolReadyContentID)
        XCTAssertEqual(webView.poolPendingContentID, newID)
    }

    func testBeginningUnkeyedNavigationInvalidatesPendingAndReadyContentIdentity() {
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.setReadyContentID(WebViewPoolContentID("page-1"))
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-2"),
            navigation: NSObject()
        )

        gate.beginUnkeyedNavigation()

        XCTAssertNil(gate.pendingContentID)
        XCTAssertNil(gate.readyContentID)
    }

    func testKeyedProvisionalNavigationKeepsItsPendingIdentity() {
        let contentID = WebViewPoolContentID("page-2")
        let navigation = NSObject()
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: contentID,
            navigation: navigation
        )

        gate.handleProvisionalNavigationStarted(navigation)

        XCTAssertEqual(gate.pendingContentID, contentID)
    }

    func testSupersededKeyedProvisionalStartCannotClearNewerPooledContentIdentity() {
        let firstNavigation = NSObject()
        let secondNavigation = NSObject()
        let secondContentID = WebViewPoolContentID("page-2")
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-1"),
            navigation: firstNavigation
        )
        gate.beginKeyedNavigation(
            contentID: secondContentID,
            navigation: secondNavigation
        )

        gate.handleProvisionalNavigationStarted(firstNavigation)

        XCTAssertEqual(gate.pendingContentID, secondContentID)
        XCTAssertNil(gate.readyContentID)
    }

    func testSupersededUnkeyedProvisionalStartCannotClearNewerPooledContentIdentity() {
        let firstNavigation = NSObject()
        let secondNavigation = NSObject()
        let secondContentID = WebViewPoolContentID("page-2")
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginUnkeyedNavigation(navigation: firstNavigation)
        gate.beginKeyedNavigation(
            contentID: secondContentID,
            navigation: secondNavigation
        )

        gate.handleProvisionalNavigationStarted(firstNavigation)

        XCTAssertEqual(gate.pendingContentID, secondContentID)
        XCTAssertNil(gate.readyContentID)
        XCTAssertFalse(gate.handleNavigationFinished(firstNavigation))
        XCTAssertTrue(gate.handleNavigationFinished(secondNavigation))
        XCTAssertEqual(gate.readyContentID, secondContentID)
    }

    func testNavigationCallbackDispositionDistinguishesCurrentStaleAndUnknownReceipts() {
        let firstNavigation = NSObject()
        let secondNavigation = NSObject()
        let unrelatedNavigation = NSObject()
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginUnkeyedNavigation(navigation: firstNavigation)
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-2"),
            navigation: secondNavigation
        )

        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: firstNavigation),
            .stale
        )
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: secondNavigation),
            .current
        )
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: unrelatedNavigation),
            .unknown
        )
    }

    func testUnknownProvisionalNavigationBecomesCurrentAndInvalidatesKeyedIdentity() {
        let keyedNavigation = NSObject()
        let externalNavigation = NSObject()
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-2"),
            navigation: keyedNavigation
        )

        XCTAssertEqual(
            gate.handleProvisionalNavigationStarted(externalNavigation),
            .current
        )
        XCTAssertNil(gate.pendingContentID)
        XCTAssertNil(gate.readyContentID)
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: keyedNavigation),
            .stale
        )
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: externalNavigation),
            .current
        )
    }

    func testUnknownCommitBecomesCurrentAndSupersedesPreviouslyAdmittedReceipt() {
        let admittedNavigation = NSObject()
        let externalNavigation = NSObject()
        let contentID = WebViewPoolContentID("page-2")
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: contentID,
            navigation: admittedNavigation
        )

        XCTAssertEqual(
            gate.admitNavigationCallback(externalNavigation),
            .current
        )
        XCTAssertNil(gate.pendingContentID)
        XCTAssertNil(gate.readyContentID)
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: admittedNavigation),
            .stale
        )
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: externalNavigation),
            .current
        )
    }

    func testUnknownTerminalCallbackSupersedesPriorReceiptBeforeItResumes() {
        let admittedNavigation = NSObject()
        let externalNavigation = NSObject()
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginUnkeyedNavigation(navigation: admittedNavigation)

        XCTAssertEqual(
            gate.admitNavigationCallback(externalNavigation),
            .current
        )
        XCTAssertFalse(gate.handleNavigationFinished(externalNavigation))
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: admittedNavigation),
            .stale
        )
    }

    func testUnknownProvisionalNavigationPreservesOlderReceiptAsStaleForLaterOwners() {
        let firstNavigation = NSObject()
        let externalNavigation = NSObject()
        let latestNavigation = NSObject()
        let latestContentID = WebViewPoolContentID("page-3")
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-1"),
            navigation: firstNavigation
        )
        gate.handleProvisionalNavigationStarted(externalNavigation)
        gate.beginKeyedNavigation(
            contentID: latestContentID,
            navigation: latestNavigation
        )

        XCTAssertEqual(
            gate.handleProvisionalNavigationStarted(firstNavigation),
            .stale
        )
        XCTAssertEqual(gate.pendingContentID, latestContentID)
        XCTAssertFalse(gate.handleNavigationFinished(firstNavigation))
        XCTAssertTrue(gate.handleNavigationFinished(latestNavigation))
        XCTAssertEqual(gate.readyContentID, latestContentID)
    }

    func testReceiptlessCallbackSupersedesPreviouslyAdmittedNavigation() {
        let admittedNavigation = NSObject()
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-2"),
            navigation: admittedNavigation
        )

        XCTAssertEqual(
            gate.admitNavigationCallback(nil),
            .unknown
        )
        XCTAssertNil(gate.pendingContentID)
        XCTAssertNil(gate.readyContentID)
        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: admittedNavigation),
            .stale
        )
    }

    func testReceiptlessSupersessionMarksPreviouslyAdmittedNavigationStale() {
        let navigation = NSObject()
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-2"),
            navigation: navigation
        )

        gate.beginUnkeyedNavigation()

        XCTAssertEqual(
            gate.navigationCallbackDisposition(for: navigation),
            .stale
        )
    }

    func testPoolResetMakesCancelledNavigationReceiptStaleBeforeReuse() throws {
        let pool = WebViewPool(warmUpCount: 0, keepAliveCount: 1)
        pool.setCreationClosureIfNeeded {
            EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        let webView = pool.dequeue {
            XCTFail("Expected retained WebView")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        let navigation = try XCTUnwrap(webView.loadHTMLString(
            "<html><body>cancelled</body></html>",
            baseURL: URL(string: "https://example.com/cancelled")
        ))
        webView.beginUnkeyedNavigation(navigation: navigation)

        pool.enqueue(webView)

        XCTAssertEqual(
            webView.navigationCallbackDisposition(navigation),
            .stale
        )
    }

    func testStaleFinishCannotPromoteNewerPooledContentIdentity() {
        let firstNavigation = NSObject()
        let secondNavigation = NSObject()
        let secondContentID = WebViewPoolContentID("page-2")
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-1"),
            navigation: firstNavigation
        )
        gate.beginKeyedNavigation(
            contentID: secondContentID,
            navigation: secondNavigation
        )

        XCTAssertFalse(gate.handleNavigationFinished(firstNavigation))
        XCTAssertNil(gate.readyContentID)
        XCTAssertEqual(gate.pendingContentID, secondContentID)

        XCTAssertTrue(gate.handleNavigationFinished(secondNavigation))
        XCTAssertEqual(gate.readyContentID, secondContentID)
        XCTAssertNil(gate.pendingContentID)
    }

    func testStaleFailureCannotClearNewerPooledContentIdentity() {
        let firstNavigation = NSObject()
        let secondNavigation = NSObject()
        let secondContentID = WebViewPoolContentID("page-2")
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-1"),
            navigation: firstNavigation
        )
        gate.beginKeyedNavigation(
            contentID: secondContentID,
            navigation: secondNavigation
        )

        XCTAssertFalse(gate.handleNavigationFailed(firstNavigation))
        XCTAssertEqual(gate.pendingContentID, secondContentID)

        XCTAssertTrue(gate.handleNavigationFailed(secondNavigation))
        XCTAssertNil(gate.pendingContentID)
        XCTAssertNil(gate.readyContentID)
    }

    func testNonOwningProvisionalNavigationSupersedesPendingPooledContentIdentity() {
        let pendingNavigation = NSObject()
        let unrelatedNavigation = NSObject()
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: WebViewPoolContentID("page-2"),
            navigation: pendingNavigation
        )

        gate.handleProvisionalNavigationStarted(unrelatedNavigation)

        XCTAssertNil(gate.pendingContentID)
        XCTAssertNil(gate.readyContentID)
        XCTAssertFalse(gate.handleNavigationFinished(pendingNavigation))
    }

    func testUnknownFailureCannotClearExactPendingPooledContentIdentity() {
        let contentID = WebViewPoolContentID("page-2")
        var gate = WebViewPoolContentNavigationGate<NSObject>()
        gate.beginKeyedNavigation(
            contentID: contentID,
            navigation: NSObject()
        )

        XCTAssertFalse(gate.handleNavigationFailed(nil))
        XCTAssertEqual(gate.pendingContentID, contentID)
    }

    func testTransparentNonScrollingOverlayConfigIsGestureNeutralByDefault() {
        let config = WebViewConfig.transparentNonScrollingOverlay

        XCTAssertTrue(config.javaScriptEnabled)
        XCTAssertFalse(config.allowsBackForwardNavigationGestures)
        XCTAssertFalse(config.dataDetectorsEnabled)
        XCTAssertFalse(config.isScrollEnabled)
        XCTAssertFalse(config.isOpaque)
        XCTAssertFalse(config.adjustsScrollViewContentInsetsForSafeArea)
        XCTAssertFalse(config.nativeLookupHitTestingEnabled)
        XCTAssertEqual(config.paginationConfiguration.mode, .unpaginated)
    }

    func testReplacingUserScriptsPreservesUnrelatedConfiguration() {
        let originalScript = WebViewUserScript(
            source: "window.original = true",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        let replacementScript = WebViewUserScript(
            source: "window.replacement = true",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        let config = WebViewConfig(
            javaScriptEnabled: false,
            contentRules: "[]",
            allowsBackForwardNavigationGestures: false,
            allowsInlineMediaPlayback: false,
            mediaTypesRequiringUserActionForPlayback: [.audio],
            dataDetectorsEnabled: true,
            isScrollEnabled: false,
            pageZoom: 1.5,
            isOpaque: false,
            usesSampledPageTopColorForUnderPageBackground: true,
            usesConfiguredBackgroundForReaderDocuments: true,
            adjustsScrollViewContentInsetsForSafeArea: false,
            hidesTopScrollEdgeEffect: true,
            nativeLookupHitTestingEnabled: false,
            userScripts: [originalScript],
            darkModeSetting: .darkModeOverride
        )

        let replaced = config.withUserScripts([replacementScript], dataDetectorsEnabled: false)

        XCTAssertFalse(replaced.javaScriptEnabled)
        XCTAssertEqual(replaced.contentRules, "[]")
        XCTAssertFalse(replaced.allowsBackForwardNavigationGestures)
        XCTAssertFalse(replaced.allowsInlineMediaPlayback)
        XCTAssertEqual(replaced.mediaTypesRequiringUserActionForPlayback.rawValue, WKAudiovisualMediaTypes.audio.rawValue)
        XCTAssertFalse(replaced.dataDetectorsEnabled)
        XCTAssertFalse(replaced.isScrollEnabled)
        XCTAssertEqual(replaced.pageZoom, 1.5)
        XCTAssertFalse(replaced.isOpaque)
        XCTAssertTrue(replaced.usesSampledPageTopColorForUnderPageBackground)
        XCTAssertTrue(replaced.usesConfiguredBackgroundForReaderDocuments)
        XCTAssertFalse(replaced.adjustsScrollViewContentInsetsForSafeArea)
        XCTAssertTrue(replaced.hidesTopScrollEdgeEffect)
        XCTAssertFalse(replaced.nativeLookupHitTestingEnabled)
        XCTAssertEqual(replaced.userScripts, [replacementScript])
        XCTAssertEqual(replaced.darkModeSetting.rawValue, DarkModeSetting.darkModeOverride.rawValue)
    }

    func testTotalCountTargetIncludesLeasedViewsAndTrimsIdleViews() {
        let pool = WebViewPool()
        pool.totalCountTarget = 3
        var createdCount = 0
        pool.setCreationClosureIfNeeded {
            createdCount += 1
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        XCTAssertEqual(pool.retainedCount, 3)
        XCTAssertEqual(pool.leasedCount, 0)
        XCTAssertEqual(pool.totalCount, 3)

        let first = pool.dequeue {
            XCTFail("Expected a warmed web view")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        let second = pool.dequeue {
            XCTFail("Expected a warmed web view")
            return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }
        XCTAssertEqual(pool.retainedCount, 1)
        XCTAssertEqual(pool.leasedCount, 2)
        XCTAssertEqual(pool.totalCount, 3)

        pool.totalCountTarget = 2
        XCTAssertEqual(pool.retainedCount, 0)
        XCTAssertEqual(pool.leasedCount, 2)
        XCTAssertEqual(pool.totalCount, 2)

        pool.enqueue(first)
        XCTAssertEqual(pool.retainedCount, 1)
        XCTAssertEqual(pool.leasedCount, 1)
        XCTAssertEqual(pool.totalCount, 2)

        pool.totalCountTarget = 1
        XCTAssertEqual(pool.retainedCount, 0)
        XCTAssertEqual(pool.leasedCount, 1)
        XCTAssertEqual(pool.totalCount, 1)

        pool.enqueue(second)
        XCTAssertEqual(pool.retainedCount, 1)
        XCTAssertEqual(pool.leasedCount, 0)
        XCTAssertEqual(pool.totalCount, 1)
        XCTAssertEqual(createdCount, 3)
    }
}
