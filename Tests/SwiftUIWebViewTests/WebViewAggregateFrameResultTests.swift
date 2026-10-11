import Foundation
import WebKit
import XCTest
@testable import SwiftUIWebView

private final class AggregateFrameProbe: NSObject, WKScriptMessageHandler {
    var receive: ((WKScriptMessage) -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive?(message)
    }
}

@MainActor
private final class AggregateFrameSource {
    typealias Result = WebViewScriptCaller.JavaScriptEvaluationResult
    var handler: ((WKFrameInfo?, Int) async throws -> Result)?
    private(set) var calls: [WKFrameInfo?] = []
    func call(_ frame: WKFrameInfo?) async throws -> Result {
        calls.append(frame)
        if let handler { return try await handler(frame, calls.count) }
        return .init(nil)
    }
}

@MainActor
final class WebViewAggregateFrameResultTests: XCTestCase {
    private struct Fixture {
        let view: WKWebView
        let first: WKFrameInfo
        let second: WKFrameInfo
        let replacement: WKFrameInfo
        func uuid(_ frame: WKFrameInfo) -> String { frame === first ? "a" : "b" }
    }
    private enum Change { case remove, replace, removeThenError }

    private func fixture() async throws -> Fixture {
        let ready = expectation(description: "three real child frames")
        ready.expectedFulfillmentCount = 3
        var handles: [String: WKFrameInfo] = [:]
        let probe = AggregateFrameProbe()
        probe.receive = { message in
            guard let name = message.body as? String, handles[name] == nil else { return }
            handles[name] = message.frameInfo
            ready.fulfill()
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(probe, name: "aggregateProbe")
        defer { configuration.userContentController.removeScriptMessageHandler(forName: "aggregateProbe") }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        view.loadHTMLString("""
            <iframe srcdoc="<script>window.webkit.messageHandlers.aggregateProbe.postMessage('a')</script>"></iframe>
            <iframe srcdoc="<script>window.webkit.messageHandlers.aggregateProbe.postMessage('b')</script>"></iframe>
            <iframe srcdoc="<script>window.webkit.messageHandlers.aggregateProbe.postMessage('replacement')</script>"></iframe>
            """, baseURL: URL(string: "https://example.invalid/aggregate"))
        await fulfillment(of: [ready], timeout: 10)
        return Fixture(view: view, first: try XCTUnwrap(handles["a"]),
                       second: try XCTUnwrap(handles["b"]), replacement: try XCTUnwrap(handles["replacement"]))
    }

    private func caller(_ source: AggregateFrameSource, _ fixture: Fixture) -> WebViewScriptCaller {
        let caller = WebViewScriptCaller()
        caller.asyncCaller = { _, _, frame, _ in try await source.call(frame) }
        caller.addMultiTargetFrame(fixture.first, uuid: "a")
        caller.addMultiTargetFrame(fixture.second, uuid: "b")
        return caller
    }

    /// The actual first/last dispatch order is observed, never assumed from Dictionary ordering.
    private func checkEarlierResult(_ change: Change, strict: Bool,
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let fixture = try await fixture()
        defer { withExtendedLifetime(fixture.view) {} }
        let source = AggregateFrameSource()
        let caller = caller(source, fixture)
        defer { source.handler = nil; caller.asyncCaller = nil }
        var firstDispatched: WKFrameInfo?
        let lateError = NSError(domain: "aggregate-test", code: 42)
        source.handler = { frame, call in
            guard let frame else { return .init(NSString(string: "main")) }
            if call == 2 {
                firstDispatched = frame
                return .init(NSString(string: "early"))
            }
            let earlier = try XCTUnwrap(firstDispatched)
            if change == .replace {
                caller.addMultiTargetFrame(fixture.replacement, uuid: fixture.uuid(earlier))
            } else {
                caller.removeAllMultiTargetFrames()
                caller.addMultiTargetFrame(frame, uuid: fixture.uuid(frame))
            }
            if change == .removeThenError { throw lateError }
            return .init(NSString(string: "late"))
        }
        do {
            let result = try await caller.evaluateJavaScriptInMultiTargetFrames("collect", propagatesFrameErrors: strict)
            if strict {
                XCTFail("strict result accepted a retired earlier frame", file: file, line: line)
            } else {
                XCTAssertEqual(result.compactMap { $0 as? String },
                               change == .removeThenError ? ["main"] : ["main", "late"], file: file, line: line)
            }
        } catch {
            if strict { XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line) }
            else { throw error }
        }
        XCTAssertEqual(source.calls.count, 3, file: file, line: line)
        let earlier = try XCTUnwrap(firstDispatched)
        if change == .replace {
            XCTAssertTrue(caller.frame(forUUID: fixture.uuid(earlier)) === fixture.replacement, file: file, line: line)
            XCTAssertFalse(source.calls.contains { $0 === fixture.replacement }, file: file, line: line)
        } else {
            XCTAssertNil(caller.frame(forUUID: fixture.uuid(earlier)), file: file, line: line)
        }
    }

    func testOptionalOmitsEarlierFrameRemovedDuringLaterSuccess() async throws {
        try await checkEarlierResult(.remove, strict: false)
    }
    func testStrictRejectsEarlierFrameRemovedDuringLaterSuccess() async throws {
        try await checkEarlierResult(.remove, strict: true)
    }
    func testOptionalOmitsEarlierFrameReplacedDuringLaterSuccess() async throws {
        try await checkEarlierResult(.replace, strict: false)
    }
    func testStrictRejectsEarlierFrameReplacedDuringLaterSuccess() async throws {
        try await checkEarlierResult(.replace, strict: true)
    }
    func testLaterOptionalErrorStillRevalidatesEarlierResults() async throws {
        try await checkEarlierResult(.removeThenError, strict: false)
    }

    func testLaterInvalidAliasRetiresItsEarlierSuccessfulResult() async throws {
        let fixture = try await fixture()
        defer { withExtendedLifetime(fixture.view) {} }
        let source = AggregateFrameSource()
        let caller = WebViewScriptCaller()
        caller.asyncCaller = { _, _, frame, _ in try await source.call(frame) }
        defer { source.handler = nil; caller.asyncCaller = nil }
        caller.addMultiTargetFrame(fixture.first, uuid: "alias-one")
        caller.addMultiTargetFrame(fixture.first, uuid: "alias-two")
        source.handler = { frame, call in
            guard frame != nil else { return .init("main") }
            if call == 2 { return .init("early") }
            throw NSError(domain: WKError.errorDomain, code: WKError.javaScriptInvalidFrameTarget.rawValue)
        }
        let result = try await caller.evaluateJavaScriptInMultiTargetFrames("collect")
        XCTAssertEqual(result.compactMap { $0 as? String }, ["main"])
        XCTAssertEqual(source.calls.count, 3)
        XCTAssertNil(caller.frame(forUUID: "alias-one"))
        XCTAssertNil(caller.frame(forUUID: "alias-two"))
    }

    func testUnchangedResultsKeepOrderAndSuccessfulNilEntries() async throws {
        let fixture = try await fixture()
        defer { withExtendedLifetime(fixture.view) {} }
        let source = AggregateFrameSource()
        let caller = caller(source, fixture)
        defer { source.handler = nil; caller.asyncCaller = nil }
        source.handler = { _, call in call == 2 ? .init(NSString(string: "middle")) : .init(NSNull()) }
        let result = try await caller.evaluateJavaScriptInMultiTargetFrames("collect", propagatesFrameErrors: true)
        XCTAssertEqual(result.count, 3)
        guard result.count == 3 else { return }
        XCTAssertNil(result[0])
        XCTAssertEqual(result[1] as? String, "middle")
        XCTAssertNil(result[2])
    }

    func testUnrelatedRegistrationDoesNotJoinOrInvalidateResults() async throws {
        let fixture = try await fixture()
        defer { withExtendedLifetime(fixture.view) {} }
        let source = AggregateFrameSource()
        let caller = caller(source, fixture)
        defer { source.handler = nil; caller.asyncCaller = nil }
        source.handler = { _, call in
            if call == 3 { caller.addMultiTargetFrame(fixture.replacement, uuid: "new") }
            return .init(NSNumber(value: call))
        }
        let result = try await caller.evaluateJavaScriptInMultiTargetFrames("collect", propagatesFrameErrors: true)
        XCTAssertEqual(result.compactMap { ($0 as? NSNumber)?.intValue }, [1, 2, 3])
        XCTAssertFalse(source.calls.contains { $0 === fixture.replacement })
        XCTAssertTrue(caller.frame(forUUID: "new") === fixture.replacement)
    }
}
