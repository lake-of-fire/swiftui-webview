import XCTest
import WebKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
@testable import SwiftUIWebView

private actor JavaScriptEvaluationRecorder {
    private var scripts = [String]()

    func record(_ script: String) {
        scripts.append(script)
    }

    func recordedScripts() -> [String] {
        scripts
    }
}

@MainActor
private final class JavaScriptContinuationState {
    var shouldContinue: Bool
    var evaluationCount = 0
    var stopEvaluationCount = 0

    init(shouldContinue: Bool) {
        self.shouldContinue = shouldContinue
    }
}

private final class FrameProbeMessageHandler: NSObject, WKScriptMessageHandler {
    var onMessage: ((WKScriptMessage) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        onMessage?(message)
    }
}

@MainActor
private final class RecordingLoadWebView: EnhancedWKWebView {
    struct RecordedHTMLLoad {
        let html: String
        let baseURL: URL?
    }

    struct RecordedDataLoad {
        let data: Data
        let mimeType: String
        let characterEncodingName: String
        let baseURL: URL
    }

    var simulatedURL: URL?
    private(set) var loadedRequests = [URLRequest]()
    private(set) var loadedHTML = [RecordedHTMLLoad]()
    private(set) var loadedData = [RecordedDataLoad]()

    override var url: URL? {
        simulatedURL ?? super.url
    }

    override func load(_ request: URLRequest) -> WKNavigation? {
        loadedRequests.append(request)
        simulatedURL = request.url
        return nil
    }

    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        loadedHTML.append(RecordedHTMLLoad(html: string, baseURL: baseURL))
        simulatedURL = baseURL
        return nil
    }

    override func load(
        _ data: Data,
        mimeType: String,
        characterEncodingName: String,
        baseURL: URL
    ) -> WKNavigation? {
        loadedData.append(RecordedDataLoad(
            data: data,
            mimeType: mimeType,
            characterEncodingName: characterEncodingName,
            baseURL: baseURL
        ))
        simulatedURL = baseURL
        return nil
    }
}

@MainActor
private func drainMainDispatchQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

@MainActor
final class WebViewScriptCallerTests: XCTestCase {
#if os(macOS)
    func testTopLeadingWebViewOriginIncludesWindowChrome() {
        XCTAssertEqual(
            topLeadingWebViewOriginInWindow(
                frameInWindow: CGRect(x: 408, y: 0, width: 842, height: 798),
                contentViewHeight: 798,
                windowChromeTopInset: 52
            ),
            CGPoint(x: 408, y: 52)
        )
    }
#endif

    func testReaderLoaderCanonicalizationPreservesEscapedReservedCharacters() throws {
        let contentURL = try XCTUnwrap(URL(
            string: "ebook://book/chapter%2Fpart.xhtml?literal=%2523#selection"
        ))
        let encodedContentURL = try XCTUnwrap(
            contentURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let loaderURL = try XCTUnwrap(URL(
            string: "internal://local/load/reader?reader-url=\(encodedContentURL)"
        ))

        XCTAssertEqual(
            canonicalContentURLForReaderLoader(loaderURL)?.absoluteString,
            contentURL.absoluteString
        )
    }

    func testReaderLoaderCanonicalizationSupportsLegacyDoubleEncoding() throws {
        let contentURL = try XCTUnwrap(URL(
            string: "ebook://book/chapter%2Fpart.xhtml?literal=%2523#selection"
        ))
        let encodedContentURL = try XCTUnwrap(
            contentURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let doubleEncodedContentURL = try XCTUnwrap(
            encodedContentURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let loaderURL = try XCTUnwrap(URL(
            string: "internal://local/load/reader?reader-url=\(doubleEncodedContentURL)"
        ))

        XCTAssertEqual(
            canonicalContentURLForReaderLoader(loaderURL)?.absoluteString,
            contentURL.absoluteString
        )
    }

    func testExactRuntimeFrameResolutionAlsoRequiresCanonicalDocumentURL() async throws {
        let configuration = WKWebViewConfiguration()
        let messageHandler = FrameProbeMessageHandler()
        configuration.userContentController.add(messageHandler, name: "frameProbe")
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: configuration
        )
        let frameExpectation = expectation(description: "child frame registration")
        var childFrame: WKFrameInfo?
        messageHandler.onMessage = { message in
            guard !message.frameInfo.isMainFrame else { return }
            childFrame = message.frameInfo
            frameExpectation.fulfill()
        }
        let childDocument = """
        <script>
        window.webkit.messageHandlers.frameProbe.postMessage('ready')
        </script>
        """
        let srcdoc = childDocument
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        webView.loadHTMLString(
            "<iframe srcdoc=\"\(srcdoc)\"></iframe>",
            baseURL: URL(string: "ebook://book/container.xhtml")
        )

        await fulfillment(of: [frameExpectation], timeout: 3)
        let frame = try XCTUnwrap(childFrame)
        let caller = WebViewScriptCaller()
        let requestURL = try XCTUnwrap(frame.request.url)
        XCTAssertTrue(caller.addMultiTargetFrame(
            frame,
            uuid: "default-runtime-frame"
        ))
        XCTAssertEqual(
            caller.exactFrame(
                forUUID: "default-runtime-frame",
                documentURL: requestURL
            ),
            frame
        )
        if frame.request.mainDocumentURL != requestURL {
            XCTAssertNil(caller.exactFrame(
                forUUID: "default-runtime-frame",
                documentURL: frame.request.mainDocumentURL
            ))
        }

        let documentURL = URL(string: "ebook://book/chapter.xhtml")!
        XCTAssertTrue(caller.addMultiTargetFrame(
            frame,
            uuid: "runtime-frame",
            canonicalURL: documentURL
        ))
        XCTAssertEqual(
            caller.exactFrame(
                forUUID: "runtime-frame",
                documentURL: URL(string: "ebook://book/chapter.xhtml#selection")
            ),
            frame
        )
        XCTAssertNil(caller.exactFrame(
            forUUID: "runtime-frame",
            documentURL: URL(string: "ebook://book/other.xhtml")
        ))

        let escapedDocumentURL = try XCTUnwrap(URL(
            string: "ebook://book/chapter%2Fpart.xhtml?literal=%2523#selection"
        ))
        let encodedEscapedDocumentURL = try XCTUnwrap(
            escapedDocumentURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let escapedLoaderURL = try XCTUnwrap(URL(
            string: "internal://local/load/reader?reader-url=\(encodedEscapedDocumentURL)"
        ))
        XCTAssertTrue(caller.addMultiTargetFrame(
            frame,
            uuid: "escaped-runtime-frame",
            canonicalURL: escapedLoaderURL
        ))
        XCTAssertEqual(caller.exactFrame(
            forUUID: "escaped-runtime-frame",
            documentURL: escapedDocumentURL
        ), frame)
        XCTAssertNil(caller.exactFrame(
            forUUID: "escaped-runtime-frame",
            documentURL: URL(string: "ebook://book/chapter/part.xhtml?literal=%2523")
        ))

        let replacementURL = URL(string: "ebook://book/replacement.xhtml")!
        XCTAssertTrue(caller.addMultiTargetFrame(
            frame,
            uuid: "runtime-frame",
            canonicalURL: replacementURL
        ))
        XCTAssertNil(caller.exactFrame(
            forUUID: "runtime-frame",
            documentURL: documentURL
        ))
        XCTAssertEqual(caller.exactFrame(
            forUUID: "runtime-frame",
            documentURL: replacementURL
        ), frame)

        caller.removeAllMultiTargetFrames()
        XCTAssertNil(caller.exactFrame(
            forUUID: "runtime-frame",
            documentURL: replacementURL
        ))
    }


    func testReregisteringExactFrameUnderNewRuntimeUUIDRemovesOldAlias() async throws {
        let configuration = WKWebViewConfiguration()
        let messageHandler = FrameProbeMessageHandler()
        configuration.userContentController.add(messageHandler, name: "frameProbe")
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: configuration
        )
        let frameExpectation = expectation(description: "child frame registration")
        var childFrame: WKFrameInfo?
        messageHandler.onMessage = { message in
            guard !message.frameInfo.isMainFrame else { return }
            childFrame = message.frameInfo
            frameExpectation.fulfill()
        }
        let childDocument = """
        <script>window.webkit.messageHandlers.frameProbe.postMessage('ready')</script>
        """
        let srcdoc = childDocument
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        webView.loadHTMLString(
            "<iframe srcdoc=\"\(srcdoc)\"></iframe>",
            baseURL: URL(string: "ebook://book/container.xhtml")
        )

        await fulfillment(of: [frameExpectation], timeout: 3)
        let frame = try XCTUnwrap(childFrame)
        let caller = WebViewScriptCaller()
        let documentURL = URL(string: "ebook://book/chapter.xhtml")!

        XCTAssertTrue(caller.addMultiTargetFrame(
            frame,
            uuid: "old-runtime-frame",
            canonicalURL: documentURL
        ))
        XCTAssertTrue(caller.addMultiTargetFrame(
            frame,
            uuid: "new-runtime-frame",
            canonicalURL: documentURL
        ))

        XCTAssertNil(caller.exactFrame(
            forUUID: "old-runtime-frame",
            documentURL: documentURL
        ))
        XCTAssertTrue(caller.exactFrame(
            forUUID: "new-runtime-frame",
            documentURL: documentURL
        ) === frame)
    }

    func testReplacingSameURLRegistrationOwnsExactFrameInstance() async throws {
        let configuration = WKWebViewConfiguration()
        let messageHandler = FrameProbeMessageHandler()
        configuration.userContentController.add(messageHandler, name: "frameProbe")
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: configuration
        )
        let frameExpectation = expectation(description: "two child frame registrations")
        frameExpectation.expectedFulfillmentCount = 2
        var childFrames = [WKFrameInfo]()
        messageHandler.onMessage = { message in
            guard !message.frameInfo.isMainFrame else { return }
            childFrames.append(message.frameInfo)
            frameExpectation.fulfill()
        }
        let childDocument = """
        <script>window.webkit.messageHandlers.frameProbe.postMessage('ready')</script>
        """
        let srcdoc = childDocument
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        webView.loadHTMLString(
            "<iframe srcdoc=\"\(srcdoc)\"></iframe><iframe srcdoc=\"\(srcdoc)\"></iframe>",
            baseURL: URL(string: "ebook://book/container.xhtml")
        )

        await fulfillment(of: [frameExpectation], timeout: 3)
        XCTAssertEqual(childFrames.count, 2)
        let firstFrame = childFrames[0]
        let replacementFrame = childFrames[1]
        XCTAssertFalse(firstFrame === replacementFrame)

        let caller = WebViewScriptCaller()
        let documentURL = URL(string: "ebook://book/shared.xhtml")!
        XCTAssertTrue(caller.addMultiTargetFrame(
            firstFrame,
            uuid: "runtime-frame",
            canonicalURL: documentURL
        ))
        XCTAssertTrue(caller.addMultiTargetFrame(
            replacementFrame,
            uuid: "replacement-runtime-frame",
            canonicalURL: documentURL
        ))
        XCTAssertEqual(
            caller.exactFrameIdentifier(for: firstFrame, documentURL: documentURL),
            "runtime-frame"
        )
        XCTAssertEqual(
            caller.exactFrameIdentifier(for: replacementFrame, documentURL: documentURL),
            "replacement-runtime-frame"
        )
        XCTAssertTrue(caller.exactRegisteredFrame(
            expectedFrame: firstFrame,
            frameIdentifier: nil,
            documentURL: documentURL
        ) === firstFrame)
        XCTAssertTrue(caller.exactRegisteredFrame(
            expectedFrame: replacementFrame,
            frameIdentifier: nil,
            documentURL: documentURL
        ) === replacementFrame)
        XCTAssertNil(caller.exactRegisteredFrame(
            expectedFrame: firstFrame,
            frameIdentifier: "replacement-runtime-frame",
            documentURL: documentURL
        ))

        XCTAssertTrue(caller.addMultiTargetFrame(
            replacementFrame,
            uuid: "runtime-frame",
            canonicalURL: documentURL
        ))
        XCTAssertFalse(caller.addMultiTargetFrame(
            replacementFrame,
            uuid: "runtime-frame",
            canonicalURL: documentURL
        ))
        XCTAssertNil(caller.exactFrame(
            forUUID: "replacement-runtime-frame",
            documentURL: documentURL
        ))
        XCTAssertNil(caller.exactFrameIdentifier(
            for: firstFrame,
            documentURL: documentURL
        ))
        XCTAssertNil(caller.exactRegisteredFrame(
            expectedFrame: firstFrame,
            frameIdentifier: "runtime-frame",
            documentURL: documentURL
        ))
        XCTAssertTrue(caller.exactRegisteredFrame(
            expectedFrame: replacementFrame,
            frameIdentifier: "runtime-frame",
            documentURL: documentURL
        ) === replacementFrame)
    }

    func testRemovingAllRegisteredFramesAlsoClearsMainFrameFallback() async throws {
        let configuration = WKWebViewConfiguration()
        let messageHandler = FrameProbeMessageHandler()
        configuration.userContentController.add(messageHandler, name: "frameProbe")
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: configuration
        )
        let frameExpectation = expectation(description: "main frame registration")
        var mainFrame: WKFrameInfo?
        messageHandler.onMessage = { message in
            guard message.frameInfo.isMainFrame else { return }
            mainFrame = message.frameInfo
            frameExpectation.fulfill()
        }
        webView.loadHTMLString(
            "<script>window.webkit.messageHandlers.frameProbe.postMessage('ready')</script>",
            baseURL: URL(string: "ebook://book/container.xhtml")
        )

        await fulfillment(of: [frameExpectation], timeout: 3)
        let frame = try XCTUnwrap(mainFrame)
        let caller = WebViewScriptCaller()
        XCTAssertTrue(caller.addMultiTargetFrame(
            frame,
            uuid: "main-runtime-frame"
        ))
        XCTAssertEqual(caller.mainFrameInfo, frame)
        XCTAssertEqual(
            caller.frame(for: URL(string: "ebook://book/unregistered.xhtml")),
            frame
        )

        caller.removeAllMultiTargetFrames()

        XCTAssertNil(caller.mainFrameInfo)
        XCTAssertNil(caller.frame(for: frame.request.url))
        XCTAssertNil(caller.frame(for: URL(string: "ebook://book/unregistered.xhtml")))
    }

    func testMultiTargetEvaluationIncludesMainDocumentResult() async throws {
        let caller = WebViewScriptCaller()
        caller.asyncCaller = { script, arguments, frame, _ in
            XCTAssertEqual(script, "return value")
            XCTAssertNil(frame)
            XCTAssertEqual(arguments?["value"] as? Int, 42)
            return WebViewScriptCaller.JavaScriptEvaluationResult("main")
        }

        let results = try await caller.evaluateJavaScriptInMultiTargetFrames(
            "return value",
            arguments: ["value": 42],
            propagatesFrameErrors: true
        )

        XCTAssertEqual(results as? [String], ["main"])
    }

    func testStaleBindingOwnerCannotClearReplacement() async throws {
        let caller = WebViewScriptCaller()
        let staleOwnerID = UUID()
        let activeOwnerID = UUID()

        caller.installBinding(
            ownedBy: staleOwnerID,
            asyncCaller: { _, _, _, _ in
                WebViewScriptCaller.JavaScriptEvaluationResult("stale")
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { CGPoint(x: 1, y: 2) }
        )
        caller.installBinding(
            ownedBy: activeOwnerID,
            asyncCaller: { _, _, _, _ in
                WebViewScriptCaller.JavaScriptEvaluationResult("active")
            },
            unsafeCaller: { _, _, _ in },
            snapshotCapture: nil,
            coordinateOriginInWindow: { CGPoint(x: 3, y: 4) }
        )

        XCTAssertFalse(caller.clearBinding(ownedBy: staleOwnerID))
        XCTAssertTrue(caller.canEvaluateJavaScript)
        XCTAssertNotNil(caller.unsafeCaller)
        XCTAssertEqual(caller.coordinateOriginInWindow, CGPoint(x: 3, y: 4))
        let activeValue = try await caller.evaluateJavaScript("value") as? String
        XCTAssertEqual(activeValue, "active")

        XCTAssertTrue(caller.clearBinding(ownedBy: activeOwnerID))
        XCTAssertFalse(caller.canEvaluateJavaScript)
        XCTAssertNil(caller.unsafeCaller)
        XCTAssertNil(caller.coordinateOriginInWindow)
    }

    func testExactJavaScriptBindingTokenRejectsReplacementBinding() async throws {
        let caller = WebViewScriptCaller()
        let firstOwnerID = UUID()
        let replacementOwnerID = UUID()
        var firstEvaluationCount = 0
        var replacementEvaluationCount = 0

        caller.installBinding(
            ownedBy: firstOwnerID,
            asyncCaller: { @MainActor _, _, _, _ in
                firstEvaluationCount += 1
                return WebViewScriptCaller.JavaScriptEvaluationResult("first")
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { .zero }
        )
        let firstToken = try XCTUnwrap(caller.currentJavaScriptBindingToken)

        caller.installBinding(
            ownedBy: replacementOwnerID,
            asyncCaller: { @MainActor _, _, _, _ in
                replacementEvaluationCount += 1
                return WebViewScriptCaller.JavaScriptEvaluationResult("replacement")
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { .zero }
        )

        do {
            _ = try await caller.evaluateJavaScript(
                "old callback",
                requiring: firstToken
            )
            XCTFail("A replacement binding must not accept older callback work")
        } catch is CancellationError {
        }
        XCTAssertEqual(firstEvaluationCount, 0)
        XCTAssertEqual(replacementEvaluationCount, 0)

        let replacementToken = try XCTUnwrap(caller.currentJavaScriptBindingToken)
        let value = try await caller.evaluateJavaScript(
            "current callback",
            requiring: replacementToken
        ) as? String
        XCTAssertEqual(value, "replacement")
        XCTAssertEqual(replacementEvaluationCount, 1)
    }

    func testExactJavaScriptBindingTokenRejectsCompletionAfterReplacement() async throws {
        let caller = WebViewScriptCaller()
        let firstOwnerID = UUID()
        let replacementOwnerID = UUID()
        let firstEvaluationStarted = expectation(description: "first evaluation started")
        var resumeFirstEvaluation: CheckedContinuation<
            WebViewScriptCaller.JavaScriptEvaluationResult,
            Never
        >?
        var replacementEvaluationCount = 0

        caller.installBinding(
            ownedBy: firstOwnerID,
            asyncCaller: { @MainActor _, _, _, _ in
                firstEvaluationStarted.fulfill()
                return await withCheckedContinuation { continuation in
                    resumeFirstEvaluation = continuation
                }
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { .zero }
        )
        let firstToken = try XCTUnwrap(caller.currentJavaScriptBindingToken)
        let evaluationTask = Task { @MainActor in
            try await caller.evaluateJavaScript(
                "suspended old callback",
                requiring: firstToken
            )
        }
        await fulfillment(of: [firstEvaluationStarted], timeout: 1)

        caller.installBinding(
            ownedBy: replacementOwnerID,
            asyncCaller: { @MainActor _, _, _, _ in
                replacementEvaluationCount += 1
                return WebViewScriptCaller.JavaScriptEvaluationResult("replacement")
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { .zero }
        )
        resumeFirstEvaluation?.resume(
            returning: WebViewScriptCaller.JavaScriptEvaluationResult("first")
        )

        do {
            _ = try await evaluationTask.value
            XCTFail("Completion from the outgoing binding must be rejected")
        } catch is CancellationError {
        }
        XCTAssertEqual(replacementEvaluationCount, 0)
    }

    func testCoordinatorPublishesBindingTokenOnlyForExactBoundWebView() throws {
        let caller = WebViewScriptCaller()
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty),
            scriptCaller: caller
        )
        let coordinator = webViewModel.makeCoordinator()
        let firstWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let replacementWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )

        coordinator.installScriptCallerBinding(
            for: firstWebView,
            asyncCaller: { _, _, _, _ in
                WebViewScriptCaller.JavaScriptEvaluationResult(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { .zero }
        )
        XCTAssertNotNil(coordinator.javaScriptBindingToken(for: firstWebView))
        XCTAssertNil(coordinator.javaScriptBindingToken(for: replacementWebView))

        coordinator.installScriptCallerBinding(
            for: replacementWebView,
            asyncCaller: { _, _, _, _ in
                WebViewScriptCaller.JavaScriptEvaluationResult(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { .zero }
        )
        XCTAssertNil(coordinator.javaScriptBindingToken(for: firstWebView))
        XCTAssertNotNil(coordinator.javaScriptBindingToken(for: replacementWebView))

        coordinator.tearDownBindingsForDetachedWebView(replacementWebView)
        XCTAssertNil(coordinator.javaScriptBindingToken(for: replacementWebView))
    }

    func testForceClearLoadingIndicatorsCannotClearANewerNavigation() async {
        let oldURL = URL(string: "https://example.com/old")!
        let newURL = URL(string: "https://example.com/new")!
        var state = WebViewState.empty
        state.isLoading = true
        state.isProvisionallyNavigating = true
        state.loadingProgress = 0.4
        state.pageURL = oldURL

        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: Binding(
                get: { state },
                set: { state = $0 }
            )
        )
        let coordinator = webViewModel.makeCoordinator()

        navigator.forceClearLoadingIndicators(
            reason: "reader-render-ready",
            pageURL: oldURL
        )

        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(state.isProvisionallyNavigating)
        XCTAssertNil(state.loadingProgress)

        state.isLoading = true
        state.isProvisionallyNavigating = true
        state.loadingProgress = 0.2
        state.pageURL = newURL
        await drainMainDispatchQueue()

        XCTAssertTrue(state.isLoading)
        XCTAssertTrue(state.isProvisionallyNavigating)
        XCTAssertEqual(state.loadingProgress, 0.2)
        XCTAssertEqual(state.pageURL, newURL)
        _ = coordinator
    }



    func testCoordinatorIgnoresStaleNavigationStartCommitAndFinishFromCurrentWebView() throws {
        var state = WebViewState.empty
        state.pageTitle = "newer"
        state.mainFrameHTTPStatusCode = 418
        var committedCount = 0
        var finishedCount = 0
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: Binding(
                get: { state },
                set: { state = $0 }
            ),
            onNavigationCommitted: { _ in committedCount += 1 },
            onNavigationFinished: { _ in finishedCount += 1 }
        )
        let coordinator = webViewModel.makeCoordinator()
        let currentWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(currentWebView)

        let receiptSource = WKWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        let staleNavigation = try XCTUnwrap(receiptSource.loadHTMLString(
            "<html><body>stale</body></html>",
            baseURL: URL(string: "https://example.com/stale")
        ))
        let latestNavigation = try XCTUnwrap(receiptSource.loadHTMLString(
            "<html><body>latest</body></html>",
            baseURL: URL(string: "https://example.com/latest")
        ))
        let latestContentID = WebViewPoolContentID("latest")
        currentWebView.beginUnkeyedNavigation(navigation: staleNavigation)
        currentWebView.beginKeyedNavigation(
            contentID: latestContentID,
            navigation: latestNavigation
        )

        coordinator.webView(
            currentWebView,
            didStartProvisionalNavigation: staleNavigation
        )
        coordinator.webView(currentWebView, didCommit: staleNavigation)
        coordinator.webView(currentWebView, didFinish: staleNavigation)

        XCTAssertEqual(committedCount, 0)
        XCTAssertEqual(finishedCount, 0)
        XCTAssertEqual(state.pageTitle, "newer")
        XCTAssertEqual(state.mainFrameHTTPStatusCode, 418)
        XCTAssertEqual(currentWebView.poolPendingContentID, latestContentID)
    }

    func testCoordinatorIgnoresNavigationCompletionSupersededForPoolReset() throws {
        var state = WebViewState.empty
        state.pageTitle = "replacement"
        var finishedCount = 0
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: Binding(
                get: { state },
                set: { state = $0 }
            ),
            onNavigationFinished: { _ in finishedCount += 1 }
        )
        let coordinator = webViewModel.makeCoordinator()
        let currentWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(currentWebView)

        let receiptSource = WKWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        let cancelledNavigation = try XCTUnwrap(receiptSource.loadHTMLString(
            "<html><body>cancelled</body></html>",
            baseURL: URL(string: "https://example.com/cancelled")
        ))
        currentWebView.beginUnkeyedNavigation(navigation: cancelledNavigation)
        currentWebView.cancelPendingPooledContentNavigation()

        coordinator.webView(currentWebView, didFinish: cancelledNavigation)

        XCTAssertEqual(finishedCount, 0)
        XCTAssertEqual(state.pageTitle, "replacement")
    }

    func testCoordinatorIgnoresStaleNavigationFailuresFromCurrentWebView() throws {
        var state = WebViewState.empty
        state.pageTitle = "newer"
        var failedCount = 0
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: Binding(
                get: { state },
                set: { state = $0 }
            ),
            onNavigationFailed: { _ in failedCount += 1 }
        )
        let coordinator = webViewModel.makeCoordinator()
        let currentWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(currentWebView)

        let receiptSource = WKWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        let staleProvisionalNavigation = try XCTUnwrap(receiptSource.loadHTMLString(
            "<html><body>stale provisional</body></html>",
            baseURL: URL(string: "https://example.com/stale-provisional")
        ))
        let staleCommittedNavigation = try XCTUnwrap(receiptSource.loadHTMLString(
            "<html><body>stale committed</body></html>",
            baseURL: URL(string: "https://example.com/stale-committed")
        ))
        let latestNavigation = try XCTUnwrap(receiptSource.loadHTMLString(
            "<html><body>latest</body></html>",
            baseURL: URL(string: "https://example.com/latest")
        ))
        let latestContentID = WebViewPoolContentID("latest")
        currentWebView.beginUnkeyedNavigation(navigation: staleProvisionalNavigation)
        currentWebView.beginUnkeyedNavigation(navigation: staleCommittedNavigation)
        currentWebView.beginKeyedNavigation(
            contentID: latestContentID,
            navigation: latestNavigation
        )
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled
        )

        coordinator.webView(
            currentWebView,
            didFailProvisionalNavigation: staleProvisionalNavigation,
            withError: error
        )
        coordinator.webView(
            currentWebView,
            didFail: staleCommittedNavigation,
            withError: error
        )

        XCTAssertEqual(failedCount, 0)
        XCTAssertEqual(state.pageTitle, "newer")
        XCTAssertNil(state.error)
        XCTAssertEqual(currentWebView.poolPendingContentID, latestContentID)
    }

    func testCoordinatorIgnoresNavigationCompletionFromDetachedWebView() {
        var state = WebViewState.empty
        var finishedCount = 0
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: Binding(
                get: { state },
                set: { state = $0 }
            ),
            onNavigationFinished: { _ in
                finishedCount += 1
            }
        )
        let coordinator = webViewModel.makeCoordinator()
        let currentWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let detachedWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(currentWebView)
        state.pageTitle = "current"

        coordinator.webView(detachedWebView, didFinish: nil)

        XCTAssertEqual(finishedCount, 0)
        XCTAssertEqual(state.pageTitle, "current")
        XCTAssertTrue(navigator.webView === currentWebView)
    }

    func testExplicitNilContentRulesBypassDoesNotFallBackToConfiguredRules() {
        let configuredRules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]
        """
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            config: WebViewConfig(contentRules: configuredRules),
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let sourceWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(sourceWebView)
        coordinator.recordAppliedContentRules(configuredRules, for: sourceWebView)

        webViewModel.refreshContentRules(
            webView: sourceWebView,
            coordinator: coordinator,
            contentRules: nil
        )

        XCTAssertNil(coordinator.appliedContentRules(for: sourceWebView))
        XCTAssertNil(sourceWebView.persistedAppliedContentRules)
    }



    func testPendingContentRulesDoNotAuthorizeCurrentWebViewState() {
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let currentWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let pendingWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let pendingRules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]
        """

        coordinator.setWebView(currentWebView)
        coordinator.recordAppliedContentRules(nil, for: currentWebView)
        coordinator.scheduleWebViewBinding(
            pendingWebView,
            paginationReason: "content-rule-state-test"
        )
        coordinator.recordAppliedContentRules(pendingRules, for: pendingWebView)

        XCTAssertNil(coordinator.appliedContentRules(for: currentWebView))
        XCTAssertEqual(
            coordinator.appliedContentRules(for: pendingWebView),
            pendingRules
        )
    }

    func testChangingOnlyUserScriptContentWorldReinstallsScript() throws {
        let source = "window.worldOwnership = true"
        let pageScript = WebViewUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
        let isolatedWorld = WKContentWorld.world(name: "isolated-world")
        let isolatedScript = WebViewUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: isolatedWorld
        )
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            config: WebViewConfig(userScripts: [pageScript]),
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let sourceWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(sourceWebView)

        webViewModel.updateUserScripts(
            webView: sourceWebView,
            coordinator: coordinator,
            forDomain: URL(string: "https://example.com"),
            config: WebViewConfig(userScripts: [pageScript])
        )
        XCTAssertTrue(try XCTUnwrap(
            sourceWebView.configuration.userContentController.userScripts
                .first(where: { $0.source == source })
        ).contentWorld.isEqual(WKContentWorld.page))

        webViewModel.updateUserScripts(
            webView: sourceWebView,
            coordinator: coordinator,
            forDomain: URL(string: "https://example.com"),
            config: WebViewConfig(userScripts: [isolatedScript])
        )

        let installedScript = try XCTUnwrap(
            sourceWebView.configuration.userContentController.userScripts
                .first(where: { $0.source == source })
        )
        XCTAssertTrue(installedScript.contentWorld.isEqual(isolatedWorld))
    }

    func testPendingUserScriptConfigurationPersistsOnExactWebView() {
        let script = WebViewUserScript(
            source: "window.pendingOwner = true",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        let config = WebViewConfig(userScripts: [script])
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            config: config,
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let currentWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let pendingWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        currentWebView.persistedUserScriptsSignature = "current-owner"
        coordinator.setWebView(currentWebView)

        webViewModel.updateUserScripts(
            webView: pendingWebView,
            coordinator: coordinator,
            forDomain: URL(string: "https://pending.example"),
            config: config
        )

        XCTAssertEqual(
            currentWebView.persistedUserScriptsSignature,
            "current-owner"
        )
        XCTAssertNotNil(pendingWebView.persistedUserScriptsSignature)
        XCTAssertNotEqual(
            pendingWebView.persistedUserScriptsSignature,
            currentWebView.persistedUserScriptsSignature
        )
    }

    func testPendingReplacementDoesNotBlockCurrentContentRuleRestoration() throws {
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let currentWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let replacementWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(currentWebView)

        let currentGeneration = try XCTUnwrap(
            coordinator.beginContentRulesApplication(for: currentWebView)
        )
        XCTAssertTrue(coordinator.acceptsContentRulesApplication(
            currentGeneration,
            for: currentWebView
        ))

        coordinator.scheduleWebViewBinding(
            replacementWebView,
            paginationReason: "content-rule-owner-test"
        )

        let currentRestorationGeneration = try XCTUnwrap(
            coordinator.beginContentRulesApplication(for: currentWebView)
        )
        let replacementGeneration = try XCTUnwrap(
            coordinator.beginContentRulesApplication(for: replacementWebView)
        )
        XCTAssertFalse(coordinator.acceptsContentRulesApplication(
            currentGeneration,
            for: currentWebView
        ))
        XCTAssertTrue(coordinator.acceptsContentRulesApplication(
            currentRestorationGeneration,
            for: currentWebView
        ))
        XCTAssertTrue(coordinator.acceptsContentRulesApplication(
            replacementGeneration,
            for: replacementWebView
        ))

        coordinator.tearDownBindingsForDetachedWebView(replacementWebView)
        XCTAssertFalse(coordinator.acceptsContentRulesApplication(
            replacementGeneration,
            for: replacementWebView
        ))
        XCTAssertTrue(coordinator.acceptsContentRulesApplication(
            currentRestorationGeneration,
            for: currentWebView
        ))
        XCTAssertTrue(navigator.webView === currentWebView)
    }

    func testSupersededPendingReplacementCannotResumeOldContentRuleApplicationAfterRebinding() throws {
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let currentWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let firstReplacementWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let secondReplacementWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(currentWebView)

        coordinator.scheduleWebViewBinding(
            firstReplacementWebView,
            paginationReason: "first-content-rule-owner-test"
        )
        let staleGeneration = try XCTUnwrap(
            coordinator.beginContentRulesApplication(for: firstReplacementWebView)
        )

        coordinator.scheduleWebViewBinding(
            secondReplacementWebView,
            paginationReason: "second-content-rule-owner-test"
        )
        XCTAssertFalse(coordinator.acceptsContentRulesApplication(
            staleGeneration,
            for: firstReplacementWebView
        ))

        coordinator.scheduleWebViewBinding(
            firstReplacementWebView,
            paginationReason: "rebound-content-rule-owner-test"
        )
        XCTAssertFalse(coordinator.acceptsContentRulesApplication(
            staleGeneration,
            for: firstReplacementWebView
        ))
        XCTAssertTrue(navigator.webView === currentWebView)
    }

    func testWhitespaceEquivalentContentRulesDoNotRequireReapplication() {
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let sourceWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(sourceWebView)

        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        coordinator.recordAppliedContentRules(
            "  \n\(rules)\n  ",
            for: sourceWebView
        )

        XCTAssertEqual(coordinator.appliedContentRules(for: sourceWebView), rules)
        XCTAssertFalse(coordinator.needsContentRulesApplication(
            rules,
            for: sourceWebView
        ))
        XCTAssertFalse(coordinator.needsContentRulesApplication(
            "\n  \(rules)  \n",
            for: sourceWebView
        ))
        XCTAssertTrue(coordinator.needsContentRulesApplication(
            #"[{"trigger":{"url-filter":"example"},"action":{"type":"block"}}]"#,
            for: sourceWebView
        ))

        coordinator.recordAppliedContentRules("  \n  ", for: sourceWebView)
        XCTAssertNil(coordinator.appliedContentRules(for: sourceWebView))
        XCTAssertFalse(coordinator.needsContentRulesApplication(
            nil,
            for: sourceWebView
        ))
    }

    func testConfiguredContentRulesReconciliationUsesCanonicalAppliedAndPendingIdentity() throws {
        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            config: WebViewConfig(contentRules: "  \n\(rules)\n  "),
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let sourceWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(sourceWebView)
        coordinator.recordAppliedContentRules(rules, for: sourceWebView)
        let generationBeforeReconciliation = sourceWebView.persistedContentRulesApplicationGeneration

        coordinator.applyConfiguredContentRulesIfNeeded(on: sourceWebView)

        XCTAssertEqual(
            sourceWebView.persistedContentRulesApplicationGeneration,
            generationBeforeReconciliation
        )
        XCTAssertEqual(coordinator.appliedContentRules(for: sourceWebView), rules)

        let pendingGeneration = try XCTUnwrap(
            coordinator.beginContentRulesApplication(
                for: sourceWebView,
                pendingContentRules: rules
            )
        )
        coordinator.applyConfiguredContentRulesIfNeeded(on: sourceWebView)

        XCTAssertTrue(coordinator.acceptsContentRulesApplication(
            pendingGeneration,
            for: sourceWebView
        ))
        XCTAssertEqual(sourceWebView.persistedPendingContentRules, rules)
    }

    func testUncachedContentRuleReplacementIsTransactionalAndReversionCancelsIt() throws {
        let appliedRules = #"[{"trigger":{"url-filter":"applied"},"action":{"type":"block"}}]"#
        let replacementRules = #"[{"trigger":{"url-filter":"replacement"},"action":{"type":"block"}}]"#
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let sourceWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(sourceWebView)
        coordinator.recordAppliedContentRules(appliedRules, for: sourceWebView)

        webViewModel.refreshContentRules(
            webView: sourceWebView,
            coordinator: coordinator,
            contentRules: replacementRules
        )
        let pendingGeneration = sourceWebView.persistedContentRulesApplicationGeneration

        XCTAssertEqual(
            coordinator.appliedContentRules(for: sourceWebView),
            appliedRules
        )
        XCTAssertEqual(sourceWebView.persistedPendingContentRules, replacementRules)
        XCTAssertTrue(coordinator.acceptsContentRulesApplication(
            pendingGeneration,
            for: sourceWebView
        ))

        webViewModel.refreshContentRules(
            webView: sourceWebView,
            coordinator: coordinator,
            contentRules: appliedRules
        )

        XCTAssertFalse(coordinator.acceptsContentRulesApplication(
            pendingGeneration,
            for: sourceWebView
        ))
        XCTAssertEqual(
            coordinator.appliedContentRules(for: sourceWebView),
            appliedRules
        )
        XCTAssertNil(sourceWebView.persistedPendingContentRules)
        XCTAssertNil(sourceWebView.persistedContentRulesApplicationOwner)
    }

    func testPendingContentRulesAreOwnedCanonicallyAndSupersededByClear() throws {
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let sourceWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(sourceWebView)

        let firstGeneration = try XCTUnwrap(
            coordinator.beginContentRulesApplication(
                for: sourceWebView,
                pendingContentRules: "  first-rules  "
            )
        )
        XCTAssertNil(coordinator.beginContentRulesApplication(
            for: sourceWebView,
            pendingContentRules: "first-rules"
        ))
        XCTAssertFalse(coordinator.needsContentRulesApplication(
            "\nfirst-rules\n",
            for: sourceWebView
        ))
        XCTAssertTrue(coordinator.needsContentRulesApplication(
            nil,
            for: sourceWebView
        ))

        let clearGeneration = try XCTUnwrap(
            coordinator.beginContentRulesApplication(for: sourceWebView)
        )
        XCTAssertFalse(coordinator.acceptsContentRulesApplication(
            firstGeneration,
            for: sourceWebView
        ))
        XCTAssertTrue(coordinator.acceptsContentRulesApplication(
            clearGeneration,
            for: sourceWebView
        ))
        coordinator.finishContentRulesApplication(
            clearGeneration,
            for: sourceWebView
        )
        XCTAssertFalse(coordinator.needsContentRulesApplication(
            nil,
            for: sourceWebView
        ))
    }

    func testEquivalentPendingContentRuleApplicationDoesNotSupersedeItsOwner() throws {
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let sourceWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(sourceWebView)

        let firstGeneration = try XCTUnwrap(
            coordinator.beginContentRulesApplication(
                for: sourceWebView,
                pendingContentRules: "first-rules"
            )
        )
        XCTAssertNil(coordinator.beginContentRulesApplication(
            for: sourceWebView,
            pendingContentRules: "first-rules"
        ))
        XCTAssertTrue(coordinator.acceptsContentRulesApplication(
            firstGeneration,
            for: sourceWebView
        ))

        let replacementGeneration = try XCTUnwrap(
            coordinator.beginContentRulesApplication(
                for: sourceWebView,
                pendingContentRules: "replacement-rules"
            )
        )
        XCTAssertFalse(coordinator.acceptsContentRulesApplication(
            firstGeneration,
            for: sourceWebView
        ))
        XCTAssertTrue(coordinator.acceptsContentRulesApplication(
            replacementGeneration,
            for: sourceWebView
        ))

        coordinator.finishContentRulesApplication(
            replacementGeneration,
            for: sourceWebView
        )
        XCTAssertFalse(coordinator.acceptsContentRulesApplication(
            replacementGeneration,
            for: sourceWebView
        ))
        XCTAssertNotNil(coordinator.beginContentRulesApplication(
            for: sourceWebView,
            pendingContentRules: "replacement-rules"
        ))
    }

    func testOutgoingCoordinatorCannotCancelReplacementCoordinatorContentRuleApplication() throws {
        let firstNavigator = WebViewNavigator()
        let firstWebViewModel = WebView(
            navigator: firstNavigator,
            state: .constant(.empty)
        )
        let firstCoordinator = firstWebViewModel.makeCoordinator()
        let replacementNavigator = WebViewNavigator()
        let replacementWebViewModel = WebView(
            navigator: replacementNavigator,
            state: .constant(.empty)
        )
        let replacementCoordinator = replacementWebViewModel.makeCoordinator()
        let sharedWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )

        firstCoordinator.setWebView(sharedWebView)
        let staleGeneration = try XCTUnwrap(
            firstCoordinator.beginContentRulesApplication(
                for: sharedWebView,
                pendingContentRules: "shared-rules"
            )
        )

        replacementCoordinator.setWebView(sharedWebView)
        XCTAssertFalse(firstCoordinator.acceptsContentRulesApplication(
            staleGeneration,
            for: sharedWebView
        ))
        XCTAssertFalse(replacementCoordinator.needsContentRulesApplication(
            nil,
            for: sharedWebView
        ))

        let replacementGeneration = try XCTUnwrap(
            replacementCoordinator.beginContentRulesApplication(
                for: sharedWebView,
                pendingContentRules: "shared-rules"
            )
        )
        XCTAssertTrue(replacementCoordinator.acceptsContentRulesApplication(
            replacementGeneration,
            for: sharedWebView
        ))

        firstCoordinator.tearDownBindingsForDetachedWebView(sharedWebView)

        XCTAssertNil(firstNavigator.webView)
        XCTAssertTrue(replacementNavigator.webView === sharedWebView)
        XCTAssertTrue(replacementCoordinator.acceptsContentRulesApplication(
            replacementGeneration,
            for: sharedWebView
        ))
    }

    func testOutgoingCoordinatorTeardownPreservesReplacementWindowAttachmentCallback() {
        let outgoingNavigator = WebViewNavigator()
        let outgoingWebViewModel = WebView(
            navigator: outgoingNavigator,
            state: .constant(.empty)
        )
        let outgoingCoordinator = outgoingWebViewModel.makeCoordinator()
        let replacementNavigator = WebViewNavigator()
        let replacementWebViewModel = WebView(
            navigator: replacementNavigator,
            state: .constant(.empty)
        )
        let replacementCoordinator = replacementWebViewModel.makeCoordinator()
        let sharedWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )

        outgoingCoordinator.setWebView(sharedWebView)
        replacementCoordinator.setWebView(sharedWebView)
        let replacementCallback = sharedWebView.onDidMoveToWindow

        outgoingCoordinator.tearDownBindingsForDetachedWebView(sharedWebView)

        XCTAssertNil(outgoingNavigator.webView)
        XCTAssertTrue(replacementNavigator.webView === sharedWebView)
        XCTAssertTrue(
            sharedWebView.persistedWindowAttachmentCallbackOwner === replacementCoordinator
        )
        XCTAssertTrue(sharedWebView.persistedNavigatorOwner === replacementNavigator)
        XCTAssertNotNil(replacementCallback)
        XCTAssertNotNil(sharedWebView.onDidMoveToWindow)
    }

    func testNavigatorOwnershipTransferCancelsOutgoingFallbackLoad() async throws {
        let outgoingNavigator = WebViewNavigator()
        outgoingNavigator.attachFallbackURL = try XCTUnwrap(
            URL(string: "https://outgoing.invalid/fallback")
        )
        outgoingNavigator.attachFallbackDelayNanoseconds = 5_000_000
        let outgoingWebViewModel = WebView(
            navigator: outgoingNavigator,
            state: .constant(.empty)
        )
        let outgoingCoordinator = outgoingWebViewModel.makeCoordinator()

        let replacementNavigator = WebViewNavigator()
        replacementNavigator.shouldLoadFallbackOnAttach = false
        let replacementWebViewModel = WebView(
            navigator: replacementNavigator,
            state: .constant(.empty)
        )
        let replacementCoordinator = replacementWebViewModel.makeCoordinator()
        let sharedWebView = RecordingLoadWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
#if os(macOS)
        let host = NSView(frame: sharedWebView.frame)
        host.addSubview(sharedWebView)
#elseif os(iOS)
        let host = UIView(frame: sharedWebView.frame)
        host.addSubview(sharedWebView)
#endif

        outgoingCoordinator.setWebView(sharedWebView)
        outgoingNavigator.nativeLookupHitTesting.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "outgoing-target",
                rects: [CGRect(x: 0, y: 0, width: 20, height: 20)]
            )
        ])
        XCTAssertTrue(sharedWebView.persistedNavigatorOwner === outgoingNavigator)
        XCTAssertEqual(outgoingNavigator.nativeLookupHitTesting.targetCount, 1)

        replacementCoordinator.setWebView(sharedWebView)

        XCTAssertNil(outgoingNavigator.webView)
        XCTAssertEqual(outgoingNavigator.nativeLookupHitTesting.targetCount, 0)
        XCTAssertTrue(replacementNavigator.webView === sharedWebView)
        XCTAssertTrue(sharedWebView.persistedNavigatorOwner === replacementNavigator)

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(sharedWebView.loadedRequests.contains { request in
            request.url == outgoingNavigator.attachFallbackURL
        })
        withExtendedLifetime(host) {}
    }

    func testOutgoingCoordinatorReplacementPreservesTransferredWindowAttachmentCallback() {
        let outgoingNavigator = WebViewNavigator()
        let outgoingWebViewModel = WebView(
            navigator: outgoingNavigator,
            state: .constant(.empty)
        )
        let outgoingCoordinator = outgoingWebViewModel.makeCoordinator()
        let replacementNavigator = WebViewNavigator()
        let replacementWebViewModel = WebView(
            navigator: replacementNavigator,
            state: .constant(.empty)
        )
        let replacementCoordinator = replacementWebViewModel.makeCoordinator()
        let transferredWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let outgoingReplacementWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )

        outgoingCoordinator.setWebView(transferredWebView)
        replacementCoordinator.setWebView(transferredWebView)
        outgoingCoordinator.setWebView(outgoingReplacementWebView)

        XCTAssertTrue(outgoingNavigator.webView === outgoingReplacementWebView)
        XCTAssertTrue(replacementNavigator.webView === transferredWebView)
        XCTAssertTrue(
            transferredWebView.persistedWindowAttachmentCallbackOwner === replacementCoordinator
        )
        XCTAssertTrue(transferredWebView.persistedNavigatorOwner === replacementNavigator)
        XCTAssertNotNil(transferredWebView.onDidMoveToWindow)
        XCTAssertTrue(
            outgoingReplacementWebView.persistedWindowAttachmentCallbackOwner === outgoingCoordinator
        )
    }

    func testAcceptedPooledHTMLLoadCancelsScheduledAttachFallback() async throws {
        let navigator = WebViewNavigator()
        navigator.attachFallbackURL = try XCTUnwrap(URL(
            string: "https://fallback.invalid/blank"
        ))
        navigator.attachFallbackDelayNanoseconds = 5_000_000
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let contentID = WebViewPoolContentID("ready-document")
        let webView = RecordingLoadWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        webView.poolReadyContentID = contentID
#if os(macOS)
        let host = NSView(frame: webView.frame)
        host.addSubview(webView)
#elseif os(iOS)
        let host = UIView(frame: webView.frame)
        host.addSubview(webView)
#endif

        coordinator.setWebView(webView)
        navigator.loadHTML(
            "<p>already loaded</p>",
            baseURL: try XCTUnwrap(URL(string: "https://ready.invalid/document")),
            contentID: contentID
        )

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(webView.loadedRequests.isEmpty)
        XCTAssertTrue(webView.loadedHTML.isEmpty)
        XCTAssertEqual(webView.poolReadyContentID, contentID)
        withExtendedLifetime(host) {}
    }

    func testStartedAttachFallbackInvalidatesPooledReadyContentBeforeSameIDHTMLLoad() async throws {
        let navigator = WebViewNavigator()
        let fallbackURL = try XCTUnwrap(URL(
            string: "https://fallback.invalid/blank"
        ))
        navigator.attachFallbackURL = fallbackURL
        navigator.attachFallbackDelayNanoseconds = 1_000_000
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let contentID = WebViewPoolContentID("ready-before-fallback")
        let webView = RecordingLoadWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        webView.poolReadyContentID = contentID
#if os(macOS)
        let host = NSView(frame: webView.frame)
        host.addSubview(webView)
#elseif os(iOS)
        let host = UIView(frame: webView.frame)
        host.addSubview(webView)
#endif

        coordinator.setWebView(webView)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(webView.loadedRequests.last?.url, fallbackURL)
        XCTAssertNil(webView.poolReadyContentID)

        let baseURL = try XCTUnwrap(URL(
            string: "https://reader.example/current"
        ))
        navigator.loadHTML(
            "<p>restore current content</p>",
            baseURL: baseURL,
            contentID: contentID
        )

        XCTAssertEqual(webView.loadedHTML.count, 1)
        XCTAssertEqual(webView.loadedHTML.first?.baseURL, baseURL)
        withExtendedLifetime(host) {}
    }

    func testStartedAttachFallbackClearsPendingPooledContentIdentity() async throws {
        let navigator = WebViewNavigator()
        let fallbackURL = try XCTUnwrap(URL(
            string: "https://fallback.invalid/pending"
        ))
        navigator.attachFallbackURL = fallbackURL
        navigator.attachFallbackDelayNanoseconds = 1_000_000
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let webView = RecordingLoadWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let navigationSource = WKWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        let pendingNavigation = try XCTUnwrap(navigationSource.loadHTMLString(
            "<p>pending keyed content</p>",
            baseURL: nil
        ))
        webView.beginKeyedNavigation(
            contentID: WebViewPoolContentID("pending-keyed-content"),
            navigation: pendingNavigation
        )
#if os(macOS)
        let host = NSView(frame: webView.frame)
        host.addSubview(webView)
#elseif os(iOS)
        let host = UIView(frame: webView.frame)
        host.addSubview(webView)
#endif

        coordinator.setWebView(webView)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(webView.loadedRequests.last?.url, fallbackURL)
        XCTAssertNil(webView.poolPendingContentID)
        XCTAssertNil(webView.poolReadyContentID)
        withExtendedLifetime(navigationSource) {}
        withExtendedLifetime(host) {}
    }

    func testStaleProvisionalNavigationDoesNotClearCurrentNativeTargetsOrPooledOwner() throws {
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let webView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let navigationSource = WKWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        let staleNavigation = try XCTUnwrap(navigationSource.loadHTMLString(
            "<p>stale</p>",
            baseURL: nil
        ))
        let currentNavigation = try XCTUnwrap(navigationSource.loadHTMLString(
            "<p>current</p>",
            baseURL: nil
        ))
        let currentContentID = WebViewPoolContentID("current-content")

        coordinator.setWebView(webView)
        webView.beginUnkeyedNavigation(navigation: staleNavigation)
        webView.beginKeyedNavigation(
            contentID: currentContentID,
            navigation: currentNavigation
        )
        navigator.nativeLookupHitTesting.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "current-target",
                rects: [CGRect(x: 0, y: 0, width: 20, height: 20)]
            )
        ])

        coordinator.webView(
            webView,
            didStartProvisionalNavigation: staleNavigation
        )

        XCTAssertEqual(navigator.nativeLookupHitTesting.targetCount, 1)
        XCTAssertEqual(webView.poolPendingContentID, currentContentID)
        withExtendedLifetime(navigationSource) {}
    }

    func testUnavailableHistoryNavigationPreservesPooledReadyIdentity() {
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let contentID = WebViewPoolContentID("ready-without-history")
        let webView = RecordingLoadWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )

        coordinator.setWebView(webView)
        webView.poolReadyContentID = contentID
        navigator.goBack()

        XCTAssertEqual(webView.poolReadyContentID, contentID)
    }

    func testLatestHTMLLoadSupersedesPendingRequestBeforeWebViewBinding() throws {
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let oldRequest = URLRequest(url: try XCTUnwrap(URL(
            string: "https://old.invalid/request"
        )))
        let latestBaseURL = try XCTUnwrap(URL(
            string: "https://latest.invalid/document"
        ))

        navigator.load(oldRequest)
        navigator.loadHTML("<p>latest</p>", baseURL: latestBaseURL)

        let webView = RecordingLoadWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(webView)

        XCTAssertTrue(webView.loadedRequests.isEmpty)
        XCTAssertTrue(webView.loadedData.isEmpty)
        XCTAssertEqual(webView.loadedHTML.count, 1)
        XCTAssertEqual(webView.loadedHTML.first?.html, "<p>latest</p>")
        XCTAssertEqual(webView.loadedHTML.first?.baseURL, latestBaseURL)
    }

    func testLatestDataLoadSupersedesPendingHTMLAndRequestBeforeWebViewBinding() throws {
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let oldHTMLBaseURL = try XCTUnwrap(URL(
            string: "https://old.invalid/html"
        ))
        let oldRequest = URLRequest(url: try XCTUnwrap(URL(
            string: "https://old.invalid/request"
        )))
        let latestData = Data("latest".utf8)
        let latestBaseURL = try XCTUnwrap(URL(
            string: "https://latest.invalid/data"
        ))

        navigator.loadHTML("<p>old</p>", baseURL: oldHTMLBaseURL)
        navigator.load(oldRequest)
        navigator.load(
            latestData,
            mimeType: "text/html",
            characterEncodingName: "utf-8",
            baseURL: latestBaseURL
        )

        let webView = RecordingLoadWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(webView)

        XCTAssertTrue(webView.loadedRequests.isEmpty)
        XCTAssertTrue(webView.loadedHTML.isEmpty)
        XCTAssertEqual(webView.loadedData.count, 1)
        XCTAssertEqual(webView.loadedData.first?.data, latestData)
        XCTAssertEqual(webView.loadedData.first?.mimeType, "text/html")
        XCTAssertEqual(webView.loadedData.first?.characterEncodingName, "utf-8")
        XCTAssertEqual(webView.loadedData.first?.baseURL, latestBaseURL)
    }

    func testNavigatorAttachmentPublicationRejectsQueuedAttachAfterDetach() async {
        let navigator = WebViewNavigator()
        let sourceWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )

        navigator.webView = sourceWebView
        navigator.webView = nil
        await drainMainDispatchQueue()

        XCTAssertNil(navigator.webView)
        XCTAssertFalse(navigator.hasAttachedWebView)
    }

    func testNavigatorAttachmentPublicationUsesCurrentReplacementAfterQueuedDetach() async {
        let navigator = WebViewNavigator()
        let sourceWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let replacementWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )

        navigator.webView = sourceWebView
        await drainMainDispatchQueue()
        XCTAssertTrue(navigator.hasAttachedWebView)

        navigator.webView = nil
        navigator.webView = replacementWebView
        await drainMainDispatchQueue()

        XCTAssertTrue(navigator.webView === replacementWebView)
        XCTAssertTrue(navigator.hasAttachedWebView)
    }

    func testWindowAttachmentCallbackDoesNotFlushPendingRequestBeforeWindowAttachment() async throws {
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let webView = RecordingLoadWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
#if os(macOS)
        let host = NSView(frame: webView.frame)
        host.addSubview(webView)
#elseif os(iOS)
        let host = UIView(frame: webView.frame)
        host.addSubview(webView)
#endif
        webView.simulatedURL = try XCTUnwrap(URL(string: "ebook://book/current.xhtml"))
        coordinator.setWebView(webView)
        webView.navigationDelegate = coordinator
        let encodedDestination = try XCTUnwrap(
            "ebook://book/next.xhtml".addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let request = URLRequest(url: try XCTUnwrap(URL(
            string: "internal://local/load/reader?reader-url=\(encodedDestination)"
        )))

        navigator.load(request)
        XCTAssertEqual(webView.loadedRequests.count, 0)
        XCTAssertNil(webView.window)
        XCTAssertNotNil(webView.superview)

        let attachmentCallback = try XCTUnwrap(webView.onDidMoveToWindow)
        attachmentCallback(true)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(webView.loadedRequests.count, 0)
        _ = host
    }

    func testUnloadTransactionGateRejectsDuplicateAndStaleCompletionAfterCancellation() throws {
        var gate = WebViewUnloadTransactionGate()
        let controller = NSObject()
        let sourceWebView = NSObject()
        let replacementWebView = NSObject()
        let controllerID = ObjectIdentifier(controller)
        let sourceWebViewID = ObjectIdentifier(sourceWebView)
        let replacementWebViewID = ObjectIdentifier(replacementWebView)

        let firstGeneration = try XCTUnwrap(gate.begin(
            controllerID: controllerID,
            webViewID: sourceWebViewID
        ))
        XCTAssertNil(gate.begin(
            controllerID: controllerID,
            webViewID: sourceWebViewID
        ))
        XCTAssertTrue(gate.accepts(
            firstGeneration,
            controllerID: controllerID,
            webViewID: sourceWebViewID
        ))

        gate.cancel()
        let replacementGeneration = try XCTUnwrap(gate.begin(
            controllerID: controllerID,
            webViewID: replacementWebViewID
        ))
        XCTAssertFalse(gate.accepts(
            firstGeneration,
            controllerID: controllerID,
            webViewID: sourceWebViewID
        ))
        XCTAssertTrue(gate.accepts(
            replacementGeneration,
            controllerID: controllerID,
            webViewID: replacementWebViewID
        ))

        gate.finish(
            firstGeneration,
            controllerID: controllerID,
            webViewID: sourceWebViewID
        )
        XCTAssertTrue(gate.accepts(
            replacementGeneration,
            controllerID: controllerID,
            webViewID: replacementWebViewID
        ))
    }

    func testContentRulesBypassGateDoesNotLetOlderCompletionEndNewerBypass() throws {
        var gate = WebViewContentRulesBypassGate()
        let sourceWebView = NSObject()
        let sourceWebViewID = ObjectIdentifier(sourceWebView)
        let firstNavigation = NSObject()
        let secondNavigation = NSObject()
        let firstOwner = WebViewContentRulesBypassOwner(
            webViewID: sourceWebViewID,
            navigationID: ObjectIdentifier(firstNavigation)
        )
        let secondOwner = WebViewContentRulesBypassOwner(
            webViewID: sourceWebViewID,
            navigationID: ObjectIdentifier(secondNavigation)
        )

        gate.register(firstOwner)
        XCTAssertEqual(gate.consumeNext(webViewID: sourceWebViewID), firstOwner)
        gate.register(secondOwner)

        XCTAssertTrue(gate.finish(firstOwner))
        XCTAssertTrue(gate.isBypassing(webViewID: sourceWebViewID))
        XCTAssertEqual(gate.consumeNext(webViewID: sourceWebViewID), secondOwner)
        XCTAssertFalse(gate.finish(firstOwner))
        XCTAssertTrue(gate.isBypassing(webViewID: sourceWebViewID))
        XCTAssertTrue(gate.finish(secondOwner))
        XCTAssertFalse(gate.isBypassing(webViewID: sourceWebViewID))

        gate.register(firstOwner)
        gate.register(secondOwner)
        XCTAssertEqual(gate.consumeNext(webViewID: sourceWebViewID), firstOwner)
        XCTAssertEqual(gate.consumeNext(webViewID: sourceWebViewID), secondOwner)
        XCTAssertTrue(gate.finish(secondOwner))
        XCTAssertTrue(gate.isBypassing(webViewID: sourceWebViewID))
        XCTAssertTrue(gate.finish(firstOwner))
        XCTAssertFalse(gate.isBypassing(webViewID: sourceWebViewID))

        gate.register(firstOwner)
        XCTAssertTrue(gate.cancelAll(webViewID: sourceWebViewID))
        XCTAssertFalse(gate.isBypassing(webViewID: sourceWebViewID))
        XCTAssertNil(gate.consumeNext(webViewID: sourceWebViewID))
    }

    func testContentRulesBypassGateIsolatesPendingReplacementWebViews() throws {
        var gate = WebViewContentRulesBypassGate()
        let currentWebView = NSObject()
        let replacementWebView = NSObject()
        let currentWebViewID = ObjectIdentifier(currentWebView)
        let replacementWebViewID = ObjectIdentifier(replacementWebView)
        let currentNavigation = NSObject()
        let replacementNavigation = NSObject()
        let currentOwner = WebViewContentRulesBypassOwner(
            webViewID: currentWebViewID,
            navigationID: ObjectIdentifier(currentNavigation)
        )
        let replacementOwner = WebViewContentRulesBypassOwner(
            webViewID: replacementWebViewID,
            navigationID: ObjectIdentifier(replacementNavigation)
        )

        gate.register(currentOwner)

        XCTAssertTrue(gate.isBypassing(webViewID: currentWebViewID))
        XCTAssertFalse(gate.isBypassing(webViewID: replacementWebViewID))
        XCTAssertNil(gate.consumeNext(webViewID: replacementWebViewID))
        XCTAssertFalse(gate.cancelAll(webViewID: replacementWebViewID))
        XCTAssertTrue(gate.isBypassing(webViewID: currentWebViewID))

        gate.register(replacementOwner)
        XCTAssertEqual(gate.consumeNext(webViewID: replacementWebViewID), replacementOwner)
        XCTAssertTrue(gate.cancelAll(webViewID: replacementWebViewID))
        XCTAssertFalse(gate.isBypassing(webViewID: replacementWebViewID))
        XCTAssertTrue(gate.isBypassing(webViewID: currentWebViewID))

        XCTAssertEqual(gate.consumeNext(webViewID: currentWebViewID), currentOwner)
        XCTAssertTrue(gate.finish(currentOwner))
        XCTAssertFalse(gate.isBypassing(webViewID: currentWebViewID))
    }

    func testScriptMessageAdmissionRequiresExactCurrentWebViewAndController() {
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let currentWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let pendingWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )

        coordinator.setWebView(currentWebView)
        coordinator.reconcileMessageHandlers(
            on: currentWebView,
            requiredHandlers: ["current-handler"],
            environmentHandlerNames: ["current-handler"]
        )
        XCTAssertTrue(coordinator.admitsScriptMessage(
            from: currentWebView,
            userContentController: currentWebView.configuration.userContentController
        ))
        XCTAssertFalse(coordinator.admitsScriptMessage(
            from: pendingWebView,
            userContentController: currentWebView.configuration.userContentController
        ))

        coordinator.scheduleWebViewBinding(pendingWebView, paginationReason: "test-pending")
        coordinator.reconcileMessageHandlers(
            on: pendingWebView,
            requiredHandlers: ["pending-handler"],
            environmentHandlerNames: ["pending-handler"]
        )
        XCTAssertFalse(coordinator.admitsScriptMessage(
            from: pendingWebView,
            userContentController: pendingWebView.configuration.userContentController
        ))
        XCTAssertTrue(coordinator.admitsScriptMessage(
            from: currentWebView,
            userContentController: currentWebView.configuration.userContentController
        ))

        coordinator.setWebView(pendingWebView)
        XCTAssertTrue(coordinator.admitsScriptMessage(
            from: pendingWebView,
            userContentController: pendingWebView.configuration.userContentController
        ))
        XCTAssertFalse(coordinator.admitsScriptMessage(
            from: currentWebView,
            userContentController: currentWebView.configuration.userContentController
        ))

        coordinator.tearDownBindingsForDetachedWebView(pendingWebView)
        XCTAssertFalse(coordinator.admitsScriptMessage(
            from: pendingWebView,
            userContentController: pendingWebView.configuration.userContentController
        ))
    }

    func testPendingMessageHandlerConfigurationPreservesCurrentWebViewRegistrations() {
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let currentWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let pendingWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let currentHandlers: Set<String> = ["current-handler"]
        let pendingHandlers: Set<String> = ["pending-handler"]
        coordinator.setWebView(currentWebView)
        coordinator.reconcileMessageHandlers(
            on: currentWebView,
            requiredHandlers: currentHandlers,
            environmentHandlerNames: ["current-handler"]
        )
        coordinator.scheduleWebViewBinding(pendingWebView, paginationReason: "test-pending")
        coordinator.reconcileMessageHandlers(
            on: pendingWebView,
            requiredHandlers: pendingHandlers,
            environmentHandlerNames: ["pending-handler"]
        )

        XCTAssertEqual(currentWebView.persistedMessageHandlerNames, currentHandlers)
        XCTAssertEqual(pendingWebView.persistedMessageHandlerNames, pendingHandlers)
        XCTAssertTrue(coordinator.admitsScriptMessage(
            from: currentWebView,
            userContentController: currentWebView.configuration.userContentController
        ))
        XCTAssertFalse(coordinator.admitsScriptMessage(
            from: pendingWebView,
            userContentController: pendingWebView.configuration.userContentController
        ))

        coordinator.tearDownBindingsForDetachedWebView(pendingWebView)
        XCTAssertEqual(currentWebView.persistedMessageHandlerNames, currentHandlers)
        XCTAssertTrue(pendingWebView.persistedMessageHandlerNames.isEmpty)
    }

    func testOldCoordinatorTeardownDoesNotRemoveReplacementMessageHandlers() {
        let sourceWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let oldCoordinator = WebView(
            navigator: WebViewNavigator(),
            state: .constant(.empty)
        ).makeCoordinator()
        let replacementCoordinator = WebView(
            navigator: WebViewNavigator(),
            state: .constant(.empty)
        ).makeCoordinator()
        let replacementHandlers: Set<String> = ["shared-handler"]
        oldCoordinator.setWebView(sourceWebView)
        oldCoordinator.reconcileMessageHandlers(
            on: sourceWebView,
            requiredHandlers: replacementHandlers,
            environmentHandlerNames: ["shared-handler"]
        )
        replacementCoordinator.setWebView(sourceWebView)
        replacementCoordinator.reconcileMessageHandlers(
            on: sourceWebView,
            requiredHandlers: replacementHandlers,
            environmentHandlerNames: ["shared-handler"]
        )

        oldCoordinator.tearDownBindingsForDetachedWebView(sourceWebView)

        XCTAssertTrue(sourceWebView.persistedMessageHandlerOwner === replacementCoordinator)
        XCTAssertEqual(sourceWebView.persistedMessageHandlerNames, replacementHandlers)
        XCTAssertTrue(replacementCoordinator.admitsScriptMessage(
            from: sourceWebView,
            userContentController: sourceWebView.configuration.userContentController
        ))
    }

    func testTeardownOfDetachedOldWebViewPreservesReplacementOwnership() {
        let caller = WebViewScriptCaller()
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty),
            scriptCaller: caller
        )
        let coordinator = webViewModel.makeCoordinator()
        let detachedWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let replacementWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )

        coordinator.setWebView(detachedWebView)
        detachedWebView.navigationDelegate = coordinator
        detachedWebView.uiDelegate = coordinator
#if os(iOS)
        detachedWebView.scrollView.delegate = coordinator
#endif
        coordinator.installScriptCallerBinding(
            for: detachedWebView,
            asyncCaller: { _, _, _, _ in
                WebViewScriptCaller.JavaScriptEvaluationResult(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { .zero }
        )

        coordinator.setWebView(replacementWebView)
        replacementWebView.navigationDelegate = coordinator
        replacementWebView.uiDelegate = coordinator
#if os(iOS)
        replacementWebView.scrollView.delegate = coordinator
#endif
        coordinator.installScriptCallerBinding(
            for: replacementWebView,
            asyncCaller: { _, _, _, _ in
                WebViewScriptCaller.JavaScriptEvaluationResult(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { .zero }
        )
        XCTAssertNotNil(coordinator.javaScriptBindingToken(for: replacementWebView))
        navigator.nativeLookupHitTesting.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "replacement-segment",
                rects: [CGRect(x: 0, y: 0, width: 20, height: 20)]
            )
        ])

        coordinator.tearDownBindingsForDetachedWebView(detachedWebView)

        XCTAssertTrue(navigator.webView === replacementWebView)
        XCTAssertNotNil(coordinator.javaScriptBindingToken(for: replacementWebView))
        XCTAssertEqual(navigator.nativeLookupHitTesting.targetCount, 1)
        XCTAssertTrue(replacementWebView.navigationDelegate === coordinator)
        XCTAssertTrue(replacementWebView.uiDelegate === coordinator)
        XCTAssertNotNil(replacementWebView.onDidMoveToWindow)
#if os(iOS)
        XCTAssertTrue(replacementWebView.scrollView.delegate === coordinator)
#endif
        XCTAssertNil(detachedWebView.navigationDelegate)
        XCTAssertNil(detachedWebView.uiDelegate)
        XCTAssertNil(detachedWebView.onDidMoveToWindow)
#if os(iOS)
        XCTAssertNil(detachedWebView.scrollView.delegate)
#endif
    }

#if os(iOS)
    func testSnapshotBoundsAdjustmentCancellationPreventsStaleRestoreAfterReuse() throws {
        let sourceWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 10, height: 20),
            configuration: WKWebViewConfiguration()
        )
        let controller = WebViewController(webView: sourceWebView)
        let originalBounds = CGRect(x: 0, y: 0, width: 10, height: 20)
        sourceWebView.bounds = originalBounds

        let firstGeneration = try XCTUnwrap(
            controller.beginSnapshotBoundsAdjustmentIfNeeded(
                for: sourceWebView,
                targetSize: CGSize(width: 320, height: 480),
                shouldAdjust: true
            )
        )
        XCTAssertEqual(sourceWebView.bounds.size, CGSize(width: 320, height: 480))

        controller.cancelPendingSnapshotBoundsAdjustment()
        XCTAssertEqual(sourceWebView.bounds, originalBounds)

        let secondGeneration = try XCTUnwrap(
            controller.beginSnapshotBoundsAdjustmentIfNeeded(
                for: sourceWebView,
                targetSize: CGSize(width: 640, height: 960),
                shouldAdjust: true
            )
        )
        controller.finishSnapshotBoundsAdjustment(firstGeneration, for: sourceWebView)
        XCTAssertEqual(sourceWebView.bounds.size, CGSize(width: 640, height: 960))

        controller.finishSnapshotBoundsAdjustment(secondGeneration, for: sourceWebView)
        XCTAssertEqual(sourceWebView.bounds, originalBounds)

        _ = try XCTUnwrap(
            controller.beginSnapshotBoundsAdjustmentIfNeeded(
                for: sourceWebView,
                targetSize: CGSize(width: 800, height: 1200),
                shouldAdjust: true
            )
        )
        let replacementBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        sourceWebView.bounds = replacementBounds
        controller.cancelPendingSnapshotBoundsAdjustment()
        XCTAssertEqual(sourceWebView.bounds, replacementBounds)

        let finalGeneration = try XCTUnwrap(
            controller.beginSnapshotBoundsAdjustmentIfNeeded(
                for: sourceWebView,
                targetSize: CGSize(width: 900, height: 1400),
                shouldAdjust: true
            )
        )
        let relaidOutBounds = CGRect(x: 0, y: 0, width: 430, height: 932)
        sourceWebView.bounds = relaidOutBounds
        controller.finishSnapshotBoundsAdjustment(finalGeneration, for: sourceWebView)
        XCTAssertEqual(sourceWebView.bounds, relaidOutBounds)
    }

    func testDismantlingAlreadyUnloadedControllerDoesNotTearDownReusedSharedNavigatorWebView() {
        let navigator = WebViewNavigator()
        let outgoingModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let outgoingCoordinator = outgoingModel.makeCoordinator()
        let replacementCaller = WebViewScriptCaller()
        let replacementModel = WebView(
            navigator: navigator,
            state: .constant(.empty),
            scriptCaller: replacementCaller
        )
        let replacementCoordinator = replacementModel.makeCoordinator()
        let reusedWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let outgoingController = WebViewController(webView: reusedWebView)
        outgoingController.isWebViewUnloaded = true

        replacementCoordinator.setWebView(reusedWebView)
        reusedWebView.navigationDelegate = replacementCoordinator
        reusedWebView.uiDelegate = replacementCoordinator
        reusedWebView.scrollView.delegate = replacementCoordinator
        replacementCoordinator.installScriptCallerBinding(
            for: reusedWebView,
            asyncCaller: { _, _, _, _ in
                WebViewScriptCaller.JavaScriptEvaluationResult(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { .zero }
        )

        WebView.dismantleUIViewController(
            outgoingController,
            coordinator: outgoingCoordinator
        )

        XCTAssertTrue(navigator.webView === reusedWebView)
        XCTAssertTrue(reusedWebView.navigationDelegate === replacementCoordinator)
        XCTAssertTrue(reusedWebView.uiDelegate === replacementCoordinator)
        XCTAssertTrue(reusedWebView.scrollView.delegate === replacementCoordinator)
        XCTAssertNotNil(replacementCoordinator.javaScriptBindingToken(for: reusedWebView))
    }
#endif



#if os(iOS)
    func testDetachedScrollCallbacksCannotMutateCurrentScrollState() {
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let currentWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let detachedWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(currentWebView)
        coordinator.lastContentOffset = CGPoint(x: 11, y: 12)
        coordinator.accumulatedScrollOffset = 37
        detachedWebView.scrollView.contentOffset = CGPoint(x: 50, y: 60)

        coordinator.scrollViewWillBeginDragging(detachedWebView.scrollView)
        coordinator.scrollViewDidScroll(detachedWebView.scrollView)
        coordinator.scrollViewDidEndDragging(
            detachedWebView.scrollView,
            willDecelerate: false
        )
        coordinator.scrollViewDidEndDecelerating(detachedWebView.scrollView)

        XCTAssertEqual(coordinator.lastContentOffset, CGPoint(x: 11, y: 12))
        XCTAssertEqual(coordinator.accumulatedScrollOffset, 37)
        XCTAssertTrue(navigator.webView === currentWebView)
    }
#endif

    func testCoordinatorTeardownReleasesExactWebViewDelegates() {
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinator()
        let mountedWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(mountedWebView)
        mountedWebView.navigationDelegate = coordinator
        mountedWebView.uiDelegate = coordinator
#if os(iOS)
        mountedWebView.scrollView.delegate = coordinator
#endif
        navigator.nativeLookupHitTesting.updateTargets([
            WebViewNativeLookupHitTarget(
                elementID: "mounted-segment",
                rects: [CGRect(x: 0, y: 0, width: 20, height: 20)]
            )
        ])

        coordinator.tearDownBindingsForDetachedWebView(mountedWebView)

        XCTAssertNil(mountedWebView.navigationDelegate)
        XCTAssertNil(mountedWebView.uiDelegate)
        XCTAssertEqual(navigator.nativeLookupHitTesting.targetCount, 0)
        XCTAssertNil(mountedWebView.onDidMoveToWindow)
#if os(iOS)
        XCTAssertNil(mountedWebView.scrollView.delegate)
#endif
        XCTAssertNil(navigator.webView)
    }

    func testRealWebViewHostSynchronizesOnlyAfterDelayedBindingAndStopsAfterTeardown() async throws {
        let caller = WebViewScriptCaller()
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty),
            scriptCaller: caller
        )
        let coordinator = webViewModel.makeCoordinator()
        let mountedWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 480),
            configuration: WKWebViewConfiguration()
        )
#if os(macOS)
        let host = WebViewHostNSView(webView: mountedWebView)
        XCTAssertTrue(mountedWebView.superview === host)
#elseif os(iOS)
        let host = WebViewController(webView: mountedWebView)
        host.loadViewIfNeeded()
        XCTAssertTrue(mountedWebView.superview === host.view)
#endif
        let evaluations = JavaScriptEvaluationRecorder()
        var unboundAttempts = [WebViewScriptCaller.UnboundEvaluationAttempt]()
        caller.onUnboundEvaluation = { attempt in
            unboundAttempts.append(attempt)
        }

        let readinessDrivenSynchronization = Task { @MainActor in
            while !caller.hasAsyncCaller {
                await Task.yield()
            }
            guard caller.canEvaluateJavaScript else { return }
            _ = try await caller.evaluateJavaScript("synchronize-reader-dom")
        }

        await Task.yield()
        let scriptsBeforeBinding = await evaluations.recordedScripts()
        XCTAssertEqual(scriptsBeforeBinding, [])
        XCTAssertEqual(unboundAttempts, [])

        coordinator.installScriptCallerBinding(
            for: mountedWebView,
            asyncCaller: { script, _, _, _ in
                await evaluations.record(script)
                return WebViewScriptCaller.JavaScriptEvaluationResult(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { CGPoint(x: 7, y: 8) }
        )

        try await readinessDrivenSynchronization.value
        let scriptsAfterBinding = await evaluations.recordedScripts()
        XCTAssertEqual(scriptsAfterBinding, ["synchronize-reader-dom"])
        XCTAssertEqual(unboundAttempts, [])
        XCTAssertEqual(caller.coordinateOriginInWindow, CGPoint(x: 7, y: 8))

        coordinator.tearDownBindingsForDetachedWebView(mountedWebView)
        XCTAssertNil(caller.coordinateOriginInWindow)
        mountedWebView.removeFromSuperview()
        await Task.yield()

        if caller.canEvaluateJavaScript {
            _ = try await caller.evaluateJavaScript("must-not-run-after-teardown")
        }
        let scriptsAfterTeardown = await evaluations.recordedScripts()
        XCTAssertEqual(scriptsAfterTeardown, ["synchronize-reader-dom"])
        XCTAssertEqual(unboundAttempts, [])
    }


    func testMultiTargetEvaluationCanStopAfterAcceptedResult() async throws {
        let caller = WebViewScriptCaller()
        let state = JavaScriptContinuationState(shouldContinue: true)
        caller.asyncCaller = { _, _, _, _ in
            await MainActor.run {
                state.evaluationCount += 1
            }
            return WebViewScriptCaller.JavaScriptEvaluationResult(["opened": true])
        }

        let results = try await caller.evaluateJavaScriptInMultiTargetFrames(
            "navigation transaction",
            propagatesFrameErrors: true,
            continueWhile: { state.shouldContinue },
            stopAfterResult: { result in
                state.stopEvaluationCount += 1
                return (result as? [String: Any])?["opened"] as? Bool == true
            }
        )

        XCTAssertEqual(state.evaluationCount, 1)
        XCTAssertEqual(state.stopEvaluationCount, 1)
        XCTAssertEqual((results.first as? [String: Any])?["opened"] as? Bool, true)
    }

    func testMultiTargetEvaluationStopsWhenContinuationIsSuperseded() async throws {
        let caller = WebViewScriptCaller()
        let state = JavaScriptContinuationState(shouldContinue: true)
        caller.asyncCaller = { _, _, _, _ in
            await MainActor.run {
                state.evaluationCount += 1
                state.shouldContinue = false
            }
            return WebViewScriptCaller.JavaScriptEvaluationResult("main")
        }

        do {
            _ = try await caller.evaluateJavaScriptInMultiTargetFrames(
                "navigation transaction",
                propagatesFrameErrors: true,
                continueWhile: { state.shouldContinue }
            )
            XCTFail("Expected superseded multi-target evaluation to stop")
        } catch is CancellationError {
            // Expected: the main result cannot authorize later frame evaluation.
        }

        XCTAssertEqual(state.evaluationCount, 1)
    }

    func testMultiTargetEvaluationDoesNotStartWhenContinuationIsAlreadySuperseded() async throws {
        let caller = WebViewScriptCaller()
        let state = JavaScriptContinuationState(shouldContinue: false)
        caller.asyncCaller = { _, _, _, _ in
            await MainActor.run {
                state.evaluationCount += 1
            }
            return WebViewScriptCaller.JavaScriptEvaluationResult("unexpected")
        }

        do {
            _ = try await caller.evaluateJavaScriptInMultiTargetFrames(
                "navigation transaction",
                propagatesFrameErrors: true,
                continueWhile: { state.shouldContinue }
            )
            XCTFail("Expected superseded multi-target evaluation not to start")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(state.evaluationCount, 0)
    }

    func testUnexpectedUnboundEvaluationsInvokeDiagnosticHook() async {
        let caller = WebViewScriptCaller()
        var attempts = [WebViewScriptCaller.UnboundEvaluationAttempt]()
        caller.onUnboundEvaluation = { attempt in
            attempts.append(attempt)
        }

        do {
            _ = try await caller.evaluateJavaScript("unexpected-single")
            XCTFail("Expected an unbound evaluation to throw")
        } catch {
            // The diagnostic attempt below is the behavior under test.
        }

        do {
            _ = try await caller.evaluateJavaScriptInMultiTargetFrames("unexpected-multi")
            XCTFail("Expected an unbound multi-frame evaluation to throw")
        } catch {
            // The diagnostic attempt below is the behavior under test.
        }

        XCTAssertEqual(
            attempts,
            [
                .init(
                    callerID: caller.id,
                    operation: .evaluateJavaScript,
                    script: "unexpected-single"
                ),
                .init(
                    callerID: caller.id,
                    operation: .evaluateJavaScriptInMultiTargetFrames,
                    script: "unexpected-multi"
                )
            ]
        )
    }
}
