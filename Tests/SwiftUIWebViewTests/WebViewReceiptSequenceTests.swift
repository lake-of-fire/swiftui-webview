import Foundation
import WebKit
import XCTest
@testable import SwiftUIWebView

/// Retain actual WebKit receipts without changing their native frame/view
/// ownership. Synchronous replay through the production coordinator makes
/// provider reentry and trusted-action deferral deterministic.
@MainActor
private final class ReceiptSequenceRecorder: NSObject, WKScriptMessageHandler {
    var messages = [String: WKScriptMessage]()
    let captured: XCTestExpectation

    init(captured: XCTestExpectation) { self.captured = captured }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        messages[message.name] = message
        captured.fulfill()
    }
}

@MainActor
private final class ReceiptSequenceState {
    var delivered = [String: UInt64]()
    var latestSequence: UInt64 = 0
    var displayedName: String?
    var afterOlderCapture: (() -> Void)?
}

@MainActor
final class WebViewReceiptSequenceTests: XCTestCase {
    func testProviderReentryKeepsTheEarlierReceiptSequence() async throws {
        try await assertReceiptOrder(olderDeferred: false, newerDeferred: false,
                                     reenterFromProvider: true)
    }

    func testDeferredProviderReentryKeepsTheEarlierReceiptSequence() async throws {
        try await assertReceiptOrder(olderDeferred: true, newerDeferred: false,
                                     reenterFromProvider: true)
    }

    func testBrokerDeferralCannotMakeAnOlderReceiptNewer() async throws {
        try await assertReceiptOrder(olderDeferred: true, newerDeferred: false,
                                     reenterFromProvider: false)
    }

    func testLaterBrokerDeferralPreservesNativeArrivalOrder() async throws {
        try await assertReceiptOrder(olderDeferred: false, newerDeferred: true,
                                     reenterFromProvider: false)
    }

    private func assertReceiptOrder(olderDeferred: Bool, newerDeferred: Bool,
                                    reenterFromProvider: Bool) async throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let olderName = "receiptOlder" + suffix
        let newerName = "receiptNewer" + suffix
        let key = "test.sequence." + suffix
        let state = ReceiptSequenceState()
        let captured = expectation(description: "two real WebKit receipts captured")
        captured.expectedFulfillmentCount = 2
        let recorder = ReceiptSequenceRecorder(captured: captured)
        let delivered = expectation(description: "both production handlers complete")
        delivered.expectedFulfillmentCount = 2
        WebViewMessageReceiptCapture.register(key: key) { [weak state] receipt in
            guard let state, receipt.name == olderName || receipt.name == newerName else { return nil }
            if receipt.name == olderName { state.afterOlderCapture?() }
            return receipt.name
        }
        let handler: @Sendable (WebViewMessage) async -> Void = { @MainActor message in
            let evidence: String? = WebViewMessageReceiptContext.evidence?.value(for: key)
            XCTAssertEqual(evidence, message.name, "Reentry must retain each receipt's evidence")
            XCTAssertNil(message.trustedUserAction, "Optional deferral must not invent activation")
            if let sequence = message.receiptSequence {
                state.delivered[message.name] = sequence
                // Model the sequence gate used by native producer/publication
                // consumers. The newest arrival must survive any dispatch order.
                if sequence > state.latestSequence {
                    state.latestSequence = sequence
                    state.displayedName = message.name
                }
            } else {
                XCTFail("A native receipt must carry its reserved sequence")
            }
            delivered.fulfill()
        }
        var handlers = WebViewMessageHandlers([(olderName, handler), (newerName, handler)])
        if olderDeferred { handlers = handlers.acceptingTrustedUserAction(olderName) }
        if newerDeferred { handlers = handlers.acceptingTrustedUserAction(newerName) }
        let model = WebView(navigator: WebViewNavigator(), state: .constant(.empty))
        let coordinator = model.makeCoordinatorForTesting(messageHandlers: handlers)
        let view = EnhancedWKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480),
                                     configuration: WKWebViewConfiguration())
        coordinator.setWebView(view)
        coordinator.reconcileMessageHandlers(on: view,
            requiredHandlers: [olderName, newerName], environmentHandlerNames: [olderName, newerName])
        view.navigationDelegate = coordinator
        let controller = view.configuration.userContentController
        // Only interception uses the recorder. The tested receipts enter the
        // unchanged production callback with their actual WebKit objects.
        for name in [olderName, newerName] {
            controller.removeScriptMessageHandler(forName: name)
            controller.add(recorder, name: name)
        }
        defer {
            state.afterOlderCapture = nil
            view.stopLoading()
            coordinator.tearDownBindingsForDetachedWebView(view)
            for name in [olderName, newerName] { controller.removeScriptMessageHandler(forName: name) }
            view.navigationDelegate = nil
        }
        view.loadHTMLString("""
            <script>
            window.webkit.messageHandlers.\(olderName).postMessage('older');
            window.webkit.messageHandlers.\(newerName).postMessage('newer');
            </script>
            """, baseURL: URL(string: "https://example.invalid/receipt-sequence"))
        await fulfillment(of: [captured], timeout: 10)
        let older = try XCTUnwrap(recorder.messages[olderName])
        let newer = try XCTUnwrap(recorder.messages[newerName])
        if reenterFromProvider {
            state.afterOlderCapture = {
                // Clear before reentry so this callback can never recurse.
                state.afterOlderCapture = nil
                coordinator.userContentController(controller, didReceive: newer)
            }
        }
        coordinator.userContentController(controller, didReceive: older)
        if !reenterFromProvider {
            coordinator.userContentController(controller, didReceive: newer)
        }
        await fulfillment(of: [delivered], timeout: 10)
        let olderSequence = try XCTUnwrap(state.delivered[olderName])
        let newerSequence = try XCTUnwrap(state.delivered[newerName])
        XCTAssertLessThan(olderSequence, newerSequence,
                          "Native arrival order must survive callback reentry and broker deferral")
        XCTAssertEqual(state.displayedName, newerName,
                       "An older delayed handler must never supersede the newer publication")
        XCTAssertNil(WebViewMessageReceiptContext.evidence)
    }
}
