import XCTest
@testable import SwiftUIWebView

@MainActor
final class WebViewJavaScriptBindingCommitFenceTests: XCTestCase {
    private func bind(_ caller: WebViewScriptCaller, owner: UUID) {
        caller.installBinding(
            ownedBy: owner,
            asyncCaller: { _, _, _, _ in .init(nil) },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
    }

    func testRebindingRejectsCapturedFenceAndOldToken() throws {
        let caller = WebViewScriptCaller()
        bind(caller, owner: UUID())
        let token = try XCTUnwrap(caller.currentJavaScriptBindingToken)
        let oldFence = try XCTUnwrap(caller.makeJavaScriptBindingCommitFence(requiring: token))
        XCTAssertTrue(oldFence())
        bind(caller, owner: UUID())
        XCTAssertFalse(oldFence())
        XCTAssertNil(caller.makeJavaScriptBindingCommitFence(requiring: token))
        let newToken = try XCTUnwrap(caller.currentJavaScriptBindingToken)
        XCTAssertTrue(try XCTUnwrap(caller.makeJavaScriptBindingCommitFence(requiring: newToken))())
    }

    func testOnlyOwningCoordinatorCanRevokeDocumentFence() throws {
        let caller = WebViewScriptCaller()
        let owner = UUID()
        bind(caller, owner: owner)
        let token = try XCTUnwrap(caller.currentJavaScriptBindingToken)
        let fence = try XCTUnwrap(caller.makeJavaScriptBindingCommitFence(requiring: token))
        caller.invalidateJavaScriptBindingCommitFence(ownedBy: UUID())
        XCTAssertTrue(fence())
        caller.invalidateJavaScriptBindingCommitFence(ownedBy: owner)
        XCTAssertFalse(fence())
    }

    func testCallerReleaseRevokesEscapedFenceWithoutKeepingOwnerAlive() throws {
        var caller: WebViewScriptCaller? = WebViewScriptCaller()
        weak var weakCaller = caller
        bind(caller!, owner: UUID())
        let token = try XCTUnwrap(caller!.currentJavaScriptBindingToken)
        let fence = try XCTUnwrap(caller!.makeJavaScriptBindingCommitFence(requiring: token))
        caller = nil
        XCTAssertNil(weakCaller)
        XCTAssertFalse(fence())
    }
}
