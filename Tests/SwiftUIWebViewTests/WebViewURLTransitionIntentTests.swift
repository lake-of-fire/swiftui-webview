import Foundation
import SwiftUI
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
final class WebViewURLTransitionIntentTests: XCTestCase {
    func testSuspendedPolicyCannotResumeAfterDocumentLifecycleRetirement() async throws {
        for retirement in ["commit", "provisional", "termination", "detach-and-rebind"] {
            for isSubframe in [false, true] {
                try await assertSuspendedPolicy(retirement: retirement, isSubframe: isSubframe)
            }
        }
    }

    func testSuspendedPolicyWithLiveDocumentStillUsesHostPolicy() async throws {
        try await assertSuspendedPolicy(retirement: nil)
    }

    func testSuspendedPolicyWithLiveDocumentStillAllowsNavigation() async throws {
        try await assertSuspendedPolicy(retirement: nil, blocksHost: false)
    }

    private func assertSuspendedPolicy(retirement: String?, blocksHost: Bool = true,
                                       isSubframe: Bool = false) async throws {
        let url = try XCTUnwrap(URL(string:
            "internal://local/load/reader?reader-url=https://blocked.example/article"))
        let capture = LoaderPolicyActionCapture()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(capture, forURLScheme: "internal")
        let source = EnhancedWKWebView(frame: .zero, configuration: configuration)
        source.navigationDelegate = capture
        defer {
            source.stopLoading()
            source.navigationDelegate = nil
        }
        let captured = expectation(description: "Capture real WebKit navigation action")
        var action: WKNavigationAction?
        capture.receive = { action = $0; captured.fulfill() }
        capture.allowsMainDocument = isSubframe
        if isSubframe {
            XCTAssertNotNil(source.loadHTMLString(
                "<html><body><iframe src='\(url.absoluteString)'></iframe></body></html>",
                baseURL: URL(string: "https://fixture.invalid")))
        } else {
            XCTAssertNotNil(source.load(URLRequest(url: url)))
        }
        await fulfillment(of: [captured], timeout: 10)
        let policyAction = try XCTUnwrap(action)
        XCTAssertEqual(policyAction.targetFrame?.isMainFrame, !isSubframe)
        source.navigationDelegate = nil
        let successorURL = try XCTUnwrap(URL(string: "https://successor.example/article"))

        var state = WebViewState.empty
        let navigator = WebViewNavigator()
        let suspended = expectation(description: "Policy awaits application decision")
        var release: CheckedContinuation<WKNavigationActionPolicy?, Never>?
        var callbackAdmissionClosed = false
        let model = WebView(navigator: navigator,
            state: Binding(get: { state }, set: { state = $0 }),
            blockedHosts: blocksHost ? ["blocked.example"] : [],
            onNavigationAction: { _ in
                guard !callbackAdmissionClosed else { return .cancel }
                suspended.fulfill()
                return await withCheckedContinuation { release = $0 }
            })
        let coordinator = model.makeCoordinatorForTesting()
        coordinator.setWebView(source)
        coordinator.webView(source, didCommit: nil)
        defer { coordinator.tearDownBindingsForDetachedWebView(source) }
        let pending = Task { @MainActor in
            await coordinator.webView(source, decidePolicyFor: policyAction,
                                      preferences: WKWebpagePreferences())
        }
        let arrival = await XCTWaiter.fulfillment(of: [suspended], timeout: 10)
        guard arrival == .completed, let continuation = release else {
            // A callback entering after the timeout must not create a new held
            // continuation while cleanup is joining the pending policy task.
            callbackAdmissionClosed = true
            pending.cancel()
            let pendingRelease = release
            release = nil
            pendingRelease?.resume(returning: .cancel)
            _ = await pending.value
            XCTFail("Policy did not register its controlled continuation before the bounded arrival wait ended")
            return
        }
        switch retirement {
        case "commit": coordinator.webView(source, didCommit: nil)
        case "provisional": coordinator.webView(source, didStartProvisionalNavigation: nil)
        case "termination": coordinator.webViewWebContentProcessDidTerminate(source)
        case "detach-and-rebind":
            coordinator.tearDownBindingsForDetachedWebView(source)
            coordinator.setWebView(source)
            coordinator.webView(source, didCommit: nil)
        default: break
        }
        state.pageURL = successorURL
        state.isLoading = true
        state.isProvisionallyNavigating = true
        callbackAdmissionClosed = true
        release = nil
        continuation.resume(returning: .allow)
        let result = await pending.value
        XCTAssertEqual(result.0, retirement == nil && !blocksHost ? .allow : .cancel)
        XCTAssertEqual(state.pageURL, successorURL)
        XCTAssertEqual(state.isLoading, retirement != nil || !blocksHost,
                       "Only a live policy may settle loading via the blocked-host rule: \(retirement ?? "live")")
        XCTAssertEqual(state.isProvisionallyNavigating, retirement != nil || !blocksHost)
    }

    func testRetiredLoaderPolicyCannotClearSuccessorLoadingState() async throws {
        try await assertRetiredPolicyCannotClearSuccessorLoadingState(isSubframe: false)
    }

    func testRetiredSubframePolicyCannotClearSuccessorLoadingState() async throws {
        try await assertRetiredPolicyCannotClearSuccessorLoadingState(isSubframe: true)
    }

    private func assertRetiredPolicyCannotClearSuccessorLoadingState(isSubframe: Bool) async throws {
        let first = try XCTUnwrap(URL(string:
            "internal://local/load/reader?reader-url=https://blocked.example/article"))
        let second = try XCTUnwrap(URL(string:
            "internal://local/load/reader?reader-url=https://allowed.example/article"))
        let capture = LoaderPolicyActionCapture()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(capture, forURLScheme: "internal")
        let source = EnhancedWKWebView(frame: .zero, configuration: configuration)
        source.navigationDelegate = capture
        defer {
            source.stopLoading()
            source.navigationDelegate = nil
        }
        var actions: [WKNavigationAction] = []
        for (index, url) in [first, second].enumerated() {
            let captured = expectation(description: "Capture navigation policy")
            capture.receive = { action in
                actions.append(action)
                captured.fulfill()
            }
            capture.allowsMainDocument = isSubframe && index == 0
            if capture.allowsMainDocument {
                XCTAssertNotNil(source.loadHTMLString(
                    "<html><body><iframe src='\(url.absoluteString)'></iframe></body></html>",
                    baseURL: URL(string: "https://fixture.invalid")
                ))
            } else {
                XCTAssertNotNil(source.load(URLRequest(url: url)))
            }
            await fulfillment(of: [captured], timeout: 10)
        }
        XCTAssertEqual(actions.count, 2)
        guard actions.count == 2 else { return }
        XCTAssertEqual(actions[0].targetFrame?.isMainFrame, !isSubframe)
        XCTAssertEqual(actions[1].targetFrame?.isMainFrame, true)
        source.navigationDelegate = nil

        var state = WebViewState.empty
        let navigator = WebViewNavigator()
        let suspended = expectation(description: "Older policy is awaiting app callback")
        var release: CheckedContinuation<WKNavigationActionPolicy?, Never>?
        let model = WebView(
            navigator: navigator,
            state: Binding(get: { state }, set: { state = $0 }),
            blockedHosts: ["blocked.example"],
            onNavigationAction: { action in
                if action.request.url == first {
                    suspended.fulfill()
                    return await withCheckedContinuation { release = $0 }
                }
                return .allow
            }
        )
        let coordinator = model.makeCoordinatorForTesting()
        coordinator.setWebView(source)
        let stale = Task { @MainActor in
            await coordinator.webView(source, decidePolicyFor: actions[0],
                                      preferences: WKWebpagePreferences())
        }
        await fulfillment(of: [suspended], timeout: 10)
        let successor = await coordinator.webView(source, decidePolicyFor: actions[1],
                                                 preferences: WKWebpagePreferences())
        XCTAssertEqual(successor.0, .allow)
        state.pageURL = try XCTUnwrap(canonicalContentURLForReaderLoader(second))
        state.isLoading = true
        release?.resume(returning: .allow)
        let retired = await stale.value
        XCTAssertEqual(retired.0, .cancel)
        XCTAssertTrue(state.isLoading, "An older blocked source must not stop its successor")
        XCTAssertEqual(state.pageURL.host, "allowed.example")
    }

    func testReaderLoaderSameDocumentFragmentUsesOriginalArticleURL() throws {
        let original = try XCTUnwrap(URL(string: "https://example.com/a%2Fb?q=x%26y#old"))
        let encoded = try XCTUnwrap(original.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let loader = try XCTUnwrap(URL(string: "internal://local/load/reader?reader-url=\(encoded)#section"))
        XCTAssertEqual(
            canonicalContentURLForReaderLoader(loader)?.absoluteString,
            "https://example.com/a%2Fb?q=x%26y#section"
        )
        XCTAssertEqual(canonicalContentURLForReaderLoader(original), nil)
    }

    func testReaderLoaderCanonicalizationRejectsUntrustedOrAmbiguousTargets() throws {
        for rawURL in [
            "internal://local/load/reader?reader-url=javascript%3Aalert%281%29",
            "internal://local/load/reader?reader-url=data%3Atext%2Fhtml%2Ctest",
            "internal://local/load/reader?reader-url=internal%3A%2F%2Flocal%2Fload%2Freader",
            "internal://local/load/reader?reader-url=https%3A%2F%2Fexample.com&reader-url=https%3A%2F%2Fother.com",
            "internal://local/load/reader?other=reader-url%3Dhttps%3A%2F%2Fexample.com",
        ] {
            XCTAssertNil(canonicalContentURLForReaderLoader(URL(string: rawURL)), rawURL)
        }
    }

    func testReaderLoaderRejectsInvalidAuthoritiesAndExtraItems() throws {
        for value in [
            "internal://user@local/load/reader?reader-url=https://example.org",
            "internal://local:8080/load/reader?reader-url=https://example.org",
            "internal://local/load/reader?reader-url=https://example.org&other=1",
        ] {
            XCTAssertNil(canonicalContentURLForReaderLoader(try XCTUnwrap(URL(string: value))), value)
        }
    }

    func testReaderLoaderRetainsLegacyNestedAndAboutSnippetSources() throws {
        for value in [
            "https://example.org/a%2Fb?q=x%26y",
            "about:snippet?key=legacy%252Fnote",
            "ebook://book/chapter%2Fpart.xhtml?literal=%2523#selection",
        ] {
            let source = try XCTUnwrap(URL(string: value))
            var loader = source
            for _ in 0 ..< 3 {
                var parts = try XCTUnwrap(URLComponents(string: "internal://local/load/reader"))
                parts.queryItems = [URLQueryItem(name: "reader-url", value: loader.absoluteString)]
                loader = try XCTUnwrap(parts.url)
            }
            XCTAssertEqual(canonicalContentURLForReaderLoader(loader), source)
        }
    }

    private func caller() throws -> WebViewScriptCaller {
        let caller = WebViewScriptCaller()
        caller.installBinding(ownedBy: UUID(), asyncCaller: { _, _, _, _ in .init(nil) },
            unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
        XCTAssertNotNil(caller.currentJavaScriptBindingToken)
        return caller
    }

    func testInitialNativeObservationDoesNotInventURLTransition() throws {
        let caller = try caller()
        let sequence = WebViewURLPublicationReceiptSequencer()
        let url = URL(string: "https://example.invalid/A")!
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: url)
        let first = try XCTUnwrap(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
        XCTAssertFalse(first.representsURLChange)
        XCTAssertTrue(first.isCurrent)
        let same = sequence.observe(url, from: ObjectIdentifier(caller))
        XCTAssertTrue(first === same.intent)
        XCTAssertFalse(try XCTUnwrap(same.intent).representsURLChange)
    }

    func testNativeTransitionsRetainOrderBeforeAnyDeferredPublication() throws {
        let caller = try caller()
        let sequence = WebViewURLPublicationReceiptSequencer()
        let a = URL(string: "https://example.invalid/A")!
        let b = URL(string: "https://example.invalid/B")!
        let c = URL(string: "https://example.invalid/C")!
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: a)
        let b1 = sequence.observe(b, from: ObjectIdentifier(caller))
        let c1 = sequence.observe(c, from: ObjectIdentifier(caller))
        let b2 = sequence.observe(b, from: ObjectIdentifier(caller))
        let receipt = sequence.observe(b, from: ObjectIdentifier(caller))
        XCTAssertLessThan(b1.sequence, c1.sequence)
        XCTAssertLessThan(c1.sequence, b2.sequence)
        XCTAssertLessThan(b2.sequence, receipt.sequence)
        XCTAssertNotEqual(b1.intent?.id, b2.intent?.id)
        XCTAssertFalse(try XCTUnwrap(b1.intent).isCurrent)
        XCTAssertFalse(try XCTUnwrap(c1.intent).isCurrent)
        XCTAssertTrue(try XCTUnwrap(b2.intent).isCurrent)
        XCTAssertTrue(b2.intent === receipt.intent)
    }

    func testFragmentChangeRetainsCanonicalTransitionIdentity() throws {
        let caller = try caller()
        let sequence = WebViewURLPublicationReceiptSequencer()
        let url = URL(string: "https://example.invalid/A")!
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: url)
        let first = try XCTUnwrap(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
        let fragment = try XCTUnwrap(sequence.observe(URL(string: url.absoluteString + "#section")!,
            from: ObjectIdentifier(caller)).intent)
        XCTAssertTrue(first === fragment)
        XCTAssertEqual(fragment.destinationURL, url)
        XCTAssertTrue(first.isCurrent)
    }

    func testForeignNativeSourceCannotReplaceOwnedIntent() throws {
        let caller = try caller()
        let foreign = try self.caller()
        let sequence = WebViewURLPublicationReceiptSequencer()
        let url = URL(string: "https://example.invalid/A")!
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: url)
        let first = try XCTUnwrap(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
        XCTAssertNil(sequence.observe(URL(string: "https://example.invalid/foreign")!, from: ObjectIdentifier(foreign)).intent)
        XCTAssertTrue(first.isCurrent)
        XCTAssertTrue(sequence.observe(url, from: ObjectIdentifier(caller)).intent === first)
    }

    func testReplacementBindingPermanentlyWithdrawsPriorURLIntent() throws {
        let caller = try caller()
        let sequence = WebViewURLPublicationReceiptSequencer()
        let url = URL(string: "https://example.invalid/A")!
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: url)
        let first = try XCTUnwrap(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
        caller.installBinding(ownedBy: UUID(), asyncCaller: { _, _, _, _ in .init(nil) },
            unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: url)
        let next = try XCTUnwrap(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
        XCTAssertFalse(first.isCurrent)
        XCTAssertTrue(next.isCurrent)
        XCTAssertNotEqual(first.javaScriptBindingToken, next.javaScriptBindingToken)
        XCTAssertNotEqual(first.id, next.id)
        XCTAssertFalse(next.representsURLChange)
    }

    func testInvalidatedCaptureCannotCreateAuthorityFromLateURLObservation() throws {
        let caller = try caller()
        let sequence = WebViewURLPublicationReceiptSequencer()
        let url = URL(string: "https://example.invalid/A")!
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: url)
        let first = try XCTUnwrap(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
        sequence.invalidate()
        XCTAssertFalse(first.isCurrent)
        XCTAssertNil(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
    }
    func testWithdrawalCallbacksAreExactOnceAndCanReenterSequencer() throws {
        let caller = try caller()
        let sequence = WebViewURLPublicationReceiptSequencer()
        let url = URL(string: "https://example.invalid/A")!
        sequence.configure(webViewID: ObjectIdentifier(caller), binding: caller.currentJavaScriptBindingToken, url: url)
        let first = try XCTUnwrap(sequence.observe(url, from: ObjectIdentifier(caller)).intent)
        let successorURL = URL(string: "https://example.invalid/B")!
        let count = WithdrawalCallbackCount()
        first.onWithdrawal {
            count.increment()
            _ = sequence.observe(successorURL, from: ObjectIdentifier(caller))
        }
        _ = sequence.observe(successorURL, from: ObjectIdentifier(caller))
        sequence.invalidate()
        XCTAssertEqual(count.value, 1)
        first.onWithdrawal { count.increment() }
        XCTAssertEqual(count.value, 2)
    }

}

private final class WithdrawalCallbackCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

@MainActor
private final class LoaderPolicyActionCapture: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
    var receive: ((WKNavigationAction) -> Void)?
    var allowsMainDocument = false

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if allowsMainDocument, navigationAction.targetFrame?.isMainFrame == true {
            decisionHandler(.allow)
            return
        }
        let callback = receive
        receive = nil
        decisionHandler(.cancel)
        callback?(navigationAction)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        urlSchemeTask.didFailWithError(URLError(.cancelled))
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
