#if os(iOS)
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
private final class BottomLayoutHeldWebView: WKWebView {
    enum ScrollSemantics { case vertical, horizontal, unavailable }

    private var completions: [@MainActor @Sendable (Any?, Error?) -> Void] = []
    var nextScrollSemantics: ScrollSemantics?
    var pendingLayoutCount: Int { completions.count }

    override func __callAsyncJavaScript(
        _ functionBody: String,
        arguments: [String: Any]?,
        inFrame frame: WKFrameInfo?,
        in contentWorld: WKContentWorld,
        completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)? = nil
    ) {
        if let completionHandler {
            completions.append(completionHandler)
        }
    }

    override func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)? = nil
    ) {
        guard let nextScrollSemantics else {
            super.evaluateJavaScript(javaScriptString, completionHandler: completionHandler)
            return
        }
        self.nextScrollSemantics = nil
        switch nextScrollSemantics {
        case .vertical:
            completionHandler?(["axis": "vertical", "horizontalForwardSign": 1], nil)
        case .horizontal:
            completionHandler?(["axis": "horizontal", "horizontalForwardSign": 1], nil)
        case .unavailable:
            completionHandler?(nil, URLError(.cannotDecodeContentData))
        }
    }

    func completeLayout(error: Error? = nil, semantics: ScrollSemantics = .vertical) {
        guard !completions.isEmpty else {
            XCTFail("Expected a renderer layout wait")
            return
        }
        nextScrollSemantics = semantics
        defer { nextScrollSemantics = nil }
        completions.removeFirst()(true, error)
    }
}

@MainActor
final class WebViewScrollOwnershipTests: XCTestCase {
    private func fixture(
        scriptCaller: WebViewScriptCaller? = nil,
        publish: @escaping @MainActor (Bool) -> Void
    ) -> (WebViewCoordinator, BottomLayoutHeldWebView) {
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        let model = WebView(navigator: navigator, state: .constant(.empty),
                            scriptCaller: scriptCaller, onScrollBottomStateChanged: publish)
        let coordinator = model.makeCoordinatorForTesting()
        let view = BottomLayoutHeldWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480),
                                           configuration: WKWebViewConfiguration())
        navigator.webView = view
        view.scrollView.bounds = view.bounds
        view.scrollView.contentSize = CGSize(width: 320, height: 240)
        return (coordinator, view)
    }

    func testCommittedDocumentBlocksPreLayoutGeometryAndPublishesNewGeometry() {
        var publications: [Bool] = []
        let (coordinator, view) = fixture { publications.append($0) }
        defer { coordinator.tearDownBindingsForDetachedWebView(view) }
        coordinator.webView(view, didCommit: nil)
        coordinator.scrollViewDidScroll(view.scrollView)
        XCTAssertTrue(publications.isEmpty)

        coordinator.webView(view, didFinish: nil)
        coordinator.publishScrollBottomState(for: view.scrollView)
        XCTAssertTrue(publications.isEmpty)
        view.scrollView.contentSize.height = 960
        view.completeLayout()
        XCTAssertEqual(publications, [false])

        view.scrollView.contentOffset.y = 480
        coordinator.scrollViewDidScroll(view.scrollView)
        XCTAssertEqual(publications, [false, true])
    }

    func testActiveRendererWaitRearmsForNewBindingAndObserverInstallation() {
        var publications: [Bool] = []
        let (coordinator, view) = fixture(scriptCaller: WebViewScriptCaller()) { publications.append($0) }
        defer { coordinator.tearDownBindingsForDetachedWebView(view) }
        func installBinding() {
            coordinator.installScriptCallerBinding(for: view,
                asyncCaller: { _, _, _, _ in .init(nil) }, unsafeCaller: nil, snapshotCapture: nil)
        }
        installBinding()
        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        let context = coordinator.captureDocumentCallbackContext(for: view)
        XCTAssertNotNil(context)
        XCTAssertEqual(view.pendingLayoutCount, 1)
        let oldBinding = coordinator.javaScriptBindingToken(for: view)
        XCTAssertNotNil(oldBinding)
        installBinding()
        XCTAssertNotEqual(coordinator.javaScriptBindingToken(for: view), oldBinding)
        XCTAssertEqual(coordinator.captureDocumentCallbackContext(for: view), context)
        view.completeLayout(error: URLError(.cancelled))
        XCTAssertEqual(view.pendingLayoutCount, 1)
        XCTAssertTrue(publications.isEmpty)

        coordinator.onScrollBottomStateChanged = nil
        coordinator.installScrollBottomStateObservations(for: view.scrollView)
        coordinator.onScrollBottomStateChanged = { publications.append($0) }
        coordinator.installScrollBottomStateObservations(for: view.scrollView)
        XCTAssertEqual(view.pendingLayoutCount, 2)
        view.completeLayout()
        XCTAssertTrue(publications.isEmpty)
        view.completeLayout()
        XCTAssertEqual(publications, [true])
    }

    func testSameHostReinstallationRearmsPendingAndCompletedLayout() {
        var publications: [Bool] = []
        let (coordinator, view) = fixture { publications.append($0) }
        defer { coordinator.tearDownBindingsForDetachedWebView(view) }
        coordinator.setWebView(view)
        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        let context = coordinator.captureDocumentCallbackContext(for: view)
        XCTAssertNotNil(context)
        XCTAssertEqual(view.pendingLayoutCount, 1)

        coordinator.setWebView(view)
        XCTAssertEqual(coordinator.captureDocumentCallbackContext(for: view), context)
        XCTAssertEqual(view.pendingLayoutCount, 2)
        view.completeLayout()
        XCTAssertTrue(publications.isEmpty, "Observer reinstallation retired the first wait")
        view.completeLayout()
        XCTAssertEqual(publications, [true])

        coordinator.setWebView(view)
        XCTAssertEqual(coordinator.captureDocumentCallbackContext(for: view), context)
        XCTAssertEqual(view.pendingLayoutCount, 1, "A finished document will not send another finish callback")
        coordinator.publishScrollBottomState(for: view.scrollView)
        XCTAssertEqual(publications, [true])
        view.completeLayout()
        XCTAssertEqual(publications, [true, true])
    }

    func testCurrentRendererErrorRecoversOnNextNativeGeometryWithoutRetry() {
        var publications: [Bool] = []
        let (coordinator, view) = fixture { publications.append($0) }
        defer { coordinator.tearDownBindingsForDetachedWebView(view) }
        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        view.completeLayout(error: URLError(.cannotDecodeContentData))
        XCTAssertTrue(publications.isEmpty)

        coordinator.webView(view, didFinish: nil)
        XCTAssertEqual(view.pendingLayoutCount, 0)
        view.scrollView.contentSize.height = 960
        view.nextScrollSemantics = .vertical
        coordinator.scrollViewDidScroll(view.scrollView)
        XCTAssertEqual(publications, [false])
    }

    func testFailedSemanticsDoesNotUseDefaultVerticalAxisForBottom() {
        var publications: [Bool] = []
        let (coordinator, view) = fixture { publications.append($0) }
        defer { coordinator.tearDownBindingsForDetachedWebView(view) }
        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        view.scrollView.contentSize = CGSize(width: 960, height: 240)
        view.completeLayout(semantics: .unavailable)
        XCTAssertTrue(publications.isEmpty)
        XCTAssertFalse(coordinator.canPublishScrollBottomState(for: view))

        view.nextScrollSemantics = .unavailable
        coordinator.scrollViewDidScroll(view.scrollView)
        XCTAssertTrue(publications.isEmpty)
        XCTAssertFalse(coordinator.canPublishScrollBottomState(for: view))

        view.nextScrollSemantics = .horizontal
        coordinator.scrollViewDidScroll(view.scrollView)
        XCTAssertEqual(publications, [false])
        view.scrollView.contentOffset.x = 640
        coordinator.scrollViewDidScroll(view.scrollView)
        XCTAssertEqual(publications, [false, true])
    }

    func testTerminalDocumentCannotPublishWhileSuccessorLayoutIsPending() {
        for terminate in [true, false] {
            var publications: [Bool] = []
            let (coordinator, view) = fixture { publications.append($0) }
            defer { coordinator.tearDownBindingsForDetachedWebView(view) }
            coordinator.webView(view, didCommit: nil)
            coordinator.webView(view, didFinish: nil)
            if terminate {
                coordinator.webViewWebContentProcessDidTerminate(view)
            } else {
                coordinator.webView(view, didFail: nil, withError: URLError(.cannotLoadFromNetwork))
            }
            coordinator.scrollViewDidScroll(view.scrollView)
            XCTAssertTrue(publications.isEmpty)
            view.completeLayout()
            XCTAssertTrue(publications.isEmpty)

            coordinator.webView(view, didCommit: nil)
            coordinator.webView(view, didFinish: nil)
            coordinator.scrollViewDidScroll(view.scrollView)
            XCTAssertTrue(publications.isEmpty)
            view.scrollView.contentSize.height = 960
            view.completeLayout()
            XCTAssertEqual(publications, [false])
        }
    }

    func testPreservedProvisionalFailureRearmsSurvivingDocumentLayout() {
        var publications: [Bool] = []
        let (coordinator, view) = fixture { publications.append($0) }
        defer { coordinator.tearDownBindingsForDetachedWebView(view) }
        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        view.completeLayout()
        XCTAssertEqual(publications, [true])

        coordinator.webView(view, didStartProvisionalNavigation: nil)
        coordinator.webView(view, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))
        XCTAssertEqual(view.pendingLayoutCount, 1)
        view.scrollView.contentSize.height = 960
        coordinator.scrollViewDidScroll(view.scrollView)
        XCTAssertEqual(publications, [true])
        view.completeLayout()
        XCTAssertEqual(publications, [true, false])
    }

    func testSuppressedRevealRemainsScopedToCurrentDocumentAndDrag() {
        let (coordinator, view) = fixture { _ in }
        defer { coordinator.tearDownBindingsForDetachedWebView(view) }
        let navigator = coordinator.navigator
        let scrollView = view.scrollView
        let unrelatedScrollView = UIScrollView()
        navigator.suppressNavigationRevealForCurrentDrag()
        XCTAssertTrue(navigator.allowsScrollDrivenNavigationVisibility(false, for: scrollView))

        navigator.scrollViewSuppressingNavigationReveal = scrollView
        XCTAssertFalse(navigator.allowsScrollDrivenNavigationVisibility(false, for: scrollView))
        XCTAssertTrue(navigator.allowsScrollDrivenNavigationVisibility(true, for: scrollView))
        coordinator.scrollViewDidEndDragging(unrelatedScrollView, willDecelerate: false)
        XCTAssertFalse(navigator.allowsScrollDrivenNavigationVisibility(false, for: scrollView))
        coordinator.scrollViewDidEndDragging(scrollView, willDecelerate: true)
        XCTAssertTrue(navigator.allowsScrollDrivenNavigationVisibility(false, for: scrollView))

        navigator.scrollViewSuppressingNavigationReveal = scrollView
        coordinator.scrollViewWillBeginDragging(scrollView)
        XCTAssertTrue(navigator.allowsScrollDrivenNavigationVisibility(false, for: scrollView))
        navigator.scrollViewSuppressingNavigationReveal = scrollView
        coordinator.webView(view, didCommit: nil)
        XCTAssertTrue(navigator.allowsScrollDrivenNavigationVisibility(false, for: scrollView))

        navigator.scrollViewSuppressingNavigationReveal = scrollView
        navigator.webView = WKWebView(frame: view.frame, configuration: WKWebViewConfiguration())
        XCTAssertTrue(navigator.allowsScrollDrivenNavigationVisibility(false, for: scrollView))
    }

    func testStaleScrollViewCallbacksDoNotMutateCurrentNavigationState() {
        let navigator = WebViewNavigator()
        let webViewModel = WebView(
            navigator: navigator,
            state: .constant(.empty)
        )
        let coordinator = webViewModel.makeCoordinatorForTesting()
        let currentWebView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        let staleWebView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            configuration: WKWebViewConfiguration()
        )
        navigator.webView = currentWebView
        coordinator.lastContentOffset = CGPoint(x: 3, y: 5)
        coordinator.accumulatedScrollOffset = 17
        staleWebView.scrollView.contentOffset = CGPoint(x: 80, y: 120)

        coordinator.scrollViewWillBeginDragging(staleWebView.scrollView)
        coordinator.scrollViewDidEndDragging(staleWebView.scrollView, willDecelerate: false)
        coordinator.scrollViewDidEndDecelerating(staleWebView.scrollView)
        coordinator.scrollViewDidScroll(staleWebView.scrollView)

        XCTAssertEqual(coordinator.lastContentOffset, CGPoint(x: 3, y: 5))
        XCTAssertEqual(coordinator.accumulatedScrollOffset, 17)
    }
}
#endif
