import CoreGraphics
import WebKit
import XCTest
@testable import SwiftUIWebView
#if os(iOS)
import UIKit
private typealias SnapshotTestImage = UIImage
#else
import AppKit
private typealias SnapshotTestImage = NSImage
#endif

@MainActor
private final class SnapshotGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func open() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor
private final class DelayedSnapshotWebView: WKWebView {
    var started: XCTestExpectation?
    var reply: (@MainActor @Sendable (SnapshotTestImage?, (any Error)?) -> Void)?
    var requestedRect: CGRect?
    override func takeSnapshot(with configuration: WKSnapshotConfiguration?,
        completionHandler: @escaping @MainActor @Sendable (SnapshotTestImage?, (any Error)?) -> Void) {
        requestedRect = configuration?.rect
        reply = completionHandler
        started?.fulfill()
    }
    func complete(_ image: SnapshotTestImage) {
        let callback = reply
        reply = nil
        callback?(image, nil)
    }
}

@MainActor
final class WebViewSnapshotFencingTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
    private let viewport = CGRect(x: 20, y: 30, width: 400, height: 800.0 / 3)
    private let dom = CGRect(x: 100, y: 80, width: 200, height: 100)
    private enum Injected: Error { case failure }

    private func bitmap() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 150,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
    private func platformImage() throws -> SnapshotTestImage {
#if os(iOS)
        return UIImage(cgImage: try bitmap())
#else
        return NSImage(cgImage: try bitmap(), size: CGSize(width: 300, height: 150))
#endif
    }
    private func result() throws -> WebViewSnapshotImage {
        WebViewSnapshotImage(cgImage: try bitmap(), bounds: bounds, scale: 1, capturedRect: dom)
    }
    private func capture(_ caller: WebViewScriptCaller, domRequest: Bool) async throws -> WebViewSnapshotImage {
        if domRequest { return try await caller.captureSnapshot(domViewportRect: dom, viewportRect: viewport) }
        return try await caller.captureSnapshot(rect: dom)
    }
    private func requireCancellation(_ task: Task<WebViewSnapshotImage, Error>,
        file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Stale snapshot escaped", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line) }
    }

    func testUnchangedDOMCaptureUsesOriginalGeometryAndImage() async throws {
        let webView = DelayedSnapshotWebView(frame: bounds, configuration: WKWebViewConfiguration())
        webView.started = expectation(description: "capture")
        let caller = WebViewScriptCaller()
        caller.snapshotCapture = makeWebViewSnapshotCapture(for: webView)
        let image = try platformImage()
        let task = Task { try await self.capture(caller, domRequest: true) }
        await fulfillment(of: [try XCTUnwrap(webView.started)], timeout: 2)
        XCTAssertEqual(webView.requestedRect, CGRect(x: 120, y: 75, width: 300, height: 150))
        webView.complete(image)
        let value = try await task.value
        let actual = try XCTUnwrap(value.domViewportRect)
        XCTAssertEqual(actual.minX, dom.minX, accuracy: 0.001)
        XCTAssertEqual(actual.minY, dom.minY, accuracy: 0.001)
        XCTAssertEqual(actual.width, dom.width, accuracy: 0.001)
        XCTAssertEqual(actual.height, dom.height, accuracy: 0.001)
        XCTAssertEqual(value.cgImage.width, 300)
    }

    func testResizeRejectsBothPublicCaptureOverloads() async throws {
        for domRequest in [false, true] {
            let webView = DelayedSnapshotWebView(frame: bounds, configuration: WKWebViewConfiguration())
            webView.started = expectation(description: "capture")
            let caller = WebViewScriptCaller()
            caller.snapshotCapture = makeWebViewSnapshotCapture(for: webView)
            let image = try platformImage()
            let task = Task { try await self.capture(caller, domRequest: domRequest) }
            await fulfillment(of: [try XCTUnwrap(webView.started)], timeout: 2)
            webView.bounds.size.width = 300
            webView.complete(image)
            await requireCancellation(task)
        }
    }

    func testZeroWidthAfterCaptureCannotPublishNonfiniteDOMMetadata() async throws {
        let webView = DelayedSnapshotWebView(frame: bounds, configuration: WKWebViewConfiguration())
        webView.started = expectation(description: "capture")
        let caller = WebViewScriptCaller()
        caller.snapshotCapture = makeWebViewSnapshotCapture(for: webView)
        let image = try platformImage()
        let task = Task { try await self.capture(caller, domRequest: true) }
        await fulfillment(of: [try XCTUnwrap(webView.started)], timeout: 2)
        webView.bounds.size.width = 0
        webView.complete(image)
        await requireCancellation(task)
    }

    func testPageZoomChangeRejectsOldCapture() async throws {
        let webView = DelayedSnapshotWebView(frame: bounds, configuration: WKWebViewConfiguration())
        webView.started = expectation(description: "capture")
        let caller = WebViewScriptCaller()
        caller.snapshotCapture = makeWebViewSnapshotCapture(for: webView)
        let image = try platformImage()
        let task = Task { try await self.capture(caller, domRequest: true) }
        await fulfillment(of: [try XCTUnwrap(webView.started)], timeout: 2)
        webView.pageZoom = 1.5
        webView.complete(image)
        await requireCancellation(task)
    }

    private func bindingChange(_ change: (WebViewScriptCaller, WebViewScriptCaller.SnapshotCapture) -> Void) async throws {
        for domRequest in [false, true] {
            let caller = WebViewScriptCaller(), gate = SnapshotGate()
            let began = expectation(description: "capture")
            let value = try result()
            let original: WebViewScriptCaller.SnapshotCapture = { _ in
                began.fulfill(); await gate.wait(); return value
            }
            caller.snapshotCapture = original
            let task = Task { try await self.capture(caller, domRequest: domRequest) }
            await fulfillment(of: [began], timeout: 2)
            change(caller, original)
            gate.open()
            await requireCancellation(task)
        }
    }
    func testReplacedCaptureCannotReturnUnderNewBinding() async throws {
        let value = try result()
        try await bindingChange { caller, _ in caller.snapshotCapture = { _ in value } }
    }
    func testClearedCaptureCannotReturnSuccess() async throws {
        try await bindingChange { caller, _ in caller.snapshotCapture = nil }
    }
    func testRestoringSameClosureDoesNotReviveOldGeneration() async throws {
        try await bindingChange { caller, original in
            caller.snapshotCapture = nil
            caller.snapshotCapture = original
        }
    }
    func testPreCancelledCaptureDoesNotInvokeProvider() async throws {
        let caller = WebViewScriptCaller(), value = try result()
        var calls = 0
        caller.snapshotCapture = { _ in calls += 1; return value }
        for domRequest in [false, true] {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await self.capture(caller, domRequest: domRequest)
            }
            await requireCancellation(task)
        }
        XCTAssertEqual(calls, 0)
    }
    func testCancellationCannotReturnSuccessWhenProviderIgnoresIt() async throws {
        for domRequest in [false, true] {
            let caller = WebViewScriptCaller(), gate = SnapshotGate(), value = try result()
            let began = expectation(description: "capture")
            caller.snapshotCapture = { _ in began.fulfill(); await gate.wait(); return value }
            let task = Task { try await self.capture(caller, domRequest: domRequest) }
            await fulfillment(of: [began], timeout: 2)
            task.cancel(); gate.open()
            await requireCancellation(task)
        }
    }
    func testProviderErrorIsNotReclassified() async {
        let caller = WebViewScriptCaller()
        caller.snapshotCapture = { _ in throw Injected.failure }
        do { _ = try await caller.captureSnapshot(); XCTFail("Expected error") }
        catch { XCTAssertTrue(error is Injected) }
    }
    func testMissingProviderRemainsUnavailable() async {
        do { _ = try await WebViewScriptCaller().captureSnapshot(); XCTFail("Expected error") }
        catch { XCTAssertEqual(error as? WebViewScriptCallerSnapshotError, .unavailable) }
    }

    private func coordinatorChange(_ change: (WebViewCoordinator, EnhancedWKWebView) -> Void,
        shouldCancel: Bool = true) async throws {
        let navigator = WebViewNavigator(), caller = WebViewScriptCaller(), gate = SnapshotGate()
        let model = WebView(navigator: navigator, state: .constant(.empty))
        let coordinator = model.makeCoordinatorForTesting()
        coordinator.updateScriptCaller(caller)
        let webView = EnhancedWKWebView(frame: bounds, configuration: WKWebViewConfiguration())
        coordinator.setWebView(webView)
        coordinator.webView(webView, didCommit: nil)
        let began = expectation(description: "capture"), value = try result()
        coordinator.installScriptCallerBinding(for: webView,
            asyncCaller: { _, _, _, _ in WebViewScriptCaller.JavaScriptEvaluationResult(nil) },
            unsafeCaller: nil,
            snapshotCapture: { _ in began.fulfill(); await gate.wait(); return value })
        let task = Task { try await caller.captureSnapshot() }
        await fulfillment(of: [began], timeout: 2)
        change(coordinator, webView)
        gate.open()
        if shouldCancel { await requireCancellation(task) }
        else { let image = try await task.value; XCTAssertTrue(image.cgImage === value.cgImage) }
    }
    func testUnchangedCoordinatorCaptureStillSucceeds() async throws {
        try await coordinatorChange({ _, _ in }, shouldCancel: false)
    }
    func testSameWebViewNewDocumentGenerationCannotPublishOldImage() async throws {
        try await coordinatorChange { coordinator, webView in
            coordinator.webView(webView, didStartProvisionalNavigation: nil)
            coordinator.webView(webView, didCommit: nil)
        }
    }
    func testPendingNavigationRejectsCapture() async throws {
        try await coordinatorChange { coordinator, webView in
            coordinator.webView(webView, didStartProvisionalNavigation: nil)
        }
    }
    func testReplacedCoordinatorWebViewRejectsCapture() async throws {
        try await coordinatorChange { coordinator, _ in
            coordinator.setWebView(EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration()))
        }
    }
}
