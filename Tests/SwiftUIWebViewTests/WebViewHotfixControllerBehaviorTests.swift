#if os(iOS)
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
private final class HotfixSafeAreaWindow: UIWindow {
    override var safeAreaInsets: UIEdgeInsets { UIEdgeInsets(top: 24, left: 6, bottom: 20, right: 6) }
}

/// Holds WebKit's public navigation policy boundary before provisional start.
@MainActor
private final class HotfixPendingNavigationDelegate: NSObject, WKNavigationDelegate {
    let reachedPolicy: XCTestExpectation
    var decision: ((WKNavigationActionPolicy) -> Void)?
    init(_ reachedPolicy: XCTestExpectation) { self.reachedPolicy = reachedPolicy }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decision = decisionHandler
        reachedPolicy.fulfill()
    }
    func cancel() {
        let handler = decision
        decision = nil
        handler?(.cancel)
    }
}

@MainActor
private final class HotfixPendingRequestWebView: EnhancedWKWebView {
    var requests: [URLRequest] = []
    var issuedNavigation: WKNavigation?

    override func load(_ request: URLRequest) -> WKNavigation? {
        requests.append(request)
        let navigation = super.load(request)
        issuedNavigation = navigation
        return navigation
    }
}

@MainActor
private final class HotfixReaderRequestBoundary: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
    let policy: XCTestExpectation
    let coordinator: WebViewCoordinator
    let expectedRequestURL: URL
    private var didHoldPolicy = false
    var decision: ((WKNavigationActionPolicy) -> Void)?

    init(policy: XCTestExpectation, coordinator: WebViewCoordinator, expectedRequestURL: URL) {
        self.policy = policy
        self.coordinator = coordinator
        self.expectedRequestURL = expectedRequestURL
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !didHoldPolicy, navigationAction.request.url == expectedRequestURL else {
            decisionHandler(.allow)
            return
        }
        didHoldPolicy = true
        decision = decisionHandler
        policy.fulfill()
    }

    // The test delivers this receipt at the held policy boundary, while the
    // outgoing URL is still observable. Do not deliver it a second time.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        coordinator.webView(webView, didCommit: navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        coordinator.webView(webView, didFinish: navigation)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let html = """
        <html data-mnb-reader-render-ready="1"><body>
        <script>history.replaceState(null, '', 'internal://local/reader-final');</script>
        <main id="reader-content">本文</main></body></html>
        """
        let bytes = Data(html.utf8)
        urlSchemeTask.didReceive(URLResponse(url: urlSchemeTask.request.url!, mimeType: "text/html",
                                            expectedContentLength: bytes.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(bytes)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor
final class WebViewHotfixControllerBehaviorTests: XCTestCase {
    func testPendingRequestStartWithOutgoingURLCannotReplayAfterReaderReady() async throws {
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        let ready = expectation(description: "production document summary publishes render readiness")
        var state = WebViewState.empty
        var didPublishReady = false
        let model = WebView(navigator: navigator, state: Binding(get: { state }, set: {
            state = $0
            if state.hasReaderRenderReady, !didPublishReady {
                didPublishReady = true
                ready.fulfill()
            }
        }))
        let coordinator = model.makeCoordinatorForTesting()
        let policy = expectation(description: "mounted request reaches native policy")
        let request = URLRequest(url: URL(string: "internal://local/load/reader")!)
        let boundary = HotfixReaderRequestBoundary(
            policy: policy,
            coordinator: coordinator,
            expectedRequestURL: request.url!
        )
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(boundary, forURLScheme: "internal")
        let web = HotfixPendingRequestWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480),
                                             configuration: configuration)
        let controller = WebViewController(webView: web)
        let window = HotfixSafeAreaWindow(frame: web.frame)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        defer {
            let decision = boundary.decision
            boundary.decision = nil
            decision?(.cancel)
            coordinator.tearDownBindingsForDetachedWebView(web)
            web.stopLoading()
            web.navigationDelegate = nil
            window.isHidden = true
            window.rootViewController = nil
        }
        // Begin only after the real reader host has completed attachment and layout.
        web.navigationDelegate = boundary
        coordinator.setWebView(web)
        navigator.load(request)
        await fulfillment(of: [policy], timeout: 10)
        let navigation = try XCTUnwrap(web.issuedNavigation)
        XCTAssertNotEqual(web.url, request.url, "Policy must still expose the outgoing document")
        coordinator.webView(web, didStartProvisionalNavigation: navigation)
        let decision = try XCTUnwrap(boundary.decision)
        boundary.decision = nil
        decision(.allow)
        await fulfillment(of: [ready], timeout: 10)
        let finalURL = URL(string: "internal://local/reader-final")!
        XCTAssertEqual(web.url, finalURL, "The actual document must have replaced its loader URL")
        XCTAssertEqual(state.pageURL, finalURL)
        let issuedCount = web.requests.count
        let readyURL = state.pageURL
        // The real host rechecks attachment after final document readiness.
        navigator.handleWindowAttachmentChanged(webView: web)
        XCTAssertEqual(web.requests.count, issuedCount, "A consumed request cannot replay after readiness")
        XCTAssertEqual(state.pageURL, readyURL)
        XCTAssertTrue(state.hasReaderRenderReady)
        let text = try await web.evaluateJavaScript("document.getElementById('reader-content').textContent")
        XCTAssertEqual(text as? String, "本文")
    }

    private func host(size: CGSize = CGSize(width: 320, height: 480)) -> (UIWindow, WebViewController) {
        let web = EnhancedWKWebView(frame: CGRect(origin: .zero, size: size), configuration: .init())
        web.scrollView.contentInsetAdjustmentBehavior = .never
        let controller = WebViewController(webView: web)
        let window = HotfixSafeAreaWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        return (window, controller)
    }

    private func publishedTop(in webView: WKWebView) async throws -> Double? {
        let value = try await webView.evaluateJavaScript("window.__swiftUIWebViewObscuredInsets?.obscuredTopInset ?? null")
        return (value as? NSNumber)?.doubleValue
    }

    private func awaitPublishedTop(_ expected: Double, in webView: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(2)
        var actual = try await publishedTop(in: webView)
        while actual != expected && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            actual = try await publishedTop(in: webView)
        }
        XCTAssertEqual(actual, expected)
    }

    private func assertPublishedTopRemains(_ expected: Double, in webView: WKWebView) async throws {
        // A single Task.yield is not a dispatch/completion barrier. Observe real
        // WebKit state across a bounded window while pending main-actor work runs.
        let deadline = Date().addingTimeInterval(0.1)
        repeat {
            let actual = try await publishedTop(in: webView)
            XCTAssertEqual(actual, expected)
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
    }

    func testPaginatedSelectionCollapseResetAndStoreReplacementRestoreConfiguredScrolling() {
        let (window, controller) = host()
        defer { window.isHidden = true; window.rootViewController = nil }
        let old = WebViewNativeLookupHitTestStore()
        let current = WebViewNativeLookupHitTestStore()
        controller.setNativeLookupHitTestStore(old)
        controller.configureWebTextSelectionScrollSuppression(isScrollEnabled: true, isPaginated: true, reason: "test")
        old.updateWebTextSelection(active: true, textLength: 3, source: "test")
        XCTAssertFalse(controller.webView.scrollView.isScrollEnabled)
        old.updateWebTextSelection(active: false, textLength: 0, source: "collapse")
        XCTAssertTrue(controller.webView.scrollView.isScrollEnabled)
        old.updateWebTextSelection(active: true)
        old.removeAllTargets()
        XCTAssertTrue(controller.webView.scrollView.isScrollEnabled)
        old.updateWebTextSelection(active: true)
        controller.setNativeLookupHitTestStore(current)
        XCTAssertTrue(controller.webView.scrollView.isScrollEnabled)
        old.updateWebTextSelection(active: false)
        old.updateWebTextSelection(active: true)
        XCTAssertTrue(controller.webView.scrollView.isScrollEnabled, "Retired store callbacks cannot suppress the current host")
        current.updateWebTextSelection(active: true)
        XCTAssertFalse(controller.webView.scrollView.isScrollEnabled)
        controller.configureWebTextSelectionScrollSuppression(isScrollEnabled: true, isPaginated: false, reason: "continuous")
        XCTAssertTrue(controller.webView.scrollView.isScrollEnabled)
        controller.configureWebTextSelectionScrollSuppression(isScrollEnabled: false, isPaginated: true, reason: "disabled")
        current.updateWebTextSelection(active: false)
        XCTAssertFalse(controller.webView.scrollView.isScrollEnabled)
    }

    func testCancellationReentrancyPreservesTheNewerSelectionStore() {
        let (window, controller) = host()
        defer { window.isHidden = true; window.rootViewController = nil }
        let old = WebViewNativeLookupHitTestStore()
        let superseded = WebViewNativeLookupHitTestStore()
        let current = WebViewNativeLookupHitTestStore()
        current.updateWebTextSelection(active: true)
        controller.setNativeLookupHitTestStore(old)
        controller.configureWebTextSelectionScrollSuppression(isScrollEnabled: true, isPaginated: true, reason: "test")
        old.onNativeTouchStreamFinished = { _ in
            old.onNativeTouchStreamFinished = nil
            controller.setNativeLookupHitTestStore(current)
        }
        controller.setNativeLookupHitTestStore(superseded)
        XCTAssertFalse(controller.webView.scrollView.isScrollEnabled)
        superseded.updateWebTextSelection(active: true)
        current.updateWebTextSelection(active: false)
        XCTAssertTrue(controller.webView.scrollView.isScrollEnabled)
    }

    func testPublicUIKitHitTestingPublishesOverlayObservationsAndPassesThrough() {
        let (window, controller) = host()
        defer { window.isHidden = true; window.rootViewController = nil }
        let store = WebViewNativeLookupHitTestStore(hitSlop: 0)
        controller.setNativeLookupHitTestStore(store)
        let rect = CGRect(x: 40, y: 40, width: 40, height: 40)
        store.updateTargets([WebViewNativeLookupHitTarget(elementID: "segment", rects: [rect])])
        var pointHits: [String?] = []
        var segmentHits: [String] = []
        var touchStarts = 0
        store.onOverlayPointHitTested = { _, _, target in pointHits.append(target?.elementID) }
        store.onOverlaySegmentHitObserved = { target, _, _ in segmentHits.append(target.elementID) }
        store.onTouchStartHitTested = { _, _, _ in touchStarts += 1 }
        let hit = controller.view.hitTest(CGPoint(x: rect.midX, y: rect.midY), with: nil)
        XCTAssertTrue(hit === controller.webView || hit?.isDescendant(of: controller.webView) == true)
        XCTAssertEqual(pointHits.count, 1)
        XCTAssertEqual(pointHits.compactMap { $0 }, ["segment"])
        XCTAssertEqual(segmentHits, ["segment"])
        _ = controller.view.hitTest(CGPoint(x: 200, y: 200), with: nil)
        XCTAssertEqual(pointHits.count, 2)
        XCTAssertNil(pointHits.last ?? nil)
        XCTAssertEqual(segmentHits, ["segment"])
        XCTAssertEqual(touchStarts, 0, "UIKit hit testing alone does not deliver a touch stream")
    }

    func testPendingInternalLoaderSuppressesActualInitialKVOPublicationsUntilSuperseded() async {
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        var state = WebViewState.empty
        state.loadingProgress = 0.42
        var publication: XCTestExpectation?
        var waitsForClearedProgress = false
        let readerURL = URL(string: "internal://local/load/reader")!
        let web = EnhancedWKWebView(frame: .zero, configuration: .init())
        let model = WebView(navigator: navigator, state: Binding(
            get: { state },
            set: {
                let previousProgress = state.loadingProgress
                state = $0
                // Pagination and setLoading's state publication are legitimate.
                // A changed progress must match real positive native progress;
                // stale initial idle/zero KVO must not replace either value.
                let invalidPendingProgress = state.loadingProgress == nil
                    || state.loadingProgress == 0
                    || (state.loadingProgress != previousProgress
                        && state.loadingProgress != web.estimatedProgress)
                if waitsForClearedProgress ? state.loadingProgress == nil : invalidPendingProgress {
                    publication?.fulfill()
                    if waitsForClearedProgress { publication = nil }
                }
            }
        ))
        let coordinator = model.makeCoordinatorForTesting()
        let reachedPolicy = expectation(description: "native load reached its pre-provisional policy boundary")
        let delegate = HotfixPendingNavigationDelegate(reachedPolicy)
        web.navigationDelegate = delegate
        defer {
            delegate.cancel()
            coordinator.tearDownBindingsForDetachedWebView(web)
            web.navigationDelegate = nil
        }
        // With no host, the public navigator records a pending HTML load and
        // publishes its native pre-provisional activity without starting WebKit.
        navigator.loadHTML("<body>pending reader</body>", baseURL: readerURL)
        XCTAssertTrue(WebViewReaderLoadActivity.shared.hasPendingPreProvisionalLoad)
        XCTAssertFalse(web.isLoading)
        XCTAssertEqual(web.estimatedProgress, 0)
        let suppressed = expectation(description: "pending loader cannot publish idle or zero KVO progress")
        suppressed.isInverted = true
        publication = suppressed
        // Binding flushes the HTML to real WebKit. The public policy delegate
        // holds it before provisional start while production observers receive
        // actual .initial and .new KVO receipts; no manual KVO or mocked getters.
        coordinator.setWebView(web)
        XCTAssertEqual(state.loadingProgress, 0.42, "Attaching observers must retain progress before native URL publication")
        await fulfillment(of: [reachedPolicy], timeout: 10)
        XCTAssertNotNil(delegate.decision)
        XCTAssertTrue(web.isLoading, "Cancellation must produce an actual native loading-to-idle transition")
        XCTAssertFalse(state.isProvisionallyNavigating)
        XCTAssertGreaterThan(web.estimatedProgress, 0)
        // The pending-load guard may retain the original progress rather than
        // publish the native value. URL handoff is allowed to publish native
        // progress, but it is not required to happen before provisional start.
        let retainedProgress = state.loadingProgress
        XCTAssertTrue(retainedProgress == 0.42 || retainedProgress == web.estimatedProgress)
        await fulfillment(of: [suppressed], timeout: 0.2)
        publication = nil
        XCTAssertEqual(state.loadingProgress, retainedProgress)

        // An ordinary request supersedes the native reader activity. This host
        // has no window, so the new request is deferred. Cancelling the held
        // WebKit load now produces a real idle KVO transition that must publish.
        let resumed = expectation(description: "ordinary idle KVO clears retained progress")
        waitsForClearedProgress = true
        publication = resumed
        navigator.load(URLRequest(url: URL(string: "https://controller.example")!))
        delegate.cancel()
        await fulfillment(of: [resumed], timeout: 10)
        publication = nil
        XCTAssertNil(state.loadingProgress)
    }

    func testQueuedDelayedProgressIsSuppressedByPendingInternalLoaderAndOrdinarySuccessorCanPublish() async throws {
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        var state = WebViewState.empty
        state.loadingProgress = 0.42
        var publication: XCTestExpectation?
        var expectedProgress: Double?
        let readerURL = URL(string: "internal://local/load/reader")!
        let nativeProgress = expectation(description: "reader URL publishes legitimate native progress")
        var nativeProgressPublication: XCTestExpectation? = nativeProgress
        let model = WebView(navigator: navigator, state: Binding(
            get: { state },
            set: {
                state = $0
                if state.pageURL == readerURL, state.isLoading,
                   let progress = state.loadingProgress, progress > 0, progress != 0.42 {
                    nativeProgressPublication?.fulfill()
                    nativeProgressPublication = nil
                }
                if state.loadingProgress == expectedProgress {
                    publication?.fulfill()
                    publication = nil
                }
            }
        ))
        let coordinator = model.makeCoordinatorForTesting()
        let web = EnhancedWKWebView(frame: .zero, configuration: .init())
        let reachedPolicy = expectation(description: "reader load held before provisional start")
        let delegate = HotfixPendingNavigationDelegate(reachedPolicy)
        web.navigationDelegate = delegate
        defer {
            publication = nil
            delegate.cancel()
            coordinator.tearDownBindingsForDetachedWebView(web)
            web.navigationDelegate = nil
        }

        let initialIdle = expectation(description: "initial native KVO publishes idle progress")
        publication = initialIdle
        coordinator.setWebView(web)
        await fulfillment(of: [initialIdle], timeout: 10)
        // Let both initial observation tasks settle before priming the throttle.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(web.isLoading)
        XCTAssertEqual(web.estimatedProgress, 0)

        coordinator.setLoading(true)
        XCTAssertEqual(state.loadingProgress, web.estimatedProgress)
        // The identical update within the 120 ms interval queues the real task.
        coordinator.setLoading(true)
        // Make a stale publication observable even though its progress matches
        // the last emitted value. This only changes the Binding's backing state.
        state.loadingProgress = 0.42
        let suppressed = expectation(description: "queued progress cannot overwrite pending reader progress")
        suppressed.isInverted = true
        expectedProgress = web.estimatedProgress
        publication = suppressed
        navigator.loadHTML("<body>pending reader</body>", baseURL: readerURL)
        XCTAssertTrue(WebViewReaderLoadActivity.shared.hasPendingPreProvisionalLoad)
        await fulfillment(of: [reachedPolicy, nativeProgress], timeout: 10)
        XCTAssertNotNil(delegate.decision)
        XCTAssertTrue(web.isLoading)
        XCTAssertFalse(state.isProvisionallyNavigating)
        let retainedNativeProgress = web.estimatedProgress
        XCTAssertGreaterThan(retainedNativeProgress, 0)
        XCTAssertNotEqual(retainedNativeProgress, 0.42)
        XCTAssertEqual(state.loadingProgress, retainedNativeProgress)
        // The URL handoff legitimately supersedes the old zero-progress timer.
        // That old timer must never replace the newly published native progress.
        await fulfillment(of: [suppressed], timeout: 0.3)
        publication = nil
        XCTAssertEqual(state.loadingProgress, retainedNativeProgress)

        // Queue a fresh real throttle task while the policy is still held. A
        // legitimate explicit setLoading must publish, but its delayed repeat
        // cannot overwrite a later retained value during pre-provisional work.
        coordinator.setLoading(false)
        XCTAssertNil(state.loadingProgress)
        coordinator.setLoading(true)
        XCTAssertEqual(state.loadingProgress, retainedNativeProgress)
        coordinator.setLoading(true)
        state.loadingProgress = 0.42
        let pendingTimer = expectation(description: "pending reader fences the queued native-progress timer")
        pendingTimer.isInverted = true
        expectedProgress = retainedNativeProgress
        publication = pendingTimer
        await fulfillment(of: [pendingTimer], timeout: 0.3)
        publication = nil
        XCTAssertEqual(state.loadingProgress, 0.42)
        XCTAssertTrue(WebViewReaderLoadActivity.shared.hasPendingPreProvisionalLoad)

        // A detached ordinary successor clears reader ownership without issuing
        // another WebKit navigation or releasing the held policy decision.
        navigator.load(URLRequest(url: URL(string: "https://controller.example")!))
        XCTAssertFalse(WebViewReaderLoadActivity.shared.hasPendingPreProvisionalLoad)
        coordinator.setLoading(false)
        coordinator.setLoading(true)
        let successorProgress = web.estimatedProgress
        XCTAssertNotEqual(successorProgress, 0.42, "The retained value must distinguish a delayed publication")
        XCTAssertEqual(state.loadingProgress, successorProgress)
        coordinator.setLoading(true)
        state.loadingProgress = 0.42
        let resumed = expectation(description: "ordinary successor's queued progress publishes")
        expectedProgress = successorProgress
        publication = resumed
        await fulfillment(of: [resumed], timeout: 2)
        publication = nil
        XCTAssertEqual(state.loadingProgress, successorProgress)
    }

    func testReplacementWebViewUsesCurrentSelectionAndConfiguration() {
        let (window, controller) = host()
        defer { window.isHidden = true; window.rootViewController = nil }
        let store = WebViewNativeLookupHitTestStore()
        controller.setNativeLookupHitTestStore(store)
        controller.configureWebTextSelectionScrollSuppression(isScrollEnabled: true, isPaginated: true, reason: "test")
        store.updateWebTextSelection(active: true)
        let replacement = EnhancedWKWebView(frame: controller.webView.bounds, configuration: .init())
        controller.replaceWebView(replacement)
        XCTAssertFalse(replacement.scrollView.isScrollEnabled)
        store.updateWebTextSelection(active: false)
        XCTAssertTrue(replacement.scrollView.isScrollEnabled)
    }

    func testRetiredSelectionControllerCannotSuppressAReusedNativeHost() {
        let (window, controller) = host()
        defer { window.isHidden = true; window.rootViewController = nil }
        let oldStore = WebViewNativeLookupHitTestStore()
        controller.setNativeLookupHitTestStore(oldStore)
        controller.configureWebTextSelectionScrollSuppression(isScrollEnabled: true, isPaginated: true, reason: "old")
        let web = controller.webView
        controller.terminalizeLifecycleOwnership()
        controller.detachWebView()
        let current = WebViewController(webView: web)
        current.configureWebTextSelectionScrollSuppression(isScrollEnabled: true, isPaginated: false, reason: "current")
        oldStore.updateWebTextSelection(active: true)
        XCTAssertTrue(web.scrollView.isScrollEnabled)
        oldStore.updateWebTextSelection(active: false)
        XCTAssertTrue(web.scrollView.isScrollEnabled)
    }

    func testBookAndReaderFileClearanceUsesWindowSafeAreaAndLateralAdditionalInsets() {
        let (window, controller) = host()
        defer { window.isHidden = true; window.rootViewController = nil }
        for url in ["ebook://book/chapter", "reader-file://book/chapter", "https://books.example/book.epub"] {
            controller.configureHostLayout(obscuredInsets: UIEdgeInsets(top: 8, left: 16, bottom: 200, right: 18),
                pageURL: URL(string: url)!)
            XCTAssertEqual(controller.obscuredInsets.top, window.safeAreaInsets.top)
            XCTAssertEqual(controller.obscuredInsets.bottom, window.safeAreaInsets.bottom)
            XCTAssertEqual(controller.additionalSafeAreaInsets.top, 0)
            XCTAssertEqual(controller.additionalSafeAreaInsets.bottom, 0)
            XCTAssertEqual(controller.additionalSafeAreaInsets.left, 10)
            XCTAssertEqual(controller.additionalSafeAreaInsets.right, 12)
        }
        controller.configureHostLayout(obscuredInsets: UIEdgeInsets(top: 50, left: 16, bottom: 10, right: 18),
            pageURL: URL(string: "https://articles.example/story")!)
        XCTAssertEqual(controller.obscuredInsets.top, 50)
        XCTAssertEqual(controller.obscuredInsets.bottom, 30)
        XCTAssertEqual(controller.additionalSafeAreaInsets.bottom, 10)
        XCTAssertEqual(controller.additionalSafeAreaInsets.top, 0)
    }

    func testInsetApplicationPreservesPinnedAndInteriorOffsetsAndBoundsOversizedClearance() {
        let (window, controller) = host()
        defer { window.isHidden = true; window.rootViewController = nil }
        let scroll = controller.webView.scrollView
        scroll.contentSize = CGSize(width: 640, height: 2000)
        scroll.contentOffset = .zero
        controller.obscuredInsets = UIEdgeInsets(top: 40, left: 10, bottom: 30, right: 12)
        XCTAssertEqual(scroll.contentInset.top, 40)
        XCTAssertEqual(scroll.contentOffset.y, -scroll.adjustedContentInset.top, accuracy: 1)
        XCTAssertEqual(scroll.contentOffset.x, -scroll.adjustedContentInset.left, accuracy: 1)
        scroll.contentOffset = CGPoint(x: 60, y: 400)
        controller.obscuredInsets = UIEdgeInsets(top: 50, left: 20, bottom: 40, right: 22)
        XCTAssertEqual(scroll.contentOffset.x, 60, accuracy: 1)
        XCTAssertEqual(scroll.contentOffset.y, 400, accuracy: 1)
        scroll.contentOffset.y = max(-scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        controller.obscuredInsets = UIEdgeInsets(top: 50, left: 20, bottom: 60, right: 22)
        XCTAssertEqual(scroll.contentOffset.y,
            max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), accuracy: 1)
        scroll.contentOffset.x = max(-scroll.adjustedContentInset.left,
            scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right)
        controller.obscuredInsets = UIEdgeInsets(top: 50, left: 20, bottom: 60, right: 32)
        XCTAssertEqual(scroll.contentOffset.x,
            max(-scroll.adjustedContentInset.left, scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right), accuracy: 1)
        controller.obscuredInsets = UIEdgeInsets(top: 10000, left: 10000, bottom: 10000, right: 10000)
        XCTAssertLessThan(scroll.contentInset.top + scroll.contentInset.bottom, controller.webView.bounds.height)
        XCTAssertLessThan(scroll.contentInset.left + scroll.contentInset.right, controller.webView.bounds.width)
    }

    func testZeroLayoutDefersClearanceUntilUsableViewport() {
        let web = EnhancedWKWebView(frame: .zero, configuration: .init())
        let controller = WebViewController(webView: web)
        controller.view.frame = .zero
        web.frame = .zero
        controller.obscuredInsets = UIEdgeInsets(top: 40, left: 8, bottom: 30, right: 8)
        XCTAssertEqual(web.scrollView.contentInset, .zero)
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.viewDidLayoutSubviews()
        XCTAssertEqual(web.scrollView.contentInset.top, 40)
        XCTAssertEqual(web.scrollView.contentInset.bottom, 30)
    }

    func testDocumentCommitPublishesActualBoundedClearanceAndRejectsRetiredHostPublication() async throws {
        let (window, controller) = host()
        defer { window.isHidden = true; window.rootViewController = nil }
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        let model = WebView(navigator: navigator, state: .constant(.empty))
        let coordinator = model.makeCoordinatorForTesting()
        defer {
            if let webView = navigator.webView { coordinator.tearDownBindingsForDetachedWebView(webView) }
        }
        coordinator.setWebView(controller.webView)
        coordinator.hostLayoutController = controller
        controller.layoutCoordinator = coordinator
        controller.webView.navigationDelegate = coordinator
        let finished = expectation(description: "real document loaded")
        coordinator.onNavigationFinished = { _ in finished.fulfill() }
        controller.obscuredInsets = UIEdgeInsets(top: 40, left: 8, bottom: 30, right: 8)
        controller.webView.loadHTMLString("<html><body>Reader</body></html>", baseURL: URL(string: "https://controller.example"))
        await fulfillment(of: [finished], timeout: 10)
        controller.reapplyObscuredInsets(reason: "test")
        let appliedTop = Double(controller.webView.scrollView.contentInset.top)
        try await awaitPublishedTop(appliedTop, in: controller.webView)
        controller.obscuredInsets = UIEdgeInsets(top: 60, left: 8, bottom: 30, right: 8)
        coordinator.webView(controller.webView, didStartProvisionalNavigation: nil)
        try await assertPublishedTopRemains(appliedTop, in: controller.webView)
        coordinator.webView(controller.webView, didCommit: nil)
        try await awaitPublishedTop(60, in: controller.webView)
        // Queue an old-host publication, synchronously replace coordinator ownership,
        // and verify it never changes the retired document's published clearance.
        controller.obscuredInsets = UIEdgeInsets(top: 80, left: 8, bottom: 30, right: 8)
        let replacement = EnhancedWKWebView(frame: controller.webView.bounds, configuration: .init())
        coordinator.setWebView(replacement)
        try await assertPublishedTopRemains(60, in: controller.webView)

        // Rebind the original host and queue a publication, then detach only the
        // controller's view. Coordinator ownership alone must not authorize it.
        coordinator.setWebView(controller.webView)
        coordinator.webView(controller.webView, didCommit: nil)
        try await awaitPublishedTop(80, in: controller.webView)
        controller.obscuredInsets = UIEdgeInsets(top: 90, left: 8, bottom: 30, right: 8)
        controller.detachWebView()
        try await assertPublishedTopRemains(80, in: controller.webView)
    }
}
#endif
