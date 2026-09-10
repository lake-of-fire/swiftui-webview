import Foundation
import WebKit
import XCTest
@testable import SwiftUIWebView

private final class RetirementFrameProbe: NSObject, WKScriptMessageHandler {
    var onMessage: ((WKScriptMessage) -> Void)?
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) { onMessage?(message) }
}

@MainActor
private final class RetirementPause {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class RetirementSource {
    typealias Result = WebViewScriptCaller.JavaScriptEvaluationResult
    var handler: ((WKFrameInfo?, Int) async throws -> Result)?
    private(set) var frames: [WKFrameInfo?] = []
    func call(_ frame: WKFrameInfo?) async throws -> Result {
        frames.append(frame)
        if let handler { return try await handler(frame, frames.count) }
        return .init(NSString(string: "ok"))
    }
    func count(_ frame: WKFrameInfo) -> Int { frames.filter { $0 === frame }.count }
}

@MainActor
final class WebViewInvalidFrameRetirementTests: XCTestCase {
    private struct Frames {
        let view: WKWebView
        let main: WKFrameInfo
        let first: WKFrameInfo
        let second: WKFrameInfo
    }
    private enum Route { case duplicate, optional, strict }
    private var invalid: NSError {
        NSError(domain: WKError.errorDomain, code: WKError.javaScriptInvalidFrameTarget.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "retired target"])
    }
    private let firstURL = URL(string: "ebook://book/first.xhtml")!
    private let aliasURL = URL(string: "ebook://book/alias.xhtml")!
    private let secondURL = URL(string: "ebook://book/second.xhtml")!

    private func frames() async throws -> Frames {
        let ready = expectation(description: "three real frame handles")
        ready.expectedFulfillmentCount = 3
        var received: [String: WKFrameInfo] = [:]
        let probe = RetirementFrameProbe()
        probe.onMessage = { message in
            guard let key = message.body as? String, received[key] == nil else { return }
            received[key] = message.frameInfo
            ready.fulfill()
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(probe, name: "retirementProbe")
        defer { configuration.userContentController.removeScriptMessageHandler(forName: "retirementProbe") }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        view.loadHTMLString("""
            <script>window.webkit.messageHandlers.retirementProbe.postMessage('main')</script>
            <iframe srcdoc="<script>window.webkit.messageHandlers.retirementProbe.postMessage('first')</script>"></iframe>
            <iframe srcdoc="<script>window.webkit.messageHandlers.retirementProbe.postMessage('second')</script>"></iframe>
            """, baseURL: URL(string: "https://example.invalid/retirement"))
        await fulfillment(of: [ready], timeout: 10)
        return Frames(view: view, main: try XCTUnwrap(received["main"]),
                      first: try XCTUnwrap(received["first"]), second: try XCTUnwrap(received["second"]))
    }

    private func caller(_ source: RetirementSource) -> WebViewScriptCaller {
        let caller = WebViewScriptCaller()
        caller.asyncCaller = { _, _, frame, _ in try await source.call(frame) }
        return caller
    }
    private func aliases(_ caller: WebViewScriptCaller, frame: WKFrameInfo) {
        caller.addTrackedWordTargetFrame(frame, uuid: "first", canonicalURL: firstURL)
        caller.addTrackedWordTargetFrame(frame, uuid: "alias", canonicalURL: aliasURL)
    }
    private func assertRetired(_ caller: WebViewScriptCaller, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(caller.frame(forUUID: "first"), file: file, line: line)
        XCTAssertNil(caller.frame(forUUID: "alias"), file: file, line: line)
        XCTAssertNil(caller.exactFrame(for: firstURL), file: file, line: line)
        XCTAssertNil(caller.exactFrame(for: aliasURL), file: file, line: line)
        XCTAssertNil(caller.exactFrame(forUUID: "first", documentURL: firstURL), file: file, line: line)
        XCTAssertTrue(caller.registeredTrackedWordFrameIdentities().allSatisfy {
            $0.uuid != "first" && $0.uuid != "alias"
        }, file: file, line: line)
    }
    private func invoke(_ caller: WebViewScriptCaller, route: Route) async throws {
        switch route {
        case .duplicate:
            _ = try await caller.evaluateJavaScript("plain", duplicateInMultiTargetFrames: true)
        case .optional:
            _ = try await caller.evaluateJavaScriptInMultiTargetFrames("plain")
        case .strict:
            _ = try await caller.evaluateJavaScriptInMultiTargetFrames("plain", propagatesFrameErrors: true)
        }
    }

    func testPrimaryMainFailureRetiresURLUUIDTrackedAndFallbackLookups() async throws {
        let frames = try await frames()
        defer { withExtendedLifetime(frames.view) {} }
        for required in [false, true] {
            let source = RetirementSource(), expected = invalid
            source.handler = { _, _ in throw expected }
            let caller = caller(source)
            aliases(caller, frame: frames.main)
            let value: Any?
            if required {
                let token = try XCTUnwrap(caller.currentJavaScriptBindingToken)
                value = try await caller.evaluateJavaScript("plain", in: frames.main, requiring: token)
            } else { value = try await caller.evaluateJavaScript("plain", in: frames.main) }
            XCTAssertNil(value, "Preserve primary invalid-frame nil policy")
            assertRetired(caller)
            XCTAssertNil(caller.mainFrameInfo)
            XCTAssertNil(caller.frame(for: nil))
        }
    }

    func testPrimaryChildFailurePreservesUnrelatedMainAndChild() async throws {
        let frames = try await frames()
        defer { withExtendedLifetime(frames.view) {} }
        let source = RetirementSource(), expected = invalid
        source.handler = { _, _ in throw expected }
        let caller = caller(source)
        caller.addMultiTargetFrame(frames.main, uuid: "main")
        aliases(caller, frame: frames.first)
        caller.addTrackedWordTargetFrame(frames.second, uuid: "second", canonicalURL: secondURL)
        _ = try await caller.evaluateJavaScript("plain", in: frames.first)
        assertRetired(caller)
        XCTAssertTrue(caller.mainFrameInfo === frames.main)
        XCTAssertTrue(caller.exactFrame(for: secondURL) === frames.second)
        XCTAssertEqual(caller.registeredTrackedWordFrameIdentities().map(\.uuid), ["second"])
    }

    func testCoercionFailureRetiresAliasesAndPreservesThrownError() async throws {
        let frames = try await frames()
        defer { withExtendedLifetime(frames.view) {} }
        let source = RetirementSource(), expected = invalid
        let unsupported = NSError(domain: WKError.errorDomain, code: WKError.javaScriptResultTypeIsUnsupported.rawValue)
        source.handler = { _, call in throw call == 1 ? unsupported : expected }
        let caller = caller(source)
        aliases(caller, frame: frames.first)
        do {
            _ = try await caller.evaluateJavaScript("window.location.href", in: frames.first)
            XCTFail("A coercion error must still propagate")
        } catch { XCTAssertTrue((error as NSError) === expected) }
        XCTAssertEqual(source.frames.count, 2)
        assertRetired(caller)
    }

    private func invalidFanout(_ route: Route) async throws {
        let frames = try await frames()
        defer { withExtendedLifetime(frames.view) {} }
        let source = RetirementSource(), expected = invalid
        source.handler = { frame, _ in
            if frame != nil { throw expected }
            return .init(NSString(string: "main"))
        }
        let caller = caller(source)
        aliases(caller, frame: frames.first)
        do {
            try await invoke(caller, route: route)
            if case .strict = route { XCTFail("Strict fanout must retain its error") }
        } catch {
            guard case .strict = route else { throw error }
            XCTAssertTrue((error as NSError) === expected)
        }
        assertRetired(caller)
        XCTAssertEqual(source.count(frames.first), 1, "Never redispatch an invalid alias from the loop snapshot")
    }
    func testOptionalFanoutRetiresEveryAliasAfterOneRejectedDispatch() async throws { try await invalidFanout(.optional) }
    func testStrictFanoutRetiresEveryAliasBeforePropagatingFailure() async throws { try await invalidFanout(.strict) }
    func testDuplicateFanoutRetiresEveryAliasAfterOneRejectedDispatch() async throws { try await invalidFanout(.duplicate) }

    func testFailureDoesNotRemoveReplacementUnderTheSameUUIDAndURL() async throws {
        let frames = try await frames()
        defer { withExtendedLifetime(frames.view) {} }
        let source = RetirementSource(), expected = invalid, pause = RetirementPause()
        let entered = expectation(description: "old target suspended")
        source.handler = { _, _ in entered.fulfill(); await pause.wait(); throw expected }
        let caller = caller(source)
        aliases(caller, frame: frames.first)
        let task = Task { _ = try await caller.evaluateJavaScript("plain", in: frames.first) }
        defer { task.cancel(); pause.release() }
        await fulfillment(of: [entered], timeout: 3)
        caller.addTrackedWordTargetFrame(frames.second, uuid: "first", canonicalURL: firstURL)
        pause.release()
        try await task.value
        XCTAssertTrue(caller.frame(forUUID: "first") === frames.second)
        XCTAssertTrue(caller.exactFrame(for: firstURL) === frames.second)
        XCTAssertNil(caller.frame(forUUID: "alias"))
        XCTAssertNil(caller.exactFrame(for: aliasURL))
        XCTAssertEqual(caller.registeredTrackedWordFrameIdentities().map(\.uuid), ["first"])
    }

    func testFailureRestoresAnotherFramesSharedCanonicalURLMapping() async throws {
        let frames = try await frames()
        defer { withExtendedLifetime(frames.view) {} }
        let source = RetirementSource(), expected = invalid
        source.handler = { _, _ in throw expected }
        let caller = caller(source)
        caller.addTrackedWordTargetFrame(frames.second, uuid: "survivor", canonicalURL: firstURL)
        caller.addTrackedWordTargetFrame(frames.first, uuid: "first", canonicalURL: firstURL)
        caller.addTrackedWordTargetFrame(frames.first, uuid: "alias", canonicalURL: firstURL)
        _ = try await caller.evaluateJavaScript("plain", in: frames.first)
        XCTAssertNil(caller.frame(forUUID: "first"))
        XCTAssertNil(caller.frame(forUUID: "alias"))
        XCTAssertTrue(caller.exactFrame(for: firstURL) === frames.second)
        XCTAssertEqual(caller.registeredTrackedWordFrameIdentities().map(\.uuid), ["survivor"])
    }

    private func staleFailure(rebind: Bool) async throws {
        let frames = try await frames()
        defer { withExtendedLifetime(frames.view) {} }
        let source = RetirementSource(), expected = invalid, pause = RetirementPause()
        let entered = expectation(description: "stale failure suspended")
        source.handler = { _, _ in entered.fulfill(); await pause.wait(); throw expected }
        let caller = caller(source)
        aliases(caller, frame: frames.first)
        let task = Task { _ = try await caller.evaluateJavaScript("plain", in: frames.first) }
        defer { task.cancel(); pause.release() }
        await fulfillment(of: [entered], timeout: 3)
        if rebind { caller.asyncCaller = { _, _, _, _ in .init(nil) } }
        else { task.cancel() }
        pause.release()
        do { try await task.value; XCTFail("Stale error must be cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(caller.frame(forUUID: "first") === frames.first)
        XCTAssertTrue(caller.frame(forUUID: "alias") === frames.first)
    }
    func testReboundProviderCannotRetireCurrentRegistrations() async throws { try await staleFailure(rebind: true) }
    func testCancelledProviderCannotRetireCurrentRegistrations() async throws { try await staleFailure(rebind: false) }

    func testNilMainTargetDoesNotGuessWhichRegisteredFrameFailed() async throws {
        let frames = try await frames()
        defer { withExtendedLifetime(frames.view) {} }
        let source = RetirementSource(), expected = invalid
        source.handler = { _, _ in throw expected }
        let caller = caller(source)
        aliases(caller, frame: frames.main)
        let value = try await caller.evaluateJavaScript("plain")
        XCTAssertNil(value)
        XCTAssertTrue(caller.mainFrameInfo === frames.main)
        XCTAssertTrue(caller.frame(forUUID: "first") === frames.main)
        XCTAssertTrue(caller.exactFrame(for: aliasURL) === frames.main)
    }

    func testOtherErrorsAndSuccessfulCallsDoNotRetireRegistrations() async throws {
        let frames = try await frames()
        defer { withExtendedLifetime(frames.view) {} }
        for error in [nil, NSError(domain: "provider", code: WKError.javaScriptInvalidFrameTarget.rawValue),
                      NSError(domain: WKError.errorDomain, code: WKError.javaScriptExceptionOccurred.rawValue)] {
            let source = RetirementSource()
            source.handler = { _, _ in if let error { throw error }; return .init(NSString(string: "ok")) }
            let caller = caller(source)
            aliases(caller, frame: frames.first)
            do {
                let value = try await caller.evaluateJavaScript("plain", in: frames.first)
                XCTAssertNil(error)
                XCTAssertEqual(value as? String, "ok")
            } catch let caught { XCTAssertTrue((caught as NSError) === error) }
            XCTAssertTrue(caller.frame(forUUID: "first") === frames.first)
            XCTAssertTrue(caller.exactFrame(for: aliasURL) === frames.first)
        }
    }

    private func clearedSnapshot(_ route: Route) async throws {
        let frames = try await frames()
        defer { withExtendedLifetime(frames.view) {} }
        let source = RetirementSource()
        let caller = caller(source)
        aliases(caller, frame: frames.first)
        defer { source.handler = nil }
        source.handler = { frame, _ in
            if frame != nil { caller.removeAllMultiTargetFrames() }
            return .init(nil)
        }
        do {
            try await invoke(caller, route: route)
            if case .strict = route { XCTFail("Strict fanout must reject a retired undispatched target") }
        } catch {
            guard case .strict = route else { throw error }
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(source.count(frames.first), 1)
        assertRetired(caller)
    }
    func testOptionalFanoutDoesNotDispatchClearedSnapshotEntries() async throws { try await clearedSnapshot(.optional) }
    func testStrictFanoutRejectsClearedSnapshotEntries() async throws { try await clearedSnapshot(.strict) }

    private func lastTargetReplacement(strict: Bool) async throws {
        let frames = try await frames()
        defer { withExtendedLifetime(frames.view) {} }
        for replace in [false, true] {
            let source = RetirementSource()
            let caller = caller(source)
            caller.addTrackedWordTargetFrame(frames.first, uuid: "first", canonicalURL: firstURL)
            defer { source.handler = nil }
            source.handler = { frame, _ in
                if frame != nil {
                    caller.removeAllMultiTargetFrames()
                    if replace {
                        caller.addTrackedWordTargetFrame(frames.second, uuid: "first", canonicalURL: self.firstURL)
                    }
                }
                return .init(NSString(string: frame == nil ? "main" : "obsolete"))
            }
            do {
                let values = try await caller.evaluateJavaScriptInMultiTargetFrames("plain", propagatesFrameErrors: strict)
                XCTAssertFalse(strict, "Strict fanout accepted an obsolete last result")
                XCTAssertEqual(values.compactMap { $0 as? String }, ["main"])
            } catch { XCTAssertTrue(strict && error is CancellationError) }
            XCTAssertEqual(source.count(frames.first), 1)
            XCTAssertEqual(source.count(frames.second), 0, "A replacement is not part of the old snapshot")
            if replace {
                XCTAssertTrue(caller.frame(forUUID: "first") === frames.second)
                XCTAssertTrue(caller.exactFrame(for: firstURL) === frames.second)
            } else { XCTAssertNil(caller.frame(forUUID: "first")) }
        }
    }

    func testOptionalFanoutOmitsAStaleLastResult() async throws { try await lastTargetReplacement(strict: false) }
    func testStrictFanoutRejectsAStaleLastResult() async throws { try await lastTargetReplacement(strict: true) }
}
