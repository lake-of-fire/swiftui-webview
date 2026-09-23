#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import SwiftUIWebView

private final class InitialDocumentScriptHandler: NSObject, WKScriptMessageHandler {
    var onMessage: ((WKScriptMessage) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        onMessage?(message)
    }
}

@MainActor
final class WebViewMacColdUserScriptTests: XCTestCase {
    func testDocumentStartScriptRunsOnFirstNavigationBeforeSwiftUIUpdate() async throws {
        let script = WebViewUserScript(
            source: "window.webkit.messageHandlers.initialScriptProbe.postMessage(document.readyState)",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
        let view = WebView(
            config: WebViewConfig(userScripts: [script]),
            navigator: WebViewNavigator(),
            state: .constant(.empty)
        )
        let coordinator = view.makeCoordinatorForTesting()
        let configuration = WKWebViewConfiguration()
        let handler = InitialDocumentScriptHandler()
        configuration.userContentController.add(handler, name: "initialScriptProbe")
        let webView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: configuration
        )
        let scriptRan = expectation(description: "document-start script ran on first navigation")
        handler.onMessage = { message in
            XCTAssertTrue(message.frameInfo.isMainFrame)
            XCTAssertEqual(message.body as? String, "loading")
            scriptRan.fulfill()
        }

        view.installInitialMacUserScripts(on: webView, coordinator: coordinator)
        webView.loadHTMLString(
            "<html><body>First document</body></html>",
            baseURL: URL(string: "https://example.com/first")
        )

        await fulfillment(of: [scriptRan], timeout: 5)
    }
}
#endif
