import XCTest
@testable import SwiftUIWebView

@MainActor
final class WebViewScriptCallerTests: XCTestCase {
    func testMultiTargetEvaluationIncludesMainDocumentResult() async throws {
        let caller = WebViewScriptCaller()
        caller.asyncCaller = { script, arguments, frame, _ in
            XCTAssertEqual(script, "return value")
            XCTAssertNil(frame)
            XCTAssertEqual(arguments?["value"] as? Int, 42)
            return WebViewScriptCaller.JavaScriptEvaluationResult("main")
        }

        let results = try await caller.evaluateJavaScriptInMultiTargetFrames(
            "return value",
            arguments: ["value": 42],
            propagatesFrameErrors: true
        )

        XCTAssertEqual(results as? [String], ["main"])
    }

    func testStaleBindingOwnerCannotClearReplacement() async throws {
        let caller = WebViewScriptCaller()
        let staleOwnerID = UUID()
        let activeOwnerID = UUID()

        caller.installBinding(
            ownedBy: staleOwnerID,
            asyncCaller: { _, _, _, _ in
                WebViewScriptCaller.JavaScriptEvaluationResult("stale")
            },
            unsafeCaller: nil,
            snapshotCapture: nil
        )
        caller.installBinding(
            ownedBy: activeOwnerID,
            asyncCaller: { _, _, _, _ in
                WebViewScriptCaller.JavaScriptEvaluationResult("active")
            },
            unsafeCaller: { _, _, _ in },
            snapshotCapture: nil
        )

        XCTAssertFalse(caller.clearBinding(ownedBy: staleOwnerID))
        XCTAssertTrue(caller.canEvaluateJavaScript)
        XCTAssertNotNil(caller.unsafeCaller)
        let activeValue = try await caller.evaluateJavaScript("value") as? String
        XCTAssertEqual(activeValue, "active")

        XCTAssertTrue(caller.clearBinding(ownedBy: activeOwnerID))
        XCTAssertFalse(caller.canEvaluateJavaScript)
        XCTAssertNil(caller.unsafeCaller)
    }
}
