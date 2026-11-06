import Foundation
import SwiftUI
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
final class WebViewURLTransitionIntentTests: XCTestCase {
    func testIssuedPreparedDataIdentitySurvivesNativePolicyAcknowledgment() async throws {
        try await verifyIssuedPreparedDataPolicy(unissuedSuccessor: false)
    }

    func testUnissuedSameURLNativeNavigationRetiresPreparedDataIdentity() async throws {
        try await verifyIssuedPreparedDataPolicy(unissuedSuccessor: true)
    }

    func testOlderNativePolicyCannotRetireNewerIssuedDataIdentity() async throws {
        try await verifyIssuedPreparedDataPolicy(unissuedSuccessor: false, deliversOlderPolicy: true)
    }

    func testQueuedDataIdentitySurvivesInitialAttachmentButNotDetach() throws {
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        let url = URL(string: "https://example.com/prepared-document")!
        navigator.load(Data("Prepared document".utf8), mimeType: "text/plain",
            characterEncodingName: "utf-8", baseURL: url)
        let issued = try XCTUnwrap(navigator.issuedDataNavigationIdentity)
        let webView = WKWebView(frame: .zero)
        defer {
            webView.stopLoading()
            navigator.webView = nil
        }
        navigator.webView = webView
        XCTAssertTrue(navigator.isCurrent(issued), "Flushing a queued data load keeps its producer")
        navigator.webView = nil
        XCTAssertFalse(navigator.isCurrent(issued), "A detached document cannot retain dispatch authority")
    }

    private func verifyIssuedPreparedDataPolicy(
        unissuedSuccessor: Bool, deliversOlderPolicy: Bool = false
    ) async throws {
        let capture = LoaderPolicyActionCapture()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(capture, forURLScheme: "internal")
        let source = EnhancedWKWebView(frame: .zero, configuration: configuration)
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        let model = WebView(navigator: navigator, state: .constant(.empty))
        let coordinator = model.makeCoordinatorForTesting()
        coordinator.setWebView(source)
        source.navigationDelegate = capture
        defer {
            source.stopLoading()
            source.navigationDelegate = nil
            coordinator.tearDownBindingsForDetachedWebView(source)
        }
        var olderAction: WKNavigationAction?
        if deliversOlderPolicy {
            let olderCaptured = expectation(description: "capture older native policy before the next dispatch")
            capture.receive = { olderAction = $0; olderCaptured.fulfill() }
            navigator.load(Data("Older document".utf8), mimeType: "text/html",
                characterEncodingName: "utf-8", baseURL: URL(string: "internal://local/older-document")!)
            await fulfillment(of: [olderCaptured], timeout: 10)
            XCTAssertNotNil(olderAction)
        }
        capture.allowsMainDocument = true
        let started = expectation(description: "issued data starts its concrete native navigation")
        var issuedNativeNavigation: WKNavigation?
        capture.started = { issuedNativeNavigation = $0; started.fulfill() }
        let captured = expectation(description: "issued data reaches actual native navigation policy")
        var action: WKNavigationAction?
        capture.receive = { action = $0; captured.fulfill() }
        let url = URL(string: "internal://local/prepared-document")!
        navigator.load(Data("<html><body>Prepared document</body></html>".utf8),
            mimeType: "text/html", characterEncodingName: "utf-8", baseURL: url)
        let issued = try XCTUnwrap(navigator.issuedDataNavigationIdentity)
        await fulfillment(of: [captured, started], timeout: 10)
        let nativeAction = try XCTUnwrap(action)
        XCTAssertEqual(nativeAction.targetFrame?.isMainFrame, true)
        XCTAssertEqual(nativeAction.navigationType, .other)
        source.navigationDelegate = nil
        if let olderAction {
            _ = await coordinator.webView(
                source, decidePolicyFor: olderAction, preferences: WKWebpagePreferences()
            )
        }
        let decision = await coordinator.webView(
            source, decidePolicyFor: nativeAction, preferences: WKWebpagePreferences()
        )
        XCTAssertEqual(decision.0, .allow)
        coordinator.webView(source, didStartProvisionalNavigation: try XCTUnwrap(issuedNativeNavigation))
        XCTAssertTrue(navigator.isCurrent(issued),
            "Native acknowledgment of our own data load must retain its issued identity")
        if unissuedSuccessor {
            let nextCaptured = expectation(description: "a distinct native same-URL navigation reaches policy")
            var nextAction: WKNavigationAction?
            capture.receive = { nextAction = $0; nextCaptured.fulfill() }
            let successorStarted = expectation(description: "native successor starts its own concrete navigation")
            var successorNavigation: WKNavigation?
            capture.started = { successorNavigation = $0; successorStarted.fulfill() }
            source.navigationDelegate = capture
            XCTAssertNotNil(source.loadHTMLString("<html><body>Browser successor</body></html>", baseURL: url))
            await fulfillment(of: [nextCaptured, successorStarted], timeout: 10)
            let nativeSuccessor = try XCTUnwrap(nextAction)
            XCTAssertEqual(nativeSuccessor.navigationType, .other)
            source.navigationDelegate = nil
            _ = await coordinator.webView(
                source, decidePolicyFor: nativeSuccessor, preferences: WKWebpagePreferences()
            )
            coordinator.webView(source, didStartProvisionalNavigation: try XCTUnwrap(successorNavigation))
            XCTAssertFalse(navigator.isCurrent(issued),
                "A distinct native navigation cannot inherit the prepared data load")
            return
        }
        navigator.load(URLRequest(url: url))
        XCTAssertFalse(navigator.isCurrent(issued), "A same-URL explicit request is a new producer")
    }

    func testExplicitLoadReloadAndHistoryCommandsSupersedeIssuedDataIdentity() throws {
        let navigator = WebViewNavigator()
        let other = WebViewNavigator()
        let url = URL(string: "https://example.com/prepared-document")!
        let commands: [() -> Void] = [
            { navigator.load(URLRequest(url: url)) },
            { navigator.loadHTML("<p>Replacement</p>", baseURL: url) },
            { navigator.load(Data("replacement".utf8), mimeType: "text/plain", characterEncodingName: "utf-8", baseURL: url) },
            { navigator.reload() }, { navigator.reloadLast() },
            { navigator.reloadWithoutContentRules() },
            { navigator.goBack() }, { navigator.goForward() },
        ]
        for command in commands {
            navigator.load(Data("prepared".utf8), mimeType: "text/plain", characterEncodingName: "utf-8", baseURL: url)
            let issued = try XCTUnwrap(navigator.issuedDataNavigationIdentity)
            XCTAssertTrue(navigator.isCurrent(issued))
            XCTAssertFalse(other.isCurrent(issued))
            command()
            XCTAssertFalse(navigator.isCurrent(issued))
        }
    }

    func testBrowserReloadPolicyRetiresIssuedDataIdentity() async throws {
        let capture = LoaderPolicyActionCapture()
        capture.allowsMainDocument = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(capture, forURLScheme: "internal")
        let source = EnhancedWKWebView(frame: .zero, configuration: configuration)
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        let model = WebView(navigator: navigator, state: .constant(.empty))
        let coordinator = model.makeCoordinatorForTesting()
        coordinator.setWebView(source)
        source.navigationDelegate = capture
        defer {
            source.stopLoading()
            source.navigationDelegate = nil
            coordinator.tearDownBindingsForDetachedWebView(source)
        }
        let loaded = expectation(description: "issued data finishes before native browser reload")
        capture.finished = { loaded.fulfill() }
        let url = URL(string: "internal://local/prepared-browser-reload")!
        navigator.load(Data("<html><body>Prepared document</body></html>".utf8),
            mimeType: "text/html", characterEncodingName: "utf-8", baseURL: url)
        let issued = try XCTUnwrap(navigator.issuedDataNavigationIdentity)
        await fulfillment(of: [loaded], timeout: 10)
        capture.allowsMainDocument = true
        let started = expectation(description: "native browser reload starts its concrete navigation")
        var reloadNavigation: WKNavigation?
        capture.started = { reloadNavigation = $0; started.fulfill() }
        let captured = expectation(description: "native browser reload reaches policy")
        var action: WKNavigationAction?
        capture.receive = { action = $0; captured.fulfill() }
        XCTAssertNotNil(source.reload())
        await fulfillment(of: [captured, started], timeout: 10)
        let nativeAction = try XCTUnwrap(action)
        XCTAssertEqual(nativeAction.navigationType, .reload)
        source.navigationDelegate = nil
        _ = await coordinator.webView(
            source, decidePolicyFor: nativeAction, preferences: WKWebpagePreferences()
        )
        coordinator.webView(source, didStartProvisionalNavigation: try XCTUnwrap(reloadNavigation))
        XCTAssertFalse(navigator.isCurrent(issued))
    }

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

        let successorURL = try XCTUnwrap(canonicalContentURLForReaderLoader(second))
        var state = WebViewState.empty
        let navigator = WebViewNavigator()
        let suspended = expectation(description: "Older policy is awaiting app callback")
        var release: CheckedContinuation<WKNavigationActionPolicy?, Never>?
        var callbackAdmissionClosed = false
        let model = WebView(
            navigator: navigator,
            state: Binding(get: { state }, set: { state = $0 }),
            blockedHosts: ["blocked.example"],
            onNavigationAction: { action in
                if action.request.url == first {
                    guard !callbackAdmissionClosed else { return .cancel }
                    suspended.fulfill()
                    return await withCheckedContinuation { release = $0 }
                }
                return .allow
            }
        )
        let coordinator = model.makeCoordinatorForTesting()
        coordinator.setWebView(source)
        defer { coordinator.tearDownBindingsForDetachedWebView(source) }
        let stale = Task { @MainActor in
            await coordinator.webView(source, decidePolicyFor: actions[0],
                                      preferences: WKWebpagePreferences())
        }
        let arrival = await XCTWaiter.fulfillment(of: [suspended], timeout: 10)
        guard arrival == .completed, let continuation = release else {
            // Late policy callbacks must not create a held continuation after
            // cleanup's final release opportunity.
            callbackAdmissionClosed = true
            stale.cancel()
            let pendingRelease = release
            release = nil
            pendingRelease?.resume(returning: .cancel)
            _ = await stale.value
            XCTFail("Older policy did not register its controlled continuation before the bounded arrival wait ended")
            return
        }
        let successor = await coordinator.webView(source, decidePolicyFor: actions[1],
                                                 preferences: WKWebpagePreferences())
        XCTAssertEqual(successor.0, .allow)
        state.pageURL = successorURL
        state.isLoading = true
        callbackAdmissionClosed = true
        release = nil
        continuation.resume(returning: .allow)
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
    var finished: (() -> Void)?
    var started: ((WKNavigation) -> Void)?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation else { return }
        let callback = started
        started = nil
        callback?(navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let callback = finished
        finished = nil
        callback?()
    }

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
