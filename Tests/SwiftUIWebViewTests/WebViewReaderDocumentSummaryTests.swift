import XCTest
import SwiftUI
import WebKit
@testable import SwiftUIWebView

@MainActor
final class WebViewReaderDocumentSummaryTests: XCTestCase {
    private final class HeldSummaryWebView: EnhancedWKWebView {
        var evaluationsToHold = 0
        var evaluationFinished: XCTestExpectation?
        var heldDeliveries: [() -> Void] = []
        var heldErrors: [Error] = []

        override func evaluateJavaScript(
            _ javaScriptString: String,
            completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)? = nil
        ) {
            guard evaluationsToHold > 0 else {
                super.evaluateJavaScript(javaScriptString, completionHandler: completionHandler)
                return
            }
            evaluationsToHold -= 1
            super.evaluateJavaScript(javaScriptString) { [weak self] value, error in
                guard let self else { return }
                if let error { self.heldErrors.append(error) }
                self.heldDeliveries.append { completionHandler?(value, error) }
                self.evaluationFinished?.fulfill()
            }
        }

        func deliver() {
            let deliveries = heldDeliveries
            heldDeliveries.removeAll()
            for delivery in deliveries { delivery() }
        }
    }

    func testDelayedSummaryCannotRollBackPublishedSameDocumentURL() async throws {
        try await assertHeldSummary(moveBeforeDelivery: true)
    }

    func testDelayedSummaryCannotOverwriteReturnedSameDocumentURL() async throws {
        try await assertHeldSummary(moveBeforeDelivery: true, returnsToInitialURL: true)
    }

    func testDelayedSummaryCannotOverwriteSameURLHistoryEntry() async throws {
        try await assertHeldSummary(moveBeforeDelivery: true, pushesSameURL: true)
    }

    func testLiveSummaryStillPublishesDocumentMetadata() async throws {
        try await assertHeldSummary(moveBeforeDelivery: false)
    }

    func testLiveSummaryRetainsInternalLoaderDocumentIdentity() async throws {
        try await assertHeldSummary(moveBeforeDelivery: false,
            initialURLString: "internal://local/load/reader?reader-url=https://example.com/article")
    }

    private func assertHeldSummary(moveBeforeDelivery: Bool,
                                   returnsToInitialURL: Bool = false,
                                   pushesSameURL: Bool = false,
                                   initialURLString: String = "https://example.com/summary/start") async throws {
        let initialURL = try XCTUnwrap(URL(string: initialURLString))
        let nextURL = try XCTUnwrap(URL(string: "https://example.com/summary/next"))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = HeldSummaryWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 932),
                                        configuration: configuration)
        let loaded = expectation(description: "Summary fixture loaded")
        let delegate = NavigationDelegate(completion: loaded)
        webView.navigationDelegate = delegate
        webView.loadHTMLString(
            "<!doctype html><html data-mnb-reader-render-ready='1'><head><title>Summary metadata</title></head><body><main id='reader-content'>article</main></body></html>",
            baseURL: initialURL)
        await fulfillment(of: [loaded], timeout: 10)
        webView.navigationDelegate = nil
        var state = WebViewState.empty
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        let model = SwiftUIWebView.WebView(navigator: navigator,
            state: Binding(get: { state }, set: { state = $0 }), htmlInState: true)
        let coordinator = model.makeCoordinatorForTesting()
        coordinator.setWebView(webView)
        coordinator.webView(webView, didCommit: nil)
        defer { coordinator.tearDownBindingsForDetachedWebView(webView) }
        let summaryFinished = expectation(description: "Actual summary evaluated before callback delivery")
        summaryFinished.expectedFulfillmentCount = 2
        webView.evaluationFinished = summaryFinished
        webView.evaluationsToHold = 2
        coordinator.webView(webView, didFinish: nil)
        await fulfillment(of: [summaryFinished], timeout: 10)
        XCTAssertTrue(webView.heldErrors.isEmpty)
        XCTAssertEqual(webView.heldDeliveries.count, 2)
        var expectedURL = initialURL
        if moveBeforeDelivery {
            if pushesSameURL {
                _ = try await webView.evaluateJavaScript("history.pushState({}, '', window.location.href)")
            } else {
                _ = try await webView.evaluateJavaScript("history.pushState({}, '', '/summary/next')")
                expectedURL = nextURL
            }
            XCTAssertEqual(webView.url, expectedURL)
            coordinator.handleObservedURLChange(expectedURL, from: webView,
                receiptSequence: UInt64.max - 1, forceHistoryStatePublication: true)
            XCTAssertEqual(state.pageURL, expectedURL)
            if returnsToInitialURL {
                _ = try await webView.evaluateJavaScript("history.pushState({}, '', '/summary/start')")
                expectedURL = initialURL
                XCTAssertEqual(webView.url, expectedURL)
                coordinator.handleObservedURLChange(expectedURL, from: webView,
                    receiptSequence: UInt64.max, forceHistoryStatePublication: true)
                XCTAssertEqual(state.pageURL, expectedURL)
            }
            _ = try await webView.evaluateJavaScript("""
                document.title = 'Successor metadata';
                document.getElementById('reader-content').textContent = 'Successor content';
                delete document.documentElement.dataset.mnbReaderRenderReady;
                """)
            state.pageTitle = "Successor metadata"
            state.hasReaderRenderReady = false
            state.pageHTML = "Successor HTML"
        }
        webView.deliver()
        XCTAssertEqual(state.pageURL, expectedURL)
        XCTAssertEqual(state.pageTitle, moveBeforeDelivery ? "Successor metadata" : "Summary metadata")
        XCTAssertEqual(state.hasReaderRenderReady, !moveBeforeDelivery)
        if moveBeforeDelivery {
            XCTAssertEqual(state.pageHTML, "Successor HTML")
        } else {
            XCTAssertTrue(try XCTUnwrap(state.pageHTML).contains("Summary metadata"))
        }
        XCTAssertEqual(webView.url, expectedURL)
        withExtendedLifetime(delegate) {}
    }

    private final class NavigationDelegate: NSObject, WKNavigationDelegate {
        let completion: XCTestExpectation
        private var didComplete = false

        init(completion: XCTestExpectation) {
            self.completion = completion
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            completeOnce()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            completeOnce()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            completeOnce()
        }

        private func completeOnce() {
            guard !didComplete else { return }
            didComplete = true
            completion.fulfill()
        }
    }

    func testReaderDocumentSummaryWaitsForMnbFontGate() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 430, height: 932),
            configuration: configuration
        )
        let loadExpectation = expectation(description: "reader summary fixture loaded")
        let navigationDelegate = NavigationDelegate(completion: loadExpectation)
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString(
            """
            <!doctype html>
            <html data-mnb-reader-render-ready="1" data-mnb-font-pending="1">
            <head><title>Reader Summary</title></head>
            <body>
                <main id="reader-content"><p>本文</p></main>
            </body>
            </html>
            """,
            baseURL: URL(string: "https://example.com/reader-summary")!
        )

        await fulfillment(of: [loadExpectation], timeout: 10)
        let pendingSummaryResult = try await webView.evaluateJavaScript(
            webViewReaderDocumentSummaryScript
        ) as? [String: Any]
        let pendingSummary = try XCTUnwrap(pendingSummaryResult)
        XCTAssertEqual(pendingSummary["hasReaderRenderReady"] as? Bool, false)
        XCTAssertEqual(pendingSummary["documentTitle"] as? String, "Reader Summary")
        XCTAssertEqual(
            pendingSummary["documentURL"] as? String,
            "https://example.com/reader-summary"
        )

        try await webView.evaluateJavaScript(
            "delete document.documentElement.dataset.mnbFontPending"
        )
        let readySummaryResult = try await webView.evaluateJavaScript(
            webViewReaderDocumentSummaryScript
        ) as? [String: Any]
        let readySummary = try XCTUnwrap(readySummaryResult)
        XCTAssertEqual(readySummary["hasReaderRenderReady"] as? Bool, true)

        withExtendedLifetime(navigationDelegate) {}
        withExtendedLifetime(webView) {}
    }
    func testReaderDocumentSummaryReportsExactRenderGeneration() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 430, height: 932),
            configuration: configuration
        )
        let loadExpectation = expectation(description: "reader generation fixture loaded")
        let navigationDelegate = NavigationDelegate(completion: loadExpectation)
        webView.navigationDelegate = navigationDelegate
        let generation = UUID()
        webView.loadHTMLString(
            """
            <!doctype html>
            <html
                data-mnb-reader-render-ready="1"
                data-mnb-reader-render-generation="\(generation.uuidString)"
            >
            <body>
                <main id="reader-content"><p>本文</p></main>
            </body>
            </html>
            """,
            baseURL: URL(string: "https://example.com/reader-generation")!
        )

        await fulfillment(of: [loadExpectation], timeout: 10)
        let summaryResult = try await webView.evaluateJavaScript(
            webViewReaderDocumentSummaryScript
        ) as? [String: Any]
        let summary = try XCTUnwrap(summaryResult)
        XCTAssertEqual(summary["hasReaderRenderReady"] as? Bool, true)
        XCTAssertEqual(summary["readerRenderGeneration"] as? String, generation.uuidString)

        withExtendedLifetime(navigationDelegate) {}
        withExtendedLifetime(webView) {}
    }

    func testMutationGenerationGateRejectsSupersededWork() {
        var gate = WebViewMutationGenerationGate()
        let first = gate.begin()
        XCTAssertTrue(gate.accepts(first))

        let second = gate.begin()
        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))

        gate.invalidate()
        XCTAssertFalse(gate.accepts(second))
    }


    func testCurrentWebViewURLObservationPublishesHistoryStateChanges() async throws {
        var state = WebViewState.empty
        var expectedURL: URL?
        var didFinishInitialLoad = false
        let loadExpectation = expectation(description: "history fixture loaded")
        let urlExpectation = expectation(description: "history URL published")
        let navigator = WebViewNavigator()
        let webViewModel = SwiftUIWebView.WebView(
            navigator: navigator,
            state: Binding(
                get: { state },
                set: { newState in
                    state = newState
                    if let expectedURL, newState.pageURL == expectedURL {
                        urlExpectation.fulfill()
                    }
                }
            ),
            onNavigationFinished: { _ in
                guard !didFinishInitialLoad else { return }
                didFinishInitialLoad = true
                loadExpectation.fulfill()
            }
        )
        let coordinator = webViewModel.makeCoordinatorForTesting()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 430, height: 932),
            configuration: configuration
        )
        coordinator.setWebView(webView)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        defer {
            coordinator.tearDownBindingsForDetachedWebView(webView)
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }

        webView.loadHTMLString(
            "<!doctype html><html><body>history</body></html>",
            baseURL: URL(string: "https://example.com/history/start")!
        )
        await fulfillment(of: [loadExpectation], timeout: 10)

        let nextURL = try XCTUnwrap(URL(string: "https://example.com/history/next"))
        expectedURL = nextURL
        try await webView.evaluateJavaScript(
            "history.pushState({}, '', '/history/next')"
        )
        await fulfillment(of: [urlExpectation], timeout: 3)

        XCTAssertEqual(state.pageURL, nextURL)
        XCTAssertTrue(navigator.webView === webView)
        withExtendedLifetime(coordinator) {}
        withExtendedLifetime(webView) {}
    }

    func testSameURLHistoryEntryPublishesBackForwardState() async throws {
        var state = WebViewState.empty
        var didFinishInitialLoad = false
        var didPublishHistoryState = false
        let loadExpectation = expectation(description: "same-URL fixture loaded")
        let backStateExpectation = expectation(description: "same-URL history state published")
        let navigator = WebViewNavigator()
        let webViewModel = SwiftUIWebView.WebView(
            navigator: navigator,
            state: Binding(
                get: { state },
                set: { newState in
                    state = newState
                    if didFinishInitialLoad, !didPublishHistoryState {
                        didPublishHistoryState = true
                        backStateExpectation.fulfill()
                    }
                }
            ),
            onNavigationFinished: { _ in
                guard !didFinishInitialLoad else { return }
                didFinishInitialLoad = true
                loadExpectation.fulfill()
            }
        )
        let coordinator = webViewModel.makeCoordinatorForTesting()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 430, height: 932),
            configuration: configuration
        )
        coordinator.setWebView(webView)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        defer {
            coordinator.tearDownBindingsForDetachedWebView(webView)
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }

        let baseURL = try XCTUnwrap(URL(string: "https://example.com/history/same"))
        webView.loadHTMLString(
            "<!doctype html><html><body>same URL history</body></html>",
            baseURL: baseURL
        )
        await fulfillment(of: [loadExpectation], timeout: 10)

        try await webView.evaluateJavaScript(
            "history.pushState({same: true}, '', window.location.href)"
        )
        coordinator.handleObservedURLChange(
            baseURL,
            from: webView,
            receiptSequence: 1,
            forceHistoryStatePublication: true
        )
        await fulfillment(of: [backStateExpectation], timeout: 3)

        XCTAssertEqual(state.pageURL, baseURL)
        XCTAssertEqual(state.canGoBack, webView.canGoBack)
        withExtendedLifetime(coordinator) {}
        withExtendedLifetime(webView) {}
    }

    func testDetachedWebViewTeardownPreservesReplacementURLObservation() async throws {
        var state = WebViewState.empty
        var expectedURL: URL?
        var didFinishInitialLoad = false
        let loadExpectation = expectation(description: "replacement fixture loaded")
        let urlExpectation = expectation(description: "replacement history URL published")
        let navigator = WebViewNavigator()
        let webViewModel = SwiftUIWebView.WebView(
            navigator: navigator,
            state: Binding(
                get: { state },
                set: { newState in
                    state = newState
                    if let expectedURL, newState.pageURL == expectedURL {
                        urlExpectation.fulfill()
                    }
                }
            ),
            onNavigationFinished: { _ in
                guard !didFinishInitialLoad else { return }
                didFinishInitialLoad = true
                loadExpectation.fulfill()
            }
        )
        let coordinator = webViewModel.makeCoordinatorForTesting()
        let detachedWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 430, height: 932),
            configuration: WKWebViewConfiguration()
        )
        let replacementConfiguration = WKWebViewConfiguration()
        replacementConfiguration.websiteDataStore = .nonPersistent()
        let replacementWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 430, height: 932),
            configuration: replacementConfiguration
        )

        coordinator.setWebView(detachedWebView)
        detachedWebView.navigationDelegate = coordinator
        detachedWebView.uiDelegate = coordinator
        coordinator.setWebView(replacementWebView)
        replacementWebView.navigationDelegate = coordinator
        replacementWebView.uiDelegate = coordinator
        coordinator.tearDownBindingsForDetachedWebView(detachedWebView)
        defer {
            coordinator.tearDownBindingsForDetachedWebView(replacementWebView)
            replacementWebView.navigationDelegate = nil
            replacementWebView.uiDelegate = nil
        }

        replacementWebView.loadHTMLString(
            "<!doctype html><html><body>replacement</body></html>",
            baseURL: URL(string: "https://example.com/replacement/start")!
        )
        await fulfillment(of: [loadExpectation], timeout: 10)

        let nextURL = try XCTUnwrap(URL(string: "https://example.com/replacement/next"))
        expectedURL = nextURL
        try await replacementWebView.evaluateJavaScript(
            "history.pushState({}, '', '/replacement/next')"
        )
        await fulfillment(of: [urlExpectation], timeout: 3)

        XCTAssertEqual(state.pageURL, nextURL)
        XCTAssertTrue(navigator.webView === replacementWebView)
        withExtendedLifetime(coordinator) {}
        withExtendedLifetime(replacementWebView) {}
    }

}
