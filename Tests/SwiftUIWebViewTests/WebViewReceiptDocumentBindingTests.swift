import Foundation
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
private final class ReceiptBindingGate {
    private var released = false
    private var waiters = [CheckedContinuation<Void, Never>]()
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
private final class ReceiptBindingState {
    var captured = [WebViewScriptCaller.JavaScriptBindingToken]()
    var delivered = [WebViewScriptCaller.JavaScriptBindingToken]()
    var afterCapture: (() -> Void)?
}

/// Actual WKScriptMessage delivery, production coordinator, and native-issued
/// caller/document bindings. No renderer-provided owner identifier is trusted.
@MainActor
final class WebViewReceiptDocumentBindingTests: XCTestCase {
    private typealias Token = WebViewScriptCaller.JavaScriptBindingToken
    private let url = URL(string: "https://example.invalid/same-book.epub")!

    func testLegacyReceiptInitializerDoesNotInventNativeBinding() {
        let receipt = WebViewMessageReceipt(name: "legacy", mainDocumentURL: url, requestURL: url)
        XCTAssertNil(receipt.javaScriptBindingToken)
    }

    func testOrdinaryDeliveryUsesTheExactReceiptBinding() async throws {
        try await assertDelivery(brokerDeferred: false, rebindDuringProvider: false)
    }

    func testBrokerDeferredDeliveryUsesTheExactReceiptBinding() async throws {
        try await assertDelivery(brokerDeferred: true, rebindDuringProvider: false)
    }

    func testOrdinaryProviderReentryCannotRetargetTheMessageBinding() async throws {
        try await assertDelivery(brokerDeferred: false, rebindDuringProvider: true)
    }

    func testBrokerProviderReentryCannotRetargetTheMessageBinding() async throws {
        try await assertDelivery(brokerDeferred: true, rebindDuringProvider: true)
    }

    private func assertDelivery(brokerDeferred: Bool, rebindDuringProvider: Bool) async throws {
        let name = uniqueName(), key = "test." + uniqueName()
        let state = ReceiptBindingState()
        let delivered = expectation(description: "native delivery")
        WebViewMessageReceiptCapture.register(key: key) { [weak state] receipt in
            guard receipt.name == name, let state, let token = receipt.javaScriptBindingToken else { return nil }
            state.captured.append(token)
            state.afterCapture?()
            return token
        }
        let handler: @Sendable (WebViewMessage) async -> Void = { @MainActor message in
            let evidence: Token? = WebViewMessageReceiptContext.evidence?.value(for: key)
            XCTAssertNotNil(evidence)
            XCTAssertEqual(evidence, state.captured.first)
            XCTAssertEqual(message.javaScriptBindingToken, evidence)
            await Task.yield()
            let retained: Token? = WebViewMessageReceiptContext.evidence?.value(for: key)
            XCTAssertEqual(retained, evidence)
            if let evidence { state.delivered.append(evidence) }
            delivered.fulfill()
        }
        var handlers = WebViewMessageHandlers([(name, handler)])
        if brokerDeferred { handlers = handlers.acceptingTrustedUserAction(name) }
        try await withView(name: name, handlers: handlers) { view, coordinator, caller in
            if rebindDuringProvider {
                state.afterCapture = { [weak coordinator, weak view] in
                    guard let coordinator, let view else { return }
                    self.installBinding(coordinator, view: view)
                }
            }
            defer { state.afterCapture = nil }
            view.loadHTMLString(html(name, body: "first"), baseURL: url)
            await fulfillment(of: [delivered], timeout: 10)
            XCTAssertEqual(state.captured.count, 1, "Deferral must not recapture app evidence")
            XCTAssertEqual(state.delivered, state.captured)
            let captured = try XCTUnwrap(state.captured.first)
            if rebindDuringProvider {
                XCTAssertNotEqual(caller.currentJavaScriptBindingToken, captured)
            } else {
                XCTAssertEqual(caller.currentJavaScriptBindingToken, captured)
            }
            let detached = await Task.detached { captured }.value
            XCTAssertEqual(detached, captured)
        }
        XCTAssertNil(WebViewMessageReceiptContext.evidence)
    }

    func testSameURLAndSameMessageNameStillIdentifyDifferentNativeViews() async throws {
        let name = uniqueName(), key = "test." + uniqueName()
        let state = ReceiptBindingState()
        let entered = expectation(description: "both documents entered")
        entered.expectedFulfillmentCount = 2
        let completed = expectation(description: "both documents completed")
        completed.expectedFulfillmentCount = 2
        let gate = ReceiptBindingGate()
        defer { gate.release() }
        WebViewMessageReceiptCapture.register(key: key) { [weak state] receipt in
            guard receipt.name == name, let state, let token = receipt.javaScriptBindingToken else { return nil }
            state.captured.append(token)
            return token
        }
        let handler: @Sendable (WebViewMessage) async -> Void = { @MainActor message in
            let before: Token? = WebViewMessageReceiptContext.evidence?.value(for: key)
            entered.fulfill()
            await gate.wait()
            let after: Token? = WebViewMessageReceiptContext.evidence?.value(for: key)
            XCTAssertNotNil(before)
            XCTAssertEqual(before, after)
            XCTAssertEqual(after, message.javaScriptBindingToken)
            if let after { state.delivered.append(after) }
            completed.fulfill()
        }
        let handlers = WebViewMessageHandlers([(name, handler)]).acceptingTrustedUserAction(name)
        try await withView(name: name, handlers: handlers) { first, _, firstCaller in
            try await withView(name: name, handlers: handlers) { second, _, secondCaller in
                first.loadHTMLString(html(name, body: "same"), baseURL: url)
                second.loadHTMLString(html(name, body: "same"), baseURL: url)
                await fulfillment(of: [entered], timeout: 10)
                let expected: Set<Token> = [try XCTUnwrap(firstCaller.currentJavaScriptBindingToken),
                                           try XCTUnwrap(secondCaller.currentJavaScriptBindingToken)]
                XCTAssertEqual(expected.count, 2)
                XCTAssertEqual(Set(state.captured), expected)
                gate.release()
                await fulfillment(of: [completed], timeout: 10)
                XCTAssertEqual(Set(state.delivered), expected)
            }
        }
    }

    func testSameURLDocumentReplacementKeepsOldEvidenceAndAllowsFreshReceipt() async throws {
        let name = uniqueName(), key = "test." + uniqueName()
        let state = ReceiptBindingState()
        let oldEntered = expectation(description: "old document entered")
        let oldFinished = expectation(description: "old handler finished")
        let fresh = expectation(description: "new document delivered")
        let gate = ReceiptBindingGate()
        defer { gate.release() }
        WebViewMessageReceiptCapture.register(key: key) { [weak state] receipt in
            guard receipt.name == name, let state, let token = receipt.javaScriptBindingToken else { return nil }
            state.captured.append(token)
            return token
        }
        let handler: @Sendable (WebViewMessage) async -> Void = { @MainActor message in
            let captured: Token? = WebViewMessageReceiptContext.evidence?.value(for: key)
            XCTAssertEqual(captured, message.javaScriptBindingToken)
            if message.body as? String == "old" {
                oldEntered.fulfill()
                await gate.wait()
                XCTAssertTrue(Task.isCancelled)
                let retained: Token? = WebViewMessageReceiptContext.evidence?.value(for: key)
                XCTAssertEqual(retained, captured)
                oldFinished.fulfill()
            } else {
                XCTAssertFalse(Task.isCancelled)
                if let captured { state.delivered.append(captured) }
                fresh.fulfill()
            }
        }
        let handlers = WebViewMessageHandlers([(name, handler)])
        try await withView(name: name, handlers: handlers) { view, _, caller in
            view.loadHTMLString(html(name, body: "old"), baseURL: url)
            await fulfillment(of: [oldEntered], timeout: 10)
            let original = try XCTUnwrap(state.captured.first)
            view.loadHTMLString(html(name, body: "fresh"), baseURL: url)
            await fulfillment(of: [fresh], timeout: 10)
            let replacement = try XCTUnwrap(caller.currentJavaScriptBindingToken)
            XCTAssertNotEqual(original, replacement)
            XCTAssertEqual(state.captured, [original, replacement])
            XCTAssertEqual(state.delivered, [replacement])
            gate.release()
            await fulfillment(of: [oldFinished], timeout: 10)
        }
        XCTAssertNil(WebViewMessageReceiptContext.evidence)
    }

    func testRealDeliveryWithoutCallerRetainsMissingBinding() async throws {
        let name = uniqueName(), key = "test." + uniqueName()
        let delivered = expectation(description: "unbound delivery")
        WebViewMessageReceiptCapture.register(key: key) { receipt in
            receipt.name == name ? receipt : nil
        }
        let handler: @Sendable (WebViewMessage) async -> Void = { @MainActor message in
            let receipt: WebViewMessageReceipt? = WebViewMessageReceiptContext.evidence?.value(for: key)
            XCTAssertNotNil(receipt)
            XCTAssertNil(receipt?.javaScriptBindingToken)
            XCTAssertNil(message.javaScriptBindingToken)
            delivered.fulfill()
        }
        let model = WebView(navigator: WebViewNavigator(), state: .constant(.empty))
        let coordinator = model.makeCoordinatorForTesting(messageHandlers: .init([(name, handler)]))
        let view = EnhancedWKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: .init())
        coordinator.setWebView(view)
        coordinator.reconcileMessageHandlers(on: view, requiredHandlers: [name], environmentHandlerNames: [name])
        view.navigationDelegate = coordinator
        defer {
            view.stopLoading()
            coordinator.tearDownBindingsForDetachedWebView(view)
            view.navigationDelegate = nil
        }
        view.loadHTMLString(html(name, body: "no-caller"), baseURL: url)
        await fulfillment(of: [delivered], timeout: 10)
    }

    private func uniqueName() -> String {
        "nativeBinding" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
    private func html(_ name: String, body: String) -> String {
        "<script>window.webkit.messageHandlers.\(name).postMessage('\(body)')</script>"
    }
    private func installBinding(_ coordinator: WebViewCoordinator, view: EnhancedWKWebView) {
        // This unused evaluation closure is not the delivery path under test.
        // Messages and document commits use the actual WKWebView/coordinator.
        coordinator.installScriptCallerBinding(for: view,
            asyncCaller: { _, _, _, _ in .init(nil) },
            unsafeCaller: nil, snapshotCapture: nil)
    }
    private func withView(name: String, handlers: WebViewMessageHandlers,
                          operation: (EnhancedWKWebView, WebViewCoordinator, WebViewScriptCaller) async throws -> Void) async rethrows {
        let caller = WebViewScriptCaller()
        let model = WebView(navigator: WebViewNavigator(), state: .constant(.empty), scriptCaller: caller)
        let coordinator = model.makeCoordinatorForTesting(messageHandlers: handlers)
        let view = EnhancedWKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: .init())
        coordinator.setWebView(view)
        installBinding(coordinator, view: view)
        coordinator.reconcileMessageHandlers(on: view, requiredHandlers: [name], environmentHandlerNames: [name])
        view.navigationDelegate = coordinator
        defer {
            view.stopLoading()
            coordinator.tearDownBindingsForDetachedWebView(view)
            view.navigationDelegate = nil
        }
        try await operation(view, coordinator, caller)
    }
}
