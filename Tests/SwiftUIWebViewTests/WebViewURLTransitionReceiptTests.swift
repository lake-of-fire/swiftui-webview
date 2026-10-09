import Foundation
import SwiftUI
import WebKit
import XCTest
@testable import SwiftUIWebView

private struct CapturedURLTransitionReceipt: Sendable {
    let receipt: WebViewMessageReceipt
    let publishedURL: URL
    let publishedIntentID: UUID?
    let URLCallbacksAtCapture: Int
}

@MainActor
private final class URLTransitionReceiptState {
    var webState = WebViewState.empty
    var publications: [WebViewState] = []
    var messages: [String: CapturedURLTransitionReceipt] = [:]
    var onMessage: ((String) -> Void)?
    var onLoaded: (() -> Void)?
    var onStateSet: (() -> Void)?
}

@MainActor
private final class URLTransitionReceiptHost {
    let state: URLTransitionReceiptState
    let caller: WebViewScriptCaller
    let view: EnhancedWKWebView
    let coordinator: WebViewCoordinator
    let name: String

    init() {
        let state = URLTransitionReceiptState()
        self.state = state
        let caller = WebViewScriptCaller()
        self.caller = caller
        let name = "urlTransition" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        self.name = name
        let key = "test." + name
        WebViewMessageReceiptCapture.register(key: key) { [weak state] receipt in
            guard let state, receipt.name == name else { return nil }
            return CapturedURLTransitionReceipt(receipt: receipt,
                publishedURL: state.webState.pageURL,
                publishedIntentID: state.webState.urlTransitionIntent?.id,
                URLCallbacksAtCapture: state.publications.count)
        }
        let handler: @Sendable (WebViewMessage) async -> Void = { @MainActor [weak state] message in
            guard let state, let body = message.body as? [String: String], let label = body["label"],
                  let captured: CapturedURLTransitionReceipt = WebViewMessageReceiptContext.evidence?.value(for: key) else { return }
            state.messages[label] = captured
            state.onMessage?(label)
        }
        let model = WebView(navigator: WebViewNavigator(),
            state: Binding(get: { state.webState }, set: { state.webState = $0; state.onStateSet?() }),
            scriptCaller: caller,
            onNavigationFinished: { _ in state.onLoaded?() },
            onURLChanged: { snapshot in state.publications.append(snapshot) })
        let coordinator = model.makeCoordinatorForTesting(messageHandlers: .init([(name, handler)]))
        self.coordinator = coordinator
        let view = EnhancedWKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: .init())
        self.view = view
        coordinator.setWebView(view)
        coordinator.installScriptCallerBinding(for: view,
            asyncCaller: { _, _, _, _ in .init(nil) }, unsafeCaller: nil, snapshotCapture: nil)
        coordinator.reconcileMessageHandlers(on: view,
            requiredHandlers: [name, "swiftUIWebViewLocationChanged"], environmentHandlerNames: [name])
        view.navigationDelegate = coordinator
    }

    func load(_ url: URL) { view.loadHTMLString("<html><body>Native URL capture</body></html>", baseURL: url) }

    func emit(label: String, script: String = "") async throws {
        _ = try await view.evaluateJavaScript("""
            \(script)
            window.webkit.messageHandlers['\(name)'].postMessage({label:'\(label)', url:location.href});
            0;
            """)
    }

    func close() {
        state.onMessage = nil
        state.onLoaded = nil
        state.onStateSet = nil
        view.stopLoading()
        coordinator.tearDownBindingsForDetachedWebView(view)
        view.navigationDelegate = nil
    }
}

@MainActor
final class WebViewURLTransitionReceiptTests: XCTestCase {
    private let originalURL = URL(string: "https://example.invalid/native-transition/A")!

    private func loadedHost() async -> URLTransitionReceiptHost {
        let host = URLTransitionReceiptHost()
        let loaded = expectation(description: "actual WKWebView main document finished")
        host.state.onLoaded = { loaded.fulfill() }
        host.load(originalURL)
        await fulfillment(of: [loaded], timeout: 10)
        host.state.onLoaded = nil
        host.state.publications.removeAll()
        addTeardownBlock { @MainActor in host.close() }
        return host
    }

    private func receipt(_ label: String, host: URLTransitionReceiptHost, script: String = "") async throws -> CapturedURLTransitionReceipt {
        let delivered = expectation(description: "native message " + label)
        host.state.onMessage = { received in if received == label { delivered.fulfill() } }
        try await host.emit(label: label, script: script)
        await fulfillment(of: [delivered], timeout: 10)
        host.state.onMessage = nil
        return try XCTUnwrap(host.state.messages[label])
    }

    func testNativeSPAReceiptAndURLPublicationCarrySameOriginalIntent() async throws {
        let host = await loadedHost()
        let b = URL(string: "https://example.invalid/native-transition/B")!
        let captured = try await receipt("B", host: host, script: "history.pushState({}, '', '\(b.absoluteString)');")
        let intent = try XCTUnwrap(captured.receipt.urlTransitionIntent)
        XCTAssertEqual(intent.destinationURL, b)
        XCTAssertTrue(intent.isCurrent)
        XCTAssertTrue(intent.representsURLChange)
        XCTAssertEqual(captured.receipt.javaScriptBindingToken, intent.javaScriptBindingToken)
        XCTAssertEqual(captured.receipt.nativeDocumentURL, b,
            "The application may reserve this destination only from native receipt evidence")
        XCTAssertEqual(captured.publishedURL, b)
        XCTAssertEqual(captured.publishedIntentID, intent.id)
        XCTAssertGreaterThan(captured.URLCallbacksAtCapture, 0,
            "The native URL intent must reach selection admission before application evidence providers")
    }

    func testNativeBaselineAndFragmentsCannotPublishFreshSelectionIntent() async throws {
        let host = await loadedHost()
        let initial = try await receipt("initial", host: host)
        let baseline = try XCTUnwrap(initial.receipt.urlTransitionIntent)
        XCTAssertFalse(baseline.representsURLChange)
        XCTAssertNil(initial.publishedIntentID)
        XCTAssertEqual(initial.URLCallbacksAtCapture, 0)
        let fragment = try await receipt("fragment", host: host,
            script: "history.pushState({}, '', '\(originalURL.absoluteString)#first');")
        XCTAssertTrue(fragment.receipt.urlTransitionIntent === baseline)
        XCTAssertNil(fragment.publishedIntentID)
        XCTAssertEqual(fragment.publishedURL.fragment, "first")
        XCTAssertTrue(host.state.publications.allSatisfy { $0.urlTransitionIntent == nil })

        let b = URL(string: "https://example.invalid/native-transition/B")!
        let next = try await receipt("B", host: host, script: "history.pushState({}, '', '\(b.absoluteString)');")
        let nextIntent = try XCTUnwrap(next.receipt.urlTransitionIntent)
        let nextFragment = try await receipt("B-fragment", host: host,
            script: "history.pushState({}, '', '\(b.absoluteString)#second');")
        XCTAssertTrue(nextFragment.receipt.urlTransitionIntent === nextIntent)
        XCTAssertEqual(nextFragment.publishedIntentID, nextIntent.id)
        XCTAssertTrue(nextIntent.isCurrent)
    }

    func testNativeRapidReturnCannotReuseIntentEvenWhenIntermediatePublicationIsDeferred() async throws {
        let host = await loadedHost()
        let b = URL(string: "https://example.invalid/native-transition/B")!
        let c = URL(string: "https://example.invalid/native-transition/C")!
        let first = try await receipt("B1", host: host, script: "history.pushState({}, '', '\(b.absoluteString)');")
        let old = try XCTUnwrap(first.receipt.urlTransitionIntent)
        let next = try await receipt("B2", host: host, script: """
            history.pushState({}, '', '\(c.absoluteString)');
            history.pushState({}, '', '\(b.absoluteString)');
            """)
        let successor = try XCTUnwrap(next.receipt.urlTransitionIntent)
        XCTAssertNotEqual(old.id, successor.id)
        XCTAssertFalse(old.isCurrent)
        XCTAssertTrue(successor.isCurrent)
        XCTAssertEqual(next.publishedURL, b)
        XCTAssertEqual(next.publishedIntentID, successor.id)
        XCTAssertEqual(host.state.webState.urlTransitionIntent?.id, successor.id,
            "A late URL publication cannot replace the current receipt's exact intent")
    }

    func testForgedLocationHintCannotReplaceNativeReceiptIntent() async throws {
        let host = await loadedHost()
        let initial = try await receipt("initial", host: host)
        let original = try XCTUnwrap(initial.receipt.urlTransitionIntent)
        let next = try await receipt("after-hint", host: host, script: """
            window.webkit.messageHandlers.swiftUIWebViewLocationChanged.postMessage('https://example.invalid/forged');
            """)
        XCTAssertTrue(next.receipt.urlTransitionIntent === original)
        XCTAssertTrue(original.isCurrent)
        XCTAssertEqual(next.publishedURL, originalURL)
        XCTAssertEqual(next.URLCallbacksAtCapture, 0)
    }

    func testNativeDocumentDetachWithdrawsRetainedTransition() async throws {
        let host = await loadedHost()
        let captured = try await receipt("initial", host: host)
        let intent = try XCTUnwrap(captured.receipt.urlTransitionIntent)
        XCTAssertTrue(intent.isCurrent)
        host.close()
        XCTAssertFalse(intent.isCurrent)
    }
    func testReentrantBindingSetterCannotPublishRetiredURLIntent() async throws {
        let host = await loadedHost()
        let originalBinding = try XCTUnwrap(host.caller.currentJavaScriptBindingToken)
        let intent = WebViewURLTransitionIntent(
            destinationURL: URL(string: "https://example.invalid/native-transition/B")!,
            javaScriptBindingToken: originalBinding)
        var replaced = false
        host.state.onStateSet = {
            guard !replaced else { return }
            replaced = true
            host.state.onStateSet = nil
            host.coordinator.installScriptCallerBinding(for: host.view,
                asyncCaller: { _, _, _, _ in .init(nil) }, unsafeCaller: nil, snapshotCapture: nil)
        }
        _ = host.coordinator.setLoading(false, pageURL: intent.destinationURL, urlTransitionIntent: intent)
        XCTAssertTrue(replaced)
        XCTAssertNotEqual(originalBinding, host.caller.currentJavaScriptBindingToken)
        XCTAssertEqual(host.state.publications.count, 0,
            "A Binding setter that replaces native ownership must suppress the original callback")
    }

}
