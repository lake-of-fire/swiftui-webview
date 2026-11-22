import Foundation
import WebKit
import XCTest
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
@testable import SwiftUIWebView

@MainActor
final class WebViewNavigationIntentTests: XCTestCase {
    private let url = URL(string: "https://example.com/saved")!

    func testQueuedRequestIdentityPreservesDataOnlyProjectionAndRetiresOnDetach() throws {
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        navigator.load(URLRequest(url: url))
        let issued = try XCTUnwrap(navigator.issuedNavigationIdentity)
        XCTAssertNil(navigator.issuedDataNavigationIdentity)
        navigator.beginNavigationIntent() // native policy acknowledgment
        XCTAssertTrue(navigator.isCurrent(issued))
        let view = WKWebView(frame: .zero)
        navigator.webView = view
        XCTAssertTrue(navigator.isCurrent(issued))
        navigator.webView = nil
        XCTAssertFalse(navigator.isCurrent(issued))
        navigator.load(URLRequest(url: url))
        let queued = try XCTUnwrap(navigator.issuedNavigationIdentity)
        navigator.reload() // no native view can accept this reload
        XCTAssertFalse(navigator.isCurrent(queued))
        XCTAssertNil(navigator.issuedNavigationIdentity)
    }

    func testIssuedRequestReloadAndOwnedBlankStageKeepExactNativeProvenance() async throws {
        let probe = IssuedNavigationProbe()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(probe, forURLScheme: "fixture")
        configuration.setURLSchemeHandler(probe, forURLScheme: "internal")
        let view = IssuedRequestProbeWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        let model = WebView(navigator: navigator, state: .constant(.empty))
        let coordinator = model.makeCoordinatorForTesting()
#if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: view.frame)
        window.frame = view.frame
        let host = UIViewController()
        window.rootViewController = host
        host.view.addSubview(view)
        window.isHidden = false
        host.view.layoutIfNeeded()
#elseif os(macOS)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: view.frame)
        host.addSubview(view)
        window.contentView = host
#endif
        coordinator.setWebView(view)
        probe.policy = { source, action, preferences in
            await coordinator.webView(source, decidePolicyFor: action, preferences: preferences)
        }
        probe.started = { source, navigation in coordinator.webView(source, didStartProvisionalNavigation: navigation) }
        probe.committed = { source, navigation in coordinator.webView(source, didCommit: navigation) }
        probe.finishedNavigation = { source, navigation in coordinator.webView(source, didFinish: navigation) }
        probe.failedProvisional = { source, navigation, error in
            coordinator.webView(source, didFailProvisionalNavigation: navigation, withError: error)
        }
        view.navigationDelegate = probe
        defer {
            view.stopLoading()
            view.navigationDelegate = nil
            coordinator.tearDownBindingsForDetachedWebView(view)
            probe.policy = nil
            probe.started = nil
            probe.committed = nil
            probe.finishedNavigation = nil
            probe.failedProvisional = nil
#if os(iOS)
            window.isHidden = true
            window.rootViewController = nil
#elseif os(macOS)
            window.close()
#endif
        }
        let firstFinished = expectation(description: "request finished")
        probe.finished = { _ in firstFinished.fulfill() }
        let firstURL = URL(string: "fixture://local/article")!
        view.refusedRequestURL = firstURL
        navigator.load(URLRequest(url: firstURL))
        let first = try XCTUnwrap(navigator.issuedNavigationIdentity)
        XCTAssertEqual(view.refusedRequests, 1)
        XCTAssertNil(probe.lastNavigation)
        await fulfillment(of: [firstFinished], timeout: 10)
        XCTAssertTrue(navigator.isCurrent(first), "A nil native attempt, retry, policy, start and commit must keep the exact request")
        XCTAssertNil(navigator.issuedDataNavigationIdentity)
        let oldNavigation = try XCTUnwrap(probe.lastNavigation)
        let oldPolicy = try XCTUnwrap(probe.lastAction)

        let reloadFinished = expectation(description: "reload finished")
        probe.finished = { _ in reloadFinished.fulfill() }
        navigator.reload()
        let reload = try XCTUnwrap(navigator.issuedNavigationIdentity)
        XCTAssertFalse(navigator.isCurrent(first))
        await fulfillment(of: [reloadFinished], timeout: 10)
        XCTAssertTrue(navigator.isCurrent(reload))
        coordinator.webView(view, didFailProvisionalNavigation: oldNavigation, withError: URLError(.cancelled))
        _ = await coordinator.webView(view, decidePolicyFor: oldPolicy, preferences: WKWebpagePreferences())
        XCTAssertTrue(navigator.isCurrent(reload), "An older failed navigation or policy cannot retire the successor")

        XCTAssertFalse(view.canGoForward)
        var displacedReload: WKNavigation?
        view.afterReloadStarts = { navigation in
            displacedReload = navigation
            navigator.goForward()
        }
        navigator.reloadWithoutContentRules()
        XCTAssertEqual(view.navigationCallbackDisposition(try XCTUnwrap(displacedReload)), .stale)
        XCTAssertFalse(navigator.peekContentRulesBypass(for: view))

        let replacementURL = URL(string: "fixture://local/reentrant-replacement")!
        let replacementFinished = expectation(description: "replacement issued during native reload finished")
        probe.finished = { source in
            if source.url == replacementURL { replacementFinished.fulfill() }
        }
        var replacement: WebViewNavigator.IssuedNavigationIdentity?
        view.afterReloadStarts = { _ in
            navigator.load(URLRequest(url: replacementURL))
            replacement = navigator.issuedNavigationIdentity
        }
        navigator.reloadWithoutContentRules()
        let replacementIdentity = try XCTUnwrap(replacement)
        XCTAssertTrue(navigator.isCurrent(replacementIdentity))
        XCTAssertFalse(navigator.peekContentRulesBypass(for: view))
        await fulfillment(of: [replacementFinished], timeout: 10)
        XCTAssertTrue(navigator.isCurrent(replacementIdentity), "A reentrant reload return cannot replace its successor's native handle")

        let stagedFinished = expectation(description: "owned blank stage and final reader request finished")
        let target = URL(string: "internal://local/load/reader?url=https%3A%2F%2Fexample.com%2Farticle")!
        probe.finished = { source in
            if source.url == target {
                probe.finished = nil
                stagedFinished.fulfill()
            }
        }
        navigator.load(URLRequest(url: target))
        let staged = try XCTUnwrap(navigator.issuedNavigationIdentity)
        await fulfillment(of: [stagedFinished], timeout: 15)
        XCTAssertTrue(probe.committedURLs.contains("about:blank"))
        XCTAssertTrue(navigator.isCurrent(staged), "Owned blank staging and final native request share one producer")
        XCTAssertFalse(navigator.isCurrent(replacementIdentity))
        let blankNavigation = try XCTUnwrap(probe.committedNavigations["about:blank"])
        coordinator.webView(view, didStartProvisionalNavigation: blankNavigation)
        coordinator.webView(view, didCommit: blankNavigation)
        coordinator.webView(view, didFinish: blankNavigation)
        coordinator.webView(view, didFailProvisionalNavigation: blankNavigation, withError: URLError(.cancelled))
        coordinator.webView(view, didFail: blankNavigation, withError: URLError(.cancelled))
        XCTAssertTrue(navigator.isCurrent(staged), "Late callbacks from owned staging cannot retire the final request")

        let foreignFinished = expectation(description: "unowned same-URL replacement finished")
        probe.finished = { _ in foreignFinished.fulfill() }
        XCTAssertNotNil(view.loadHTMLString("<html><body>Unowned replacement</body></html>", baseURL: target))
        await fulfillment(of: [foreignFinished], timeout: 10)
        XCTAssertFalse(navigator.isCurrent(staged), "Equal URLs cannot grant an unowned native navigation refresh permission")

        let failedFinished = expectation(description: "current native request failed")
        probe.finished = nil
        probe.expectedFailureURL = URL(string: "fixture://local/failure")!
        probe.failure = { failedFinished.fulfill() }
        navigator.load(URLRequest(url: try XCTUnwrap(probe.expectedFailureURL)))
        let failed = try XCTUnwrap(navigator.issuedNavigationIdentity)
        await fulfillment(of: [failedFinished], timeout: 10)
        XCTAssertFalse(navigator.isCurrent(failed))
    }

    func testSameURLRequestStillSupersedesEarlierIntentAndReceipt() {
        let navigator = WebViewNavigator()
        let reserved = navigator.beginNavigationIntent()
        guard case .issued(let receipt) = navigator.dispatch(URLRequest(url: url), for: reserved) else {
            return XCTFail("Current reservation must dispatch")
        }
        XCTAssertTrue(navigator.isCurrent(receipt))
        XCTAssertFalse(navigator.isCurrent(reserved))
        navigator.load(URLRequest(url: url))
        XCTAssertFalse(navigator.isCurrent(receipt))
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, url.absoluteString)
    }

    func testRefusedAndReplayedReservationsCannotChangeActualRequest() {
        let navigator = WebViewNavigator()
        let old = navigator.beginNavigationIntent()
        let current = navigator.beginNavigationIntent()
        XCTAssertEqual(navigator.dispatch(URLRequest(url: url), for: old), .refused)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
        guard case .issued(let receipt) = navigator.dispatch(URLRequest(url: url), for: current) else {
            return XCTFail("Latest reservation must dispatch")
        }
        XCTAssertEqual(navigator.dispatch(URLRequest(url: URL(string: "https://example.com/replay")!), for: current), .refused)
        XCTAssertTrue(navigator.isCurrent(receipt))
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, url.absoluteString)
    }

    func testIntentFromAnotherNavigatorCannotDispatch() {
        let source = WebViewNavigator(), other = WebViewNavigator()
        let intent = source.beginNavigationIntent()
        XCTAssertFalse(other.isCurrent(intent))
        XCTAssertEqual(other.dispatch(URLRequest(url: url), for: intent), .refused)
        XCTAssertEqual(other.debugLoadSnapshot.lastRequestURL, "nil")
        XCTAssertTrue(source.isCurrent(intent))
    }

    func testDataAndHTMLProducersInvalidateSameBaseURLReservations() {
        let navigator = WebViewNavigator()
        let beforeData = navigator.beginNavigationIntent()
        navigator.load(Data("body".utf8), mimeType: "text/plain", characterEncodingName: "utf-8", baseURL: url)
        XCTAssertFalse(navigator.isCurrent(beforeData))
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, url.absoluteString)
        let beforeHTML = navigator.navigationIntent
        navigator.loadHTML("<p>saved</p>", baseURL: url)
        XCTAssertFalse(navigator.isCurrent(beforeHTML))
        XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, url.absoluteString)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
    }

    func testExplicitReloadAndHistoryCommandsRetirePendingIntentEvenWithoutAttachment() {
        let navigator = WebViewNavigator()
        let commands: [() -> Void] = [
            { navigator.reload() }, { navigator.reloadLast() },
            { navigator.reloadWithoutContentRules() },
            { navigator.goBack() }, { navigator.goForward() }
        ]
        for command in commands {
            let before = navigator.beginNavigationIntent()
            command()
            XCTAssertFalse(navigator.isCurrent(before))
        }
    }

    func testInitialAttachmentPreservesQueuedRequestButDetachRetiresReceipt() {
        let navigator = WebViewNavigator()
        let intent = navigator.beginNavigationIntent()
        guard case .issued(let receipt) = navigator.dispatch(URLRequest(url: url), for: intent) else {
            return XCTFail("Pre-attachment request must queue")
        }
        let webView = WKWebView(frame: .zero)
        navigator.webView = webView
        XCTAssertTrue(navigator.isCurrent(receipt))
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, url.absoluteString)
        navigator.webView = nil
        XCTAssertFalse(navigator.isCurrent(receipt))
    }

    func testReplacingAttachedWebViewRetiresOriginalRequestAuthority() {
        let navigator = WebViewNavigator()
        let original = WKWebView(frame: .zero)
        navigator.webView = original
        let intent = navigator.beginNavigationIntent()
        let replacement = WKWebView(frame: .zero)
        navigator.webView = replacement
        XCTAssertFalse(navigator.isCurrent(intent))
        let nextIntent = navigator.beginNavigationIntent()
        navigator.webView = replacement
        XCTAssertTrue(navigator.isCurrent(nextIntent))
    }
}

@MainActor
private final class IssuedRequestProbeWebView: EnhancedWKWebView {
    var refusedRequestURL: URL?
    var afterReloadStarts: ((WKNavigation?) -> Void)?
    private(set) var refusedRequests = 0

    override func load(_ request: URLRequest) -> WKNavigation? {
        if let refusedRequestURL, request.url == refusedRequestURL {
            self.refusedRequestURL = nil
            refusedRequests += 1
            return nil
        }
        return super.load(request)
    }

    override func reload() -> WKNavigation? {
        let navigation = super.reload()
        let action = afterReloadStarts
        afterReloadStarts = nil
        action?(navigation)
        return navigation
    }
}

@MainActor
private final class IssuedNavigationProbe: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
    var policy: ((WKWebView, WKNavigationAction, WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences))?
    var started: ((WKWebView, WKNavigation) -> Void)?
    var committed: ((WKWebView, WKNavigation) -> Void)?
    var finishedNavigation: ((WKWebView, WKNavigation) -> Void)?
    var failedProvisional: ((WKWebView, WKNavigation, Error) -> Void)?
    var finished: ((WKWebView) -> Void)?
    var failure: (() -> Void)?
    var expectedFailureURL: URL?
    var lastAction: WKNavigationAction?
    var lastNavigation: WKNavigation?
    var committedURLs: [String] = []
    var committedNavigations: [String: WKNavigation] = [:]

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        lastAction = action
        return await policy?(webView, action, preferences) ?? (.allow, preferences)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation else { return }
        lastNavigation = navigation
        started?(webView, navigation)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let navigation else { return }
        committedURLs.append(webView.url?.absoluteString ?? "nil")
        committedNavigations[webView.url?.absoluteString ?? "nil"] = navigation
        committed?(webView, navigation)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let navigation { finishedNavigation?(webView, navigation) }
        finished?(webView)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let navigation else { return }
        failedProvisional?(webView, navigation, error)
        if (error as NSError).code == URLError.Code.resourceUnavailable.rawValue {
            failure?()
        }
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        if url == expectedFailureURL {
            task.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        let bytes = Data("<html><body>Owned navigation fixture.</body></html>".utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: bytes.count, textEncodingName: "utf-8"))
        task.didReceive(bytes)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
