import Foundation
import XCTest
@testable import SwiftUIWebView

final class WebViewMessageReceiptEvidenceTests: XCTestCase {
    @MainActor
    func testCapturedEvidenceSurvivesDeferralAndNestedDelivery() async {
        let key = UUID().uuidString
        var lifetime = 1
        WebViewMessageReceiptCapture.register(key: key) { _ in lifetime }
        let receipt = WebViewMessageReceipt(name: "progress", mainDocumentURL: nil, requestURL: nil)
        let first = WebViewMessageReceiptCapture.capture(receipt)
        lifetime = 2
        let second = WebViewMessageReceiptCapture.capture(receipt)
        await WebViewMessageReceiptContext.$evidence.withValue(first) {
            await Task.yield()
            let retained: Int? = WebViewMessageReceiptContext.evidence?.value(for: key)
            XCTAssertEqual(retained, 1)
            XCTAssertNotEqual(retained, lifetime)
            await WebViewMessageReceiptContext.$evidence.withValue(second) {
                await Task.yield()
                let nested: Int? = WebViewMessageReceiptContext.evidence?.value(for: key)
                XCTAssertEqual(nested, 2)
            }
            let restored: Int? = WebViewMessageReceiptContext.evidence?.value(for: key)
            XCTAssertEqual(restored, 1)
        }
        XCTAssertNil(WebViewMessageReceiptContext.evidence)
    }

    @MainActor
    func testScopedProvidersAreIsolatedAndSurviveHandlerTransformations() {
        let receipt = WebViewMessageReceipt(name: "initialize", mainDocumentURL: nil, requestURL: nil)
        let first = WebViewMessageHandlers(receiptEvidenceProviders: ["owner": { _ in 1 }])
        let second = WebViewMessageHandlers(receiptEvidenceProviders: ["owner": { _ in 2 }])
        let transformed = (first + WebViewMessageHandlers())
            .updating("initialize") { _ in }
            .updatingCancellationHandler("initialize") { _ in }
            .acceptingTrustedUserAction("initialize")
            .requiringTrustedUserAction("command")
        XCTAssertEqual(transformed.captureReceiptEvidence(receipt).value(for: "owner", as: Int.self), 1)
        XCTAssertEqual(second.captureReceiptEvidence(receipt).value(for: "owner", as: Int.self), 2)
        XCTAssertNil(WebViewMessageReceiptCapture.capture(receipt).value(for: "owner", as: Int.self))
    }

    @MainActor
    func testProviderKeyCollisionsWithdrawEvidenceWithoutCallingEitherProvider() {
        let receipt = WebViewMessageReceipt(name: "initialize", mainDocumentURL: nil, requestURL: nil)
        var calls = 0
        let provider: WebViewMessageReceiptCapture.Provider = { _ in calls += 1; return 1 }
        let first = WebViewMessageHandlers(receiptEvidenceProviders: ["collision": provider])
        let second = WebViewMessageHandlers(receiptEvidenceProviders: ["collision": provider])
        let composed = first + second + first
        XCTAssertNil(composed.captureReceiptEvidence(receipt).value(for: "collision", as: Int.self))
        let globalKey = UUID().uuidString
        WebViewMessageReceiptCapture.register(key: globalKey, provider: provider)
        let globalCollision = WebViewMessageHandlers(receiptEvidenceProviders: [globalKey: provider])
        XCTAssertNil(globalCollision.captureReceiptEvidence(receipt).value(for: globalKey, as: Int.self))
        XCTAssertEqual(calls, 0)
    }

    func testMissingOrWrongTypeDoesNotInventEvidence() {
        let evidence = WebViewMessageReceiptEvidence(values: ["value": 12])
        let wrong: String? = evidence.value(for: "value")
        let missing: Int? = evidence.value(for: "missing")
        XCTAssertNil(wrong)
        XCTAssertNil(missing)
    }
}
