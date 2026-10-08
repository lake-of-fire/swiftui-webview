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

    func testMissingOrWrongTypeDoesNotInventEvidence() {
        let evidence = WebViewMessageReceiptEvidence(values: ["value": 12])
        let wrong: String? = evidence.value(for: "value")
        let missing: Int? = evidence.value(for: "missing")
        XCTAssertNil(wrong)
        XCTAssertNil(missing)

        // Even identical child/main URLs cannot establish native main-frame
        // ownership without the exact WKFrameInfo flag.
        let url = URL(string: "https://example.invalid/article")!
        let unknown = WebViewMessageReceipt(name: "manabiReaderInitialized",
            mainDocumentURL: url, requestURL: url)
        XCTAssertFalse(unknown.isMainFrame)
        XCTAssertFalse(unknown.reportsBFCacheRestoration)

        let nativeMain = WebViewMessageReceipt(name: "manabiReaderInitialized",
            mainDocumentURL: url, requestURL: url,
            reportsBFCacheRestoration: true, isMainFrame: true)
        XCTAssertTrue(nativeMain.isMainFrame)
        XCTAssertTrue(nativeMain.reportsBFCacheRestoration)

        let child = WebViewMessageReceipt(name: "manabiReaderInitialized",
            mainDocumentURL: url, requestURL: url,
            reportsBFCacheRestoration: false, isMainFrame: false)
        XCTAssertFalse(child.isMainFrame)
        XCTAssertFalse(child.reportsBFCacheRestoration)
    }
}
