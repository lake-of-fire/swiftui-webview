import Foundation
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
private final class ReceiptLifetimeBox {
    var lifetime = 1
    var captures = 0
}

private struct CapturedReceiptLifetime: Sendable {
    let lifetime: Int
    let reportsBFCacheRestoration: Bool
    let isMainFrame: Bool
}

@MainActor
final class WebViewReceiptDispatchTests: XCTestCase {
    func testOrdinaryReceiptKeepsItsPreDispatchLifetime() async throws {
        try await assertReceiptLifetime(usesBrokerDeferral: false)
    }

    func testBrokerDeferralKeepsTheOriginalReceiptLifetime() async throws {
        try await assertReceiptLifetime(usesBrokerDeferral: true)
    }

    func testRestorationHintIsCapturedBeforeOrdinaryDispatch() async throws {
        try await assertReceiptLifetime(usesBrokerDeferral: false,
            payload: "{ isBFCacheRestore: true }", reportsBFCacheRestoration: true)
    }

    func testRestorationHintSurvivesBrokerDeferralWithoutRecapture() async throws {
        try await assertReceiptLifetime(usesBrokerDeferral: true,
            payload: "{ isBFCacheRestore: true }", reportsBFCacheRestoration: true)
    }

    func testChildRestorationHintRetainsNativeChildFrameThroughBothDispatchRoutes() async throws {
        for deferred in [false, true] {
            try await assertReceiptLifetime(usesBrokerDeferral: deferred,
                payload: "{ isBFCacheRestore: true }", reportsBFCacheRestoration: true,
                inChildFrame: true)
        }
    }

    func testMissingStringAndNumericRestorationHintsDoNotReportRestore() async throws {
        for deferred in [false, true] {
            for payload in ["{}", "{ isBFCacheRestore: 'true' }",
                            "{ isBFCacheRestore: 1 }", "{ isBFCacheRestore: false }"] {
                try await assertReceiptLifetime(usesBrokerDeferral: deferred, payload: payload)
            }
        }
    }

    private func assertReceiptLifetime(
        usesBrokerDeferral: Bool,
        payload: String = "'old-lifetime'",
        reportsBFCacheRestoration: Bool = false,
        inChildFrame: Bool = false
    ) async throws {
        let name = "receiptBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let key = "test." + name
        let box = ReceiptLifetimeBox()
        let delivered = expectation(description: "real WebKit message reaches the production handler")
        WebViewMessageReceiptCapture.register(key: key) { [weak box] receipt in
            guard let box, receipt.name == name else { return nil }
            box.captures += 1
            let original = box.lifetime
            XCTAssertEqual(receipt.reportsBFCacheRestoration, reportsBFCacheRestoration,
                           "The provider must receive the raw hint synchronously")
            XCTAssertEqual(receipt.isMainFrame, !inChildFrame,
                           "Only WebKit frame identity can scope the restoration hint")
            // Deterministically advance between receipt capture and handler entry.
            // The document, WebView, and message stay identical.
            box.lifetime = 2
            return CapturedReceiptLifetime(lifetime: original,
                reportsBFCacheRestoration: receipt.reportsBFCacheRestoration,
                isMainFrame: receipt.isMainFrame)
        }
        var handlers = WebViewMessageHandlers([
            (name, { @MainActor _ in
                let retained: CapturedReceiptLifetime? = WebViewMessageReceiptContext.evidence?.value(for: key)
                XCTAssertEqual(retained?.lifetime, 1)
                XCTAssertEqual(retained?.reportsBFCacheRestoration, reportsBFCacheRestoration)
                XCTAssertEqual(retained?.isMainFrame, !inChildFrame)
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
        let script = "<script>window.webkit.messageHandlers.\(name).postMessage(\(payload))</script>"
        let html = inChildFrame ? "<iframe srcdoc=\"\(script)\"></iframe>" : script
        view.loadHTMLString(
            html,
            baseURL: URL(string: "https://example.invalid/receipt-boundary")
        )
        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertNil(WebViewMessageReceiptContext.evidence)
    }
}
