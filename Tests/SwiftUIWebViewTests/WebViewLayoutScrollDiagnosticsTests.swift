import XCTest
@testable import SwiftUIWebView

final class WebViewLayoutScrollDiagnosticsTests: XCTestCase {
    func testDisabledDiagnosticsDoNotEvaluatePageSignatureWork() {
        var evaluations = 0

        let disabledValue = webViewLayoutDiagnosticValue(
            false,
            {
                evaluations += 1
                return "page-signature"
            }()
        )

        XCTAssertNil(disabledValue)
        XCTAssertEqual(evaluations, 0)

        let enabledValue = webViewLayoutDiagnosticValue(
            true,
            {
                evaluations += 1
                return "page-signature"
            }()
        )

        XCTAssertEqual(enabledValue, "page-signature")
        XCTAssertEqual(evaluations, 1)
    }
}
