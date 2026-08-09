import XCTest
import WebKit
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

private actor DocumentCallbackTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
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

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private final class TestNavigationDelegate: NSObject, WKNavigationDelegate {
    private let completion: XCTestExpectation
    private var didComplete = false

    init(completion: XCTestExpectation) {
        self.completion = completion
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completeOnce()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
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

@MainActor
final class WebViewScriptCallerTests: XCTestCase {
    func testDefaultLifecycleConfigurationPreservesNavigatorFallbackURL() throws {
        let navigator = WebViewNavigator()
        let fallbackURL = try XCTUnwrap(URL(string: "https://fallback.invalid/reader"))
        navigator.attachFallbackURL = fallbackURL

        _ = WebView(
            navigator: navigator,
            state: .constant(.empty)
        ).makeCoordinator()

        XCTAssertEqual(navigator.attachFallbackURL, fallbackURL)
    }

#if os(iOS)
    func testCancellingSnapshotBoundsAdjustmentRestoresOwnedBounds() throws {
        let originalBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let temporarySize = CGSize(width: 320, height: 640)
        let webView = EnhancedWKWebView(frame: originalBounds, configuration: WKWebViewConfiguration())
        webView.bounds = originalBounds
        let controller = WebViewController(webView: webView)

        XCTAssertNotNil(controller.beginSnapshotBoundsAdjustmentIfNeeded(
            for: webView,
            targetSize: temporarySize,
            shouldAdjust: true
        ))
        XCTAssertEqual(webView.bounds.size, temporarySize)

        controller.cancelPendingSnapshotBoundsAdjustment()

        XCTAssertEqual(webView.bounds, originalBounds)
    }

    func testCancellingSnapshotBoundsAdjustmentPreservesNewerLayout() throws {
        let originalBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let replacementBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let webView = EnhancedWKWebView(frame: originalBounds, configuration: WKWebViewConfiguration())
        webView.bounds = originalBounds
        let controller = WebViewController(webView: webView)

        XCTAssertNotNil(controller.beginSnapshotBoundsAdjustmentIfNeeded(
            for: webView,
            targetSize: CGSize(width: 320, height: 640),
            shouldAdjust: true
        ))
        webView.bounds = replacementBounds

        controller.cancelPendingSnapshotBoundsAdjustment()

        XCTAssertEqual(webView.bounds, replacementBounds)
    }

    func testStaleSnapshotCompletionCannotConsumeNewerAdjustment() throws {
        let firstBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let secondBounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        let webView = EnhancedWKWebView(frame: firstBounds, configuration: WKWebViewConfiguration())
        webView.bounds = firstBounds
        let controller = WebViewController(webView: webView)

        let firstGeneration = try XCTUnwrap(controller.beginSnapshotBoundsAdjustmentIfNeeded(
            for: webView,
            targetSize: CGSize(width: 320, height: 640),
            shouldAdjust: true
        ))
        controller.cancelPendingSnapshotBoundsAdjustment()
        webView.bounds = secondBounds
        let secondGeneration = try XCTUnwrap(controller.beginSnapshotBoundsAdjustmentIfNeeded(
            for: webView,
            targetSize: CGSize(width: 390, height: 844),
            shouldAdjust: true
        ))

        controller.finishSnapshotBoundsAdjustment(
            firstGeneration,
            for: webView,
            ownerMayRestore: false
        )
        XCTAssertEqual(webView.bounds.size, CGSize(width: 390, height: 844))

        controller.finishSnapshotBoundsAdjustment(secondGeneration, for: webView)
        XCTAssertEqual(webView.bounds, secondBounds)
    }
#endif


    func testReplacingFrameUUIDRemovesOldCanonicalDocumentAlias() async throws {
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
        webView.loadHTMLString(
            "<iframe srcdoc=\"<script>window.webkit.messageHandlers.frameProbe.postMessage('ready')</script>\"></iframe>",
            baseURL: URL(string: "https://example.com/container.xhtml")
        )

        await fulfillment(of: [frameExpectation], timeout: 3)
        let frame = try XCTUnwrap(childFrame)
        let caller = WebViewScriptCaller()
        let originalURL = URL(string: "ebook://book/original.xhtml")!
        let replacementURL = URL(string: "ebook://book/replacement.xhtml")!

        XCTAssertTrue(caller.addMultiTargetFrame(
            frame,
            uuid: "runtime-frame",
            canonicalURL: originalURL
        ))
        XCTAssertEqual(caller.exactFrame(
            forUUID: "runtime-frame",
            documentURL: originalURL
        ), frame)
        XCTAssertNil(caller.exactFrame(
            forUUID: "runtime-frame",
            documentURL: replacementURL
        ))
        _ = caller.addMultiTargetFrame(
            frame,
            uuid: "runtime-frame",
            canonicalURL: replacementURL
        )

        XCTAssertNil(caller.exactFrame(for: originalURL))
        XCTAssertEqual(caller.exactFrame(for: replacementURL), frame)
        XCTAssertNil(caller.frameForRegisteredIdentity(
            uuid: "runtime-frame",
            documentURL: originalURL
        ))
        XCTAssertEqual(caller.frameForRegisteredIdentity(
            uuid: "runtime-frame",
            documentURL: replacementURL
        ), frame)
    }

    func testMutationGenerationGateRejectsSupersededPageExtraction() {
        var gate = WebViewMutationGenerationGate()
        let firstGeneration = gate.begin()
        XCTAssertTrue(gate.accepts(firstGeneration))

        let replacementGeneration = gate.begin()
        XCTAssertFalse(gate.accepts(firstGeneration))
        XCTAssertTrue(gate.accepts(replacementGeneration))

        gate.invalidate()
        XCTAssertFalse(gate.accepts(replacementGeneration))
    }

    func testReaderDocumentSummaryWaitsForFontGate() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 430, height: 932),
            configuration: configuration
        )
        let loadExpectation = expectation(description: "reader summary fixture loaded")
        let navigationDelegate = TestNavigationDelegate(completion: loadExpectation)
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString(
            """
            <!doctype html>
            <html data-mnb-reader-render-ready="1" data-mnb-font-pending="1">
            <head><title>Reader Summary</title></head>
            <body><main id="reader-content"><p>本文</p></main></body>
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
        XCTAssertEqual(pendingSummary["documentURL"] as? String, "https://example.com/reader-summary")

        try await webView.evaluateJavaScript("delete document.documentElement.dataset.mnbFontPending")
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
        let navigationDelegate = TestNavigationDelegate(completion: loadExpectation)
        webView.navigationDelegate = navigationDelegate
        let generation = UUID()
        webView.loadHTMLString(
            """
            <!doctype html>
            <html
                data-mnb-reader-render-ready="1"
                data-mnb-reader-render-generation="\(generation.uuidString)"
            >
            <body><main id="reader-content"><p>本文</p></main></body>
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

    func testWebViewUnloadTransactionRequiresExactOwnersAndRejectsLateCompletion() throws {
        let controller = NSObject()
        let originalWebView = NSObject()
        let replacementWebView = NSObject()
        let pool = NSObject()
        let replacementPool = NSObject()
        var gate = WebViewUnloadTransactionGate()
        let originalGeneration = try XCTUnwrap(gate.begin(
            controllerID: ObjectIdentifier(controller),
            webViewID: ObjectIdentifier(originalWebView),
            poolID: ObjectIdentifier(pool)
        ))

        XCTAssertTrue(gate.accepts(
            originalGeneration,
            controllerID: ObjectIdentifier(controller),
            webViewID: ObjectIdentifier(originalWebView),
            poolID: ObjectIdentifier(pool)
        ))
        XCTAssertFalse(gate.accepts(
            originalGeneration,
            controllerID: ObjectIdentifier(controller),
            webViewID: ObjectIdentifier(replacementWebView),
            poolID: ObjectIdentifier(pool)
        ))
        XCTAssertFalse(gate.accepts(
            originalGeneration,
            controllerID: ObjectIdentifier(controller),
            webViewID: ObjectIdentifier(originalWebView),
            poolID: ObjectIdentifier(replacementPool)
        ))
        XCTAssertNil(gate.begin(
            controllerID: ObjectIdentifier(controller),
            webViewID: ObjectIdentifier(replacementWebView),
            poolID: ObjectIdentifier(pool)
        ))
        gate.cancel()
        let replacementGeneration = try XCTUnwrap(gate.begin(
            controllerID: ObjectIdentifier(controller),
            webViewID: ObjectIdentifier(replacementWebView),
            poolID: ObjectIdentifier(pool)
        ))
        XCTAssertFalse(gate.finish(
            originalGeneration,
            controllerID: ObjectIdentifier(controller),
            webViewID: ObjectIdentifier(originalWebView),
            poolID: ObjectIdentifier(pool)
        ))
        XCTAssertTrue(gate.finish(
            replacementGeneration,
            controllerID: ObjectIdentifier(controller),
            webViewID: ObjectIdentifier(replacementWebView),
            poolID: ObjectIdentifier(pool)
        ))
    }

    func testRegisteredReturnOwnerRejectsOtherWebViewsAndLaterPools() {
        let navigator = WebViewNavigator()
        let model = WebView(navigator: navigator, state: .constant(.empty))
        let coordinator = model.makeCoordinator()
        let laterPool = WebViewPool(warmUpCount: 0, keepAliveCount: 1)
        let ownedWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 640),
            configuration: WKWebViewConfiguration()
        )
        let unrelatedWebView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 640),
            configuration: WKWebViewConfiguration()
        )
        coordinator.registerReturnOwner(for: ownedWebView, pool: nil)
        coordinator.webViewPool = laterPool

        XCTAssertNil(coordinator.returnPool(for: ownedWebView))
        XCTAssertNil(coordinator.returnPool(for: unrelatedWebView))
        coordinator.releaseUnpooledWebViewOwner(ownedWebView)
        XCTAssertTrue(coordinator.returnPool(for: ownedWebView) === laterPool)
    }

    func testRegisteredReturnOwnerRetainsOriginatingPoolAcrossConfigurationReplacement() {
        let navigator = WebViewNavigator()
        let model = WebView(navigator: navigator, state: .constant(.empty))
        let coordinator = model.makeCoordinator()
        var originalPool: WebViewPool? = WebViewPool(warmUpCount: 0, keepAliveCount: 0)
        let retainedOriginalPool = WeakReference(originalPool)
        let replacementPool = WebViewPool(warmUpCount: 0, keepAliveCount: 1)
        let webView = originalPool!.dequeue {
            EnhancedWKWebView(
                frame: CGRect(x: 0, y: 0, width: 320, height: 640),
                configuration: WKWebViewConfiguration()
            )
        }
        coordinator.registerReturnOwner(for: webView, pool: originalPool)
        coordinator.webViewPool = replacementPool

        originalPool = nil
        XCTAssertNotNil(retainedOriginalPool.value)
        XCTAssertTrue(coordinator.returnPool(for: webView) === retainedOriginalPool.value)
        XCTAssertTrue(coordinator.returnWebView(
            webView,
            to: retainedOriginalPool.value!,
            resetURL: nil
        ))
        XCTAssertNil(retainedOriginalPool.value)
        XCTAssertEqual(replacementPool.retainedCount, 0)
    }

#if os(iOS)
    func testDismantleTerminalizesLifecycleBeforeReturningWebView() {
        let navigator = WebViewNavigator()
        let pool = WebViewPool(warmUpCount: 0, keepAliveCount: 1)
        let model = WebView(
            navigator: navigator,
            state: .constant(.empty),
            webViewPool: pool,
            lifecycleConfig: WebViewLifecycleConfig(autoUnloadOnDisappear: true)
        )
        let coordinator = model.makeCoordinator()
        let webView = pool.dequeue {
            EnhancedWKWebView(
                frame: CGRect(x: 0, y: 0, width: 320, height: 640),
                configuration: WKWebViewConfiguration()
            )
        }
        coordinator.registerReturnOwner(for: webView, pool: pool)
        let controller = WebViewController(webView: webView)
        controller.onViewDidAppear = {}
        controller.onViewWillDisappear = {}
        controller.onViewDidDisappear = {}
        controller.onWillAttachToParent = {}
        controller.onDidDetachFromParent = {}

        WebView.dismantleUIViewController(controller, coordinator: coordinator)

        XCTAssertTrue(controller.isWebViewUnloaded)
        XCTAssertNil(controller.onViewDidAppear)
        XCTAssertNil(controller.onViewWillDisappear)
        XCTAssertNil(controller.onViewDidDisappear)
        XCTAssertNil(controller.onWillAttachToParent)
        XCTAssertNil(controller.onDidDetachFromParent)
        XCTAssertEqual(pool.leasedCount, 0)
        XCTAssertEqual(pool.retainedCount, 1)
    }

    func testHierarchyLifecycleWaitsForDetachAndReattachCanCancel() {
        let webView = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 640),
            configuration: WKWebViewConfiguration()
        )
        let controller = WebViewController(webView: webView)
        var lifecycleEvents = [String]()
        controller.onWillAttachToParent = { lifecycleEvents.append("willAttach") }
        controller.onDidDetachFromParent = { lifecycleEvents.append("didDetach") }

        controller.willMove(toParent: nil)
        XCTAssertTrue(lifecycleEvents.isEmpty)
        controller.didMove(toParent: nil)
        XCTAssertEqual(lifecycleEvents, ["didDetach"])
        controller.willMove(toParent: UIViewController())
        XCTAssertEqual(lifecycleEvents, ["didDetach", "willAttach"])
    }
#endif

    func testObservedURLPublicationRequiresCurrentUnpublishedURL() throws {
        let publishedURL = try XCTUnwrap(URL(string: "https://example.com/old"))
        let currentURL = try XCTUnwrap(URL(string: "https://example.com/current"))
        let staleURL = try XCTUnwrap(URL(string: "https://example.com/stale"))

        XCTAssertTrue(WebViewCoordinator.shouldPublishObservedURL(
            currentURL,
            currentWebViewURL: currentURL,
            publishedURL: publishedURL
        ))
        XCTAssertFalse(WebViewCoordinator.shouldPublishObservedURL(
            staleURL,
            currentWebViewURL: currentURL,
            publishedURL: publishedURL
        ))
        XCTAssertFalse(WebViewCoordinator.shouldPublishObservedURL(
            currentURL,
            currentWebViewURL: currentURL,
            publishedURL: currentURL
        ))
        XCTAssertTrue(WebViewCoordinator.shouldPublishObservedURL(
            currentURL,
            currentWebViewURL: currentURL,
            publishedURL: currentURL,
            hasHistoryStateChange: true
        ))
        XCTAssertFalse(WebViewCoordinator.shouldPublishObservedURL(
            currentURL,
            currentWebViewURL: currentURL,
            publishedURL: publishedURL,
            isProvisionallyNavigating: true
        ))
    }

    func testDocumentCallbackInvalidationCancelsWorkAndSettlesOnce() async {
        let gate = DocumentCallbackTestGate()
        let started = expectation(description: "callback started")
        var cancellationCount = 0
        let task = Task {
            started.fulfill()
            await gate.wait()
        }
        await fulfillment(of: [started], timeout: 1)
        var pendingTasks = [
            UUID(): WebViewPendingDocumentCallbackTask(
                task: task,
                cancellationHandler: { @MainActor in cancellationCount += 1 }
            )
        ]

        cancelPendingWebViewDocumentCallbackTasks(&pendingTasks)
        cancelPendingWebViewDocumentCallbackTasks(&pendingTasks)
        await gate.release()
        await task.value

        XCTAssertTrue(pendingTasks.isEmpty)
        XCTAssertEqual(cancellationCount, 1)
    }

    func testComposedHandlersStopAfterDocumentCancellation() async {
        let gate = DocumentCallbackTestGate()
        let started = expectation(description: "first handler started")
        let recorder = JavaScriptEvaluationRecorder()
        let task = Task {
            await WebViewMessageHandlers.runComposedHandlers(
                first: { _ in
                    started.fulfill()
                    await gate.wait()
                },
                second: { value in
                    await recorder.record(value)
                },
                message: "second handler"
            )
        }

        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await gate.release()
        await task.value

        let recordedScripts = await recorder.recordedScripts()
        XCTAssertTrue(recordedScripts.isEmpty)
    }

    func testDocumentContextRejectsReplacementAndNewNavigationGeneration() {
        let navigator = WebViewNavigator()
        let coordinator = WebView(navigator: navigator, state: .constant(.empty)).makeCoordinator()
        let firstWebView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let replacementWebView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        coordinator.setWebView(firstWebView)
        coordinator.webView(firstWebView, didCommit: nil)
        let firstContext = coordinator.captureDocumentCallbackContext(for: firstWebView)
        XCTAssertNotNil(firstContext)

        coordinator.setWebView(replacementWebView)
        XCTAssertFalse(firstContext.map(coordinator.ownsDocumentCallbackContext) ?? true)
        coordinator.webView(replacementWebView, didCommit: nil)
        let replacementContext = coordinator.captureDocumentCallbackContext(for: replacementWebView)
        XCTAssertNotNil(replacementContext)

        coordinator.webView(replacementWebView, didStartProvisionalNavigation: nil)
        XCTAssertFalse(replacementContext.map(coordinator.ownsDocumentCallbackContext) ?? true)
    }

    func testDetachingCurrentWebViewDoesNotCancelPendingReplacement() {
        let navigator = WebViewNavigator()
        let coordinator = WebView(navigator: navigator, state: .constant(.empty)).makeCoordinator()
        let currentWebView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let replacementWebView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        coordinator.setWebView(currentWebView)
        let generation = coordinator.scheduleWebViewBinding(
            replacementWebView,
            paginationReason: "test-replacement"
        )
        coordinator.tearDownBindingsForDetachedWebView(currentWebView)

        XCTAssertTrue(coordinator.completeScheduledWebViewBinding(
            replacementWebView,
            generation: generation,
            paginationReason: "test-replacement"
        ))
        XCTAssertTrue(navigator.webView === replacementWebView)
    }

    func testScheduledWebViewBindingRejectsSupersededGeneration() {
        let navigator = WebViewNavigator()
        let coordinator = WebView(navigator: navigator, state: .constant(.empty)).makeCoordinator()
        let firstWebView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let replacementWebView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        let firstGeneration = coordinator.scheduleWebViewBinding(
            firstWebView,
            paginationReason: "first"
        )
        let replacementGeneration = coordinator.scheduleWebViewBinding(
            replacementWebView,
            paginationReason: "replacement"
        )

        XCTAssertFalse(coordinator.completeScheduledWebViewBinding(
            firstWebView,
            generation: firstGeneration,
            paginationReason: "first"
        ))
        XCTAssertTrue(coordinator.completeScheduledWebViewBinding(
            replacementWebView,
            generation: replacementGeneration,
            paginationReason: "replacement"
        ))
        XCTAssertTrue(navigator.webView === replacementWebView)
    }

    func testPendingReplacementSuspendsOutgoingDocumentCallbacks() {
        let navigator = WebViewNavigator()
        let coordinator = WebView(navigator: navigator, state: .constant(.empty)).makeCoordinator()
        let currentWebView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let replacementWebView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        coordinator.setWebView(currentWebView)
        coordinator.webView(currentWebView, didCommit: nil)
        let currentContext = coordinator.captureDocumentCallbackContext(for: currentWebView)
        XCTAssertNotNil(currentContext)

        coordinator.scheduleWebViewBinding(
            replacementWebView,
            paginationReason: "replacement"
        )

        XCTAssertNil(coordinator.captureDocumentCallbackContext(for: currentWebView))
        XCTAssertFalse(currentContext.map(coordinator.ownsDocumentCallbackContext) ?? true)
    }

    func testProvisionalFailureReactivatesSurvivingCommittedDocument() {
        let navigator = WebViewNavigator()
        var disposition: WebViewNavigationFailureDisposition?
        let coordinator = WebView(
            navigator: navigator,
            state: .constant(.empty),
            onNavigationFailedWithDisposition: { _, value in disposition = value }
        ).makeCoordinator()
        let webView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        coordinator.setWebView(webView)
        coordinator.webView(webView, didCommit: nil)
        coordinator.webView(webView, didStartProvisionalNavigation: nil)
        coordinator.webView(
            webView,
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        )

        XCTAssertEqual(disposition, .preservedCommittedDocument)
        XCTAssertNotNil(coordinator.captureDocumentCallbackContext(for: webView))
    }

    func testInitialProvisionalFailureRemainsTerminal() {
        let navigator = WebViewNavigator()
        var disposition: WebViewNavigationFailureDisposition?
        let coordinator = WebView(
            navigator: navigator,
            state: .constant(.empty),
            onNavigationFailedWithDisposition: { _, value in disposition = value }
        ).makeCoordinator()
        let webView = EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        coordinator.setWebView(webView)
        coordinator.webView(webView, didStartProvisionalNavigation: nil)
        coordinator.webView(
            webView,
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        )

        XCTAssertEqual(disposition, .terminal)
        XCTAssertNil(coordinator.captureDocumentCallbackContext(for: webView))
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
            snapshotCapture: nil
        )
        caller.installBinding(
            ownedBy: activeOwnerID,
            asyncCaller: { _, _, _, _ in
                WebViewScriptCaller.JavaScriptEvaluationResult("active")
            },
            unsafeCaller: { _, _, _ in },
            snapshotCapture: nil
        )

        XCTAssertFalse(caller.clearBinding(ownedBy: staleOwnerID))
        XCTAssertTrue(caller.canEvaluateJavaScript)
        XCTAssertNotNil(caller.unsafeCaller)
        let activeValue = try await caller.evaluateJavaScript("value") as? String
        XCTAssertEqual(activeValue, "active")

        XCTAssertTrue(caller.clearBinding(ownedBy: activeOwnerID))
        XCTAssertFalse(caller.canEvaluateJavaScript)
        XCTAssertNil(caller.unsafeCaller)
    }

    func testBindingScopedEvaluationCancelsAfterCallerIsRebound() async throws {
        let caller = WebViewScriptCaller()
        let originalOwnerID = UUID()
        let replacementOwnerID = UUID()
        let evaluationStarted = expectation(description: "Original binding evaluation started")
        let evaluationGate = DocumentCallbackTestGate()

        caller.installBinding(
            ownedBy: originalOwnerID,
            asyncCaller: { _, _, _, _ in
                evaluationStarted.fulfill()
                await evaluationGate.wait()
                return WebViewScriptCaller.JavaScriptEvaluationResult("stale")
            },
            unsafeCaller: nil,
            snapshotCapture: nil
        )
        let originalBindingToken = try XCTUnwrap(caller.currentJavaScriptBindingToken)
        let evaluation = Task { @MainActor in
            _ = try await caller.evaluateJavaScript(
                "delayed-value",
                requiring: originalBindingToken
            )
        }

        await fulfillment(of: [evaluationStarted], timeout: 2)
        caller.installBinding(
            ownedBy: replacementOwnerID,
            asyncCaller: { _, _, _, _ in
                WebViewScriptCaller.JavaScriptEvaluationResult("replacement")
            },
            unsafeCaller: nil,
            snapshotCapture: nil
        )
        await evaluationGate.release()

        do {
            _ = try await evaluation.value
            XCTFail("Expected the replaced binding evaluation to be cancelled")
        } catch is CancellationError {
            // Expected: the suspended operation cannot complete under the replacement binding.
        }
    }

    func testNativeLookupHitPreservesPublishingBindingToken() throws {
        let caller = WebViewScriptCaller()
        caller.installBinding(
            ownedBy: UUID(),
            asyncCaller: { _, _, _, _ in
                WebViewScriptCaller.JavaScriptEvaluationResult(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil
        )
        let bindingToken = try XCTUnwrap(caller.currentJavaScriptBindingToken)
        let target = WebViewNativeLookupHitTarget(
            elementID: "term",
            rects: [CGRect(x: 0, y: 0, width: 20, height: 20)],
            javaScriptBindingToken: bindingToken
        )
        let store = WebViewNativeLookupHitTestStore()
        var receivedToken: WebViewScriptCaller.JavaScriptBindingToken?
        store.onHit = { receivedToken = $0.javaScriptBindingToken }

        store.updateTargets([target])
        XCTAssertTrue(store.handleTap(at: CGPoint(x: 10, y: 10)))
        XCTAssertEqual(receivedToken, bindingToken)
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
            snapshotCapture: nil
        )

        try await readinessDrivenSynchronization.value
        let scriptsAfterBinding = await evaluations.recordedScripts()
        XCTAssertEqual(scriptsAfterBinding, ["synchronize-reader-dom"])
        XCTAssertEqual(unboundAttempts, [])

        coordinator.tearDownBindingsForDetachedWebView(mountedWebView)
        mountedWebView.removeFromSuperview()
        await Task.yield()

        if caller.canEvaluateJavaScript {
            _ = try await caller.evaluateJavaScript("must-not-run-after-teardown")
        }
        let scriptsAfterTeardown = await evaluations.recordedScripts()
        XCTAssertEqual(scriptsAfterTeardown, ["synchronize-reader-dom"])
        XCTAssertEqual(unboundAttempts, [])
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
