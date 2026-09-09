import Foundation
import WebKit
import XCTest
@testable import SwiftUIWebView

private actor CoercionRetrySource {
    private let retryError: (any Error)?
    private var scripts: [String] = []
    init(retryError: (any Error)? = nil) { self.retryError = retryError }
    func call(_ script: String) throws -> WebViewScriptCaller.JavaScriptEvaluationResult {
        scripts.append(script)
        if scripts.count == 1 {
            throw NSError(domain: WKError.errorDomain,
                code: WKError.javaScriptResultTypeIsUnsupported.rawValue)
        }
        if let retryError { throw retryError }
        return WebViewScriptCaller.JavaScriptEvaluationResult(NSString(string: "https://example.invalid/reader"))
    }
    func recordedScripts() -> [String] { scripts }
}

@MainActor
final class WebViewCoercionErrorTests: XCTestCase {
    private enum Injected: Error, Equatable { case retryFailed }
    private let script = "window.location.href"

    private func caller(_ source: CoercionRetrySource) -> WebViewScriptCaller {
        let caller = WebViewScriptCaller()
        caller.asyncCaller = { script, _, _, _ in try await source.call(script) }
        return caller
    }

    func testSuccessfulCoercionStillReturnsNormalizedString() async throws {
        let source = CoercionRetrySource()
        let value = try await caller(source).evaluateJavaScript(script)
        XCTAssertEqual(value as? String, "https://example.invalid/reader")
        let scripts = await source.recordedScripts()
        XCTAssertEqual(scripts.count, 2)
        XCTAssertEqual(scripts.first, script)
        XCTAssertTrue(scripts.last?.contains("String(window.location") == true)
    }

    func testCancellationFromRetryIsNotSuccessfulNil() async {
        let source = CoercionRetrySource(retryError: CancellationError())
        do { _ = try await caller(source).evaluateJavaScript(script); XCTFail("Cancellation was swallowed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let scripts = await source.recordedScripts()
        XCTAssertEqual(scripts.count, 2)
    }

    func testBindingRequiredOverloadPreservesRetryCancellation() async throws {
        let source = CoercionRetrySource(retryError: CancellationError())
        let caller = caller(source)
        let token = try XCTUnwrap(caller.currentJavaScriptBindingToken)
        do { _ = try await caller.evaluateJavaScript(script, requiring: token); XCTFail("Cancellation was swallowed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(caller.currentJavaScriptBindingToken, token)
    }

    func testArbitraryRetryErrorRetainsItsIdentity() async {
        let source = CoercionRetrySource(retryError: Injected.retryFailed)
        do { _ = try await caller(source).evaluateJavaScript(script); XCTFail("Retry failure was swallowed") }
        catch { XCTAssertEqual(error as? Injected, .retryFailed) }
    }

    func testWebKitRetryErrorsAreNotMistakenForUnsupportedResults() async {
        for code in [WKError.javaScriptInvalidFrameTarget, .webContentProcessTerminated, .javaScriptException] {
            let expected = NSError(domain: WKError.errorDomain, code: code.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "retry error"])
            let source = CoercionRetrySource(retryError: expected)
            do { _ = try await caller(source).evaluateJavaScript(script); XCTFail("Retry failure was swallowed") }
            catch {
                XCTAssertEqual((error as NSError).domain, expected.domain)
                XCTAssertEqual((error as NSError).code, expected.code)
                XCTAssertEqual((error as NSError).localizedDescription, expected.localizedDescription)
            }
        }
    }

    func testRepeatedUnsupportedResultKeepsLegacyNilPolicy() async throws {
        let source = CoercionRetrySource(retryError: NSError(domain: WKError.errorDomain,
            code: WKError.javaScriptResultTypeIsUnsupported.rawValue))
        let value = try await caller(source).evaluateJavaScript(script)
        XCTAssertNil(value)
        let scripts = await source.recordedScripts()
        XCTAssertEqual(scripts.count, 2)
    }

    func testNonHrefUnsupportedResultDoesNotRetry() async throws {
        let source = CoercionRetrySource(retryError: Injected.retryFailed)
        let value = try await caller(source).evaluateJavaScript("document.body")
        XCTAssertNil(value)
        let scripts = await source.recordedScripts()
        XCTAssertEqual(scripts, ["document.body"])
    }

    func testOrdinarySuccessIsNotChanged() async throws {
        let caller = WebViewScriptCaller()
        caller.asyncCaller = { _, _, _, _ in WebViewScriptCaller.JavaScriptEvaluationResult(NSString(string: "ok")) }
        let value = try await caller.evaluateJavaScript(script)
        XCTAssertEqual(value as? String, "ok")
    }

    func testOriginalNonUnsupportedFailureStillPropagates() async {
        let caller = WebViewScriptCaller()
        caller.asyncCaller = { _, _, _, _ in throw Injected.retryFailed }
        do { _ = try await caller.evaluateJavaScript(script); XCTFail("Original failure was swallowed") }
        catch { XCTAssertEqual(error as? Injected, .retryFailed) }
    }
}
