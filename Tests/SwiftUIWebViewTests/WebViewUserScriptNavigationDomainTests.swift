import SwiftUI
import Network
import WebKit
import XCTest
@testable import SwiftUIWebView
#if os(iOS)
import UIKit
#endif

@MainActor
private final class ScriptDomainSchemeHandler: NSObject, WKURLSchemeHandler {
    var failingPath: String?
    var heldPath: String?
    var held: (() -> Void)?

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        if url.path == heldPath {
            held?()
            return
        }
        if url.path == failingPath {
            task.didFailWithError(URLError(.cannotLoadFromNetwork))
            return
        }
        let html = """
        <!doctype html><html><body><p>Document</p>
        <iframe srcdoc="<p>Child document</p>"></iframe></body></html>
        """
        let data = Data(html.utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// A real HTTP redirect is needed: WKURLSchemeHandler does not support 302
/// navigation redirects. This listener serves only two in-memory loopback URLs.
@MainActor
private final class ScriptDomainRedirectServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var startup: CheckedContinuation<URL, Error>?

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    if case .ready = state, let port = listener?.port {
                        self.startup?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/redirect")!)
                        self.startup = nil
                    } else if case .failed = state {
                        self.stop()
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    self.connections.append(connection)
                    connection.start(queue: .main)
                    self.receive(connection, data: Data())
                }
            }
            listener.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.startup != nil { self?.stop() }
            }
        }
    }

    func stop() {
        startup?.resume(throwing: URLError(.cancelled))
        startup = nil
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - data.count) { [weak self] chunk, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var request = data
                if let chunk { request.append(chunk) }
                guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    if complete || error != nil || request.count >= 8192 { connection.cancel() }
                    else { self.receive(connection, data: request) }
                    return
                }
                let isRedirect = String(decoding: request, as: UTF8.self).hasPrefix("GET /redirect HTTP/")
                let body = isRedirect ? "" : "<!doctype html><p>Redirected</p>"
                let status = isRedirect ? "302 Found\r\nLocation: /destination\r\n" : "200 OK\r\n"
                let response = "HTTP/1.1 \(status)Content-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

@MainActor
private final class ScriptDomainWebView: EnhancedWKWebView {
    // Exercise a host update with the outgoing URL, even on WebKit versions
    // that expose the provisional URL before their policy reply returns.
    var outgoingURLDuringHostUpdate: URL?
    override var url: URL? { outgoingURLDuringHostUpdate ?? super.url }
}

@MainActor
private final class ScriptDomainNavigationDelegate: NSObject, WKNavigationDelegate {
    let coordinator: WebViewCoordinator
    var afterPolicy: ((WKNavigationAction, WKNavigationActionPolicy) -> Void)?
    var finished: (() -> Void)?
    var failed: (() -> Void)?
    var failureToDefer: WKNavigation?
    var failureWasDeferred: (() -> Void)?
    var deferredFailure: (() -> Void)?
    var redirected: ((WKNavigation) -> Void)?

    init(coordinator: WebViewCoordinator) { self.coordinator = coordinator }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let result = await coordinator.webView(webView, decidePolicyFor: action, preferences: preferences)
        afterPolicy?(action, result.0)
        return result
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        coordinator.webView(webView, didStartProvisionalNavigation: navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        coordinator.webView(webView, didCommit: navigation)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        coordinator.webView(webView, didReceiveServerRedirectForProvisionalNavigation: navigation)
        if let navigation { redirected?(navigation) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        coordinator.webView(webView, didFinish: navigation)
        finished?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        deliverFailure(navigation) { [weak self] in
            self?.coordinator.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
            self?.failed?()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        deliverFailure(navigation) { [weak self] in
            self?.coordinator.webView(webView, didFail: navigation, withError: error)
            self?.failed?()
        }
    }

    private func deliverFailure(_ navigation: WKNavigation?, delivery: @escaping () -> Void) {
        if let failureToDefer, failureToDefer === navigation {
            deferredFailure = delivery
            failureWasDeferred?()
        } else {
            delivery()
        }
    }
}

@MainActor
final class WebViewUserScriptNavigationDomainTests: XCTestCase {
    private let ordinaryURL = URL(string: "internal://local/ordinary")!
    private let readerURL = URL(string: "internal://local/reader?reader-url=https%3A%2F%2Fpublisher.example%2Farticle")!
    private let ebookURL = URL(string: "ebook://local/chapter")!
    private let probeSource = "window.scriptDomainProbe = true;"

    @MainActor
    private final class Fixture {
        let handler = ScriptDomainSchemeHandler()
        let navigator = WebViewNavigator()
        let config: WebViewConfig
        let view: SwiftUIWebView.WebView
        let webView: ScriptDomainWebView
        let coordinator: WebViewCoordinator
        let delegate: ScriptDomainNavigationDelegate
#if os(iOS)
        private let window: UIWindow
#endif

        init(source: String) {
            config = WebViewConfig(userScripts: [WebViewUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)])
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            configuration.setURLSchemeHandler(handler, forURLScheme: "internal")
            configuration.setURLSchemeHandler(handler, forURLScheme: "ebook")
            webView = ScriptDomainWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
            // The binding is mutable so policy and commit publication follow
            // the same state transitions as a SwiftUI host.
            var state = WebViewState.empty
            view = SwiftUIWebView.WebView(config: config, navigator: navigator, state: Binding(get: { state }, set: { state = $0 }))
            coordinator = view.makeCoordinatorForTesting()
            delegate = ScriptDomainNavigationDelegate(coordinator: coordinator)
#if os(iOS)
            // Exercise a mounted iOS WebView, including the first cold
            // WebContent process, rather than relying on off-window loading.
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            let controller = UIViewController()
            window.rootViewController = controller
            controller.view.addSubview(webView)
            window.isHidden = false
#endif
            // These tests own every navigation; the host's idle fallback is
            // unrelated and must not replace a deliberately held document.
            navigator.shouldLoadFallbackOnAttach = false
            coordinator.setWebView(webView)
            webView.navigationDelegate = delegate
            webView.uiDelegate = coordinator
            refresh()
        }

        func refresh(outgoingURL: URL? = nil) {
            webView.outgoingURLDuringHostUpdate = outgoingURL
            defer { webView.outgoingURLDuringHostUpdate = nil }
            view.refreshUserScripts(webView: webView, coordinator: coordinator, config: config)
        }

        func stop() {
            delegate.afterPolicy = nil
            delegate.finished = nil
            delegate.failed = nil
            delegate.failureToDefer = nil
            delegate.failureWasDeferred = nil
            delegate.deferredFailure = nil
            delegate.redirected = nil
            webView.stopLoading()
            coordinator.tearDownBindingsForDetachedWebView(webView)
#if os(iOS)
            window.isHidden = true
            window.rootViewController = nil
#endif
        }
    }

    @discardableResult
    private func load(_ url: URL, in fixture: Fixture, fails: Bool = false) async -> WKNavigation? {
        let done = expectation(description: fails ? "navigation failed" : "navigation finished")
        fixture.delegate.finished = fails ? nil : { done.fulfill() }
        fixture.delegate.failed = fails ? { done.fulfill() } : nil
        let navigation = fixture.webView.load(URLRequest(url: url))
        fixture.webView.beginUnkeyedNavigation(navigation: navigation)
        // The first WebContent process in a cold test host can start slowly
        // while Xcode is rebuilding dependencies. This checks completion and
        // script ownership, rather than imposing a ten-second performance gate.
        await fulfillment(of: [done], timeout: 30)
        fixture.delegate.finished = nil
        fixture.delegate.failed = nil
        return navigation
    }

    private func assertProbe(_ fixture: Fixture, child: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await fixture.webView.evaluateJavaScript("[window.scriptDomainProbe === true, document.querySelector('iframe').contentWindow.scriptDomainProbe === true]") as? [Bool]
        XCTAssertEqual(result, [true, child], file: file, line: line)
    }

    func testReaderPolicySurvivesOutgoingURLHostUpdatesAndExcludesChild() async throws {
        let fixture = Fixture(source: probeSource)
        defer { fixture.stop() }
        await load(ordinaryURL, in: fixture)
        try await assertProbe(fixture, child: true)
        var checkedPolicy = false
        fixture.delegate.afterPolicy = { [self] action, decision in
            guard action.targetFrame?.isMainFrame == true, action.request.url == readerURL else { return }
            XCTAssertEqual(decision, .allow)
            let installed = fixture.webView.configuration.userContentController.userScripts
            XCTAssertTrue(installed.allSatisfy(\.isForMainFrameOnly))
            fixture.refresh(outgoingURL: ordinaryURL)
            fixture.refresh(outgoingURL: ordinaryURL)
            let refreshed = fixture.webView.configuration.userContentController.userScripts
            XCTAssertEqual(installed.count, refreshed.count)
            XCTAssertTrue(zip(installed, refreshed).allSatisfy { pair in pair.0 === pair.1 })
            checkedPolicy = true
        }
        await load(readerURL, in: fixture)
        XCTAssertTrue(checkedPolicy)
        try await assertProbe(fixture, child: false)
    }

    func testFailedReaderRestoresSurvivingOrdinaryDocumentScope() async throws {
        let fixture = Fixture(source: probeSource)
        defer { fixture.stop() }
        await load(ordinaryURL, in: fixture)
        fixture.handler.failingPath = "/reader"
        await load(readerURL, in: fixture, fails: true)
        fixture.refresh(outgoingURL: readerURL)
        let probe = try XCTUnwrap(fixture.webView.configuration.userContentController.userScripts.first { $0.source == probeSource })
        XCTAssertFalse(probe.isForMainFrameOnly)
        try await assertProbe(fixture, child: true)
    }

    func testEPUBNavigationRestoresAllFrameScriptsAfterReader() async throws {
        let fixture = Fixture(source: probeSource)
        defer { fixture.stop() }
        await load(readerURL, in: fixture)
        try await assertProbe(fixture, child: false)
        fixture.delegate.afterPolicy = { [self] action, _ in
            if action.targetFrame?.isMainFrame == true, action.request.url == ebookURL {
                fixture.refresh(outgoingURL: readerURL)
            }
        }
        await load(ebookURL, in: fixture)
        try await assertProbe(fixture, child: true)
    }

    func testCancelledReaderPolicyKeepsOrdinaryScripts() async throws {
        let fixture = Fixture(source: probeSource)
        defer { fixture.stop() }
        await load(ordinaryURL, in: fixture)
        let cancelled = expectation(description: "reader policy cancelled")
        fixture.coordinator.onNavigationAction = { [self] action in
            action.request.url == readerURL ? .cancel : nil
        }
        fixture.delegate.afterPolicy = { [self] action, decision in
            guard action.targetFrame?.isMainFrame == true, action.request.url == readerURL else { return }
            XCTAssertEqual(decision, .cancel)
            fixture.refresh(outgoingURL: ordinaryURL)
            cancelled.fulfill()
        }
        fixture.webView.load(URLRequest(url: readerURL))
        await fulfillment(of: [cancelled], timeout: 10)
        let probe = try XCTUnwrap(fixture.webView.configuration.userContentController.userScripts.first { $0.source == probeSource })
        XCTAssertFalse(probe.isForMainFrameOnly)
    }

    func testExplicitAllowCallbackStillInstallsReaderScope() async throws {
        let fixture = Fixture(source: probeSource)
        defer { fixture.stop() }
        await load(ordinaryURL, in: fixture)
        fixture.coordinator.onNavigationAction = { _ in .allow }
        await load(readerURL, in: fixture)
        try await assertProbe(fixture, child: false)
    }

    func testReaderTargetBlankLinkNavigatesInCurrentViewWithAsyncPolicy() async throws {
        let fixture = Fixture(source: probeSource)
        defer { fixture.stop() }
        await load(readerURL, in: fixture)
        fixture.coordinator.onNavigationAction = { _ in
            await Task.yield()
            return nil
        }
        let finished = expectation(description: "target blank link loaded in current view")
        fixture.delegate.finished = { finished.fulfill() }
        _ = try await fixture.webView.evaluateJavaScript("""
            const link = document.createElement('a');
            link.href = 'internal://local/ordinary';
            link.target = '_blank';
            document.body.appendChild(link);
            link.click();
            """)
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(fixture.webView.url, ordinaryURL)
        try await assertProbe(fixture, child: true)
    }

    func testSupersededAsyncAllowCannotReplaceNewerReaderScope() async throws {
        let fixture = Fixture(source: probeSource)
        defer { fixture.stop() }
        await load(ordinaryURL, in: fixture)
        let delayedURL = URL(string: "internal://local/delayed-policy")!
        let deciding = expectation(description: "older policy awaiting client")
        let replied = expectation(description: "older policy replied")
        var reply: CheckedContinuation<WKNavigationActionPolicy?, Never>?
        fixture.coordinator.onNavigationAction = { action in
            guard action.targetFrame?.isMainFrame == true,
                  action.request.url == delayedURL else { return nil }
            return await withCheckedContinuation { continuation in
                reply = continuation
                deciding.fulfill()
            }
        }
        fixture.delegate.afterPolicy = { action, decision in
            guard action.targetFrame?.isMainFrame == true,
                  action.request.url == delayedURL else { return }
            XCTAssertEqual(decision, .cancel)
            replied.fulfill()
        }
        let oldNavigation = fixture.webView.load(URLRequest(url: delayedURL))
        fixture.webView.beginUnkeyedNavigation(navigation: oldNavigation)
        await fulfillment(of: [deciding], timeout: 10)
        await load(readerURL, in: fixture)
        reply?.resume(returning: .allow)
        reply = nil
        await fulfillment(of: [replied], timeout: 10)
        fixture.refresh(outgoingURL: ordinaryURL)
        XCTAssertTrue(fixture.webView.configuration.userContentController.userScripts.allSatisfy(\.isForMainFrameOnly))
        try await assertProbe(fixture, child: false)
    }

    func testPoolCancellationInvalidatesAwaitingPolicyReply() async throws {
        let fixture = Fixture(source: probeSource)
        defer { fixture.stop() }
        await load(ordinaryURL, in: fixture)
        let deciding = expectation(description: "reader policy awaiting client")
        let replied = expectation(description: "cancelled policy replied")
        var reply: CheckedContinuation<WKNavigationActionPolicy?, Never>?
        fixture.coordinator.onNavigationAction = { [self] action in
            guard action.targetFrame?.isMainFrame == true,
                  action.request.url == readerURL else { return nil }
            return await withCheckedContinuation { continuation in
                reply = continuation
                deciding.fulfill()
            }
        }
        fixture.delegate.afterPolicy = { [self] action, decision in
            guard action.targetFrame?.isMainFrame == true,
                  action.request.url == readerURL else { return }
            XCTAssertEqual(decision, .cancel)
            replied.fulfill()
        }
        let navigation = fixture.webView.load(URLRequest(url: readerURL))
        fixture.webView.beginUnkeyedNavigation(navigation: navigation)
        await fulfillment(of: [deciding], timeout: 10)
        fixture.webView.cancelPendingPooledContentNavigation()
        reply?.resume(returning: .allow)
        reply = nil
        await fulfillment(of: [replied], timeout: 10)
        fixture.refresh(outgoingURL: readerURL)
        let probe = try XCTUnwrap(fixture.webView.configuration.userContentController.userScripts.first { $0.source == probeSource })
        XCTAssertFalse(probe.isForMainFrameOnly)
        try await assertProbe(fixture, child: true)
    }

    func testPoolCancellationRestoresCommittedScopeBeforeHostUpdate() async throws {
        let fixture = Fixture(source: probeSource)
        defer { fixture.stop() }
        await load(ordinaryURL, in: fixture)
        let held = expectation(description: "reader request held before commit")
        fixture.handler.heldPath = "/reader"
        fixture.handler.held = { held.fulfill() }
        let navigation = fixture.webView.load(URLRequest(url: readerURL))
        fixture.webView.beginUnkeyedNavigation(navigation: navigation)
        await fulfillment(of: [held], timeout: 10)
        XCTAssertTrue(fixture.webView.configuration.userContentController.userScripts.allSatisfy(\.isForMainFrameOnly))
        fixture.webView.cancelPendingPooledContentNavigation()
        fixture.webView.stopLoading()
        fixture.refresh(outgoingURL: readerURL)
        let probe = try XCTUnwrap(fixture.webView.configuration.userContentController.userScripts.first { $0.source == probeSource })
        XCTAssertFalse(probe.isForMainFrameOnly)
        try await assertProbe(fixture, child: true)
    }

    func testReplacementPoliciesAndSameDocumentFragments() {
        for type in [WKNavigationType.other, .reload, .backForward, .formResubmitted] {
            XCTAssertTrue(pageInitiatedNavigationReplacesDocument(
                from: ordinaryURL, to: readerURL, type: type),
                "Navigation type alone cannot establish native ownership: \(type)")
        }
        XCTAssertTrue(pageInitiatedNavigationReplacesDocument(
            from: ordinaryURL, to: ordinaryURL, type: .formSubmitted))
        XCTAssertTrue(pageInitiatedNavigationReplacesDocument(
            from: ordinaryURL, to: readerURL, type: .linkActivated))
        XCTAssertTrue(pageInitiatedNavigationReplacesDocument(
            from: readerURL, to: ordinaryURL, type: .linkActivated))
        XCTAssertFalse(pageInitiatedNavigationReplacesDocument(
            from: ordinaryURL, to: URL(string: "internal://local/ordinary#section"), type: .linkActivated))
        for type in [WKNavigationType.other, .backForward] {
            XCTAssertFalse(pageInitiatedNavigationReplacesDocument(
                from: ordinaryURL, to: URL(string: "internal://local/ordinary#section"), type: type))
        }
    }

    func testFragmentLinkPreservesCommittedNavigationAtPolicy() async throws {
        let fixture = Fixture(source: probeSource)
        defer { fixture.stop() }
        let loaded = await load(readerURL, in: fixture)
        let navigation = try XCTUnwrap(loaded)
        let accepted = expectation(description: "fragment link accepted")
        fixture.delegate.afterPolicy = { [self] action, decision in
            guard action.targetFrame?.isMainFrame == true,
                  action.request.url?.fragment == "section" else { return }
            XCTAssertEqual(decision, .allow)
            XCTAssertEqual(fixture.webView.navigationCallbackDisposition(navigation), .current,
                "A fragment link must not retire the surviving document's receipt")
            fixture.refresh(outgoingURL: readerURL)
            XCTAssertTrue(fixture.webView.configuration.userContentController.userScripts
                .allSatisfy(\.isForMainFrameOnly))
            accepted.fulfill()
        }
        _ = try await fixture.webView.evaluateJavaScript("""
            const link = document.createElement('a');
            link.href = '#section';
            document.body.appendChild(link);
            link.click();
            """)
        await fulfillment(of: [accepted], timeout: 10)
        try await assertProbe(fixture, child: false)
    }

    func testPageLinkPolicyRejectsOlderFailureBeforeProvisionalStart() async throws {
        try await assertReceiptlessPolicyRejectsOlderFailure(javascript: """
            const link = document.createElement('a');
            link.href = '\(readerURL.absoluteString)';
            document.body.appendChild(link);
            link.click();
            """, type: .linkActivated)
    }

    func testLocationPolicyRejectsOlderFailureBeforeProvisionalStart() async throws {
        try await assertReceiptlessPolicyRejectsOlderFailure(
            javascript: "window.location.href = '\(readerURL.absoluteString)'", type: .other)
    }

    func testWebKitHistoryPolicyRejectsOlderFailureBeforeProvisionalStart() async throws {
        // history.back() enters WebKit's built-in history path without the
        // navigator registering goBack()'s receipt, as a swipe does.
        try await assertReceiptlessPolicyRejectsOlderFailure(
            javascript: "window.history.back()", type: .backForward, preparesHistory: true)
    }

    private func assertReceiptlessPolicyRejectsOlderFailure(
        javascript: String,
        type: WKNavigationType,
        preparesHistory: Bool = false
    ) async throws {
        let fixture = Fixture(source: probeSource)
        defer { fixture.stop() }
        if preparesHistory { await load(readerURL, in: fixture) }
        await load(ordinaryURL, in: fixture)
        let held = expectation(description: "older provisional request held")
        fixture.handler.heldPath = "/held"
        fixture.handler.held = { held.fulfill() }
        let oldNavigation = try XCTUnwrap(fixture.webView.load(
            URLRequest(url: URL(string: "internal://local/held")!)))
        fixture.webView.beginUnkeyedNavigation(navigation: oldNavigation)
        await fulfillment(of: [held], timeout: 10)

        // Retain WebKit's real cancellation receipt while the committed page
        // initiates its next link. No native load registers the new receipt.
        let oldFailure = expectation(description: "older cancellation receipt deferred")
        fixture.delegate.failureToDefer = oldNavigation
        fixture.delegate.failureWasDeferred = { oldFailure.fulfill() }
        fixture.webView.stopLoading()
        await fulfillment(of: [oldFailure], timeout: 10)
        let deliver = try XCTUnwrap(fixture.delegate.deferredFailure)
        fixture.delegate.deferredFailure = nil
        let policyAccepted = expectation(description: "page link policy accepted")
        let readerFinished = expectation(description: "reader document finished")
        fixture.handler.heldPath = nil
        fixture.handler.held = nil
        fixture.delegate.finished = { readerFinished.fulfill() }
        fixture.delegate.afterPolicy = { [self] action, decision in
            guard action.targetFrame?.isMainFrame == true,
                  action.request.url == readerURL else { return }
            XCTAssertEqual(action.navigationType, type)
            XCTAssertEqual(decision, .allow)
            XCTAssertEqual(fixture.webView.navigationCallbackDisposition(oldNavigation), .stale)
            deliver()
            fixture.refresh(outgoingURL: ordinaryURL)
            XCTAssertTrue(fixture.webView.configuration.userContentController.userScripts
                .allSatisfy(\.isForMainFrameOnly),
                "An older failure cannot replace the accepted link's Reader scripts")
            policyAccepted.fulfill()
        }
        // The predecessor's authentic first failure is delivered after policy
        // preparation and before WebKit receives the replacement's allow.
        _ = try await fixture.webView.evaluateJavaScript(javascript)
        await fulfillment(of: [policyAccepted, readerFinished], timeout: 10)
        XCTAssertEqual(fixture.webView.url, readerURL)
        try await assertProbe(fixture, child: false)
    }

    func testNativeReloadAndBackPreserveTheirExactReceiptsAtPolicy() async throws {
        let fixture = Fixture(source: probeSource)
        defer { fixture.stop() }
        await load(readerURL, in: fixture)
        await load(ordinaryURL, in: fixture)
        for isBack in [true, false] {
            let finished = expectation(description: isBack ? "native back finished" : "native reload finished")
            var receipt: WKNavigation?
            var checkedPolicy = false
            fixture.delegate.finished = { finished.fulfill() }
            fixture.delegate.afterPolicy = { action, decision in
                guard action.targetFrame?.isMainFrame == true else { return }
                XCTAssertEqual(decision, .allow)
                XCTAssertEqual(action.navigationType, isBack ? .backForward : .reload)
                XCTAssertEqual(fixture.webView.navigationCallbackDisposition(receipt), .current)
                checkedPolicy = true
            }
            receipt = isBack ? fixture.webView.goBack() : fixture.webView.reload()
            let navigation = try XCTUnwrap(receipt)
            fixture.webView.beginUnkeyedNavigation(navigation: navigation)
            await fulfillment(of: [finished], timeout: 30)
            XCTAssertTrue(checkedPolicy)
            try await assertProbe(fixture, child: false)
        }
    }

    func testNativeHTTPRedirectPreservesExactReceiptAndKeyedContent() async throws {
        let server = ScriptDomainRedirectServer()
        defer { server.stop() }
        let url = try await server.start()
        let fixture = Fixture(source: probeSource)
        defer { fixture.stop() }
        let finished = expectation(description: "HTTP redirect finished")
        let redirected = expectation(description: "exact redirect receipt restored")
        let contentID = WebViewPoolContentID("redirected-document")
        var receipt: WKNavigation?
        var sawRedirectPolicy = false
        fixture.delegate.finished = { finished.fulfill() }
        fixture.delegate.afterPolicy = { action, decision in
            guard action.targetFrame?.isMainFrame == true,
                  action.request.url?.path == "/destination" else { return }
            XCTAssertEqual(action.navigationType, .other)
            XCTAssertEqual(decision, .allow)
            sawRedirectPolicy = true
        }
        fixture.delegate.redirected = { navigation in
            XCTAssertTrue(navigation === receipt)
            XCTAssertEqual(fixture.webView.navigationCallbackDisposition(navigation), .current)
            XCTAssertEqual(fixture.webView.poolPendingContentID, contentID)
            redirected.fulfill()
        }
        receipt = fixture.webView.load(URLRequest(url: url))
        fixture.webView.beginKeyedNavigation(contentID: contentID, navigation: try XCTUnwrap(receipt))
        await fulfillment(of: [redirected, finished], timeout: 30)
        XCTAssertTrue(sawRedirectPolicy)
        XCTAssertEqual(fixture.webView.url?.path, "/destination")
        XCTAssertEqual(fixture.webView.poolReadyContentID, contentID)
        let probe = try await fixture.webView.evaluateJavaScript("window.scriptDomainProbe === true") as? Bool
        XCTAssertEqual(probe, true)
    }

    func testStaleFailureCannotRollBackNewerReaderPolicy() async throws {
        let fixture = Fixture(source: probeSource)
        defer { fixture.stop() }
        await load(ordinaryURL, in: fixture)
        let held = expectation(description: "older provisional request held")
        fixture.handler.heldPath = "/held"
        fixture.handler.held = { held.fulfill() }
        let oldNavigation = try XCTUnwrap(fixture.webView.load(URLRequest(url: URL(string: "internal://local/held")!)))
        fixture.webView.beginUnkeyedNavigation(navigation: oldNavigation)
        await fulfillment(of: [held], timeout: 10)
        // Delay the actual cancellation receipt. Delivering an invented second
        // failure after WebKit already delivered its terminal receipt would
        // exercise a duplicate callback instead of a late first completion.
        let oldFailure = expectation(description: "older cancellation receipt deferred")
        fixture.delegate.failureToDefer = oldNavigation
        fixture.delegate.failureWasDeferred = { oldFailure.fulfill() }
        let readerHeld = expectation(description: "new reader policy accepted before commit")
        fixture.handler.heldPath = "/reader"
        fixture.handler.held = { readerHeld.fulfill() }
        let newNavigation = fixture.webView.load(URLRequest(url: readerURL))
        fixture.webView.beginUnkeyedNavigation(navigation: newNavigation)
        await fulfillment(of: [oldFailure, readerHeld], timeout: 10)
        XCTAssertEqual(fixture.webView.navigationCallbackDisposition(oldNavigation), .stale)
        let deliver = try XCTUnwrap(fixture.delegate.deferredFailure)
        fixture.delegate.deferredFailure = nil
        deliver()
        fixture.refresh(outgoingURL: ordinaryURL)
        XCTAssertTrue(fixture.webView.configuration.userContentController.userScripts.allSatisfy(\.isForMainFrameOnly))
    }
}
