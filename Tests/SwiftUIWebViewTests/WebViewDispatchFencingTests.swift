import Foundation
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
private final class DispatchPause {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class DispatchSource {
    let pause = DispatchPause()
    let entered: XCTestExpectation?
    let pauseOn: Int
    let errors: [Int: any Error]
    private(set) var scripts: [String] = []
    init(entered: XCTestExpectation? = nil, pauseOn: Int = 0, errors: [Int: any Error] = [:]) {
        self.entered = entered; self.pauseOn = pauseOn; self.errors = errors
    }
    func call(_ script: String) async throws -> WebViewScriptCaller.JavaScriptEvaluationResult {
        scripts.append(script)
        let index = scripts.count
        if index == pauseOn {
            entered?.fulfill()
            await pause.wait() // Deliberately ignores Task cancellation.
        }
        if let error = errors[index] { throw error }
        return .init(NSString(string: "result-\(index)"))
    }
}

private final class DispatchFrameProbe: NSObject, WKScriptMessageHandler {
    var onMessage: ((WKScriptMessage) -> Void)?
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) { onMessage?(message) }
}

@MainActor
final class WebViewDispatchFencingTests: XCTestCase {
    private enum Route: CaseIterable { case ordinary, required, fanout }
    private enum Change { case cancel, replace, clear, restore }
    private enum Injected: Error, Equatable { case failure }
    private var unsupported: NSError {
        NSError(domain: WKError.errorDomain, code: WKError.javaScriptResultTypeIsUnsupported.rawValue)
    }

    private func provider(_ source: DispatchSource) -> WebViewScriptCaller.AsyncCaller {
        { script, _, _, _ in try await source.call(script) }
    }

    private func invoke(_ caller: WebViewScriptCaller, route: Route,
                        duplicate: Bool = false, strict: Bool = false) async throws {
        switch route {
        case .ordinary:
            _ = try await caller.evaluateJavaScript("window.location.href", duplicateInMultiTargetFrames: duplicate)
        case .required:
            let token = try XCTUnwrap(caller.currentJavaScriptBindingToken)
            _ = try await caller.evaluateJavaScript("window.location.href", duplicateInMultiTargetFrames: duplicate,
                                                    requiring: token)
        case .fanout:
            _ = try await caller.evaluateJavaScriptInMultiTargetFrames("window.location.href", propagatesFrameErrors: strict)
        }
    }

    private func rejected(_ task: Task<Void, any Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await task.value; XCTFail("Obsolete operation returned success", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line) }
    }

    private func interrupted(_ change: Change, route: Route, pauseOn: Int = 1,
                             errors: [Int: any Error] = [:], frame: WKFrameInfo? = nil) async throws {
        let entered = expectation(description: "provider suspended")
        let source = DispatchSource(entered: entered, pauseOn: pauseOn, errors: errors)
        let replacement = DispatchSource()
        let caller = WebViewScriptCaller()
        let original = provider(source)
        caller.asyncCaller = original
        if let frame { caller.addMultiTargetFrame(frame, uuid: "child") }
        let task = Task { try await self.invoke(caller, route: route, duplicate: frame != nil) }
        defer { task.cancel(); source.pause.release() }
        await fulfillment(of: [entered], timeout: 3)
        switch change {
        case .cancel: task.cancel()
        case .replace: caller.asyncCaller = provider(replacement)
        case .clear: caller.asyncCaller = nil
        case .restore: caller.asyncCaller = nil; caller.asyncCaller = original
        }
        source.pause.release()
        await rejected(task)
        XCTAssertEqual(source.scripts.count, pauseOn, "No later retry or frame dispatch may run")
        XCTAssertTrue(replacement.scripts.isEmpty)
    }

    private func childFrame() async throws -> (WKWebView, WKFrameInfo) {
        let entered = expectation(description: "real child frame")
        var child: WKFrameInfo?
        let probe = DispatchFrameProbe()
        probe.onMessage = { message in
            guard !message.frameInfo.isMainFrame, child == nil else { return }
            child = message.frameInfo
            entered.fulfill()
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(probe, name: "dispatchProbe")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        view.loadHTMLString("<iframe srcdoc=\"<script>window.webkit.messageHandlers.dispatchProbe.postMessage('child')</script>\"></iframe>",
                            baseURL: URL(string: "https://example.invalid/dispatch"))
        await fulfillment(of: [entered], timeout: 10)
        configuration.userContentController.removeScriptMessageHandler(forName: "dispatchProbe")
        return (view, try XCTUnwrap(child))
    }

    func testAlreadyCancelledRequestsDoNotInvokeProviderInAnyRoute() async throws {
        for route in Route.allCases {
            let caller = WebViewScriptCaller(), source = DispatchSource()
            caller.asyncCaller = provider(source)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await self.invoke(caller, route: route)
            }
            await rejected(task)
            XCTAssertTrue(source.scripts.isEmpty)
        }
    }

    func testIgnoringProviderCannotReturnSuccessAfterTaskCancellation() async throws {
        for route in Route.allCases { try await interrupted(.cancel, route: route) }
    }

    func testReplacementRejectsResultInEveryRoute() async throws {
        for route in Route.allCases { try await interrupted(.replace, route: route) }
    }

    func testClearingBindingRejectsResultInEveryRoute() async throws {
        for route in Route.allCases { try await interrupted(.clear, route: route) }
    }

    func testRestoringSameProviderDoesNotReviveAnOldInvocation() async throws {
        for route in Route.allCases { try await interrupted(.restore, route: route) }
    }

    func testReplacedInitialUnsupportedResultCannotStartCoercionRetry() async throws {
        for route in [Route.ordinary, .required] {
            try await interrupted(.replace, route: route, errors: [1: unsupported])
        }
    }

    func testCancelledInitialUnsupportedResultCannotStartCoercionRetry() async throws {
        for route in [Route.ordinary, .required] {
            try await interrupted(.cancel, route: route, errors: [1: unsupported])
        }
    }

    func testStaleProviderErrorCannotEscapeAsAnOrdinaryFailure() async throws {
        for route in Route.allCases {
            try await interrupted(.replace, route: route, errors: [1: Injected.failure])
        }
    }

    func testCoercionRetryRechecksCancellationAndBindingAfterSuccess() async throws {
        for route in [Route.ordinary, .required] {
            for change in [Change.cancel, .replace] {
                try await interrupted(change, route: route, pauseOn: 2, errors: [1: unsupported])
            }
        }
    }

    func testReplacementBeforeFanoutDoesNotInvokeRegisteredChild() async throws {
        let (webView, frame) = try await childFrame()
        defer { withExtendedLifetime(webView) {} }
        for route in Route.allCases { try await interrupted(.replace, route: route, frame: frame) }
    }

    func testExplicitPrimaryCancellationDoesNotRunDuplicateFrame() async throws {
        let (webView, frame) = try await childFrame()
        defer { withExtendedLifetime(webView) {} }
        for route in [Route.ordinary, .required] {
            let caller = WebViewScriptCaller(), source = DispatchSource(errors: [1: CancellationError()])
            caller.asyncCaller = provider(source)
            caller.addMultiTargetFrame(frame, uuid: "child")
            await rejected(Task { try await self.invoke(caller, route: route, duplicate: true) })
            XCTAssertEqual(source.scripts.count, 1)
        }
    }

    func testOptionalFrameErrorPolicyNeverSwallowsCancellation() async throws {
        let (webView, frame) = try await childFrame()
        defer { withExtendedLifetime(webView) {} }
        for route in Route.allCases {
            let caller = WebViewScriptCaller(), source = DispatchSource(errors: [2: CancellationError()])
            caller.asyncCaller = provider(source)
            caller.addMultiTargetFrame(frame, uuid: "child")
            await rejected(Task { try await self.invoke(caller, route: route, duplicate: true) })
            XCTAssertEqual(source.scripts.count, 2)
            XCTAssertTrue(caller.frame(forUUID: "child") === frame)
        }
    }

    func testRebindingDuringChildEvaluationRejectsItsResult() async throws {
        let (webView, frame) = try await childFrame()
        defer { withExtendedLifetime(webView) {} }
        for route in Route.allCases { try await interrupted(.replace, route: route, pauseOn: 2, frame: frame) }
    }

    func testUnchangedResultsAndCoercionStillNormalizeStrings() async throws {
        let caller = WebViewScriptCaller(), source = DispatchSource(errors: [1: unsupported])
        caller.asyncCaller = provider(source)
        let value = try await caller.evaluateJavaScript("window.location.href")
        XCTAssertEqual(value as? String, "result-2")
        XCTAssertEqual(source.scripts.count, 2)
        let results = try await caller.evaluateJavaScriptInMultiTargetFrames("plain")
        XCTAssertEqual(results.compactMap { $0 as? String }, ["result-3"])
    }

    func testNonCancellationChildErrorsKeepOptionalAndStrictPolicies() async throws {
        let (webView, frame) = try await childFrame()
        defer { withExtendedLifetime(webView) {} }
        for route in [Route.ordinary, .fanout] {
            let caller = WebViewScriptCaller(), source = DispatchSource(errors: [2: Injected.failure])
            caller.asyncCaller = provider(source)
            caller.addMultiTargetFrame(frame, uuid: "child")
            try await invoke(caller, route: route, duplicate: true)
            XCTAssertEqual(source.scripts.count, 2)
            XCTAssertTrue(caller.frame(forUUID: "child") === frame)
        }
        let caller = WebViewScriptCaller(), source = DispatchSource(errors: [2: Injected.failure])
        caller.asyncCaller = provider(source)
        caller.addMultiTargetFrame(frame, uuid: "child")
        do { try await invoke(caller, route: .fanout, strict: true); XCTFail("Expected original frame error") }
        catch { XCTAssertEqual(error as? Injected, .failure) }
    }

    func testCurrentInvalidFrameErrorStillRetiresItsRegistration() async throws {
        let (webView, frame) = try await childFrame()
        defer { withExtendedLifetime(webView) {} }
        let invalid = NSError(domain: WKError.errorDomain, code: WKError.javaScriptInvalidFrameTarget.rawValue)
        for route in [Route.ordinary, .fanout] {
            let caller = WebViewScriptCaller(), source = DispatchSource(errors: [2: invalid])
            caller.asyncCaller = provider(source)
            caller.addMultiTargetFrame(frame, uuid: "child")
            try await invoke(caller, route: route, duplicate: true)
            XCTAssertNil(caller.frame(forUUID: "child"))
        }
    }
}
