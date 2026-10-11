import Foundation
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
private final class DocumentEpochSource {
    typealias Result = WebViewScriptCaller.JavaScriptEvaluationResult
    var handler: ((WKFrameInfo?, Int) async throws -> Result)?
    private(set) var calls = 0
    func call(_ frame: WKFrameInfo?) async throws -> Result {
        calls += 1
        if let handler { return try await handler(frame, calls) }
        return .init("value-\(calls)")
    }
}

private final class DocumentEpochFrameProbe: NSObject, WKScriptMessageHandler {
    var receive: ((WKScriptMessage) -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive?(message)
    }
}

@MainActor
final class WebViewDocumentEpochEvaluationTests: XCTestCase {
    private enum Route: CaseIterable { case primary, required, duplicate, optional, strict }
    private enum Failure: Error { case ordinary }
    private struct Fixture {
        let navigator: WebViewNavigator
        let caller: WebViewScriptCaller
        let coordinator: WebViewCoordinator
        let view: EnhancedWKWebView
        let source: DocumentEpochSource
    }

    private func fixture(committed: Bool = true) -> Fixture {
        let navigator = WebViewNavigator(), caller = WebViewScriptCaller()
        let model = WebView(navigator: navigator, state: .constant(.empty))
        let coordinator = model.makeCoordinatorForTesting()
        let view = EnhancedWKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: WKWebViewConfiguration())
        let source = DocumentEpochSource()
        coordinator.updateScriptCaller(caller)
        coordinator.setWebView(view)
        if committed { coordinator.webView(view, didCommit: nil) }
        coordinator.installScriptCallerBinding(for: view,
            asyncCaller: { _, _, frame, _ in try await source.call(frame) },
            unsafeCaller: nil, snapshotCapture: nil)
        return .init(navigator: navigator, caller: caller, coordinator: coordinator, view: view, source: source)
    }

    private func invoke(_ caller: WebViewScriptCaller, route: Route) async throws {
        switch route {
        case .primary, .duplicate:
            _ = try await caller.evaluateJavaScript("window.location.href", duplicateInMultiTargetFrames: route == .duplicate)
        case .required:
            let token = try XCTUnwrap(caller.currentJavaScriptBindingToken)
            _ = try await caller.evaluateJavaScript("window.location.href", requiring: token)
        case .optional, .strict:
            _ = try await caller.evaluateJavaScriptInMultiTargetFrames("collect", propagatesFrameErrors: route == .strict)
        }
    }

    private func expectCancellation(_ operation: () async throws -> Void,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Obsolete document returned success", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line) }
    }

    private func changesDuringPrimary(_ change: @escaping (Fixture) -> Void,
                                      error: NSError? = nil) async throws {
        for route in Route.allCases {
            let f = fixture()
            defer { f.source.handler = nil; f.coordinator.tearDownBindingsForDetachedWebView(f.view) }
            let before = try XCTUnwrap(f.caller.currentJavaScriptBindingToken)
            f.source.handler = { _, _ in
                change(f)
                await Task.yield()
                if let error { throw error }
                return .init("old-document")
            }
            await expectCancellation { try await self.invoke(f.caller, route: route) }
            XCTAssertEqual(f.source.calls, 1, "No obsolete coercion/fanout dispatch")
            XCTAssertTrue(f.caller.canEvaluateJavaScript, "Navigation does not unmount the binding")
            XCTAssertNotEqual(f.caller.currentJavaScriptBindingToken, before)
        }
    }

    func testSameWebViewCommitRejectsPrimaryResultInEveryRoute() async throws {
        try await changesDuringPrimary { $0.coordinator.webView($0.view, didCommit: nil) }
    }

    func testProvisionalNavigationRejectsInFlightEvaluationInEveryRoute() async throws {
        try await changesDuringPrimary { $0.coordinator.webView($0.view, didStartProvisionalNavigation: nil) }
    }

    func testPreservedDocumentAfterProvisionalFailureDoesNotReviveOldToken() async throws {
        try await changesDuringPrimary { f in
            f.coordinator.webView(f.view, didStartProvisionalNavigation: nil)
            f.coordinator.webView(f.view, didFailProvisionalNavigation: nil, withError: Failure.ordinary)
        }
    }

    func testProcessTerminationRejectsInFlightEvaluationInEveryRoute() async throws {
        try await changesDuringPrimary { $0.coordinator.webViewWebContentProcessDidTerminate($0.view) }
    }

    func testTerminalNavigationFailureRejectsInFlightEvaluationInEveryRoute() async throws {
        try await changesDuringPrimary { $0.coordinator.webView($0.view, didFail: nil, withError: Failure.ordinary) }
    }

    func testStaleUnsupportedErrorCannotStartCoercionRetry() async throws {
        try await changesDuringPrimary({ $0.coordinator.webView($0.view, didCommit: nil) },
            error: NSError(domain: WKError.errorDomain, code: WKError.javaScriptResultTypeIsUnsupported.rawValue))
    }

    func testNavigationDuringCoercionRetryCannotReturnOldValue() async throws {
        let f = fixture()
        defer { f.source.handler = nil; f.coordinator.tearDownBindingsForDetachedWebView(f.view) }
        f.source.handler = { _, call in
            if call == 1 {
                throw NSError(domain: WKError.errorDomain, code: WKError.javaScriptResultTypeIsUnsupported.rawValue)
            }
            f.coordinator.webView(f.view, didCommit: nil)
            await Task.yield()
            return .init("stale-coercion")
        }
        await expectCancellation { try await self.invoke(f.caller, route: .primary) }
        XCTAssertEqual(f.source.calls, 2)
    }

    private func childFrames(in view: WKWebView) async throws -> [WKFrameInfo] {
        let received = expectation(description: "two real child frames")
        received.expectedFulfillmentCount = 2
        var frames: [String: WKFrameInfo] = [:]
        let probe = DocumentEpochFrameProbe()
        probe.receive = { message in
            guard let id = message.body as? String, frames[id] == nil else { return }
            frames[id] = message.frameInfo
            received.fulfill()
        }
        view.configuration.userContentController.add(probe, name: "documentEpoch")
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "documentEpoch") }
        view.loadHTMLString("""
            <iframe srcdoc="<script>window.webkit.messageHandlers.documentEpoch.postMessage('one')</script>"></iframe>
            <iframe srcdoc="<script>window.webkit.messageHandlers.documentEpoch.postMessage('two')</script>"></iframe>
            """, baseURL: URL(string: "https://example.invalid/document-epoch"))
        await fulfillment(of: [received], timeout: 10)
        return [try XCTUnwrap(frames["one"]), try XCTUnwrap(frames["two"])]
    }

    func testLaterChildNavigationRejectsWholeOptionalAndStrictAggregate() async throws {
        for strict in [false, true] {
            let f = fixture()
            defer { f.source.handler = nil; f.coordinator.tearDownBindingsForDetachedWebView(f.view) }
            let frames = try await childFrames(in: f.view)
            for (i, frame) in frames.enumerated() { f.caller.addMultiTargetFrame(frame, uuid: "\(i)") }
            f.source.handler = { _, call in
                if call == 3 { f.coordinator.webView(f.view, didCommit: nil) }
                await Task.yield()
                return .init("old-\(call)")
            }
            await expectCancellation { try await self.invoke(f.caller, route: strict ? .strict : .optional) }
            XCTAssertEqual(f.source.calls, 3)
        }
    }

    func testStaleInvalidFrameErrorCannotRetireNewDocumentRegistration() async throws {
        let f = fixture()
        defer { f.source.handler = nil; f.coordinator.tearDownBindingsForDetachedWebView(f.view) }
        let frame = try await childFrames(in: f.view)[0]
        f.caller.addMultiTargetFrame(frame, uuid: "original")
        f.source.handler = { _, _ in
            f.coordinator.webView(f.view, didCommit: nil)
            // Reusing the identical handle is adversarial: only the epoch can
            // distinguish this replacement registration from the old operation.
            f.caller.addMultiTargetFrame(frame, uuid: "successor")
            await Task.yield()
            throw NSError(domain: WKError.errorDomain, code: WKError.javaScriptInvalidFrameTarget.rawValue)
        }
        await expectCancellation { _ = try await f.caller.evaluateJavaScript("collect", in: frame) }
        XCTAssertTrue(f.caller.frame(forUUID: "successor") === frame)
    }

    func testRequiredTokenFromPriorDocumentRejectsBeforeDispatch() async throws {
        let f = fixture()
        defer { f.coordinator.tearDownBindingsForDetachedWebView(f.view) }
        let token = try XCTUnwrap(f.caller.currentJavaScriptBindingToken)
        f.coordinator.webView(f.view, didCommit: nil)
        await expectCancellation { _ = try await f.caller.evaluateJavaScript("collect", requiring: token) }
        XCTAssertEqual(f.source.calls, 0)
    }

    func testFreshRequestAfterCommitUsesExistingBinding() async throws {
        let f = fixture()
        defer { f.coordinator.tearDownBindingsForDetachedWebView(f.view) }
        try await invoke(f.caller, route: .optional)
        f.coordinator.webView(f.view, didCommit: nil)
        try await invoke(f.caller, route: .strict)
        XCTAssertEqual(f.source.calls, 2)
    }

    func testEarlyDocumentScriptsRemainAvailableBeforeCommit() async throws {
        let f = fixture(committed: false)
        defer { f.coordinator.tearDownBindingsForDetachedWebView(f.view) }
        try await invoke(f.caller, route: .primary)
        XCTAssertEqual(f.source.calls, 1)
    }

    func testFrameRegistryClearIsNotADocumentChange() async throws {
        let f = fixture()
        defer { f.coordinator.tearDownBindingsForDetachedWebView(f.view) }
        let token = try XCTUnwrap(f.caller.currentJavaScriptBindingToken)
        f.caller.removeAllMultiTargetFrames()
        XCTAssertEqual(f.caller.currentJavaScriptBindingToken, token)
        _ = try await f.caller.evaluateJavaScript("collect", requiring: token)
    }
}
