#if os(iOS)
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
private final class BottomNavigationProbe: NSObject, WKNavigationDelegate {
    let coordinator: WebViewCoordinator
    var expectedNavigation: WKNavigation?
    var expectedFinish: XCTestExpectation?
    var failure: Error?
    var nativeHeightAtExpectedFinish: CGFloat?
    var nativeViewportHeightAtExpectedFinish: CGFloat?

    init(coordinator: WebViewCoordinator) { self.coordinator = coordinator }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        await coordinator.webView(webView, decidePolicyFor: action, preferences: preferences)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        coordinator.webView(webView, didStartProvisionalNavigation: navigation)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        coordinator.webView(webView, didCommit: navigation)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let navigation, navigation === expectedNavigation {
            nativeHeightAtExpectedFinish = webView.scrollView.contentSize.height
            nativeViewportHeightAtExpectedFinish = webView.scrollView.bounds.height
        }
        coordinator.webView(webView, didFinish: navigation)
        guard let navigation, navigation === expectedNavigation else { return }
        expectedFinish?.fulfill()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        coordinator.webView(webView, didFail: navigation, withError: error)
        recordFailure(error, navigation: navigation)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        coordinator.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        recordFailure(error, navigation: navigation)
    }
    private func recordFailure(_ error: Error, navigation: WKNavigation?) {
        guard let navigation, navigation === expectedNavigation else { return }
        failure = error
        expectedFinish?.fulfill()
    }
}

@MainActor
private final class BottomLayoutHeldWebView: WKWebView {
    private(set) var layoutCompletions: [@MainActor @Sendable (Any?, Error?) -> Void] = []

    override func __callAsyncJavaScript(
        _ functionBody: String, arguments: [String: Any]?, inFrame frame: WKFrameInfo?,
        in contentWorld: WKContentWorld,
        completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)? = nil
    ) {
        if let completionHandler { layoutCompletions.append(completionHandler) }
    }

    func completeLayout(error: Error? = nil) {
        guard !layoutCompletions.isEmpty else { return }
        layoutCompletions.removeFirst()(true, error)
    }

    func discardLayoutCompletions() { layoutCompletions.removeAll() }
}

@MainActor
final class WebViewScrollOwnershipTests: XCTestCase {
    func testNativeScrollCallbacksWaitForInitialDocumentLayout() async {
        let navigator = WebViewNavigator()
        var publications: [Bool] = []
        let observedSample = expectation(description: "native geometry observation delivered")
        var didObserveSample = false
        let model = WebView(navigator: navigator, state: .constant(.empty),
            onDocumentContextInvalidated: { _, _ in publications.removeAll() },
            onScrollBottomStateChanged: { publications.append($0) })
        let coordinator = model.makeCoordinatorForTesting()
        let view = BottomLayoutHeldWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: WKWebViewConfiguration())
        navigator.webView = view
        view.scrollView.bounds = view.bounds
        view.scrollView.contentSize = CGSize(width: 320, height: 240)
        coordinator.installScrollBottomStateObservations(for: view.scrollView)
        let sizeObservation = view.scrollView.observe(\.contentSize, options: [.new]) { _, _ in
            Task { @MainActor in
                guard !didObserveSample else { return }
                didObserveSample = true
                observedSample.fulfill()
            }
        }
        defer {
            sizeObservation.invalidate()
            view.discardLayoutCompletions()
            coordinator.tearDownBindingsForDetachedWebView(view)
        }
        coordinator.webView(view, didCommit: nil)
        coordinator.scrollViewDidScroll(view.scrollView)
        XCTAssertTrue(publications.isEmpty, "Commit cannot expose predecessor geometry through a native scroll callback")
        coordinator.webView(view, didFinish: nil)
        view.scrollView.contentSize.height = 241
        await fulfillment(of: [observedSample], timeout: 2)
        XCTAssertTrue(publications.isEmpty, "Content-size observations must wait for the same renderer boundary")
        view.scrollView.contentSize = CGSize(width: 320, height: 960)
        view.completeLayout()
        XCTAssertEqual(publications, [false])
        view.scrollView.contentOffset.y = 480
        coordinator.scrollViewDidScroll(view.scrollView)
        XCTAssertEqual(publications, [false, true], "Ordinary bottom arrivals remain live after initial layout")
    }

    func testPreservedProvisionalFailureRearmsBottomLayoutForSurvivingDocument() {
        let navigator = WebViewNavigator()
        var publications: [Bool] = []
        let model = WebView(navigator: navigator, state: .constant(.empty),
            onScrollBottomStateChanged: { publications.append($0) })
        let coordinator = model.makeCoordinatorForTesting()
        let view = BottomLayoutHeldWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: .init())
        navigator.webView = view
        defer {
            view.discardLayoutCompletions()
            coordinator.tearDownBindingsForDetachedWebView(view)
        }
        view.scrollView.bounds = view.bounds
        view.scrollView.contentSize = CGSize(width: 320, height: 240)
        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        view.completeLayout()
        XCTAssertEqual(publications, [true])
        coordinator.webView(view, didStartProvisionalNavigation: nil)
        coordinator.webView(view, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))
        XCTAssertEqual(view.layoutCompletions.count, 1, "A preserved document will not receive another finish callback")
        view.scrollView.contentSize.height = 960
        coordinator.scrollViewDidScroll(view.scrollView)
        XCTAssertEqual(publications, [true], "The restored context must settle before native publication")
        view.completeLayout()
        XCTAssertEqual(publications, [true, false])
        view.scrollView.contentOffset.y = 480
        coordinator.scrollViewDidScroll(view.scrollView)
        XCTAssertEqual(publications, [true, false, true])
    }

    func testObserverReinstallationRearmsFinishedAndPendingLayoutWithoutAnotherFinish() {
        let navigator = WebViewNavigator()
        var publications: [Bool] = []
        let model = WebView(navigator: navigator, state: .constant(.empty),
            onScrollBottomStateChanged: { publications.append($0) })
        let coordinator = model.makeCoordinatorForTesting()
        let view = BottomLayoutHeldWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: .init())
        navigator.webView = view
        defer {
            view.discardLayoutCompletions()
            coordinator.tearDownBindingsForDetachedWebView(view)
        }
        view.scrollView.bounds = view.bounds
        view.scrollView.contentSize = CGSize(width: 320, height: 240)
        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        view.completeLayout()
        XCTAssertEqual(publications, [true])
        let reinstall = {
            coordinator.onScrollBottomStateChanged = nil
            coordinator.installScrollBottomStateObservations(for: view.scrollView)
            coordinator.onScrollBottomStateChanged = { publications.append($0) }
            coordinator.installScrollBottomStateObservations(for: view.scrollView)
        }
        reinstall()
        XCTAssertEqual(view.layoutCompletions.count, 1)
        coordinator.scrollViewDidScroll(view.scrollView)
        XCTAssertEqual(publications, [true])
        view.completeLayout()
        XCTAssertEqual(publications, [true, true])
        reinstall()
        reinstall()
        XCTAssertEqual(view.layoutCompletions.count, 2)
        view.completeLayout()
        XCTAssertEqual(publications, [true, true], "The retired wait cannot complete the replacement installation")
        view.completeLayout()
        XCTAssertEqual(publications, [true, true, true])
    }

    func testCurrentRendererErrorAllowsLaterNativeGeometryWithoutRetry() {
        let navigator = WebViewNavigator()
        var publications: [Bool] = []
        let model = WebView(navigator: navigator, state: .constant(.empty),
            onScrollBottomStateChanged: { publications.append($0) })
        let coordinator = model.makeCoordinatorForTesting()
        let view = BottomLayoutHeldWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: .init())
        navigator.webView = view
        defer {
            view.discardLayoutCompletions()
            coordinator.tearDownBindingsForDetachedWebView(view)
        }
        view.scrollView.bounds = view.bounds
        view.scrollView.contentSize = CGSize(width: 320, height: 240)
        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        view.completeLayout(error: URLError(.cancelled))
        XCTAssertTrue(publications.isEmpty)
        coordinator.webView(view, didFinish: nil)
        XCTAssertTrue(view.layoutCompletions.isEmpty)
        view.scrollView.contentSize.height = 960
        coordinator.scrollViewDidScroll(view.scrollView)
        XCTAssertEqual(publications, [false])
        view.scrollView.contentOffset.y = 480
        coordinator.scrollViewDidScroll(view.scrollView)
        XCTAssertEqual(publications, [false, true])
    }

    func testEachFinishedDocumentPublishesBottomAfterConsumerReset() {
        let navigator = WebViewNavigator()
        var isAtBottom = false
        var publications: [Bool] = []
        let model = WebView(navigator: navigator, state: .constant(.empty),
            onDocumentContextInvalidated: { _, _ in isAtBottom = false },
            onScrollBottomStateChanged: { value in
                isAtBottom = value
                publications.append(value)
            })
        let coordinator = model.makeCoordinatorForTesting()
        let view = BottomLayoutHeldWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: WKWebViewConfiguration())
        view.scrollView.bounds = view.bounds
        view.scrollView.contentSize = CGSize(width: 320, height: 240)
        navigator.webView = view
        defer {
            view.discardLayoutCompletions()
            coordinator.tearDownBindingsForDetachedWebView(view)
        }

        coordinator.publishScrollBottomState(for: view.scrollView)
        coordinator.publishScrollBottomState(for: view.scrollView)
        XCTAssertEqual(publications, [true], "Unchanged samples within a document stay deduplicated")
        coordinator.webView(view, didCommit: nil)
        XCTAssertFalse(isAtBottom, "Commit resets the consumer without replaying predecessor geometry")
        XCTAssertEqual(publications, [true])
        coordinator.webView(view, didFinish: nil)
        XCTAssertFalse(isAtBottom, "Finish waits for renderer layout delivery")
        view.completeLayout()
        XCTAssertTrue(isAtBottom)
        let firstDocument = coordinator.captureDocumentCallbackContext(for: view)
        coordinator.webView(view, didCommit: nil)
        XCTAssertNotEqual(firstDocument, coordinator.captureDocumentCallbackContext(for: view))
        XCTAssertFalse(isAtBottom)
        XCTAssertEqual(publications, [true, true])
        coordinator.webView(view, didFinish: nil)
        view.completeLayout()
        XCTAssertTrue(isAtBottom, "A short successor still reaches its reset consumer at finish")
        coordinator.publishScrollBottomState(for: view.scrollView)
        XCTAssertEqual(publications, [true, true, true])
    }

    func testFinishedDocumentResamplesSuccessorGeometryWithoutCommitReplay() {
        let navigator = WebViewNavigator()
        var isAtBottom = false
        var publications: [Bool] = []
        let model = WebView(navigator: navigator, state: .constant(.empty),
            onDocumentContextInvalidated: { _, _ in isAtBottom = false },
            onScrollBottomStateChanged: { value in
                isAtBottom = value
                publications.append(value)
            })
        let coordinator = model.makeCoordinatorForTesting()
        let view = BottomLayoutHeldWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: WKWebViewConfiguration())
        navigator.webView = view
        defer {
            view.discardLayoutCompletions()
            coordinator.tearDownBindingsForDetachedWebView(view)
        }
        view.scrollView.bounds = view.bounds
        view.scrollView.contentSize = CGSize(width: 320, height: 240)
        coordinator.publishScrollBottomState(for: view.scrollView)
        // The predecessor's short geometry is deliberately still present at commit.
        coordinator.webView(view, didCommit: nil)
        XCTAssertFalse(isAtBottom)
        XCTAssertEqual(publications, [true], "Commit cannot invent an arrival from predecessor geometry")
        coordinator.webView(view, didFinish: nil)
        XCTAssertEqual(publications, [true], "Finish alone cannot publish pre-layout geometry")
        view.scrollView.contentSize = CGSize(width: 320, height: 960)
        view.scrollView.contentOffset = .zero
        view.completeLayout()
        XCTAssertFalse(isAtBottom)
        XCTAssertEqual(publications, [true, false], "Finish samples the loaded successor's geometry")
        coordinator.publishScrollBottomState(for: view.scrollView)
        XCTAssertEqual(publications, [true, false])
    }

    func testReentrantFinishReplacementCannotPublishOutgoingBottom() {
        let navigator = WebViewNavigator()
        let outgoing = BottomLayoutHeldWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: WKWebViewConfiguration())
        let replacement = WKWebView(frame: outgoing.frame, configuration: WKWebViewConfiguration())
        outgoing.scrollView.bounds = outgoing.bounds
        outgoing.scrollView.contentSize = CGSize(width: 320, height: 240)
        var publications: [Bool] = []
        let model = WebView(navigator: navigator, state: .constant(.empty),
            onNavigationFinished: { _ in navigator.webView = replacement },
            onScrollBottomStateChanged: { publications.append($0) })
        let coordinator = model.makeCoordinatorForTesting()
        navigator.webView = outgoing
        defer {
            outgoing.discardLayoutCompletions()
            coordinator.tearDownBindingsForDetachedWebView(outgoing)
            navigator.webView = nil
        }
        coordinator.publishScrollBottomState(for: outgoing.scrollView)
        coordinator.webView(outgoing, didCommit: nil)
        coordinator.webView(outgoing, didFinish: nil)
        XCTAssertTrue(navigator.webView === replacement)
        XCTAssertTrue(outgoing.layoutCompletions.isEmpty)
        XCTAssertEqual(publications, [true], "The retired finish cannot publish after its callback replaces the host")
    }

    func testRepeatedFinishInSameDocumentDoesNotReplayBottomArrival() {
        let navigator = WebViewNavigator()
        var publications: [Bool] = []
        var reenterFinish: (() -> Void)?
        let model = WebView(navigator: navigator, state: .constant(.empty),
            onScrollBottomStateChanged: { value in
                publications.append(value)
                let reenter = reenterFinish
                reenterFinish = nil
                reenter?()
            })
        let coordinator = model.makeCoordinatorForTesting()
        let view = BottomLayoutHeldWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: WKWebViewConfiguration())
        navigator.webView = view
        defer {
            view.discardLayoutCompletions()
            reenterFinish = nil
            coordinator.tearDownBindingsForDetachedWebView(view)
        }
        view.scrollView.bounds = view.bounds
        view.scrollView.contentSize = CGSize(width: 320, height: 240)
        coordinator.webView(view, didCommit: nil)
        reenterFinish = { coordinator.webView(view, didFinish: nil) }
        coordinator.webView(view, didFinish: nil)
        coordinator.webView(view, didFinish: nil)
        XCTAssertEqual(view.layoutCompletions.count, 1)
        view.completeLayout()
        reenterFinish = nil
        coordinator.webView(view, didFinish: nil)
        coordinator.publishScrollBottomState(for: view.scrollView)
        XCTAssertEqual(publications, [true], "Repeated or reentrant finish must not recreate a consumed arrival")
    }

    func testDelayedLayoutCompletionAndErrorCannotPublishForRetiredDocument() {
        let navigator = WebViewNavigator()
        var publications: [Bool] = []
        let model = WebView(navigator: navigator, state: .constant(.empty),
            onScrollBottomStateChanged: { publications.append($0) })
        let coordinator = model.makeCoordinatorForTesting()
        let view = BottomLayoutHeldWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: WKWebViewConfiguration())
        navigator.webView = view
        defer {
            view.discardLayoutCompletions()
            coordinator.tearDownBindingsForDetachedWebView(view)
        }
        view.scrollView.bounds = view.bounds
        view.scrollView.contentSize = CGSize(width: 320, height: 240)
        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        XCTAssertEqual(view.layoutCompletions.count, 2)
        view.completeLayout(error: URLError(.cancelled))
        XCTAssertTrue(publications.isEmpty)
        coordinator.webView(view, didFinish: nil)
        XCTAssertEqual(view.layoutCompletions.count, 1, "Old failure must not clear the successor's reserved replay")
        view.completeLayout()
        XCTAssertEqual(publications, [true])

        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        view.completeLayout()
        XCTAssertEqual(publications, [true], "Successful completion from a retired document is also rejected")
        view.scrollView.contentSize = CGSize(width: 320, height: 960)
        view.completeLayout()
        XCTAssertEqual(publications, [true, false])

        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        view.scrollView.contentSize = CGSize(width: 320, height: 240)
        view.completeLayout(error: URLError(.cannotParseResponse))
        XCTAssertEqual(publications, [true, false], "Current renderer failure cannot sample unsettled geometry")
        coordinator.webView(view, didFinish: nil)
        XCTAssertTrue(view.layoutCompletions.isEmpty, "A failed replay does not start an automatic retry loop")
    }

    func testDelayedLayoutCompletionRejectsDetachedReboundHostAndReplacedCaller() {
        let navigator = WebViewNavigator()
        var publications: [Bool] = []
        let model = WebView(navigator: navigator, state: .constant(.empty),
            onScrollBottomStateChanged: { publications.append($0) })
        let coordinator = model.makeCoordinatorForTesting()
        let view = BottomLayoutHeldWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: WKWebViewConfiguration())
        navigator.webView = view
        defer {
            view.discardLayoutCompletions()
            coordinator.tearDownBindingsForDetachedWebView(view)
        }
        view.scrollView.bounds = view.bounds
        view.scrollView.contentSize = CGSize(width: 320, height: 240)
        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        coordinator.tearDownBindingsForDetachedWebView(view)
        navigator.webView = view
        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        view.completeLayout()
        XCTAssertTrue(publications.isEmpty, "Rebinding the same WKWebView cannot revive a detached completion")
        view.completeLayout()
        XCTAssertEqual(publications, [true])

        coordinator.webView(view, didCommit: nil)
        coordinator.webView(view, didFinish: nil)
        coordinator.updateScriptCaller(WebViewScriptCaller())
        view.scrollView.contentSize = CGSize(width: 320, height: 960)
        view.completeLayout()
        XCTAssertEqual(publications, [true], "Replacing the script caller retires its pending layout sample")
    }

    func testPendingInitialBottomSampleRearmsAfterCallerOrBindingReplacement() {
        let retiredErrors: [Error?] = [nil, URLError(.cancelled)]
        for transition in ["caller", "initialBinding", "binding"] {
            for retiredError in retiredErrors {
                let navigator = WebViewNavigator()
                let caller = WebViewScriptCaller()
                var publications: [Bool] = []
                let model = WebView(navigator: navigator, state: .constant(.empty),
                    scriptCaller: caller,
                    onScrollBottomStateChanged: { publications.append($0) })
                let coordinator = model.makeCoordinatorForTesting()
                let view = BottomLayoutHeldWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: WKWebViewConfiguration())
                navigator.webView = view
                defer {
                    view.discardLayoutCompletions()
                    coordinator.tearDownBindingsForDetachedWebView(view)
                }
                let installBinding = {
                    coordinator.installScriptCallerBinding(for: view,
                        asyncCaller: { _, _, _, _ in .init(nil) },
                        unsafeCaller: nil, snapshotCapture: nil)
                }
                if transition != "initialBinding" { installBinding() }
                view.scrollView.bounds = view.bounds
                view.scrollView.contentSize = CGSize(width: 320, height: 240)
                coordinator.webView(view, didCommit: nil)
                let document = coordinator.captureDocumentCallbackContext(for: view)
                coordinator.webView(view, didFinish: nil)
                XCTAssertEqual(view.layoutCompletions.count, 1)

                if transition == "caller" {
                    coordinator.updateScriptCaller(WebViewScriptCaller())
                }
                installBinding()
                XCTAssertEqual(document, coordinator.captureDocumentCallbackContext(for: view))
                view.completeLayout(error: retiredError)
                XCTAssertTrue(publications.isEmpty, "A retired owner cannot publish its layout reply")
                XCTAssertEqual(view.layoutCompletions.count, 1, "The current owner must receive a replacement layout wait")
                coordinator.updateScriptCaller(WebViewScriptCaller())
                installBinding()
                view.completeLayout(error: retiredError)
                XCTAssertTrue(publications.isEmpty, "Another ownership change must also retire the replacement reply")
                XCTAssertEqual(view.layoutCompletions.count, 1, "Repeated ownership changes must keep the initial sample live")
                coordinator.webView(view, didFinish: nil)
                XCTAssertEqual(view.layoutCompletions.count, 1, "Repeated finish must not duplicate the replacement wait")
                view.completeLayout()
                XCTAssertEqual(publications, [true], "The same document still publishes its initial bottom state")

                coordinator.updateScriptCaller(WebViewScriptCaller())
                installBinding()
                coordinator.webView(view, didFinish: nil)
                XCTAssertTrue(view.layoutCompletions.isEmpty, "An already published document must not invent another bottom arrival")
                XCTAssertEqual(publications, [true])
            }
        }
    }

    func testDelayedLayoutCompletionRejectsSameDocumentObservationReset() {
        let retiredErrors: [Error?] = [nil, URLError(.cancelled)]
        for retiredError in retiredErrors {
            let navigator = WebViewNavigator()
            var publications: [Bool] = []
            let model = WebView(navigator: navigator, state: .constant(.empty),
                onScrollBottomStateChanged: { publications.append($0) })
            let coordinator = model.makeCoordinatorForTesting()
            let view = BottomLayoutHeldWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: WKWebViewConfiguration())
            navigator.webView = view
            defer {
                view.discardLayoutCompletions()
                coordinator.tearDownBindingsForDetachedWebView(view)
            }
            view.scrollView.bounds = view.bounds
            view.scrollView.contentSize = CGSize(width: 320, height: 240)
            coordinator.webView(view, didCommit: nil)
            let context = coordinator.captureDocumentCallbackContext(for: view)
            coordinator.webView(view, didFinish: nil)
            // Exercise the actual nil-observer reset, then restore the consumer
            // without generating unrelated ordinary KVO publications.
            coordinator.onScrollBottomStateChanged = nil
            coordinator.installScrollBottomStateObservations(for: view.scrollView)
            coordinator.onScrollBottomStateChanged = { publications.append($0) }
            XCTAssertEqual(context, coordinator.captureDocumentCallbackContext(for: view))
            coordinator.webView(view, didFinish: nil)
            XCTAssertEqual(view.layoutCompletions.count, 2)
            view.completeLayout(error: retiredError)
            XCTAssertTrue(publications.isEmpty, "The retired attempt cannot publish through an identical document context")
            coordinator.webView(view, didFinish: nil)
            XCTAssertEqual(view.layoutCompletions.count, 1, "Old completion cannot clear the new attempt's reservation")
            view.completeLayout()
            XCTAssertEqual(publications, [true])
        }
    }

    func testRealHTMLShortToLongNavigationDoesNotReplayShortBottomAtCommit() async throws {
        try await verifyRealHTMLShortToLongNavigation(observesNativeScroll: false)
    }

    func testRealHTMLWithNativeScrollObservationsDoesNotPublishPreLayoutBottom() async throws {
        try await verifyRealHTMLShortToLongNavigation(observesNativeScroll: true)
    }

    private func verifyRealHTMLShortToLongNavigation(observesNativeScroll: Bool) async throws {
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        var publications: [Bool] = []
        var isAtBottom = false
        var bottomDelivered: XCTestExpectation?
        var expectedBottom: Bool?
        var hasFinished = false
        let model = WebView(navigator: navigator, state: .constant(.empty),
            onNavigationFinished: { _ in
                hasFinished = true
            },
            onDocumentContextInvalidated: { _, _ in
                isAtBottom = false
                hasFinished = false
                publications.removeAll()
            },
            onScrollBottomStateChanged: { value in
                isAtBottom = value
                publications.append(value)
                if hasFinished, expectedBottom == value {
                    expectedBottom = nil
                    bottomDelivered?.fulfill()
                }
            })
        let coordinator = model.makeCoordinatorForTesting()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: view.frame)
        window.frame = view.frame
        let host = UIViewController()
        window.rootViewController = host
        host.view.addSubview(view)
        window.isHidden = false
        host.view.layoutIfNeeded()
        // Exercise both the isolated initial replay and the normal native callbacks.
        navigator.webView = view
        if observesNativeScroll {
            view.scrollView.delegate = coordinator
            coordinator.installScrollBottomStateObservations(for: view.scrollView)
        }
        let navigationProbe = BottomNavigationProbe(coordinator: coordinator)
        view.navigationDelegate = navigationProbe
        defer {
            navigationProbe.expectedFinish = nil
            navigationProbe.expectedNavigation = nil
            bottomDelivered = nil
            view.stopLoading()
            view.navigationDelegate = nil
            view.scrollView.delegate = nil
            coordinator.tearDownBindingsForDetachedWebView(view)
            view.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }
        let shortFinished = expectation(description: "short HTML finished")
        navigationProbe.expectedFinish = shortFinished
        let shortBottom = expectation(description: "short HTML bottom delivered after finish")
        bottomDelivered = shortBottom
        expectedBottom = true
        let shortNavigation = try XCTUnwrap(view.loadHTMLString("""
            <!doctype html><title>short-bottom-fixture</title><meta name="viewport" content="width=device-width, initial-scale=1">
            <style>html,body{margin:0;padding:0}div{height:120px}</style><div>Short</div>
            """, baseURL: URL(string: "https://example.com/short")))
        navigationProbe.expectedNavigation = shortNavigation
        await fulfillment(of: [shortFinished], timeout: 10)
        XCTAssertNil(navigationProbe.failure)
        let shortTitle = try await view.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(shortTitle, "short-bottom-fixture")
        await fulfillment(of: [shortBottom], timeout: 10)
        XCTAssertTrue(isAtBottom)
        XCTAssertEqual(publications.last, true)

        let longFinished = expectation(description: "long HTML finished")
        navigationProbe.expectedFinish = longFinished
        navigationProbe.failure = nil
        let longBottom = expectation(description: "long HTML bottom delivered after finish")
        bottomDelivered = longBottom
        expectedBottom = false
        let longLayout = expectation(description: "long HTML native content size delivered")
        var didObserveLongLayout = false
        let sizeObservation = view.scrollView.observe(\.contentSize, options: [.initial, .new]) { [weak view] _, _ in
            Task { @MainActor in
                guard let view, !didObserveLongLayout,
                      view.scrollView.contentSize.height > view.scrollView.bounds.height else { return }
                didObserveLongLayout = true
                longLayout.fulfill()
            }
        }
        defer {
            didObserveLongLayout = true
            sizeObservation.invalidate()
        }
        let longNavigation = try XCTUnwrap(view.loadHTMLString("""
            <!doctype html><title>long-bottom-fixture</title><meta name="viewport" content="width=device-width, initial-scale=1">
            <style>html,body{margin:0;padding:0}div{height:2400px}</style><div>Long</div>
            """, baseURL: URL(string: "https://example.com/long")))
        navigationProbe.expectedNavigation = longNavigation
        await fulfillment(of: [longFinished], timeout: 10)
        XCTAssertNil(navigationProbe.failure)
        let longDocument = try await view.evaluateJavaScript(
            "({title: document.title, bodyHeight: document.body.getBoundingClientRect().height})"
        ) as? [String: Any]
        XCTAssertEqual(longDocument?["title"] as? String, "long-bottom-fixture")
        XCTAssertGreaterThan((longDocument?["bodyHeight"] as? NSNumber)?.doubleValue ?? 0, 2000,
                             "The exact long navigation must finish with the authored long document")
        await fulfillment(of: [longLayout, longBottom], timeout: 10)
        XCTAssertGreaterThan(view.scrollView.contentSize.height, view.scrollView.bounds.height)
        XCTAssertFalse(isAtBottom)
        XCTAssertEqual(publications.last, false)
        let diagnostic = XCTAttachment(string: "Exact long navigation finished; URL=\(view.url?.absoluteString ?? "nil"); document=\(String(describing: longDocument)); nativeHeightAtFinish=\(String(describing: navigationProbe.nativeHeightAtExpectedFinish)); viewportAtFinish=\(String(describing: navigationProbe.nativeViewportHeightAtExpectedFinish)); finalNativeHeight=\(view.scrollView.contentSize.height); bottomPublications=\(publications)")
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        XCTAssertFalse(publications.contains(true), "The long successor must not publish a stale short-page arrival after its reset")
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
