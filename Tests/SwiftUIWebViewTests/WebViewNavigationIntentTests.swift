import Foundation
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
final class WebViewNavigationIntentTests: XCTestCase {
    private let url = URL(string: "https://example.com/saved")!

    func testSameURLRequestStillSupersedesEarlierIntentAndReceipt() {
        let navigator = WebViewNavigator()
        let reserved = navigator.beginNavigationIntent()
        guard case .issued(let receipt) = navigator.dispatch(URLRequest(url: url), for: reserved) else {
            return XCTFail("Current reservation must dispatch")
        }
        XCTAssertTrue(navigator.isCurrent(receipt))
        XCTAssertFalse(navigator.isCurrent(reserved))
        navigator.load(URLRequest(url: url))
        XCTAssertFalse(navigator.isCurrent(receipt))
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, url.absoluteString)
    }

    func testRefusedAndReplayedReservationsCannotChangeActualRequest() {
        let navigator = WebViewNavigator()
        let old = navigator.beginNavigationIntent()
        let current = navigator.beginNavigationIntent()
        XCTAssertEqual(navigator.dispatch(URLRequest(url: url), for: old), .refused)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
        guard case .issued(let receipt) = navigator.dispatch(URLRequest(url: url), for: current) else {
            return XCTFail("Latest reservation must dispatch")
        }
        XCTAssertEqual(navigator.dispatch(URLRequest(url: URL(string: "https://example.com/replay")!), for: current), .refused)
        XCTAssertTrue(navigator.isCurrent(receipt))
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, url.absoluteString)
    }

    func testIntentFromAnotherNavigatorCannotDispatch() {
        let source = WebViewNavigator(), other = WebViewNavigator()
        let intent = source.beginNavigationIntent()
        XCTAssertFalse(other.isCurrent(intent))
        XCTAssertEqual(other.dispatch(URLRequest(url: url), for: intent), .refused)
        XCTAssertEqual(other.debugLoadSnapshot.lastRequestURL, "nil")
        XCTAssertTrue(source.isCurrent(intent))
    }

    func testDataAndHTMLProducersInvalidateSameBaseURLReservations() {
        let navigator = WebViewNavigator()
        let beforeData = navigator.beginNavigationIntent()
        navigator.load(Data("body".utf8), mimeType: "text/plain", characterEncodingName: "utf-8", baseURL: url)
        XCTAssertFalse(navigator.isCurrent(beforeData))
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, url.absoluteString)
        let beforeHTML = navigator.navigationIntent
        navigator.loadHTML("<p>saved</p>", baseURL: url)
        XCTAssertFalse(navigator.isCurrent(beforeHTML))
        XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, url.absoluteString)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
    }

    func testExplicitReloadAndHistoryCommandsRetirePendingIntentEvenWithoutAttachment() {
        let navigator = WebViewNavigator()
        let commands: [() -> Void] = [
            { navigator.reload() }, { navigator.reloadLast() },
            { navigator.reloadWithoutContentRules() },
            { navigator.goBack() }, { navigator.goForward() }
        ]
        for command in commands {
            let before = navigator.beginNavigationIntent()
            command()
            XCTAssertFalse(navigator.isCurrent(before))
        }
    }

    func testInitialAttachmentPreservesQueuedRequestButDetachRetiresReceipt() {
        let navigator = WebViewNavigator()
        let intent = navigator.beginNavigationIntent()
        guard case .issued(let receipt) = navigator.dispatch(URLRequest(url: url), for: intent) else {
            return XCTFail("Pre-attachment request must queue")
        }
        let webView = WKWebView(frame: .zero)
        navigator.webView = webView
        XCTAssertTrue(navigator.isCurrent(receipt))
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, url.absoluteString)
        navigator.webView = nil
        XCTAssertFalse(navigator.isCurrent(receipt))
    }

    func testReplacingAttachedWebViewRetiresOriginalRequestAuthority() {
        let navigator = WebViewNavigator()
        let original = WKWebView(frame: .zero)
        navigator.webView = original
        let intent = navigator.beginNavigationIntent()
        let replacement = WKWebView(frame: .zero)
        navigator.webView = replacement
        XCTAssertFalse(navigator.isCurrent(intent))
        let nextIntent = navigator.beginNavigationIntent()
        navigator.webView = replacement
        XCTAssertTrue(navigator.isCurrent(nextIntent))
    }
}
