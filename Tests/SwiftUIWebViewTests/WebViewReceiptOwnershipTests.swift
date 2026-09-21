import Foundation
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
private final class ReceiptOwnershipGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class ReceiptOwnershipState {
    var lifetime = 1
    var captures = 0
    var received: [Int] = []
    var committed: [Int] = []
}

/// These use the production coordinator and actual WKScriptMessage delivery.
/// Keep the original two-method negative-control suite unchanged: its workflow
/// restores only the old scheduler and verifies assertion failures, not timeouts.
@MainActor
final class WebViewReceiptOwnershipTests: XCTestCase {
    func testOrdinaryStaleReceiptRejectsWhileFreshLifetimeSucceeds() async throws {
        try await assertFreshSuccess(brokerDeferred: false)
    }

    func testBrokerDeferredStaleReceiptRejectsWhileFreshLifetimeSucceeds() async throws {
        try await assertFreshSuccess(brokerDeferred: true)
    }

    private func assertFreshSuccess(brokerDeferred: Bool) async throws {
        let name = uniqueName()
        let key = "test." + name
        let state = ReceiptOwnershipState()
        let first = expectation(description: "old event delivered")
        let fresh = expectation(description: "fresh event delivered")
        WebViewMessageReceiptCapture.register(key: key) { [weak state] receipt in
            guard receipt.name == name, let state else { return nil }
            state.captures += 1
            let observed = state.lifetime
            if state.captures == 1 { state.lifetime = 2 }
            return observed
        }
        let handler: @Sendable (WebViewMessage) async -> Void = { @MainActor _ in
            let observed: Int? = WebViewMessageReceiptContext.evidence?.value(for: key)
            if let observed {
                state.received.append(observed)
                // Application admission can reject A without disabling B.
                if observed == state.lifetime { state.committed.append(observed) }
            }
            if state.captures == 1 { first.fulfill() } else { fresh.fulfill() }
        }
        var handlers = WebViewMessageHandlers([(name, handler)])
        if brokerDeferred { handlers = handlers.acceptingTrustedUserAction(name) }
        try await withWebView(name: name, handlers: handlers) { view in
            view.loadHTMLString(htmlPosting(name: name, body: "old"), baseURL: testURL)
            await fulfillment(of: [first], timeout: 10)
            _ = try await view.evaluateJavaScript(
                "window.webkit.messageHandlers.\(name).postMessage('fresh'); true"
            )
            await fulfillment(of: [fresh], timeout: 10)
            XCTAssertEqual(state.received, [1, 2])
            XCTAssertEqual(state.committed, [2], "Rejecting every event is not an ownership repair")
            XCTAssertEqual(state.captures, 2, "Deferral must not recapture either message")
        }
        XCTAssertNil(WebViewMessageReceiptContext.evidence)
    }

    func testConcurrentSameURLWebViewsKeepDistinctEvidenceAcrossSuspension() async throws {
        let names = [uniqueName(), uniqueName()]
        let key = "test." + uniqueName()
        let entered = expectation(description: "both handlers suspended")
        entered.expectedFulfillmentCount = 2
        let finished = expectation(description: "both handlers resumed")
        finished.expectedFulfillmentCount = 2
        let gate = ReceiptOwnershipGate()
        defer { gate.release() }
        WebViewMessageReceiptCapture.register(key: key) { receipt in
            names.contains(receipt.name) ? receipt.name : nil
        }
        func handlers(_ name: String) -> WebViewMessageHandlers {
            let handler: @Sendable (WebViewMessage) async -> Void = { @MainActor _ in
                let before: String? = WebViewMessageReceiptContext.evidence?.value(for: key)
                entered.fulfill()
                await gate.wait()
                let after: String? = WebViewMessageReceiptContext.evidence?.value(for: key)
                XCTAssertEqual(before, name)
                XCTAssertEqual(after, name)
                finished.fulfill()
            }
            return WebViewMessageHandlers([(name, handler)]).acceptingTrustedUserAction(name)
        }
        try await withWebView(name: names[0], handlers: handlers(names[0])) { first in
            try await withWebView(name: names[1], handlers: handlers(names[1])) { second in
                first.loadHTMLString(htmlPosting(name: names[0], body: "first"), baseURL: testURL)
                second.loadHTMLString(htmlPosting(name: names[1], body: "second"), baseURL: testURL)
                await fulfillment(of: [entered], timeout: 10)
                gate.release()
                await fulfillment(of: [finished], timeout: 10)
            }
        }
        XCTAssertNil(WebViewMessageReceiptContext.evidence)
    }

    func testDocumentReplacementCancelsOldWorkButDeliversNewDocument() async throws {
        let name = uniqueName()
        let key = "test." + name
        let entered = expectation(description: "old document handler entered")
        let oldFinished = expectation(description: "old document handler canceled")
        let fresh = expectation(description: "replacement document delivered")
        let gate = ReceiptOwnershipGate()
        let state = ReceiptOwnershipState()
        defer { gate.release() }
        WebViewMessageReceiptCapture.register(key: key) { [weak state] receipt in
            guard receipt.name == name, let state else { return nil }
            state.captures += 1
            return state.captures
        }
        let handler: @Sendable (WebViewMessage) async -> Void = { @MainActor _ in
            let captured: Int? = WebViewMessageReceiptContext.evidence?.value(for: key)
            if captured == 1 {
                entered.fulfill()
                await gate.wait()
                XCTAssertTrue(Task.isCancelled)
                let retained: Int? = WebViewMessageReceiptContext.evidence?.value(for: key)
                XCTAssertEqual(retained, captured)
                oldFinished.fulfill()
                return
            }
            XCTAssertFalse(Task.isCancelled)
            XCTAssertEqual(captured, 2)
            if let captured { state.committed.append(captured) }
            fresh.fulfill()
        }
        let handlers = WebViewMessageHandlers([(name, handler)])
        try await withWebView(name: name, handlers: handlers) { view in
            view.loadHTMLString(htmlPosting(name: name, body: "old"), baseURL: testURL)
            await fulfillment(of: [entered], timeout: 10)
            // Identical URL is not identical document ownership.
            view.loadHTMLString(htmlPosting(name: name, body: "new"), baseURL: testURL)
            await fulfillment(of: [fresh], timeout: 10)
            gate.release()
            await fulfillment(of: [oldFinished], timeout: 10)
            XCTAssertEqual(state.committed, [2])
        }
        XCTAssertNil(WebViewMessageReceiptContext.evidence)
    }

    func testUnregisteredEvidenceRemainsMissingAtRealDelivery() async throws {
        let name = uniqueName()
        let missingKey = "test.unregistered." + name
        let delivered = expectation(description: "unregistered provider delivery")
        let handler: @Sendable (WebViewMessage) async -> Void = { @MainActor _ in
            let missing: Int? = WebViewMessageReceiptContext.evidence?.value(for: missingKey)
            XCTAssertNil(missing)
            delivered.fulfill()
        }
        let handlers = WebViewMessageHandlers([(name, handler)])
        try await withWebView(name: name, handlers: handlers) { view in
            view.loadHTMLString(htmlPosting(name: name, body: "missing"), baseURL: testURL)
            await fulfillment(of: [delivered], timeout: 10)
        }
    }

    private var testURL: URL { URL(string: "https://example.invalid/receipt-ownership")! }

    private func uniqueName() -> String {
        "receiptOwnership" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func htmlPosting(name: String, body: String) -> String {
        "<script>window.webkit.messageHandlers.\(name).postMessage('\(body)')</script>"
    }

    private func withWebView(
        name: String,
        handlers: WebViewMessageHandlers,
        operation: (EnhancedWKWebView) async throws -> Void
    ) async rethrows {
        let model = WebView(navigator: WebViewNavigator(), state: .constant(.empty))
        let coordinator = model.makeCoordinatorForTesting(messageHandlers: handlers)
        let view = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(view)
        coordinator.reconcileMessageHandlers(
            on: view, requiredHandlers: [name], environmentHandlerNames: [name]
        )
        view.navigationDelegate = coordinator
        defer {
            view.stopLoading()
            coordinator.tearDownBindingsForDetachedWebView(view)
            view.navigationDelegate = nil
        }
        try await operation(view)
    }
}
