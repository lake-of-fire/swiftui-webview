import Foundation
import XCTest
@testable import SwiftUIWebView

@MainActor
final class WebViewURLTransitionIntentTests: XCTestCase {
    private func caller() throws -> WebViewScriptCaller {
        let caller = WebViewScriptCaller()
        caller.installBinding(ownedBy: UUID(), asyncCaller: { _, _, _, _ in .init(nil) },
            unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
        XCTAssertNotNil(caller.currentJavaScriptBindingToken)
        return caller
    }

    func testInitialNativeObservationDoesNotInventURLTransition() throws {
        let caller = try caller()
        let sequence = WebViewURLPublicationReceiptSequencer()
        let url = URL(string: "https://example.invalid/A")!
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: url)
        let first = try XCTUnwrap(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
        XCTAssertFalse(first.representsURLChange)
        XCTAssertTrue(first.isCurrent)
        let same = sequence.observe(url, from: ObjectIdentifier(caller))
        XCTAssertTrue(first === same.intent)
        XCTAssertFalse(try XCTUnwrap(same.intent).representsURLChange)
    }

    func testNativeTransitionsRetainOrderBeforeAnyDeferredPublication() throws {
        let caller = try caller()
        let sequence = WebViewURLPublicationReceiptSequencer()
        let a = URL(string: "https://example.invalid/A")!
        let b = URL(string: "https://example.invalid/B")!
        let c = URL(string: "https://example.invalid/C")!
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: a)
        let b1 = sequence.observe(b, from: ObjectIdentifier(caller))
        let c1 = sequence.observe(c, from: ObjectIdentifier(caller))
        let b2 = sequence.observe(b, from: ObjectIdentifier(caller))
        let receipt = sequence.observe(b, from: ObjectIdentifier(caller))
        XCTAssertLessThan(b1.sequence, c1.sequence)
        XCTAssertLessThan(c1.sequence, b2.sequence)
        XCTAssertLessThan(b2.sequence, receipt.sequence)
        XCTAssertNotEqual(b1.intent?.id, b2.intent?.id)
        XCTAssertFalse(try XCTUnwrap(b1.intent).isCurrent)
        XCTAssertFalse(try XCTUnwrap(c1.intent).isCurrent)
        XCTAssertTrue(try XCTUnwrap(b2.intent).isCurrent)
        XCTAssertTrue(b2.intent === receipt.intent)
    }

    func testFragmentChangeRetainsCanonicalTransitionIdentity() throws {
        let caller = try caller()
        let sequence = WebViewURLPublicationReceiptSequencer()
        let url = URL(string: "https://example.invalid/A")!
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: url)
        let first = try XCTUnwrap(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
        let fragment = try XCTUnwrap(sequence.observe(URL(string: url.absoluteString + "#section")!,
            from: ObjectIdentifier(caller)).intent)
        XCTAssertTrue(first === fragment)
        XCTAssertEqual(fragment.destinationURL, url)
        XCTAssertTrue(first.isCurrent)
    }

    func testForeignNativeSourceCannotReplaceOwnedIntent() throws {
        let caller = try caller()
        let foreign = try self.caller()
        let sequence = WebViewURLPublicationReceiptSequencer()
        let url = URL(string: "https://example.invalid/A")!
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: url)
        let first = try XCTUnwrap(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
        XCTAssertNil(sequence.observe(URL(string: "https://example.invalid/foreign")!, from: ObjectIdentifier(foreign)).intent)
        XCTAssertTrue(first.isCurrent)
        XCTAssertTrue(sequence.observe(url, from: ObjectIdentifier(caller)).intent === first)
    }

    func testReplacementBindingPermanentlyWithdrawsPriorURLIntent() throws {
        let caller = try caller()
        let sequence = WebViewURLPublicationReceiptSequencer()
        let url = URL(string: "https://example.invalid/A")!
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: url)
        let first = try XCTUnwrap(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
        caller.installBinding(ownedBy: UUID(), asyncCaller: { _, _, _, _ in .init(nil) },
            unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: url)
        let next = try XCTUnwrap(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
        XCTAssertFalse(first.isCurrent)
        XCTAssertTrue(next.isCurrent)
        XCTAssertNotEqual(first.javaScriptBindingToken, next.javaScriptBindingToken)
        XCTAssertNotEqual(first.id, next.id)
        XCTAssertFalse(next.representsURLChange)
    }

    func testInvalidatedCaptureCannotCreateAuthorityFromLateURLObservation() throws {
        let caller = try caller()
        let sequence = WebViewURLPublicationReceiptSequencer()
        let url = URL(string: "https://example.invalid/A")!
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: url)
        let first = try XCTUnwrap(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
        sequence.invalidate()
        XCTAssertFalse(first.isCurrent)
        XCTAssertNil(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
    }
    func testWithdrawalCallbacksAreExactOnceAndCanReenterSequencer() throws {
        let caller = try caller()
        let sequence = WebViewURLPublicationReceiptSequencer()
        let url = URL(string: "https://example.invalid/A")!
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: url)
        let first = try XCTUnwrap(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
        let successorURL = URL(string: "https://example.invalid/B")!
        let count = WithdrawalCallbackCount()
        first.onWithdrawal {
            count.increment()
            _ = sequence.observe(successorURL, from: ObjectIdentifier(caller))
        }
        _ = sequence.observe(successorURL, from: ObjectIdentifier(caller))
        sequence.invalidate()
        XCTAssertEqual(count.value, 1)
        first.onWithdrawal { count.increment() }
        XCTAssertEqual(count.value, 2)
    }

}

private final class WithdrawalCallbackCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
