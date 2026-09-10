import Foundation
import WebKit
import XCTest
@testable import SwiftUIWebView

private final class MainAliasProbe: NSObject, WKScriptMessageHandler {
    var onMessage: ((WKScriptMessage) -> Void)?
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) { onMessage?(message) }
}

@MainActor
final class WebViewMainFrameAliasRetentionTests: XCTestCase {
    private func frames() async throws -> (WKWebView, WKFrameInfo, WKFrameInfo) {
        let ready = expectation(description: "main and child frames")
        ready.expectedFulfillmentCount = 2
        var main: WKFrameInfo?
        var child: WKFrameInfo?
        let probe = MainAliasProbe()
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
        configuration.userContentController.add(probe, name: "mainAliasProbe")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        view.loadHTMLString("""
            <script>window.webkit.messageHandlers.mainAliasProbe.postMessage('main')</script>
            <iframe srcdoc="<script>window.webkit.messageHandlers.mainAliasProbe.postMessage('child')</script>"></iframe>
            """, baseURL: URL(string: "https://example.invalid/main-alias"))
        await fulfillment(of: [ready], timeout: 10)
        configuration.userContentController.removeScriptMessageHandler(forName: "mainAliasProbe")
        return (view, try XCTUnwrap(main), try XCTUnwrap(child))
    }

    func testReplacingOneOfTwoMainAliasesPreservesMainFallback() async throws {
        let (view, main, child) = try await frames()
        defer { withExtendedLifetime(view) {} }
        let caller = WebViewScriptCaller()
        caller.addMultiTargetFrame(main, uuid: "main-a", canonicalURL: URL(string: "ebook://book/a"))
        caller.addMultiTargetFrame(main, uuid: "main-b", canonicalURL: URL(string: "ebook://book/b"))
        XCTAssertTrue(caller.mainFrameInfo === main)
        caller.addMultiTargetFrame(child, uuid: "main-a", canonicalURL: URL(string: "ebook://book/child"))
        XCTAssertTrue(caller.mainFrameInfo === main)
        XCTAssertTrue(caller.frame(for: nil) === main)
        XCTAssertTrue(caller.frame(forUUID: "main-b") === main)
    }

    func testReplacingFinalMainAliasClearsFallback() async throws {
        let (view, main, child) = try await frames()
        defer { withExtendedLifetime(view) {} }
        let caller = WebViewScriptCaller()
        caller.addMultiTargetFrame(main, uuid: "main-a")
        caller.addMultiTargetFrame(main, uuid: "main-b")
        caller.addMultiTargetFrame(child, uuid: "main-a")
        XCTAssertTrue(caller.mainFrameInfo === main)
        caller.addMultiTargetFrame(child, uuid: "main-b")
        XCTAssertNil(caller.mainFrameInfo)
    }

    func testRemoveAllStillClearsAliasedMainFallback() async throws {
        let (view, main, _) = try await frames()
        defer { withExtendedLifetime(view) {} }
        let caller = WebViewScriptCaller()
        caller.addMultiTargetFrame(main, uuid: "main-a")
        caller.addMultiTargetFrame(main, uuid: "main-b")
        caller.removeAllMultiTargetFrames()
        XCTAssertNil(caller.mainFrameInfo)
        XCTAssertNil(caller.frame(forUUID: "main-a"))
        XCTAssertNil(caller.frame(forUUID: "main-b"))
    }
}
