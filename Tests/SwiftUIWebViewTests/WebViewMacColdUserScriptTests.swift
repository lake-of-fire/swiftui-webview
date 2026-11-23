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
    func testDetachedFactoryUsesPublicBackgroundColorForOpaqueAndTransparentHosts() throws {
        let view = WebView(navigator: WebViewNavigator(), state: .constant(.empty))
        let opaque = view.makeDetachedWebViewFactory(
            config: WebViewConfig(isOpaque: true, backgroundColor: .red), drawsBackground: true
        )()
        // WebKit resolves the dynamic SwiftUI color when setting the native property.
        let actual = try XCTUnwrap(opaque.underPageBackgroundColor?.usingColorSpace(.sRGB))
        let expected = try XCTUnwrap(NSColor(Color.red).usingColorSpace(.sRGB))
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.000_001)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.000_001)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.000_001)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.000_001)
        let transparent = view.makeDetachedWebViewFactory(
            config: WebViewConfig(isOpaque: false, backgroundColor: .red), drawsBackground: true
        )()
        let clear = try XCTUnwrap(transparent.underPageBackgroundColor?.usingColorSpace(.sRGB))
        XCTAssertEqual(clear.redComponent, 0, accuracy: 0.000_001)
        XCTAssertEqual(clear.greenComponent, 0, accuracy: 0.000_001)
        XCTAssertEqual(clear.blueComponent, 0, accuracy: 0.000_001)
        XCTAssertEqual(clear.alphaComponent, 0, accuracy: 0.000_001)
    }

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

    func testQueuedHTMLReceivesDocumentStartScriptDuringInitialBinding() async {
        let scriptRan = expectation(description: "queued first document received script")
        let handler = InitialDocumentScriptHandler()
        handler.onMessage = { message in
            XCTAssertTrue(message.frameInfo.isMainFrame)
            XCTAssertEqual(message.body as? String, "loading")
            scriptRan.fulfill()
        }
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
        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.userContentController.add(handler, name: "initialScriptProbe")
        let webView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: webViewConfiguration
        )
        let coordinator = view.makeCoordinatorForTesting()
        view.installInitialMacUserScriptsAndBind(
            on: webView,
            coordinator: coordinator
        )

        await fulfillment(of: [scriptRan], timeout: 10)
        withExtendedLifetime(webView) {}
        withExtendedLifetime(coordinator) {}
    }

    func testInstalledScriptsMatchExactHostsAndKeepExistingAliases() throws {
        let unrestricted = domainScript(source: "window.unrestrictedProbe = true", allowedDomains: [])
        let www = domainScript(source: "window.wwwProbe = true", allowedDomains: ["www.example.com"])
        let mobile = domainScript(source: "window.mobileProbe = true", allowedDomains: ["mobile.example.com"])
        let shortMobile = domainScript(source: "window.shortMobileProbe = true", allowedDomains: ["m.example.com"])
        let apex = domainScript(source: "window.apexProbe = true", allowedDomains: ["example.com"])
        let config = WebViewConfig(userScripts: [unrestricted, www, mobile, shortMobile, apex])
        let view = WebView(config: config, navigator: WebViewNavigator(), state: .constant(.empty))
        let coordinator = view.makeCoordinatorForTesting()
        let webView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        view.updateUserScripts(webView: webView, coordinator: coordinator, forDomain: nil, config: .default)
        let systemSources = webView.configuration.userContentController.userScripts.map(\.source)
        let cases: [(String?, [WebViewUserScript])] = [
            ("https://www.example.com/article", [unrestricted, www, apex]),
            ("https://mobile.example.com/article", [unrestricted, mobile, apex]),
            ("https://m.example.com/article", [unrestricted, shortMobile, apex]),
            ("https://example.com/article", [unrestricted, apex]),
            ("https://reader.example.com/article", [unrestricted]),
            ("https://www.example.com.other.test/article", [unrestricted]),
            ("about:blank", [unrestricted]),
            (nil, [unrestricted]),
        ]
        for (urlString, expected) in cases {
            let url = try urlString.map { try XCTUnwrap(URL(string: $0)) }
            view.updateUserScripts(webView: webView, coordinator: coordinator, forDomain: url, config: config)
            XCTAssertEqual(
                webView.configuration.userContentController.userScripts.map(\.source),
                systemSources + expected.map(\.source),
                urlString ?? "No destination URL"
            )
        }
    }

    func testChangingOnlyTheAllowedHostReplacesTheInstalledScript() throws {
        let source = "window.restrictedProbe = true"
        let apex = WebViewConfig(userScripts: [
            domainScript(source: source, allowedDomains: ["example.com"]),
        ])
        let exactWWW = WebViewConfig(userScripts: [
            domainScript(source: source, allowedDomains: ["www.example.com"]),
        ])
        let view = WebView(config: apex, navigator: WebViewNavigator(), state: .constant(.empty))
        let coordinator = view.makeCoordinatorForTesting()
        let webView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let controller = webView.configuration.userContentController
        let www = try XCTUnwrap(URL(string: "https://www.example.com/article"))
        let bare = try XCTUnwrap(URL(string: "https://example.com/article"))

        view.updateUserScripts(webView: webView, coordinator: coordinator, forDomain: www, config: apex)
        let first = try XCTUnwrap(controller.userScripts.first { $0.source == source })
        view.updateUserScripts(webView: webView, coordinator: coordinator, forDomain: www, config: exactWWW)
        let replacement = try XCTUnwrap(controller.userScripts.first { $0.source == source })
        XCTAssertFalse(first === replacement)

        view.updateUserScripts(webView: webView, coordinator: coordinator, forDomain: www, config: exactWWW)
        XCTAssertTrue(controller.userScripts.first { $0.source == source } === replacement)

        view.updateUserScripts(webView: webView, coordinator: coordinator, forDomain: bare, config: exactWWW)
        XCTAssertFalse(controller.userScripts.contains { $0.source == source })
    }

    func testColdMountUsesFullHostOfQueuedHTMLOrReaderLoaderSource() throws {
        let source = "window.coldScopedProbe = true"
        let scoped = domainScript(source: source, allowedDomains: ["www.example.com"])
        let config = WebViewConfig(userScripts: [scoped])
        let destination = try XCTUnwrap(URL(string: "https://www.example.com/article"))
        var loader = URLComponents()
        loader.scheme = "internal"
        loader.host = "local"
        loader.path = "/load/reader"
        loader.queryItems = [URLQueryItem(name: "reader-url", value: destination.absoluteString)]
        let loaderURL = try XCTUnwrap(loader.url)

        for baseURL in [destination, loaderURL] {
            let navigator = WebViewNavigator()
            navigator.loadHTML("<html><body>Queued first document</body></html>", baseURL: baseURL)
            let view = WebView(config: config, navigator: navigator, state: .constant(.empty))
            let webView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())

            view.installInitialMacUserScripts(on: webView, coordinator: view.makeCoordinatorForTesting())

            XCTAssertTrue(
                webView.configuration.userContentController.userScripts.contains { $0.source == source },
                baseURL.absoluteString
            )
        }
    }

    private func domainScript(source: String, allowedDomains: Set<String>) -> WebViewUserScript {
        WebViewUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page,
            allowedDomains: allowedDomains
        )
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
