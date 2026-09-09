import Foundation
import WebKit
import XCTest
@testable import SwiftUIWebView

private final class IdentityFrameProbe: NSObject, WKScriptMessageHandler {
    var onMessage: ((WKScriptMessage) -> Void)?
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        onMessage?(message)
    }
}

@MainActor
final class WebViewFrameIdentityTests: XCTestCase {
    /// Real frame objects; only the canonical registration URL is supplied by
    /// the test, exactly as it is by the Reader's registration API.
    private func frames() async throws -> (WKWebView, WKFrameInfo, WKFrameInfo) {
        let ready = expectation(description: "main and child frames")
        ready.expectedFulfillmentCount = 2
        var main: WKFrameInfo?
        var child: WKFrameInfo?
        let probe = IdentityFrameProbe()
        probe.onMessage = { message in
            if message.frameInfo.isMainFrame {
                guard main == nil else { return }
                main = message.frameInfo
            } else {
                guard child == nil else { return }
                child = message.frameInfo
            }
            ready.fulfill()
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(probe, name: "identityProbe")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480),
                                configuration: configuration)
        webView.loadHTMLString("""
            <script>window.webkit.messageHandlers.identityProbe.postMessage('main')</script>
            <iframe srcdoc="<script>window.webkit.messageHandlers.identityProbe.postMessage('child')</script>"></iframe>
            """, baseURL: URL(string: "https://example.invalid/fixture"))
        await fulfillment(of: [ready], timeout: 10)
        configuration.userContentController.removeScriptMessageHandler(forName: "identityProbe")
        return (webView, try XCTUnwrap(main), try XCTUnwrap(child))
    }

    private func loader(_ value: String) throws -> URL {
        var components = try XCTUnwrap(URLComponents(string: "internal://local/load/reader"))
        components.queryItems = [URLQueryItem(name: "reader-url", value: value)]
        return try XCTUnwrap(components.url)
    }

    func testClearingRegistrationsAlsoClearsMainFrameFallback() async throws {
        let (webView, main, _) = try await frames()
        defer { withExtendedLifetime(webView) {} }
        let caller = WebViewScriptCaller()
        let url = try XCTUnwrap(URL(string: "ebook://book/chapter.xhtml"))
        caller.addTrackedWordTargetFrame(main, uuid: "old", canonicalURL: url)
        XCTAssertTrue(caller.mainFrameInfo === main)
        for _ in 0..<3 {
            caller.removeAllMultiTargetFrames()
            XCTAssertNil(caller.mainFrameInfo)
            XCTAssertNil(caller.frame(for: url))
            XCTAssertNil(caller.frame(for: nil))
            XCTAssertNil(caller.exactFrame(for: url))
            XCTAssertNil(caller.frame(forUUID: "old"))
            XCTAssertTrue(caller.registeredTrackedWordFrameIdentities().isEmpty)
        }
    }

    func testNewChildRegistrationCannotFallBackToClearedMainFrame() async throws {
        let (webView, main, child) = try await frames()
        defer { withExtendedLifetime(webView) {} }
        let caller = WebViewScriptCaller()
        caller.addMultiTargetFrame(main, uuid: "old")
        caller.removeAllMultiTargetFrames()
        caller.addMultiTargetFrame(child, uuid: "new",
            canonicalURL: URL(string: "ebook://book/new.xhtml"))
        XCTAssertNil(caller.mainFrameInfo)
        XCTAssertTrue(caller.frame(for: nil) === child)
        XCTAssertTrue(caller.frame(forUUID: "new") === child)
        caller.addMultiTargetFrame(main, uuid: "replacement")
        XCTAssertTrue(caller.mainFrameInfo === main)
    }

    func testLoaderRoutingPreservesEscapedDelimitersInBothDirections() async throws {
        let (webView, main, _) = try await frames()
        defer { withExtendedLifetime(webView) {} }
        for spelling in ["ebook://book/a%2Fb.xhtml", "ebook://book/a%23b.xhtml",
                         "ebook://book/a%3Fb.xhtml", "ebook://book/a%252Fb.xhtml",
                         "https://example.invalid/a?q=%23x&path=%2F&literal=%2523",
                         "ebook://book/%E6%97%A5%E6%9C%AC.xhtml#selection"] {
            let url = try XCTUnwrap(URL(string: spelling))
            let wrapped = try loader(spelling)
            for (registered, queried) in [(url, wrapped), (wrapped, url)] {
                let caller = WebViewScriptCaller()
                caller.addTrackedWordTargetFrame(main, uuid: "document", canonicalURL: registered)
                XCTAssertTrue(caller.exactFrame(for: queried) === main, spelling)
                XCTAssertTrue(caller.exactFrame(forUUID: "document", documentURL: queried) === main, spelling)
                XCTAssertTrue(caller.frameForRegisteredIdentity(uuid: "document", documentURL: queried) === main, spelling)
            }
        }
    }

    func testEscapedSlashDoesNotAliasAnotherDocument() async throws {
        let (webView, main, child) = try await frames()
        defer { withExtendedLifetime(webView) {} }
        let encoded = try XCTUnwrap(URL(string: "ebook://book/a%2Fb.xhtml"))
        let ordinary = try XCTUnwrap(URL(string: "ebook://book/a/b.xhtml"))
        let caller = WebViewScriptCaller()
        caller.addTrackedWordTargetFrame(main, uuid: "encoded", canonicalURL: try loader(encoded.absoluteString))
        caller.addTrackedWordTargetFrame(child, uuid: "ordinary", canonicalURL: ordinary)
        XCTAssertTrue(caller.exactFrame(for: encoded) === main)
        XCTAssertTrue(caller.exactFrame(for: try loader(encoded.absoluteString)) === main)
        XCTAssertTrue(caller.exactFrame(for: ordinary) === child)
        XCTAssertNil(caller.exactFrame(forUUID: "encoded", documentURL: ordinary))
        XCTAssertNil(caller.exactFrame(forUUID: "ordinary", documentURL: encoded))
    }

    func testEscapedFragmentDelimiterDoesNotBecomeDiscardedFragment() async throws {
        let (webView, main, child) = try await frames()
        defer { withExtendedLifetime(webView) {} }
        let literal = try XCTUnwrap(URL(string: "ebook://book/a%23b.xhtml"))
        let fragment = try XCTUnwrap(URL(string: "ebook://book/a#b.xhtml"))
        let caller = WebViewScriptCaller()
        caller.addMultiTargetFrame(main, uuid: "literal", canonicalURL: try loader(literal.absoluteString))
        caller.addMultiTargetFrame(child, uuid: "fragment", canonicalURL: fragment)
        XCTAssertTrue(caller.exactFrame(for: literal) === main)
        XCTAssertTrue(caller.exactFrame(for: fragment) === child)
        XCTAssertNil(caller.frameForRegisteredIdentity(uuid: "literal", documentURL: fragment))
    }

    func testLegacyExtraTransportEncodingStillResolvesOnce() async throws {
        let (webView, main, _) = try await frames()
        defer { withExtendedLifetime(webView) {} }
        let spelling = "ebook://book/a%2Fb.xhtml?q=%2523"
        let url = try XCTUnwrap(URL(string: spelling))
        let extraEncoded = try XCTUnwrap(spelling.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let caller = WebViewScriptCaller()
        caller.addMultiTargetFrame(main, uuid: "legacy", canonicalURL: url)
        XCTAssertTrue(caller.exactFrame(for: try loader(extraEncoded)) === main)
    }

    func testOrdinaryURLFragmentsKeepExistingIdentityPolicy() async throws {
        let (webView, main, _) = try await frames()
        defer { withExtendedLifetime(webView) {} }
        let caller = WebViewScriptCaller()
        let url = try XCTUnwrap(URL(string: "ebook://book/chapter.xhtml#one"))
        caller.addMultiTargetFrame(main, uuid: "doc", canonicalURL: url)
        XCTAssertTrue(caller.exactFrame(for: URL(string: "ebook://book/chapter.xhtml#two")) === main)
        XCTAssertTrue(caller.exactFrame(for: try loader("ebook://book/chapter.xhtml#three")) === main)
        XCTAssertNil(caller.exactFrame(for: URL(string: "ebook://book/other.xhtml")))
    }

    func testRelativeLoaderPayloadCannotInventAnAbsoluteDocument() async throws {
        let (webView, main, _) = try await frames()
        defer { withExtendedLifetime(webView) {} }
        let wrapped = try loader("relative/chapter.xhtml")
        let caller = WebViewScriptCaller()
        caller.addMultiTargetFrame(main, uuid: "malformed", canonicalURL: wrapped)
        XCTAssertTrue(caller.exactFrame(for: wrapped) === main)
        XCTAssertNil(caller.exactFrame(for: URL(string: "relative/chapter.xhtml")))
        XCTAssertNil(caller.exactFrame(for: URL(string: "https://example.invalid/relative/chapter.xhtml")))
    }
}
