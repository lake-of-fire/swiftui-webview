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
