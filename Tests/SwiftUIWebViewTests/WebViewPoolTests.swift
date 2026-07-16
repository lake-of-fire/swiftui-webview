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

    func testUnkeyedNavigationInvalidatesPreviouslyReadyContentIdentity() {
        let webView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.poolReadyContentID = WebViewPoolContentID("page-1")

        webView.invalidatePoolContentForUnkeyedNavigation()

        XCTAssertNil(webView.poolReadyContentID)
    }

    func testKeyedNavigationKeepsItsPendingIdentity() {
        let contentID = WebViewPoolContentID("page-2")
        let webView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.poolPendingContentID = contentID

        webView.invalidatePoolContentForUnkeyedNavigation()

        XCTAssertEqual(webView.poolPendingContentID, contentID)
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
