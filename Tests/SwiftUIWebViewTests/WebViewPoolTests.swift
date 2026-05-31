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
}
