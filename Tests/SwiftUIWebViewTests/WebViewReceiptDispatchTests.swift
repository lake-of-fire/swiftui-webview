import Foundation
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
private final class ReceiptLifetimeBox {
    var lifetime = 1
    var captures = 0
}

@MainActor
final class WebViewReceiptDispatchTests: XCTestCase {
    func testOrdinaryReceiptKeepsItsPreDispatchLifetime() async throws {
        try await assertReceiptLifetime(usesBrokerDeferral: false)
    }

    func testBrokerDeferralKeepsTheOriginalReceiptLifetime() async throws {
        try await assertReceiptLifetime(usesBrokerDeferral: true)
    }

    private func assertReceiptLifetime(usesBrokerDeferral: Bool) async throws {
        let name = "receiptBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let key = "test." + name
        let box = ReceiptLifetimeBox()
        let delivered = expectation(description: "real WebKit message reaches the production handler")
        WebViewMessageReceiptCapture.register(key: key) { [weak box] receipt in
            guard let box, receipt.name == name else { return nil }
            box.captures += 1
            let original = box.lifetime
            // Deterministically advance between receipt capture and handler entry.
            // The document, WebView, and message stay identical.
            box.lifetime = 2
            return original
        }
        var handlers = WebViewMessageHandlers([
            (name, { @MainActor _ in
                let retained: Int? = WebViewMessageReceiptContext.evidence?.value(for: key)
                XCTAssertEqual(retained, 1)
                XCTAssertEqual(box.lifetime, 2)
                XCTAssertEqual(box.captures, 1, "Broker deferral must not reacquire a successor")
                delivered.fulfill()
            })
        ])
        if usesBrokerDeferral {
            // Optional activation with no broker receipt exercises the real
            // deferred path without inventing a trusted user gesture.
            handlers = handlers.acceptingTrustedUserAction(name)
        }
        let navigator = WebViewNavigator()
        let model = WebView(navigator: navigator, state: .constant(.empty))
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
        view.loadHTMLString(
            "<script>window.webkit.messageHandlers.\(name).postMessage('old-lifetime')</script>",
            baseURL: URL(string: "https://example.invalid/receipt-boundary")
        )
        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertNil(WebViewMessageReceiptContext.evidence)
    }
}


@MainActor
private final class ReceiptBindingTokenState {
    var captures = 0
}

/// A provider may synchronously rebind the caller. Both message routes must
/// retain the same token captured before provider callbacks or broker deferral.
@MainActor
final class WebViewReceiptBindingTokenTests: XCTestCase {
    func testOrdinaryDeliveryKeepsTheOriginalBindingToken() async throws {
        try await assertReceiptBindingToken(brokerDeferred: false)
    }

    func testBrokerDeferredDeliveryKeepsTheOriginalBindingToken() async throws {
        try await assertReceiptBindingToken(brokerDeferred: true)
    }

    private func assertReceiptBindingToken(brokerDeferred: Bool) async throws {
        let name = "receiptBinding" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let key = "test." + name
        let state = ReceiptBindingTokenState()
        let caller = WebViewScriptCaller()
        let delivered = expectation(description: "receipt binding delivered")
        var handlers = WebViewMessageHandlers([
            (name, { @MainActor message in
                let captured: WebViewScriptCaller.JavaScriptBindingToken? =
                    WebViewMessageReceiptContext.evidence?.value(for: key)
                XCTAssertNotNil(captured)
                XCTAssertEqual(message.javaScriptBindingToken, captured)
                XCTAssertNotEqual(caller.currentJavaScriptBindingToken, captured)
                if let captured {
                    XCTAssertNil(caller.makeJavaScriptBindingCommitFence(requiring: captured))
                }
                XCTAssertEqual(state.captures, 1)
                delivered.fulfill()
            })
        ])
        if brokerDeferred { handlers = handlers.acceptingTrustedUserAction(name) }
        let navigator = WebViewNavigator()
        let model = WebView(navigator: navigator, state: .constant(.empty))
        let coordinator = model.makeCoordinatorForTesting(messageHandlers: handlers)
        let view = EnhancedWKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.updateScriptCaller(caller)
        coordinator.setWebView(view)
        coordinator.installScriptCallerBinding(for: view,
            asyncCaller: { _, _, _, _ in .init(nil) },
            unsafeCaller: nil, snapshotCapture: nil)
        coordinator.reconcileMessageHandlers(
            on: view, requiredHandlers: [name], environmentHandlerNames: [name]
        )
        WebViewMessageReceiptCapture.register(key: key) { [weak coordinator, weak view, weak state] receipt in
            guard receipt.name == name, let coordinator, let view, let state else { return nil }
            state.captures += 1
            let captured = receipt.javaScriptBindingToken
            coordinator.installScriptCallerBinding(for: view,
                asyncCaller: { _, _, _, _ in .init(nil) },
                unsafeCaller: nil, snapshotCapture: nil)
            return captured
        }
        view.navigationDelegate = coordinator
        defer {
            view.stopLoading()
            coordinator.tearDownBindingsForDetachedWebView(view)
            view.navigationDelegate = nil
        }
        view.loadHTMLString(
            "<script>window.webkit.messageHandlers.\(name).postMessage('binding')</script>",
            baseURL: URL(string: "https://example.invalid/receipt-binding")
        )
        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertNil(WebViewMessageReceiptContext.evidence)
    }
}
