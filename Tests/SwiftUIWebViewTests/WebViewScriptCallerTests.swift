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

@MainActor
final class WebViewScriptCallerTests: XCTestCase {
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
