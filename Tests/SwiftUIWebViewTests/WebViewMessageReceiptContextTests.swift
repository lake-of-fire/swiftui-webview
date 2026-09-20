import Foundation
import XCTest
@testable import SwiftUIWebView

@MainActor
final class WebViewMessageReceiptContextTests: XCTestCase {
    private final class State {
        var epoch = 1
        var calls = 0
    }

    func testReceiptRetainsPreDispatchValueAcrossLifetimeChange() async {
        let state = State()
        let registry = WebViewMessageReceiptCaptureRegistry()
        XCTAssertTrue(registry.register(namespace: "test.article", messageNames: ["progress"]) { _ in
            state.calls += 1
            return state.epoch
        })
        let receipt = WebViewMessageReceipt(name: "progress", requestURL: nil, mainDocumentURL: nil)
        let admitted = registry.capture(receipt)
        state.epoch = 2
        await Task.yield()
        XCTAssertEqual(admitted.value(for: "test.article", as: Int.self), 1)
        XCTAssertEqual(state.calls, 1, "Delayed delivery must not recapture successor authority")
        XCTAssertEqual(registry.capture(receipt).value(for: "test.article", as: Int.self), 2)
    }

    func testDuplicateNamespaceCannotReplaceCaptureAuthority() {
        let registry = WebViewMessageReceiptCaptureRegistry()
        XCTAssertTrue(registry.register(namespace: "test.article", messageNames: ["progress"]) { _ in 1 })
        XCTAssertFalse(registry.register(namespace: "test.article", messageNames: ["progress"]) { _ in 2 })
        let receipt = WebViewMessageReceipt(name: "progress", requestURL: nil, mainDocumentURL: nil)
        XCTAssertEqual(registry.capture(receipt).value(for: "test.article", as: Int.self), 1)
    }

    func testFailedAndUnregisteredCaptureDoNotInventEvidence() {
        let registry = WebViewMessageReceiptCaptureRegistry()
        XCTAssertTrue(registry.register(namespace: "test.article", messageNames: ["progress"]) { _ in nil })
        let receipt = WebViewMessageReceipt(name: "progress", requestURL: nil, mainDocumentURL: nil)
        XCTAssertNil(registry.capture(receipt).value(for: "test.article", as: Int.self))
        XCTAssertNil(WebViewMessageReceiptContext.empty.value(for: "test.article", as: Int.self))
    }

    func testUnrelatedMessageDoesNotInvokeApplicationCapture() {
        let state = State()
        let registry = WebViewMessageReceiptCaptureRegistry()
        registry.register(namespace: "test.article", messageNames: ["progress"]) { _ in
            state.calls += 1
            return state.epoch
        }
        let receipt = WebViewMessageReceipt(name: "title", requestURL: nil, mainDocumentURL: nil)
        XCTAssertNil(registry.capture(receipt).value(for: "test.article", as: Int.self))
        XCTAssertEqual(state.calls, 0)
    }
}
