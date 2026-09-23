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
        withExtendedLifetime(webView) {}
    }

    func testQueuedHTMLReceivesDocumentStartScriptDuringInitialMount() async {
        let scriptRan = expectation(description: "queued first document received script")
        let handlers = WebViewMessageHandlers([("initialScriptProbe", { @MainActor message in
            XCTAssertTrue(message.isMainFrame)
            XCTAssertEqual(message.body as? String, "loading")
            scriptRan.fulfill()
        })])
        let script = WebViewUserScript(
            source: "window.webkit.messageHandlers.initialScriptProbe.postMessage(document.readyState)",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
        let navigator = WebViewNavigator()
        navigator.loadHTML(
            "<html><body>Queued first document</body></html>",
            baseURL: URL(string: "https://example.com/queued")
        )
        let view = WebView(
            config: WebViewConfig(userScripts: [script]),
            navigator: navigator,
            state: .constant(.empty)
        )
        .environment(\.webViewMessageHandlers, handlers)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.close()
            withExtendedLifetime(host) {}
        }

        await fulfillment(of: [scriptRan], timeout: 10)
    }

    func testMountingPooledWebViewKeepsMatchingInstalledScripts() {
        let script = WebViewUserScript(
            source: "window.initialScriptProbe = true",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
        let configuration = WebViewConfig(userScripts: [script])
        let firstView = WebView(
            config: configuration,
            navigator: WebViewNavigator(),
            state: .constant(.empty)
        )
        let webView = EnhancedWKWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        firstView.installInitialMacUserScripts(
            on: webView,
            coordinator: firstView.makeCoordinatorForTesting()
        )
        let installedScripts = webView.configuration.userContentController.userScripts
        XCTAssertFalse(installedScripts.isEmpty)

        let secondView = WebView(
            config: configuration,
            navigator: WebViewNavigator(),
            state: .constant(.empty)
        )
        secondView.installInitialMacUserScripts(
            on: webView,
            coordinator: secondView.makeCoordinatorForTesting()
        )
        let reusedScripts = webView.configuration.userContentController.userScripts
        XCTAssertEqual(installedScripts.count, reusedScripts.count)
        XCTAssertTrue(zip(installedScripts, reusedScripts).allSatisfy { pair in
            pair.0 === pair.1
        })
    }
}
#endif
