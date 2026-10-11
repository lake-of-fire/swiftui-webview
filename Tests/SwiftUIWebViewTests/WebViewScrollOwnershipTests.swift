#if os(iOS)
import SwiftUI
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
final class WebViewScrollOwnershipTests: XCTestCase {
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
