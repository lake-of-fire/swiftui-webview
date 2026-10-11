#if os(iOS)
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import SwiftUIWebView

/// Runs the production script in WebKit, then holds only its delivery so document
/// replacement can be exercised deterministically between dispatch and completion.
@MainActor
private final class ScrollCompletionHeldWebView: EnhancedWKWebView {
    var holdNextEvaluation = false
    var evaluationFinished: XCTestExpectation?
    var heldDelivery: (() -> Void)?
    private(set) var heldError: Error?

    override func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)? = nil
    ) {
        guard holdNextEvaluation else {
            super.evaluateJavaScript(javaScriptString, completionHandler: completionHandler)
            return
        }
        holdNextEvaluation = false
        super.evaluateJavaScript(javaScriptString) { [weak self] value, error in
            guard let self else { return }
            self.heldError = error
            self.heldDelivery = { completionHandler?(value, error) }
            self.evaluationFinished?.fulfill()
        }
    }

    func deliver() {
        let delivery = heldDelivery
        heldDelivery = nil
        delivery?()
    }
}

@MainActor
private final class ScrollCompletionLoadDelegate: NSObject, WKNavigationDelegate {
    let finished: XCTestExpectation
    var error: Error?
    init(_ finished: XCTestExpectation) { self.finished = finished }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished.fulfill() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
        finished.fulfill()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        finished.fulfill()
    }
}

@MainActor
final class WebViewScrollCompletionOwnershipTests: XCTestCase {
    private func fixture() -> (WebViewCoordinator, ScrollCompletionHeldWebView) {
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        let model = WebView(navigator: navigator, state: .constant(.empty))
        let coordinator = model.makeCoordinatorForTesting()
        let view = ScrollCompletionHeldWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        coordinator.setWebView(view)
        return (coordinator, view)
    }

    private func load(_ html: String, in view: WKWebView) async throws {
        let loaded = expectation(description: "WebKit document loaded")
        let delegate = ScrollCompletionLoadDelegate(loaded)
        view.navigationDelegate = delegate
        defer { view.navigationDelegate = nil }
        // These fixtures are body fragments. Supply a standards-mode document
        // so scrollingElement and root inference use a defined DOM contract.
        let document = "<!doctype html><html><head><meta charset='utf-8'></head>\(html)</body></html>"
        view.loadHTMLString(document, baseURL: URL(string: "https://example.invalid/scroll-completion"))
        await fulfillment(of: [loaded], timeout: 10)
        XCTAssertNil(delegate.error)
    }

    private func captureSemantics(_ coordinator: WebViewCoordinator,
                                  _ view: ScrollCompletionHeldWebView) async throws {
        let evaluated = expectation(description: "Production semantics script evaluated")
        view.evaluationFinished = evaluated
        view.holdNextEvaluation = true
        coordinator.scrollViewWillBeginDragging(view.scrollView)
        await fulfillment(of: [evaluated], timeout: 10)
        XCTAssertNil(view.heldError)
        XCTAssertNotNil(view.heldDelivery)
    }

    func testAllNativeCompletionCallbacksRefreshOnlyTheCurrentHost() {
        let (coordinator, view) = fixture()
        defer { coordinator.tearDownBindingsForDetachedWebView(view) }
        let initialReason = coordinator.paginationController.lastApplyReason
        coordinator.accumulatedScrollOffset = 17
        coordinator.scrollViewDidEndDragging(view.scrollView, willDecelerate: true)
        XCTAssertEqual(coordinator.accumulatedScrollOffset, 17)
        XCTAssertEqual(coordinator.paginationController.lastApplyReason, initialReason)
        coordinator.scrollViewDidEndDragging(view.scrollView, willDecelerate: false)
        XCTAssertEqual(coordinator.paginationController.lastApplyReason, "scroll.endDrag")
        XCTAssertEqual(coordinator.accumulatedScrollOffset, 0)
        coordinator.scrollViewDidEndDecelerating(view.scrollView)
        XCTAssertEqual(coordinator.paginationController.lastApplyReason, "scroll.endDecelerating")
        coordinator.scrollViewDidEndScrollingAnimation(view.scrollView)
        XCTAssertEqual(coordinator.paginationController.lastApplyReason, "scroll.endAnimation")

        let replacement = WKWebView(frame: view.frame, configuration: WKWebViewConfiguration())
        coordinator.setWebView(replacement)
        defer { coordinator.tearDownBindingsForDetachedWebView(replacement) }
        var stalePublications = 0
        coordinator.onScrollBottomStateChanged = { _ in stalePublications += 1 }
        coordinator.lastPublishedScrollBottomState = nil
        coordinator.accumulatedScrollOffset = 23
        coordinator.lastContentOffset = CGPoint(x: 7, y: 11)
        coordinator.scrollViewDidEndDragging(view.scrollView, willDecelerate: false)
        coordinator.scrollViewDidEndDecelerating(view.scrollView)
        coordinator.scrollViewDidEndScrollingAnimation(view.scrollView)
        XCTAssertEqual(coordinator.paginationController.lastApplyReason, "scroll.endAnimation")
        XCTAssertEqual(stalePublications, 0)
        XCTAssertEqual(coordinator.accumulatedScrollOffset, 23)
        XCTAssertEqual(coordinator.lastContentOffset, CGPoint(x: 7, y: 11))
    }

    func testBottomStatePublicationCannotRedirectCompletionReadbackToReplacement() {
        let (coordinator, view) = fixture()
        let replacement = WKWebView(frame: view.frame, configuration: WKWebViewConfiguration())
        defer {
            coordinator.onScrollBottomStateChanged = nil
            coordinator.tearDownBindingsForDetachedWebView(view)
            coordinator.tearDownBindingsForDetachedWebView(replacement)
        }
        let initialReason = coordinator.paginationController.lastApplyReason
        coordinator.onScrollBottomStateChanged = { _ in coordinator.setWebView(replacement) }
        coordinator.lastPublishedScrollBottomState = nil
        coordinator.scrollViewDidEndScrollingAnimation(view.scrollView)
        XCTAssertEqual(coordinator.paginationController.lastApplyReason, initialReason)
        XCTAssertEqual(coordinator.paginationController.currentState().mountedHostIdentifier,
                       WebViewPaginationController.hostIdentifier(for: replacement))
    }

    func testDragStartPublicationCannotOverwriteReplacementScrollState() {
        let (coordinator, view) = fixture()
        let replacement = WKWebView(frame: view.frame, configuration: .init())
        defer {
            coordinator.onScrollBottomStateChanged = nil
            coordinator.tearDownBindingsForDetachedWebView(view)
            coordinator.tearDownBindingsForDetachedWebView(replacement)
        }
        coordinator.onScrollBottomStateChanged = { _ in
            coordinator.setWebView(replacement)
            coordinator.accumulatedScrollOffset = 29
            coordinator.lastContentOffset = CGPoint(x: 13, y: 19)
        }
        coordinator.lastPublishedScrollBottomState = nil
        coordinator.scrollViewWillBeginDragging(view.scrollView)
        XCTAssertEqual(coordinator.accumulatedScrollOffset, 29)
        XCTAssertEqual(coordinator.lastContentOffset, CGPoint(x: 13, y: 19))
    }

    func testNestedScrollCallbackKeepsItsOwnStateOnTheSameHost() {
        let (coordinator, view) = fixture()
        defer {
            coordinator.onScrollBottomStateChanged = nil
            coordinator.tearDownBindingsForDetachedWebView(view)
        }
        coordinator.onScrollBottomStateChanged = { _ in
            coordinator.scrollViewDidEndScrollingAnimation(view.scrollView)
            coordinator.accumulatedScrollOffset = 31
            coordinator.lastContentOffset = CGPoint(x: 17, y: 23)
        }
        coordinator.lastPublishedScrollBottomState = nil
        coordinator.scrollViewWillBeginDragging(view.scrollView)
        XCTAssertEqual(coordinator.paginationController.lastApplyReason, "scroll.endAnimation")
        XCTAssertEqual(coordinator.accumulatedScrollOffset, 31)
        XCTAssertEqual(coordinator.lastContentOffset, CGPoint(x: 17, y: 23))
    }

    func testDocumentInvalidationDuringBottomPublicationRejectsCompletionReadback() {
        let (coordinator, view) = fixture()
        defer {
            coordinator.onScrollBottomStateChanged = nil
            coordinator.tearDownBindingsForDetachedWebView(view)
        }
        coordinator.webView(view, didCommit: nil)
        let reason = coordinator.paginationController.lastApplyReason
        coordinator.accumulatedScrollOffset = 37
        coordinator.lastContentOffset = CGPoint(x: 11, y: 29)
        coordinator.onScrollBottomStateChanged = { _ in
            coordinator.webView(view, didStartProvisionalNavigation: nil)
        }
        coordinator.lastPublishedScrollBottomState = nil
        coordinator.scrollViewDidEndDragging(view.scrollView, willDecelerate: false)
        XCTAssertEqual(coordinator.paginationController.lastApplyReason, reason)
        XCTAssertEqual(coordinator.accumulatedScrollOffset, 37)
        XCTAssertEqual(coordinator.lastContentOffset, CGPoint(x: 11, y: 29))
    }

    func testRuntimeProvidersReaderInferenceAndOrdinaryWritingModes() async throws {
        // In HTML, WebKit propagates the body's writing mode to the root's
        // computed style. Opposing authored html/body styles do not establish
        // a vertical computed root. Remove the body to exercise root fallback
        // against a genuinely vertical documentElement, without a provider.
        let rootOnlyHTML = "<body style='writing-mode:horizontal-tb'><script>document.documentElement.style.writingMode = 'vertical-lr'; document.body.remove();</script>"
        let cases: [(String, Bool, CGFloat)] = [
            ("<body style='writing-mode:vertical-rl'><script>window.__swiftUIWebViewNavigationScrollSemantics = () => ({axis:'vertical',horizontalForwardSign:1});</script>", false, 1),
            ("<body><script>window.__swiftUIWebViewNavigationScrollSemantics = {axis:'horizontal',horizontalForwardSign:-1};</script>", true, -1),
            ("<body style='writing-mode:vertical-lr'><script>window.__swiftUIWebViewNavigationScrollSemantics = () => ({axis:'invalid'});</script>", true, 1),
            ("<body style='writing-mode:vertical-rl'><script>window.__swiftUIWebViewNavigationScrollSemantics = {axis:'invalid'};</script>", true, -1),
            ("<body style='writing-mode:vertical-rl'><script>window.__swiftUIWebViewNavigationScrollSemantics = () => {throw Error('optional provider')};</script>", true, -1),
            ("<body style='writing-mode:vertical-rl'>ordinary rl", true, -1),
            ("<body style='writing-mode:vertical-lr'>ordinary lr", true, 1),
            (rootOnlyHTML, true, 1),
            ("<body>ordinary horizontal writing", false, 1),
            ("<body class='readability-mode'><div id='reader-content' style='writing-mode:vertical-rl'>reader</div><script>window.manabiResolveReaderWritingDirection = () => {throw Error('optional reader resolver')};</script>", true, -1),
            ("<body><script>window.manabiResolveReaderWritingDirection = () => {throw Error('optional reader resolver')};</script>", false, 1),
            ("<body class='readability-mode'><div id='reader-content' style='writing-mode:vertical-rl'>reader</div>", true, -1),
            ("<body class='readability-mode'><script>window.manabiResolveReaderWritingDirection = () => ({vertical:true,verticalRTL:false});</script>reader inferred", true, 1),
            ("<body class='readability-mode'><div id='reader-content' style='writing-mode:vertical-rl'>reader</div><script>window.__swiftUIWebViewNavigationScrollSemantics = {axis:'vertical'};</script>", false, 1),
            ("<body><script>window.__swiftUIWebViewNavigationScrollSemantics = {axis:'horizontal',horizontalForwardSign:'-1'};</script>", true, 1)
        ]
        let (coordinator, view) = fixture()
        defer { coordinator.tearDownBindingsForDetachedWebView(view) }
        for (html, horizontal, sign) in cases {
            try await load(html, in: view)
            if html == rootOnlyHTML {
                let roots = try await view.evaluateJavaScript("""
                    ({hasBody: document.body !== null,
                      standardsMode: document.compatMode === 'CSS1Compat',
                      scrollingRoot: document.scrollingElement === document.documentElement,
                      rootMode: getComputedStyle(document.documentElement).writingMode,
                      hasProvider: window.__swiftUIWebViewNavigationScrollSemantics !== undefined})
                    """) as? [String: Any]
                XCTAssertEqual(roots?["hasBody"] as? Bool, false)
                XCTAssertEqual(roots?["standardsMode"] as? Bool, true)
                XCTAssertEqual(roots?["scrollingRoot"] as? Bool, true)
                XCTAssertEqual(roots?["rootMode"] as? String, "vertical-lr")
                XCTAssertEqual(roots?["hasProvider"] as? Bool, false)
            }
            coordinator.webView(view, didCommit: nil)
            try await captureSemantics(coordinator, view)
            view.deliver()
            XCTAssertEqual(coordinator.navigationScrollAxis == .horizontal, horizontal, html)
            XCTAssertEqual(coordinator.horizontalForwardSign, sign, html)
        }
    }

    func testNewerSemanticsReadbackWinsWithinTheSameDocument() async throws {
        let (coordinator, view) = fixture()
        defer { coordinator.tearDownBindingsForDetachedWebView(view) }
        try await load("<body style='writing-mode:vertical-rl'>initial semantics", in: view)
        coordinator.webView(view, didCommit: nil)
        try await captureSemantics(coordinator, view)
        let oldDelivery = view.heldDelivery
        view.heldDelivery = nil
        _ = try await view.evaluateJavaScript("window.__swiftUIWebViewNavigationScrollSemantics = {axis:'vertical'}")
        try await captureSemantics(coordinator, view)
        view.deliver()
        XCTAssertTrue(coordinator.navigationScrollAxis == .vertical)
        oldDelivery?()
        XCTAssertTrue(coordinator.navigationScrollAxis == .vertical)
        XCTAssertEqual(coordinator.horizontalForwardSign, 1)
    }

    func testSameWebViewDocumentReplacementRejectsHeldRuntimeCompletion() async throws {
        let (coordinator, view) = fixture()
        defer { coordinator.tearDownBindingsForDetachedWebView(view) }
        try await load("<body style='writing-mode:vertical-rl'>old document", in: view)
        coordinator.webView(view, didCommit: nil)
        try await captureSemantics(coordinator, view)
        try await load("<body>replacement document", in: view)
        coordinator.webView(view, didCommit: nil)
        coordinator.navigationScrollAxis = .vertical
        coordinator.horizontalForwardSign = 1
        view.deliver()
        XCTAssertTrue(coordinator.navigationScrollAxis == .vertical)
        XCTAssertEqual(coordinator.horizontalForwardSign, 1)
    }

    func testReplacedHostRejectsHeldRuntimeCompletion() async throws {
        let (coordinator, view) = fixture()
        defer { coordinator.tearDownBindingsForDetachedWebView(view) }
        try await load("<body style='writing-mode:vertical-rl'>old host", in: view)
        coordinator.webView(view, didCommit: nil)
        try await captureSemantics(coordinator, view)
        let replacement = WKWebView(frame: view.frame, configuration: WKWebViewConfiguration())
        coordinator.setWebView(replacement)
        defer { coordinator.tearDownBindingsForDetachedWebView(replacement) }
        view.deliver()
        XCTAssertTrue(coordinator.navigationScrollAxis == .vertical)
        XCTAssertEqual(coordinator.horizontalForwardSign, 1)
    }
}
#endif
