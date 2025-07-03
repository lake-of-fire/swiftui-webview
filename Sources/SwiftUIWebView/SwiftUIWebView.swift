import SwiftUI
import WebKit
import UniformTypeIdentifiers
import ZIPFoundation
import OrderedCollections

public struct WebViewMessageHandlersKey: EnvironmentKey {
    public static let defaultValue: WebViewMessageHandlers = .init()
}

public extension EnvironmentValues {
    var webViewMessageHandlers: WebViewMessageHandlers {
        get { self[WebViewMessageHandlersKey.self] }
        set { self[WebViewMessageHandlersKey.self] = newValue }
    }
}

public class WebViewMessageHandlers: Identifiable {
    public init() { }
    
    public var handlers = OrderedDictionary<String, (WebViewMessage) async -> Void>()
    
    public func add(_ name: String, handler: @escaping (WebViewMessage) async -> Void) {
        handlers[name] = handler
    }
    
    public func add(handlers: OrderedDictionary<String, (WebViewMessage) async -> Void>) {
        self.handlers.merge(handlers) { (old, new) in
            return { message in
                await old(message)
                await new(message)
            }
        }
    }
    
    public func merge(handlers: WebViewMessageHandlers) {
        add(handlers: handlers.handlers)
    }
}

#if os(iOS)
public typealias BuildMenuType = (UIMenuBuilder) -> Void
#elseif os(macOS)
public typealias BuildMenuType = (Any) -> Void
#endif

public struct WebViewState: Equatable {
    public internal(set) var isLoading: Bool
    public internal(set) var isProvisionallyNavigating: Bool
    public internal(set) var pageURL: URL
    public internal(set) var pageTitle: String?
    public internal(set) var pageImageURL: URL?
    public internal(set) var pageIconURL: URL?
    public internal(set) var pageHTML: String?
    public internal(set) var error: Error?
    public internal(set) var canGoBack: Bool
    public internal(set) var canGoForward: Bool
    public internal(set) var backList: [WKBackForwardListItem]
    public internal(set) var forwardList: [WKBackForwardListItem]
    
    public static let empty = WebViewState(
        isLoading: false,
        isProvisionallyNavigating: false,
        pageURL: URL(string: "about:blank")!,
        pageTitle: nil,
        pageImageURL: nil,
        pageIconURL: nil,
        pageHTML: nil,
        error: nil,
        canGoBack: false,
        canGoForward: false,
        backList: [],
        forwardList: [])
    
    public static func == (lhs: WebViewState, rhs: WebViewState) -> Bool {
        lhs.isLoading == rhs.isLoading
        && lhs.isProvisionallyNavigating == rhs.isProvisionallyNavigating
        && lhs.pageURL == rhs.pageURL
        && lhs.pageTitle == rhs.pageTitle
        && lhs.pageImageURL == rhs.pageImageURL
        && lhs.pageIconURL == rhs.pageIconURL
        && lhs.pageHTML == rhs.pageHTML
        && lhs.error?.localizedDescription == rhs.error?.localizedDescription
        && lhs.canGoBack == rhs.canGoBack
        && lhs.canGoForward == rhs.canGoForward
        && lhs.backList == rhs.backList
        && lhs.forwardList == rhs.forwardList
    }
}

public struct WebViewMessage: Equatable {
    public let frameInfo: WKFrameInfo
    fileprivate let uuid: UUID
    public let name: String
    public let body: Any
    
    public static func == (lhs: WebViewMessage, rhs: WebViewMessage) -> Bool {
        lhs.uuid == rhs.uuid
        && lhs.name == rhs.name && lhs.frameInfo == rhs.frameInfo
    }
}

public struct WebViewUserScript: Equatable, Hashable {
    public let source: String
    public let injectionTime: WKUserScriptInjectionTime
    public let isForMainFrameOnly: Bool
    public let world: WKContentWorld
    public let allowedDomains: Set<String>
    
    @MainActor
    public lazy var webKitUserScript: WKUserScript = {
        return WKUserScript(
            source: source,
            injectionTime: injectionTime,
            forMainFrameOnly: isForMainFrameOnly,
            in: world
        )
    }()
    
    public static func == (lhs: WebViewUserScript, rhs: WebViewUserScript) -> Bool {
        lhs.source == rhs.source
        && lhs.injectionTime == rhs.injectionTime
        && lhs.isForMainFrameOnly == rhs.isForMainFrameOnly
        && lhs.world == rhs.world
        && lhs.allowedDomains == rhs.allowedDomains
    }
    
    public init(
        source: String,
        injectionTime: WKUserScriptInjectionTime,
        forMainFrameOnly: Bool,
        in world: WKContentWorld = .defaultClient,
        allowedDomains: Set<String> = Set()
    ) {
        self.source = source
        self.injectionTime = injectionTime
        self.isForMainFrameOnly = forMainFrameOnly
        self.world = world
        self.allowedDomains = allowedDomains
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(injectionTime)
        hasher.combine(isForMainFrameOnly)
        hasher.combine(world)
        hasher.combine(allowedDomains)
    }
}

public enum DarkModeSetting: String, CaseIterable, Identifiable {
    case system
    case darkModeOverride
    
    public var id: String { self.rawValue }
    
    public var title: String {
        switch self {
        case .system:
            return "Use System Setting"
        case .darkModeOverride:
            return "Always Dark Mode"
        }
    }
}

public class WebViewCoordinator: NSObject {
    private let webView: WebView
    
    var navigator: WebViewNavigator
    var scriptCaller: WebViewScriptCaller?
    var config: WebViewConfig
    var registeredMessageHandlerNames = Set<String>()
    //    var lastInstalledScriptsHash = -1
    var compiledContentRules = [String: WKContentRuleList]()
    private var urlObservation: NSKeyValueObservation?
    
    // UIScrollViewDelegate
    internal var lastContentOffset: CGFloat = 0
    internal var accumulatedScrollOffset: CGFloat = 0
    internal var lastEnvHandlerNames: OrderedSet<String>? = nil
    
    var onNavigationCommitted: ((WebViewState) -> Void)?
    var onNavigationFinished: ((WebViewState) -> Void)?
    var onNavigationFailed: ((WebViewState) -> Void)?
    var onURLChanged: ((WebViewState) -> Void)?
    var messageHandlers: WebViewMessageHandlers
    var messageHandlerNames: [String] {
        messageHandlers.handlers.keys.map { $0 }
    }
    var hideNavigationDueToScroll: Binding<Bool>
    var textSelection: Binding<String?>
    
    init(
        webView: WebView,
        navigator: WebViewNavigator,
        scriptCaller: WebViewScriptCaller? = nil,
        config: WebViewConfig,
        messageHandlers: WebViewMessageHandlers,
        onNavigationCommitted: ((WebViewState) -> Void)?,
        onNavigationFinished: ((WebViewState) -> Void)?,
        onNavigationFailed: ((WebViewState) -> Void)?,
        onURLChanged: ((WebViewState) -> Void)? = nil,
        hideNavigationDueToScroll: Binding<Bool>,
        textSelection: Binding<String?>
    ) {
        self.webView = webView
        self.navigator = navigator
        self.scriptCaller = scriptCaller
        self.config = config
        self.messageHandlers = messageHandlers
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onURLChanged = onURLChanged
        self.hideNavigationDueToScroll = hideNavigationDueToScroll
        self.textSelection = textSelection
        
        // TODO: Make about:blank history initialization optional via configuration.
#warning("confirm this sitll works")
        //        if  webView.state.backList.isEmpty && webView.state.forwardList.isEmpty && webView.state.pageURL.absoluteString == "about:blank" {
        //            Task { @MainActor in
        //                webView.action = .load(URLRequest(url: URL(string: "about:blank")!))
        //            }
        //        }
    }
    
    deinit {
        urlObservation?.invalidate()
    }
    
    func setWebView(_ webView: WKWebView) {
        navigator.webView = webView
        
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, change in
            guard let self else { return }
            guard let maybeNewURL = change.newValue, let newURL = maybeNewURL, newURL != webView.url else { return }
            let newState = setLoading(
                false,
                pageURL: newURL,
                canGoBack: webView.canGoBack,
                canGoForward: webView.canGoForward,
                backList: webView.backForwardList.backList,
                forwardList: webView.backForwardList.forwardList)
            onURLChanged?(newState)
        }
    }
    
    @discardableResult func setLoading(
        _ isLoading: Bool,
        pageURL: URL? = nil,
        isProvisionallyNavigating: Bool? = nil,
        canGoBack: Bool? = nil,
        canGoForward: Bool? = nil,
        backList: [WKBackForwardListItem]? = nil,
        forwardList: [WKBackForwardListItem]? = nil,
        error: Error? = nil
    ) -> WebViewState {
        var newState = webView.state
        newState.isLoading = isLoading
        if let pageURL = pageURL {
            newState.pageURL = pageURL
        }
        if let isProvisionallyNavigating = isProvisionallyNavigating {
            newState.isProvisionallyNavigating = isProvisionallyNavigating
        }
        if let canGoBack = canGoBack {
            newState.canGoBack = canGoBack
        }
        if let canGoForward = canGoForward {
            newState.canGoForward = canGoForward
        }
        if let backList = backList {
            newState.backList = backList
        }
        if let forwardList = forwardList {
            newState.forwardList = forwardList
        }
        if let error = error {
            newState.error = error
        }
        //        debugPrint("# new state:", newState, "old:", webView.state)
        webView.state = newState
        return newState
    }
}

extension WebViewCoordinator: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "swiftUIWebViewBackgroundStatus", let hasBackground = message.body as? Bool {
            webView.drawsBackground = !hasBackground
            return
        } else if message.name == "swiftUIWebViewLocationChanged" {
            guard let urlString = message.body as? String,
                  let newURL = URL(string: urlString),
                  let wk = navigator.webView else { return }
            
            Task { @MainActor in
                let newState = setLoading(
                    webView.state.isLoading,
                    pageURL: newURL,
                    canGoBack: wk.canGoBack,
                    canGoForward: wk.canGoForward,
                    backList: wk.backForwardList.backList,
                    forwardList: wk.backForwardList.forwardList
                )
                onURLChanged?(newState)
            }
            return
        } else if message.name == "swiftUIWebViewImageUpdated" {
            guard let body = message.body as? [String: Any] else { return }
            if let imageURLRaw = body["imageURL"] as? String, let urlRaw = body["url"] as? String, let url = URL(string: urlRaw), let imageURL = URL(string: imageURLRaw), url == webView.state.pageURL {
                Task { @MainActor in
                    guard webView.state.pageURL == url else { return }
                    var newState = webView.state
                    newState.pageImageURL = imageURL
                    let targetState = newState
                    //                DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [webView] in
                    webView.state = targetState
                }
            }
        } else if message.name == "swiftUIWebViewPageIconUpdated" {
            guard let body = message.body as? [String: Any] else { return }
            if let imageURLRaw = body["pageIconURL"] as? String, let urlRaw = body["url"] as? String, let url = URL(string: urlRaw), let imageURL = URL(string: imageURLRaw), url == webView.state.pageURL {
                Task { @MainActor in
                    guard webView.state.pageURL == url else { return }
                    var newState = webView.state
                    newState.pageIconURL = imageURL
                    let targetState = newState
                    webView.state = targetState
                }
            }
        } else if message.name == "swiftUIWebViewTextSelection" {
            guard let body = message.body as? [String: String], let text = body["text"] as? String else {
                return
            }
            textSelection.wrappedValue = text
        }
        /* else if message.name == "swiftUIWebViewIsWarm" {
         if !webView.isWarm, let onWarm = webView.onWarm {
         Task { @MainActor in
         webView.isWarm = true
         await onWarm()
         }
         }
         return
         }*/
        
        guard let messageHandler = messageHandlers.handlers[message.name] else { return }
        let message = WebViewMessage(frameInfo: message.frameInfo, uuid: UUID(), name: message.name, body: message.body)
        //        debugPrint("# RECV:", message.name, message.frameInfo.isMainFrame, message.frameInfo.request.url, message.frameInfo.securityOrigin.description)
        Task {
            await messageHandler(message)
        }
    }
}

extension WebViewCoordinator: WKUIDelegate {
    /// Suppress `target=_blank` and load in same view
    /// See: https://nemecek.be/blog/1/how-to-open-target_blank-links-in-wkwebview-in-ios
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let frame = navigationAction.targetFrame,
           frame.isMainFrame {
            return nil
        }
        webView.load(navigationAction.request)
        return nil
    }
    
#if os(macOS)
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let urls = FileManager.default.urls(for: .documentDirectory, in: .allDomainsMask)
        // for Japanese names.
        let name = suggestedFilename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "cannotencode"
        return URL(string: name, relativeTo: urls[0])
    }
    
    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.resolvesAliases = true
        
        func handleResult(_ result: NSApplication.ModalResponse) {
            if result == NSApplication.ModalResponse.OK {
                if let url = openPanel.url {
                    completionHandler([url])
                }
            } else if result == NSApplication.ModalResponse.cancel {
                completionHandler(nil)
            }
        }
        
        if let window = webView.window {
            openPanel.beginSheetModal(for: window, completionHandler: handleResult)
        } else { // web view is somehow not in a window? Fall back to begin
            openPanel.begin(completionHandler: handleResult)
        }
    }
#endif
}

extension WebViewCoordinator: WKNavigationDelegate {
    @MainActor
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        //                debugPrint("# didFinish nav", webView.url)
        let newState = setLoading(
            false,
            pageURL: webView.url,
            isProvisionallyNavigating: false,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            backList: webView.backForwardList.backList,
            forwardList: webView.backForwardList.forwardList)
        // TODO: Move to an init postMessage callback
        /*
         if let url = webView.url, let scheme = url.scheme, scheme == "pdf" || scheme == "pdf-url", url.absoluteString.hasPrefix("\(url.scheme ?? "")://"), url.pathExtension.lowercased() == "pdf", let loaderURL = URL(string: "\(scheme)://\(url.absoluteString.dropFirst("\(url.scheme ?? "")://".count))") {
         // TODO: Escaping? Use async eval for passing object data.
         let jsString = "pdfjsLib.getDocument('\(loaderURL.absoluteString)').promise.then(doc => { PDFViewerApplication.load(doc); });"
         webView.evaluateJavaScript(jsString, completionHandler: nil)
         }
         */
        
        onNavigationFinished?(newState)
        
        extractPageState(webView: webView)
    }
    
    private func extractPageState(webView: WKWebView) {
        // TODO: Also get window location to confirm state matches JS result
        webView.evaluateJavaScript("document.title") { (response, error) in
            if let title = response as? String {
                var newState = self.webView.state
                newState.pageTitle = title
                self.webView.state = newState
            }
        }
        
        webView.evaluateJavaScript("document.URL.toString()") { (response, error) in
            if let url = response as? String, let newURL = URL(string: url), self.webView.state.pageURL != newURL {
                var newState = self.webView.state
                newState.pageURL = newURL
                self.webView.state = newState
            }
        }
        
        if self.webView.htmlInState {
            webView.evaluateJavaScript("document.documentElement.outerHTML.toString()") { (response, error) in
                if let html = response as? String {
                    var newState = self.webView.state
                    newState.pageHTML = html
                    self.webView.state = newState
                }
            }
        }
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        scriptCaller?.removeAllMultiTargetFrames()
        let newState = setLoading(
            false,
            pageURL: webView.url,
            isProvisionallyNavigating: false,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            backList: webView.backForwardList.backList,
            forwardList: webView.backForwardList.forwardList,
            error: error
        )
        onURLChanged?(newState)
    }
    
    @MainActor
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        setLoading(false, isProvisionallyNavigating: false)
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        scriptCaller?.removeAllMultiTargetFrames()
        let newState = setLoading(false, isProvisionallyNavigating: false, error: error)
        
        extractPageState(webView: webView)
        
        onNavigationFailed?(newState)
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        scriptCaller?.removeAllMultiTargetFrames()
        var newState = setLoading(
            true,
            pageURL: webView.url,
            isProvisionallyNavigating: false
        )
        newState.pageImageURL = nil
        newState.pageIconURL = nil
        newState.pageTitle = nil
        newState.pageHTML = nil
        newState.error = nil
        onNavigationCommitted?(newState)
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let newState = setLoading(
            true,
            isProvisionallyNavigating: true,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            backList: webView.backForwardList.backList,
            forwardList: webView.backForwardList.forwardList)
        onURLChanged?(newState)
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if let host = navigationAction.request.url?.host, let blockedHosts = self.webView.blockedHosts {
            if blockedHosts.contains(where: { host.contains($0) }) {
                setLoading(false, isProvisionallyNavigating: false)
                return (.cancel, preferences)
            }
        }
        
        // ePub loader
        // TODO: Instead, issue a redirect from file:// to epub:// likewise for pdf to reuse code here.
        
        if navigationAction.targetFrame?.isMainFrame ?? false, let mainDocumentURL = navigationAction.request.mainDocumentURL {
            // TODO: this is missing all our config.userScripts, make sure it inherits those...
            self.webView.updateUserScripts(userContentController: webView.configuration.userContentController, coordinator: self, forDomain: mainDocumentURL, config: config)
            
            scriptCaller?.removeAllMultiTargetFrames()
            var newState = self.webView.state
            newState.pageURL = mainDocumentURL
            newState.pageTitle = nil
            newState.isProvisionallyNavigating = false
            newState.pageImageURL = nil
            newState.pageIconURL = nil
            newState.pageHTML = nil
            newState.error = nil
            self.webView.state = newState
        }
        
        //        // TODO: Verify that restricting to main frame is correct. Recheck brave behavior.
        //        if navigationAction.targetFrame?.isMainFrame ?? false {
        //            self.webView.refreshContentRules(userContentController: webView.configuration.userContentController, coordinator: self)
        //        }
        
        return (.allow, preferences)
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        return .allow
    }
}

public class WebViewNavigator: NSObject, ObservableObject {
    weak var webView: WKWebView? {
        didSet {
            guard let webView = webView else { return }
            // TODO: Make about:blank history initialization optional via configuration.
            if !webView.canGoBack && !webView.canGoForward && (webView.url == nil || webView.url?.absoluteString == "about:blank") {
                load(URLRequest(url: URL(string: "about:blank")!))
            }
        }
    }
    
    public var backForwardList: WKBackForwardList {
        return webView?.backForwardList ?? WKBackForwardList()
    }
    
    public func load(_ request: URLRequest) {
        guard let webView = webView else { return }
        //                debugPrint("# WebViewNavigator.load(...)", request.url)
        if let url = request.url, url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url)
        } else {
            webView.load(request)
        }
    }
    
    public func loadHTML(_ html: String, baseURL: URL? = nil) {
        //                debugPrint("# WebViewNavigator.loadHTML(...)", html.prefix(100), baseURL)
        guard let webView = webView else { return }
        webView.loadHTMLString(html, baseURL: baseURL)
    }
    
    public func reload() {
        webView?.reload()
    }
    
    public func go(_ item: WKBackForwardListItem) {
        webView?.go(to: item)
    }
    
    public func goBack() {
        webView?.goBack()
    }
    
    public func goForward() {
        webView?.goForward()
    }
    
    public override init() {
        super.init()
    }
}

public class WebViewScriptCaller: Equatable, Identifiable, ObservableObject {
    public let id = UUID().uuidString
    //    @Published var caller: ((String, ((Any?, Error?) -> Void)?) -> Void)? = nil
    var caller: ((String, ((Any?, Error?) -> Void)?) -> Void)? = nil
    var asyncCaller: ((String, [String: Any]?, WKFrameInfo?, WKContentWorld?) async throws -> Any?)? = nil
    
    private var multiTargetFrames = [String: WKFrameInfo]()
    
    public static func == (lhs: WebViewScriptCaller, rhs: WebViewScriptCaller) -> Bool {
        return lhs.id == rhs.id
    }
    
    //    @MainActor
    public func evaluateJavaScript(_ js: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        guard let caller else {
            print("No caller set for WebViewScriptCaller \(id)") // TODO: Error
            return
        }
        caller(js, completionHandler)
    }
    
    //    @MainActor
    public func evaluateJavaScript(_ js: String, arguments: [String: Any]? = nil, in frame: WKFrameInfo? = nil, duplicateInMultiTargetFrames: Bool = false, in world: WKContentWorld? = .page, completionHandler: ((Result<Any?, any Error>) async throws -> Void)? = nil) async {
        guard let asyncCaller else {
            print("No asyncCaller set for WebViewScriptCaller \(id)") // TODO: Error
            return
        }
        let primitiveArguments: [String: Any]? = arguments?.mapValues {
            if let set = $0 as? Set<AnyHashable> {
                return Array(set)
            }
            return $0
        }
        var primaryError: Error?
        var result: Any?
        
        do {
            result = try await asyncCaller(js, primitiveArguments, frame, world)
        } catch {
            primaryError = error
        }
        
        if duplicateInMultiTargetFrames {
            for (uuid, targetFrame) in multiTargetFrames.filter({ !$0.value.isMainFrame }) {
                if targetFrame == frame { continue }
                do {
                    _ = try await asyncCaller(js, primitiveArguments, targetFrame, world)
                } catch {
                    if let error = error as? WKError, error.code == .javaScriptInvalidFrameTarget {
                        multiTargetFrames.removeValue(forKey: uuid)
                    } else {
                        print(error)
                    }
                }
            }
        }
        
        if let primaryError {
            try? await completionHandler?(.failure(primaryError))
        } else {
            try? await completionHandler?(.success(result))
        }
    }
    
    //    @MainActor
    public func evaluateJavaScript(
        _ js: String,
        arguments: [String: Any]? = nil,
        in frame: WKFrameInfo? = nil,
        duplicateInMultiTargetFrames: Bool = false,
        in world: WKContentWorld? = .page
    ) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                await self.evaluateJavaScript(js, arguments: arguments, in: frame, duplicateInMultiTargetFrames: duplicateInMultiTargetFrames, in: world) { result in
                    do {
                        continuation.resume(returning: try result.get())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    /// Returns whether the frame was already added.
    @MainActor
    public func addMultiTargetFrame(_ frame: WKFrameInfo, uuid: String) -> Bool {
        var inserted = true
        if multiTargetFrames.keys.contains(uuid) && multiTargetFrames[uuid]?.request.url == frame.request.url {
            inserted = false
        }
        multiTargetFrames[uuid] = frame
        return inserted
    }
    
    @MainActor
    public func removeAllMultiTargetFrames() {
        multiTargetFrames.removeAll()
    }
    
    public init() {
    }
}

fileprivate struct WebViewBackgroundStatusUserScript {
    let userScript: WebViewUserScript
    
    init() {
        let contents = """
(function() {
    let lastReportedBackground = null;

    function checkBodyBackground() {
        const body = document.body;
        if (!body) return;

        const computedStyle = window.getComputedStyle(body);
        const bgColor = computedStyle.getPropertyValue('background-color');
        const bgImage = computedStyle.getPropertyValue('background-image');

        const hasBackground = bgColor !== 'rgba(0, 0, 0, 0)' || bgImage !== 'none';

        if (hasBackground !== lastReportedBackground) {
            lastReportedBackground = hasBackground;
            if (window.webkit) {
                window.webkit.messageHandlers.swiftUIWebViewBackgroundStatus.postMessage(hasBackground);
            }
        }
    }

    const observer = new MutationObserver((mutations) => {
        checkBodyBackground();
        mutations.forEach((mutation) => {
            if (mutation.type === 'childList' && document.body) {
                checkBodyBackground();
                observeBodyStyle();
            } else if (mutation.type === 'attributes' && mutation.target === document.body) {
                checkBodyBackground();
            }
        });
    });

    function observeBodyStyle() {
        if (document.body) {
            const bodyObserver = new MutationObserver((mutations) => {
                mutations.forEach((mutation) => {
                    if (mutation.type === 'attributes' && mutation.attributeName.startsWith('style')) {
                        checkBodyBackground();
                    }
                });
            });
            bodyObserver.observe(document.body, { attributes: true, attributeFilter: ['style'] });
        }
    }

    if (document.body) {
        checkBodyBackground();
        observeBodyStyle();
    } else {
        observer.observe(document.documentElement, { childList: true, subtree: true });
    }
})()
"""
        userScript = WebViewUserScript(source: contents, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }
}

fileprivate struct LocationChangeUserScript {
    let userScript: WebViewUserScript
    
    init() {
        let contents = """
(function() {
    var pushState = history.pushState;
    var replaceState = history.replaceState;
    history.pushState = function () {
        pushState.apply(history, arguments);
        window.dispatchEvent(new Event('swiftUIWebViewLocationChanged'));
    };
    history.replaceState = function () {
        replaceState.apply(history, arguments);
        window.dispatchEvent(new Event('swiftUIWebViewLocationChanged'));
    };
    window.addEventListener('popstate', function () {
        window.dispatchEvent(new Event('swiftUIWebViewLocationChanged'))
    });
})();
window.addEventListener('swiftUIWebViewLocationChanged', function () {
    if (window.webkit) {
        window.webkit.messageHandlers.swiftUIWebViewLocationChanged.postMessage(window.location.href);
    }
});
"""
        userScript = WebViewUserScript(source: contents, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }
}

fileprivate struct ImageChangeUserScript {
    let userScript: WebViewUserScript
    
    init() {
        let contents = """
var lastURL;
new MutationObserver(function(mutations) {
    let node = document.querySelector('head meta[property="og:image"]')
    if (node && window.webkit) {
        let url = node.getAttribute('content')
        if (lastURL === url) { return }
        window.webkit.messageHandlers.swiftUIWebViewImageUpdated.postMessage({
            imageURL: url, url: window.location.href})
        lastURL = url
    } else if (window.webkit) {
        let node = document.querySelector('#reader-header img')
        if (node && window.webkit) {
            let url = node.getAttribute('src')
            if (lastURL === url) { return }
            window.webkit.messageHandlers.swiftUIWebViewImageUpdated.postMessage({
                imageURL: url, url: window.location.href})
            lastURL = url
        }
    }
}).observe(document, {childList: true, subtree: true, attributes: true, attributeOldValue: false, attributeFilter: ['property', 'content']})
"""
        userScript = WebViewUserScript(source: contents, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }
}

fileprivate struct PageIconChangeUserScript {
    let userScript: WebViewUserScript
    
    init() {
        let contents = """
(function () {
    var lastURL = null;

    function resolveURL(url) {
        if (!url) return null;
        try {
            return new URL(url, window.location.origin).href;
        } catch (e) {
            return null;
        }
    }

    function getFaviconURL() {
        // Define the selectors in the order of preference.
        const selectors = [
            'link[rel="apple-touch-icon"]',
            'link[rel="shortcut icon"]',
            'link[rel="icon"]'
        ];

        for (let selector of selectors) {
            let element = document.querySelector(selector);
            if (element && element.getAttribute('href')) {
                return resolveURL(element.getAttribute('href'));
            }
        }
        return null;
    }

    function sendFaviconUpdate() {
        const url = getFaviconURL();
        if (url && url !== lastURL && window.webkit?.messageHandlers?.swiftUIWebViewPageIconUpdated) {
            window.webkit.messageHandlers.swiftUIWebViewPageIconUpdated.postMessage({
                pageIconURL: url,
                url: window.location.href,
            });
            lastURL = url;
        }
    }

    function init() {
        sendFaviconUpdate();

        new MutationObserver(() => {
            sendFaviconUpdate();
        }).observe(document.head, {
            childList: true,
            subtree: false, // Only need to observe the immediate head children
            attributes: true,
            attributeFilter: ['rel', 'href']
        });
    }

    if (document.readyState === 'complete') {
        init();
    } else {
        document.addEventListener('DOMContentLoaded', init);
    }
})();
"""
        userScript = WebViewUserScript(source: contents, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }
}

fileprivate struct TextSelectionUserScript {
    let userScript: WebViewUserScript
    
    init() {
        let contents = """
            (function() {
                let lastSentText = null;
            
                function sendSelectedTextAndHTML() {
                    const selection = window.getSelection();
                    const selectedText = selection.toString();
            
                    if (!selection || selection.rangeCount === 0 || selectedText === '') {
                        if (lastSentText !== null) {
                            window.webkit.messageHandlers.swiftUIWebViewTextSelection.postMessage({
                                text: null,
                            });
                            lastSentText = null;
                        }
                        return;
                    }
                    if (selectedText === lastSentText) {
                        return;
                    }
                    
                    lastSentText = selectedText;
                    window.webkit.messageHandlers.swiftUIWebViewTextSelection.postMessage({
                        text: selectedText,
                    });
                }
                document.addEventListener('selectionchange', sendSelectedTextAndHTML);
            })(); 
            """
        userScript = WebViewUserScript(source: contents, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }
}

public struct WebViewConfig {
    public static let `default` = WebViewConfig()
    
    public let javaScriptEnabled: Bool
    public let contentRules: String?
    public let allowsBackForwardNavigationGestures: Bool
    public let allowsInlineMediaPlayback: Bool
    public let mediaTypesRequiringUserActionForPlayback: WKAudiovisualMediaTypes
    public let dataDetectorsEnabled: Bool
    public let isScrollEnabled: Bool
    public let pageZoom: CGFloat
    public let isOpaque: Bool
    public let backgroundColor: Color
    public let userScripts: [WebViewUserScript]
    public let darkModeSetting: DarkModeSetting
    
    public init(
        javaScriptEnabled: Bool = true,
        contentRules: String? = nil,
        allowsBackForwardNavigationGestures: Bool = true,
        allowsInlineMediaPlayback: Bool = true,
        mediaTypesRequiringUserActionForPlayback: WKAudiovisualMediaTypes = [WKAudiovisualMediaTypes.all],
        dataDetectorsEnabled: Bool = true,
        isScrollEnabled: Bool = true,
        pageZoom: CGFloat = 1,
        isOpaque: Bool = true,
        backgroundColor: Color = .clear,
        userScripts: [WebViewUserScript] = [],
        darkModeSetting: DarkModeSetting = .system
    ) {
        self.javaScriptEnabled = javaScriptEnabled
        self.contentRules = contentRules
        self.allowsBackForwardNavigationGestures = allowsBackForwardNavigationGestures
        self.allowsInlineMediaPlayback = allowsInlineMediaPlayback
        self.mediaTypesRequiringUserActionForPlayback = mediaTypesRequiringUserActionForPlayback
        self.dataDetectorsEnabled = dataDetectorsEnabled
        self.isScrollEnabled = isScrollEnabled
        self.pageZoom = pageZoom
        self.isOpaque = isOpaque
        self.backgroundColor = backgroundColor
        self.userScripts = userScripts
        self.darkModeSetting = darkModeSetting
    }
}

fileprivate let kLeftArrowKeyCode:  UInt16  = 123
fileprivate let kRightArrowKeyCode: UInt16  = 124
fileprivate let kDownArrowKeyCode:  UInt16  = 125
fileprivate let kUpArrowKeyCode:    UInt16  = 126

public class EnhancedWKWebView: WKWebView {
#if os(iOS)
    var buildMenu: BuildMenuType?
#endif
    
#if os(macOS)
    public override var isOpaque: Bool {
        return true
    }
    
    public override func keyDown(with event: NSEvent) {
        //                    print(">> key \(event.keyCode)")
        switch event.keyCode {
        case kLeftArrowKeyCode, kRightArrowKeyCode, kDownArrowKeyCode, kUpArrowKeyCode:
            return
        default:
            super.keyDown(with: event)
        }
    }
#elseif os(iOS)
    override open func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        buildMenu?(builder)
    }
#endif
}

#if os(iOS)
public class WebViewController: UIViewController {
    let webView: EnhancedWKWebView
    let persistentWebViewID: String?
    var obscuredInsets = UIEdgeInsets.zero {
        didSet {
            updateObscuredInsets()
        }
    }
    
    public init(webView: EnhancedWKWebView, persistentWebViewID: String? = nil) {
        self.webView = webView
        self.persistentWebViewID = persistentWebViewID
        super.init(nibName: nil, bundle: nil)
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: webView.topAnchor),
            view.leftAnchor.constraint(equalTo: webView.leftAnchor),
            view.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            view.rightAnchor.constraint(equalTo: webView.rightAnchor)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateObscuredInsets()
    }
    
    override public func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateObscuredInsets()
    }
    
    private func updateObscuredInsets() {
        guard let webView = view.subviews.first as? WKWebView else { return }
        let insets = UIEdgeInsets(top: obscuredInsets.top, left: obscuredInsets.left, bottom: obscuredInsets.bottom, right: obscuredInsets.right)
        //        let insets = UIEdgeInsets(top: obscuredInsets.top, left: obscuredInsets.left, bottom: 200, right: obscuredInsets.right)
        //        let argument: [Any] = ["_o", "bscu", "red", "Ins", "ets"]
        let argument: [Any] = ["o", "bscu", "red", "Ins", "ets"]
        let key = argument.compactMap({ $0 as? String }).joined()
        webView.setValue(insets, forKey: key)
        //            webView.setValue(insets, forKey: "unobscuredSafeAreaInsets")
        //            webView.setValue(insets, forKey: "obscuredInsets")
        //        webView.safeAreaInsetsDidChange()
        //            let argument2: [Any] = ["_h", "ave", "Set", "O", "bscu", "red", "Ins", "ets"]
        //            let key2 = argument2.compactMap({ $0 as? String }).joined()
        //            webView.setValue(true, forKey: key2)
        //            webView.setValue(true, forKey: "_haveSetUnobscuredSafeAreaInsets")
        //        }
        // TODO: investigate _isChangingObscuredInsetsInteractively
    }
}

public struct WebView: UIViewControllerRepresentable {
    private let config: WebViewConfig
    var navigator: WebViewNavigator
    @Binding var state: WebViewState
    var scriptCaller: WebViewScriptCaller?
    let blockedHosts: Set<String>?
    let htmlInState: Bool
    let schemeHandlers: [(WKURLSchemeHandler, String)]
    let onNavigationCommitted: ((WebViewState) -> Void)?
    let onNavigationFinished: ((WebViewState) -> Void)?
    let onNavigationFailed: ((WebViewState) -> Void)?
    let onURLChanged: ((WebViewState) -> Void)?
    let buildMenu: BuildMenuType?
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    let obscuredInsets: EdgeInsets
    var bounces = true
    let persistentWebViewID: String?
    //    let onWarm: (() async -> Void)?
    
    @Environment(\.webViewMessageHandlers) internal var webViewMessageHandlers
    
    private var userContentController = WKUserContentController()
    //    @State fileprivate var isWarm = false
    @State fileprivate var drawsBackground = false
    @State private var lastInstalledScripts = [WebViewUserScript]()
    
    private static var webViewCache: [String: EnhancedWKWebView] = [:]
    private static let processPool = WKProcessPool()
    
    public init(config: WebViewConfig = .default,
                navigator: WebViewNavigator,
                state: Binding<WebViewState>,
                scriptCaller: WebViewScriptCaller? = nil,
                blockedHosts: Set<String>? = nil,
                htmlInState: Bool = false,
                obscuredInsets: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
                bounces: Bool = true,
                persistentWebViewID: String? = nil,
                //                onWarm: (() async -> Void)? = nil,
                schemeHandlers: [(WKURLSchemeHandler, String)] = [],
                onNavigationCommitted: ((WebViewState) -> Void)? = nil,
                onNavigationFinished: ((WebViewState) -> Void)? = nil,
                onNavigationFailed: ((WebViewState) -> Void)? = nil,
                onURLChanged: ((WebViewState) -> Void)? = nil,
                buildMenu: BuildMenuType? = nil,
                hideNavigationDueToScroll: Binding<Bool> = .constant(false),
                textSelection: Binding<String?>? = nil
    ) {
        self.config = config
        _state = state
        self.navigator = navigator
        self.scriptCaller = scriptCaller
        self.blockedHosts = blockedHosts
        self.htmlInState = htmlInState
        self.obscuredInsets = obscuredInsets
        self.bounces = bounces
        self.persistentWebViewID = persistentWebViewID
        //        self.onWarm = onWarm
        self.schemeHandlers = schemeHandlers
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onURLChanged = onURLChanged
        self.buildMenu = buildMenu
        _hideNavigationDueToScroll = hideNavigationDueToScroll
        _textSelection = textSelection ?? .constant(nil)
    }
    
    public func makeCoordinator() -> WebViewCoordinator {
        return WebViewCoordinator(
            webView: self,
            navigator: navigator,
            scriptCaller: scriptCaller,
            config: config,
            messageHandlers: webViewMessageHandlers,
            onNavigationCommitted: onNavigationCommitted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onURLChanged: onURLChanged,
            hideNavigationDueToScroll: $hideNavigationDueToScroll,
            textSelection: $textSelection
        )
    }
    
    @MainActor
    private func makeWebView(
        id: String?,
        config: WebViewConfig,
        coordinator: WebViewCoordinator
    ) -> EnhancedWKWebView {
        var web: EnhancedWKWebView?
        if let id = id {
            web = Self.webViewCache[id] // it is UI thread so safe to access static
            for messageHandlerName in coordinator.messageHandlerNames {
                web?.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
            }
        }
        if web == nil {
            let preferences = WKWebpagePreferences()
            preferences.allowsContentJavaScript = config.javaScriptEnabled
            
            let configuration = WKWebViewConfiguration()
            configuration.applicationNameForUserAgent = userAgent
            configuration.allowsInlineMediaPlayback = config.allowsInlineMediaPlayback
            //        configuration.defaultWebpagePreferences.preferredContentMode = .mobile  // for font adjustment to work
            //            configuration.mediaTypesRequiringUserActionForPlayback = config.mediaTypesRequiringUserActionForPlayback
            if config.dataDetectorsEnabled {
                configuration.dataDetectorTypes = [.all]
            } else {
                configuration.dataDetectorTypes = []
            }
            configuration.defaultWebpagePreferences = preferences
            configuration.processPool = Self.processPool
            //            configuration.dataDetectorTypes = [.calendarEvent, .flightNumber, .link, .lookupSuggestion, .trackingNumber]
            
            configuration.websiteDataStore = WKWebsiteDataStore.default()
            // For private mode later:
            //            let dataStore = WKWebsiteDataStore.nonPersistent()
            //            configuration.websiteDataStore = dataStore
            
            for (urlSchemeHandler, urlScheme) in schemeHandlers {
                configuration.setURLSchemeHandler(urlSchemeHandler, forURLScheme: urlScheme)
            }
            
            web = EnhancedWKWebView(frame: .zero, configuration: configuration)
            web?.isOpaque = false
            web?.backgroundColor = .clear
            
            if let id = id {
                Self.webViewCache[id] = web
            }
            
            web?.backgroundColor = .white
        }
        guard let web else { fatalError("Couldn't instantiate WKWebView for WebView.") }
        
        web.buildMenu = buildMenu
        
        web.scrollView.delegate = coordinator
        
        return web
    }
    
    @MainActor
    public func makeUIViewController(context: Context) -> WebViewController {
        // See: https://stackoverflow.com/questions/25200116/how-to-show-the-inspector-within-your-wkwebview-based-desktop-app
        //        preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        let webView = makeWebView(
            id: persistentWebViewID,
            config: config,
            coordinator: context.coordinator
        )
        refreshMessageHandlers(userContentController: webView.configuration.userContentController, context: context)
        
        refreshContentRules(userContentController: webView.configuration.userContentController, coordinator: context.coordinator)
        
        webView.configuration.userContentController = userContentController
        webView.allowsLinkPreview = true
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = config.allowsBackForwardNavigationGestures
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        //        webView.scrollView.contentInsetAdjustmentBehavior = .scrollableAxes
        webView.scrollView.isScrollEnabled = config.isScrollEnabled
        webView.pageZoom = config.pageZoom
        webView.isOpaque = config.isOpaque
        if #available(iOS 14.0, *) {
            webView.backgroundColor = UIColor(config.backgroundColor)
        } else {
            webView.backgroundColor = .clear
        }
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        
        //        webView.setValue(drawsBackground, forKey: "drawsBackground")
        
        context.coordinator.setWebView(webView)
        if context.coordinator.scriptCaller == nil, let scriptCaller = scriptCaller {
            context.coordinator.scriptCaller = scriptCaller
        }
        context.coordinator.scriptCaller?.caller = { webView.evaluateJavaScript($0, completionHandler: $1) }
        context.coordinator.scriptCaller?.asyncCaller = { js, args, frame, world in
            let world = world ?? .defaultClient
            //            debugPrint("# JS", js.prefix(60), args?.debugDescription.prefix(30))
            if let args = args {
                return try await webView.callAsyncJavaScript(js, arguments: args, in: frame, contentWorld: world)
            } else {
                return try await webView.callAsyncJavaScript(js, in: frame, contentWorld: world)
            }
        }
        context.coordinator.textSelection = $textSelection
        
        refreshDarkModeSetting(webView: webView)
        
        // In case we retrieved a cached web view that is already warm but we don't know it.
        //        webView.evaluateJavaScript("window.webkit.messageHandlers.swiftUIWebViewIsWarm.postMessage({})")
        
        return WebViewController(webView: webView, persistentWebViewID: persistentWebViewID)
    }
    
    @MainActor
    public func updateUIViewController(_ controller: WebViewController, context: Context) {
        context.coordinator.config = config
        context.coordinator.messageHandlers = webViewMessageHandlers
        context.coordinator.onNavigationCommitted = onNavigationCommitted
        context.coordinator.onNavigationFinished = onNavigationFinished
        context.coordinator.onNavigationFailed = onNavigationFailed
        context.coordinator.onURLChanged = onURLChanged
        
        refreshMessageHandlers(userContentController: controller.webView.configuration.userContentController, context: context)
        refreshDarkModeSetting(webView: controller.webView)
        //        refreshMessageHandlers(context: context)
        //        updateUserScripts(userContentController: controller.webView.configuration.userContentController, coordinator: context.coordinator, forDomain: controller.webView.url, config: config)
        
        //        refreshContentRules(userContentController: controller.webView.configuration.userContentController, coordinator: context.coordinator)
        
        //        controller.webView.setValue(drawsBackground, forKey: "drawsBackground")
        
        
        controller.webView.buildMenu = buildMenu
        controller.webView.scrollView.bounces = bounces
        controller.webView.scrollView.alwaysBounceVertical = bounces
        
        // TODO: Fix for RTL languages, if it matters for _obscuredInsets.
        //        let insets = UIEdgeInsets(top: obscuredInsets.top, left: obscuredInsets.leading, bottom: obscuredInsets.bottom, right: obscuredInsets.trailing)
        let bottomSafeAreaInset = controller.view.window?.safeAreaInsets.bottom ?? 0
        
        //        let insets = UIEdgeInsets(top: obscuredInsets.top, left: obscuredInsets.leading, bottom: obscuredInsets.bottom, right: obscuredInsets.trailing)
        //        print(obscuredInsets)
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: obscuredInsets.bottom - bottomSafeAreaInset, right: 0)
        //        controller.obscuredInsets = UIEdgeInsets(top: 0, left: 0, bottom: obscuredInsets.bottom, right: 0)
        controller.obscuredInsets = UIEdgeInsets(top: obscuredInsets.top, left: 0, bottom: obscuredInsets.bottom, right: 0)
        // _obscuredInsets ignores sides, probably
    }
    
    public static func dismantleUIViewController(_ controller: WebViewController, coordinator: WebViewCoordinator) {
        controller.view.subviews.forEach { $0.removeFromSuperview() }
    }
}
#endif

#if os(macOS)
public struct WebView: NSViewRepresentable {
    private let config: WebViewConfig
    var navigator: WebViewNavigator
    @Binding var state: WebViewState
    var scriptCaller: WebViewScriptCaller?
    let blockedHosts: Set<String>?
    let htmlInState: Bool
    //    let onWarm: (() -> Void)?
    let schemeHandlers: [(WKURLSchemeHandler, String)]
    let onNavigationCommitted: ((WebViewState) -> Void)?
    let onNavigationFinished: ((WebViewState) -> Void)?
    let onNavigationFailed: ((WebViewState) -> Void)?
    let onURLChanged: ((WebViewState) -> Void)?
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    /// Unused on macOS (for now?).
    var obscuredInsets: EdgeInsets
    var bounces = true
    private var userContentController = WKUserContentController()
    
    @Environment(\.webViewMessageHandlers) private var webViewMessageHandlers
    
    //    @State fileprivate var isWarm = false
    @State fileprivate var drawsBackground = false
    @State private var lastInstalledScripts = [WebViewUserScript]()
    
    private static let processPool = WKProcessPool()
    
    /// `persistentWebViewID` is only used on iOS, not macOS.
    public init(config: WebViewConfig = .default,
                navigator: WebViewNavigator,
                state: Binding<WebViewState>,
                scriptCaller: WebViewScriptCaller? = nil,
                blockedHosts: Set<String>? = nil,
                htmlInState: Bool = false,
                obscuredInsets: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
                bounces: Bool = true,
                persistentWebViewID: String? = nil,
                //                onWarm: (() -> Void)? = nil,
                schemeHandlers: [(WKURLSchemeHandler, String)] = [],
                onNavigationCommitted: ((WebViewState) -> Void)? = nil,
                onNavigationFinished: ((WebViewState) -> Void)? = nil,
                onNavigationFailed: ((WebViewState) -> Void)? = nil,
                onURLChanged: ((WebViewState) -> Void)? = nil,
                buildMenu: BuildMenuType? = nil,
                hideNavigationDueToScroll: Binding<Bool> = .constant(false),
                textSelection: Binding<String?>? = nil
    ) {
        self.config = config
        self.navigator = navigator
        _state = state
        self.scriptCaller = scriptCaller
        self.blockedHosts = blockedHosts
        self.htmlInState = htmlInState
        self.obscuredInsets = obscuredInsets
        self.bounces = bounces
        //        self.onWarm = onWarm
        self.schemeHandlers = schemeHandlers
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onURLChanged = onURLChanged
        _hideNavigationDueToScroll = hideNavigationDueToScroll
        _textSelection = textSelection ?? .constant(nil)
        
        // TODO: buildMenu macOS...
    }
    
    public func makeCoordinator() -> WebViewCoordinator {
        return WebViewCoordinator(
            webView: self,
            navigator: navigator,
            scriptCaller: scriptCaller,
            config: config,
            messageHandlers: webViewMessageHandlers,
            onNavigationCommitted: onNavigationCommitted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onURLChanged: onURLChanged,
            hideNavigationDueToScroll: $hideNavigationDueToScroll,
            textSelection: $textSelection
        )
    }
    
    @MainActor
    public func makeNSView(context: Context) -> EnhancedWKWebView {
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = config.javaScriptEnabled
        
        // See: https://stackoverflow.com/questions/25200116/how-to-show-the-inspector-within-your-wkwebview-based-desktop-app
        //        preferences.setValue(true, forKey: "developerExtrasEnabled") // Wasn't working - revisit, because it would be great to have.
        
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = userAgent
        configuration.defaultWebpagePreferences = preferences
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        // For private mode later:
        //            let dataStore = WKWebsiteDataStore.nonPersistent()
        //            configuration.websiteDataStore = dataStore
        configuration.processPool = Self.processPool
        configuration.userContentController = userContentController
        refreshMessageHandlers(userContentController: configuration.userContentController, context: context)
        //        updateUserScripts(userContentController: configuration.userContentController, coordinator: context.coordinator, forDomain: nil, config: config)
        
        // For private mode later:
        //        let dataStore = WKWebsiteDataStore.nonPersistent()
        //        configuration.websiteDataStore = dataStore
        
        configuration.setValue(drawsBackground, forKey: "drawsBackground")
        
        for (urlSchemeHandler, urlScheme) in schemeHandlers {
            configuration.setURLSchemeHandler(urlSchemeHandler, forURLScheme: urlScheme)
        }
        
        let webView = EnhancedWKWebView(frame: CGRect.zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.pageZoom = config.pageZoom
        webView.allowsBackForwardNavigationGestures = config.allowsBackForwardNavigationGestures
        webView.layer?.backgroundColor = .white
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        
        context.coordinator.setWebView(webView)
        if context.coordinator.scriptCaller == nil, let scriptCaller = scriptCaller {
            context.coordinator.scriptCaller = scriptCaller
        }
        context.coordinator.scriptCaller?.caller = { webView.evaluateJavaScript($0, completionHandler: $1) }
        context.coordinator.scriptCaller?.asyncCaller = { (js: String, args: [String: Any]?, frame: WKFrameInfo?, world: WKContentWorld?) async throws -> Any? in
            let world = world ?? .defaultClient
            if let args = args {
                return try await webView.callAsyncJavaScript(js, arguments: args, in: frame, contentWorld: world)
            } else {
                return try await webView.callAsyncJavaScript(js, in: frame, contentWorld: world)
            }
        }
        
        refreshDarkModeSetting(webView: webView)
        
        return webView
    }
    
    @MainActor
    public func updateNSView(_ uiView: EnhancedWKWebView, context: Context) {
        context.coordinator.config = config
        context.coordinator.messageHandlers = webViewMessageHandlers
        context.coordinator.onNavigationCommitted = onNavigationCommitted
        context.coordinator.onNavigationFinished = onNavigationFinished
        context.coordinator.onNavigationFailed = onNavigationFailed
        context.coordinator.onURLChanged = onURLChanged
        
        //        refreshMessageHandlers(context: context)
        refreshMessageHandlers(userContentController: context.webView?.configuration.userContentController, context: context)
        //        updateUserScripts(userContentController: uiView.configuration.userContentController, coordinator: context.coordinator, forDomain: uiView.url, config: config)
        
        //        refreshContentRules(userContentController: uiView.configuration.userContentController, coordinator: context.coordinator)
        
        // Can't disable on macOS.
        //        uiView.scrollView.bounces = bounces
        //        uiView.scrollView.alwaysBounceVertical = bounces
        
        refreshDarkModeSetting(webView: uiView)
        
        uiView.setValue(drawsBackground, forKey: "drawsBackground")
        
    }
    
    public static func dismantleNSView(_ nsView: EnhancedWKWebView, coordinator: WebViewCoordinator) {
        for messageHandlerName in coordinator.messageHandlerNames {
            nsView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
        }
    }
}
#endif

extension WebView {
    var userAgent: String {
        //        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"
        return "Version/18.4 Safari/605.1.15"
    }
    
    @MainActor
    func refreshDarkModeSetting(webView: WKWebView) {
#if os(iOS)
        webView.overrideUserInterfaceStyle = config.darkModeSetting == .darkModeOverride ? .dark : .unspecified
#elseif os(macOS)
        webView.appearance = config.darkModeSetting == .darkModeOverride ? NSAppearance(named: .darkAqua) : nil
#endif
    }
    
    @MainActor
    func refreshContentRules(userContentController: WKUserContentController, coordinator: Coordinator) {
        userContentController.removeAllContentRuleLists()
        guard let contentRules = config.contentRules else { return }
        if let ruleList = coordinator.compiledContentRules[contentRules] {
            userContentController.add(ruleList)
        } else {
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "ContentBlockingRules",
                encodedContentRuleList: contentRules) { (ruleList, error) in
                    guard let ruleList = ruleList else {
                        if let error = error {
                            print(error)
                        }
                        return
                    }
                    userContentController.add(ruleList)
                    coordinator.compiledContentRules[contentRules] = ruleList
                }
        }
    }
    
    /// Refreshes the WKScriptMessageHandlers for the WebView.
    /// - Note: `systemMessageHandlers` are constant and never change.
    ///         Only the environment's handler names are dynamic.
    /// - Performance: This function avoids unnecessary Set creation or handler updates if nothing changed.
    @MainActor
    func refreshMessageHandlers(userContentController: WKUserContentController, context: Context) {
        // systemMessageHandlers never change, so only envHandlerNames matter.
        let envHandlerNames = webViewMessageHandlers.handlers.keys
        // Early exit if environment handler keys haven't changed
        if context.coordinator.lastEnvHandlerNames == envHandlerNames {
            return
        }
        context.coordinator.lastEnvHandlerNames = envHandlerNames
        
        // Only create sets if changes detected.
        let requiredHandlers = Set(Self.systemMessageHandlers).union(envHandlerNames)
        
        // Add any missing handlers.
        for messageHandlerName in requiredHandlers {
            if context.coordinator.registeredMessageHandlerNames.contains(messageHandlerName) { continue }
            // Sometimes we reuse an underlying WKWebView for a new SwiftUI component.
            userContentController.removeScriptMessageHandler(forName: messageHandlerName, contentWorld: .page)
            userContentController.add(context.coordinator, contentWorld: .page, name: messageHandlerName)
            context.coordinator.registeredMessageHandlerNames.insert(messageHandlerName)
        }
        
        // Remove any no-longer-needed handlers.
        for missing in context.coordinator.registeredMessageHandlerNames.subtracting(requiredHandlers) {
            userContentController.removeScriptMessageHandler(forName: missing)
            context.coordinator.registeredMessageHandlerNames.remove(missing)
        }
    }
    
    @MainActor
    func updateUserScripts(userContentController: WKUserContentController, coordinator: WebViewCoordinator, forDomain domain: URL?, config: WebViewConfig) {
        var scripts = config.userScripts
        if let domain = domain?.domainURL.host {
            scripts = scripts.filter { $0.allowedDomains.isEmpty || $0.allowedDomains.contains(domain) }
        } else {
            scripts = scripts.filter { $0.allowedDomains.isEmpty }
        }
        var allScripts = Self.systemScripts + scripts
        //        guard allScripts.hashValue != coordinator.lastInstalledScriptsHash else { return }
        
        if allScripts.isEmpty && !userContentController.userScripts.isEmpty {
            userContentController.removeAllUserScripts()
            return
        }
        
        var matchedExistingScripts = [WKUserScript]()
        if !allScripts.allSatisfy({ newScript in
            return userContentController.userScripts.contains(where: { existingScript in
                if newScript.source == existingScript.source
                    && newScript.injectionTime == existingScript.injectionTime
                    && newScript.isForMainFrameOnly == existingScript.isForMainFrameOnly {
                    //                    && newScript.world == existingScript.world { // TODO: Track associated worlds...
                    matchedExistingScripts.append(existingScript)
                    return true
                }
                return false
            })
        }) || userContentController.userScripts.contains(where: { !matchedExistingScripts.contains($0) }) {
            userContentController.removeAllUserScripts()
            for var script in allScripts {
                userContentController.addUserScript(script.webKitUserScript)
            }
        }
        //        coordinator.lastInstalledScriptsHash = allScripts.hashValue
    }
    
    fileprivate static let systemScripts = [
        WebViewBackgroundStatusUserScript().userScript,
        LocationChangeUserScript().userScript,
        ImageChangeUserScript().userScript,
        PageIconChangeUserScript().userScript,
        TextSelectionUserScript().userScript,
    ]
    
    fileprivate static let systemMessageHandlers: [String] = [
        "swiftUIWebViewBackgroundStatus",
        "swiftUIWebViewLocationChanged",
        "swiftUIWebViewImageUpdated",
        "swiftUIWebViewPageIconUpdated",
        "swiftUIWebViewTextSelection",
    ]
}


//// https://adam.garrett-harris.com/2021-08-21-providing-access-to-directories-in-ios-with-bookmarks/
//fileprivate struct FileBookmarks {
//    static func
//    func startAccessingFileURL() -> URL? {
//        guard let fileURL = url.isFileURL ? url : url.fileURLFromCustomSchemeLoaderURL else { return nil }
//
//        if let fileURLBookmarkData = fileURLBookmarkData {
//            var isStale = false
//            let resolvedURL = try? URL(
//                resolvingBookmarkData: fileURLBookmarkData,
//                bookmarkDataIsStale: &isStale)
//
//            if let resolvedURL = resolvedURL, !isStale {
//                return resolvedURL
//            }
//        }
//
//        // Start accessing a security-scoped resource.
//        guard fileURL.startAccessingSecurityScopedResource() else {
//            // Handle the failure here.
//            return nil
//        }
//
//        // Make sure you release the security-scoped resource when you finish.
//        defer { fileURL.stopAccessingSecurityScopedResource() }
//
//        var err: NSError? = nil
//        var failed = true
//        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &err, byAccessor: { (newURL: URL) -> Void in
//            do {
//                let bookmarkData = try fileURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
//                safeWrite(self) { _, bookmark in
//                    bookmark.fileURLBookmarkData = bookmarkData
//                }
//                failed = false
//            } catch let error {
//                print("\(error)")
//            }
//        })
//        if failed {
//            print("Failed to access file URL \(fileURL)")
//        }
//        return fileURL
//    }
//}

/*
 struct WebViewTest: View {
 @State private var action = WebViewAction.idle
 @State private var state = WebViewState.empty
 
 private var userScripts: [WKUserScript] = []
 @State private var address = "https://www.google.com"
 
 var body: some View {
 VStack {
 titleView
 navigationToolbar
 errorView
 Divider()
 WebView(action: $action,
 state: $state,
 blockedHosts: Set(["apple.com"]),
 htmlInState: true)
 Text(state.pageHTML ?? "")
 .lineLimit(nil)
 Spacer()
 }
 }
 
 private var titleView: some View {
 Text(String(format: "%@ - %@", state.pageTitle ?? "Load a page", state.pageURL.absoluteString))
 .font(.system(size: 24))
 }
 
 private var navigationToolbar: some View {
 HStack(spacing: 10) {
 Button("Test HTML") {
 action = .loadHTML("<html><body><b>Hello World!</b></body></html>")
 }
 TextField("Address", text: $address)
 if state.isLoading {
 if #available(iOS 14, macOS 11, *) {
 ProgressView()
 .progressViewStyle(CircularProgressViewStyle())
 } else {
 Text("Loading")
 }
 }
 Spacer()
 Button("Go") {
 if let url = URL(string: address) {
 action = .load(URLRequest(url: url))
 }
 }
 Button(action: {
 action = .reload
 }) {
 if #available(iOS 14, macOS 11, *) {
 Image(systemName: "arrow.counterclockwise")
 .imageScale(.large)
 } else {
 Text("Reload")
 }
 }
 if state.canGoBack {
 Button(action: {
 action = .goBack
 }) {
 if #available(iOS 14, macOS 11, *) {
 Image(systemName: "chevron.left")
 .imageScale(.large)
 } else {
 Text("<")
 }
 }
 }
 if state.canGoForward {
 Button(action: {
 action = .goForward
 }) {
 if #available(iOS 14, macOS 11, *) {
 Image(systemName: "chevron.right")
 .imageScale(.large)
 } else {
 Text(">")
 }
 }
 }
 }.padding()
 }
 
 private var errorView: some View {
 Group {
 if let error = state.error {
 Text(error.localizedDescription)
 .foregroundColor(.red)
 }
 }
 }
 }
 
 struct WebView_Previews: PreviewProvider {
 static var previews: some View {
 WebViewTest()
 }
 }
 */
