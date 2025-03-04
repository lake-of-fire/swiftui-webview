import SwiftUI
import WebKit
import UniformTypeIdentifiers
import ZIPFoundation

public struct WebViewMessageHandlersKey: EnvironmentKey {
    public static let defaultValue: [String: (WebViewMessage) async -> Void] = [:]
}

public extension EnvironmentValues {
    var webViewMessageHandlers: [String: (WebViewMessage) async -> Void] {
        get { self[WebViewMessageHandlersKey.self] }
        set { self[WebViewMessageHandlersKey.self] = newValue }
    }
}

public struct WebViewState: Equatable {
    public internal(set) var isLoading: Bool
    public internal(set) var isProvisionallyNavigating: Bool
    public internal(set) var pageURL: URL
    public internal(set) var pageTitle: String?
    public internal(set) var pageImageURL: URL?
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
    var urlObservation: NSKeyValueObservation?
    
    var onNavigationCommitted: ((WebViewState) -> Void)?
    var onNavigationFinished: ((WebViewState) -> Void)?
    var messageHandlers: [String: ((WebViewMessage) async -> Void)]
    var messageHandlerNames: [String] {
        messageHandlers.keys.map { $0 }
    }
    var textSelection: Binding<String?>

    init(
        webView: WebView,
        navigator: WebViewNavigator,
        scriptCaller: WebViewScriptCaller? = nil,
        config: WebViewConfig,
        messageHandlers: [String: ((WebViewMessage) async -> Void)],
        onNavigationCommitted: ((WebViewState) -> Void)?,
        onNavigationFinished: ((WebViewState) -> Void)?,
        textSelection: Binding<String?>
    ) {
        self.webView = webView
        self.navigator = navigator
        self.scriptCaller = scriptCaller
        self.config = config
        self.messageHandlers = messageHandlers
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.textSelection = textSelection

        // TODO: Make about:blank history initialization optional via configuration.
        #warning("confirm this sitll works")
//        if  webView.state.backList.isEmpty && webView.state.forwardList.isEmpty && webView.state.pageURL.absoluteString == "about:blank" {
//            Task { @MainActor in
//                webView.action = .load(URLRequest(url: URL(string: "about:blank")!))
//            }
//        }
    }
    
    func setWebView(_ webView: WKWebView) {
        navigator.webView = webView
        
        urlObservation = webView.observe(\.url, changeHandler: { [weak self] (webView, change) in
            guard let self else { return }
            if let url = webView.url {
                setLoading(
                    false,
                    pageURL: url,
                    canGoBack: webView.canGoBack,
                    canGoForward: webView.canGoForward,
                    backList: webView.backForwardList.backList,
                    forwardList: webView.backForwardList.forwardList)
            }
        })
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
            webView.needsHistoryRefresh = true
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
        
        guard let messageHandler = messageHandlers[message.name] else { return }
        let message = WebViewMessage(frameInfo: message.frameInfo, uuid: UUID(), name: message.name, body: message.body)
        Task {
            await messageHandler(message)
        }
    }
}

#if os(macOS)
extension WebViewCoordinator: WKUIDelegate {
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
}
#endif

extension WebViewCoordinator: WKNavigationDelegate {
    @MainActor
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
//        debugPrint("# didFinish nav", webView.url)
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
        
        if let onNavigationFinished = self.onNavigationFinished {
            onNavigationFinished(newState)
        }
        
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
        setLoading(false, isProvisionallyNavigating: false, error: error)
    }
    
    @MainActor
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        setLoading(false, isProvisionallyNavigating: false)
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        scriptCaller?.removeAllMultiTargetFrames()
        setLoading(false, isProvisionallyNavigating: false, error: error)
        
        extractPageState(webView: webView)
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        debugPrint("# didCommit nav", webView.url)
        scriptCaller?.removeAllMultiTargetFrames()
        var newState = setLoading(
            true,
            pageURL: webView.url,
            isProvisionallyNavigating: false
        )
        newState.pageImageURL = nil
        newState.pageTitle = nil
        newState.pageHTML = nil
        newState.error = nil
        if let onNavigationCommitted = self.onNavigationCommitted {
            onNavigationCommitted(newState)
        }
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        setLoading(
            true,
            isProvisionallyNavigating: true,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            backList: webView.backForwardList.backList,
            forwardList: webView.backForwardList.forwardList)
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
        /*if let url = navigationAction.request.url,
           navigationAction.targetFrame?.isMainFrame ?? false,
           url.isEBookURL, !["ebook", "ebook-url"].contains(url.scheme),
           let viewerHtmlPath = Bundle.module.path(forResource: "ebook-reader", ofType: "html", inDirectory: "Foliate"), let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let epubURL = URL(string: url.isFileURL ? "epub://\(path)" : "epub-url://\(url.absoluteString.hasPrefix("https://") ? url.absoluteString.dropFirst("https://".count) : url.absoluteString.dropFirst("http://".count))") {
            do {
                let html = try String(contentsOfFile: viewerHtmlPath, encoding: .utf8)
                webView.loadHTMLString(html, baseURL: epubURL)
            } catch { }
            return (.cancel, preferences)
        }*/
        
        // PDF.js loader
//        if
//            false,
//                let url = navigationAction.request.url,
//            navigationAction.targetFrame?.isMainFrame ?? false,
//            url.isFileURL || url.absoluteString.hasPrefix("https://"),
//            navigationAction.request.url?.pathExtension.lowercased() == "pdf",
//            //           navigationAction.request.mainDocumentURL?.scheme != "pdf",
//            let pdfJSPath = Bundle.module.path(forResource: "viewer", ofType: "html"), let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let pdfURL = URL(string: url.isFileURL ? "pdf://\(path)" : "pdf-url://\(url.absoluteString.dropFirst("https://".count))") {
//            do {
//                let pdfJSHTML = try String(contentsOfFile: pdfJSPath)
//                webView.loadHTMLString(pdfJSHTML, baseURL: pdfURL)
//            } catch { }
//            return (.cancel, preferences)
//        }
        
        if navigationAction.targetFrame?.isMainFrame ?? false, let mainDocumentURL = navigationAction.request.mainDocumentURL {
            // TODO: this is missing all our config.userScripts, make sure it inherits those...
            self.webView.updateUserScripts(userContentController: webView.configuration.userContentController, coordinator: self, forDomain: mainDocumentURL, config: config)
            
            scriptCaller?.removeAllMultiTargetFrames()
            var newState = self.webView.state
            newState.pageURL = mainDocumentURL
            newState.pageTitle = nil
            newState.isProvisionallyNavigating = false
            newState.pageImageURL = nil
            newState.pageHTML = nil
            newState.error = nil
            self.webView.state = newState
        }
        
//        // TODO: Verify that restricting to main frame is correct. Recheck brave behavior.
        if navigationAction.targetFrame?.isMainFrame ?? false {
            self.webView.refreshContentRules(userContentController: webView.configuration.userContentController, coordinator: self)
        }
        
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
        debugPrint("# WebViewNavigator.load(...)", request.url)
        if let url = request.url, url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url)
        } else {
            webView.load(request)
        }
    }
    
    public func loadHTML(_ html: String, baseURL: URL? = nil) {
        debugPrint("# WebViewNavigator.loadHTML(...)", html.prefix(100), baseURL)
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

    @MainActor
    public func evaluateJavaScript(_ js: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        guard let caller = caller else {
            print("No caller set for WebViewScriptCaller \(id)") // TODO: Error
            return
        }
        caller(js, completionHandler)
    }
    
    @MainActor
    public func evaluateJavaScript(_ js: String, arguments: [String: Any]? = nil, in frame: WKFrameInfo? = nil, duplicateInMultiTargetFrames: Bool = false, in world: WKContentWorld? = .page, completionHandler: ((Result<Any?, any Error>) async throws -> Void)? = nil) async {
        guard let asyncCaller = asyncCaller else {
            print("No asyncCaller set for WebViewScriptCaller \(id)") // TODO: Error
            return
        }
        do {
            let result = try await asyncCaller(js, arguments, frame, world)
            if duplicateInMultiTargetFrames {
                for (uuid, targetFrame) in multiTargetFrames.filter({ !$0.value.isMainFrame }) {
                    if targetFrame == frame { continue }
                    do {
                        _ = try await asyncCaller(js, arguments, targetFrame, world)
                    } catch {
                        if let error = error as? WKError, error.code == .javaScriptInvalidFrameTarget {
                            multiTargetFrames.removeValue(forKey: uuid)
                        } else {
                            print(error)
                        }
                    }
                }
            }
            try await completionHandler?(.success(result))
        } catch {
            try? await completionHandler?(.failure(error))
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
    var buildMenu: ((UIMenuBuilder) -> Void)?
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
    let buildMenu: ((UIMenuBuilder) -> Void)?
    @Binding var textSelection: String?
    let obscuredInsets: EdgeInsets
    var bounces = true
    let persistentWebViewID: String?
//    let onWarm: (() async -> Void)?
    
    @Environment(\.webViewMessageHandlers) private var webViewMessageHandlers
    
    private var userContentController = WKUserContentController()
//    @State fileprivate var isWarm = false
    @State fileprivate var drawsBackground = false
    @State fileprivate var needsHistoryRefresh = false
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
                buildMenu: ((UIMenuBuilder) -> Void)? = nil,
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
        self.buildMenu = buildMenu
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
            textSelection: $textSelection
        )
    }
    
    @MainActor
    private func makeWebView(id: String?, config: WebViewConfig, coordinator: WebViewCoordinator, messageHandlerNamesToRegister: Set<String>) -> EnhancedWKWebView {
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
            configuration.applicationNameForUserAgent = "Safari/604.1"
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
        if let web = web {
            for messageHandlerName in messageHandlerNamesToRegister {
                if coordinator.registeredMessageHandlerNames.contains(messageHandlerName) { continue }
                web.configuration.userContentController.add(coordinator, contentWorld: .page, name: messageHandlerName)
                coordinator.registeredMessageHandlerNames.insert(messageHandlerName)
            }
            web.buildMenu = buildMenu
        }
        guard let web = web else { fatalError("Couldn't instantiate WKWebView for WebView.") }
        return web
    }
    
    @MainActor
    public func makeUIViewController(context: Context) -> WebViewController {
        // See: https://stackoverflow.com/questions/25200116/how-to-show-the-inspector-within-your-wkwebview-based-desktop-app
//        preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        let webView = makeWebView(id: persistentWebViewID, config: config, coordinator: context.coordinator, messageHandlerNamesToRegister: Set(webViewMessageHandlers.keys))
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
            if let args = args {
                return try await webView.callAsyncJavaScript(js, arguments: args, in: frame, contentWorld: world)
            } else {
                return try await webView.callAsyncJavaScript(js, in: frame, contentWorld: world)
            }
        }
        
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
        context.coordinator.textSelection = $textSelection

        refreshDarkModeSetting(webView: controller.webView)
//        refreshMessageHandlers(context: context)
//        updateUserScripts(userContentController: controller.webView.configuration.userContentController, coordinator: context.coordinator, forDomain: controller.webView.url, config: config)
        
//        refreshContentRules(userContentController: controller.webView.configuration.userContentController, coordinator: context.coordinator)
        
//        controller.webView.setValue(drawsBackground, forKey: "drawsBackground")
        
        if needsHistoryRefresh {
            var newState = state
            newState.isLoading = state.isLoading
            newState.isProvisionallyNavigating = state.isProvisionallyNavigating
            newState.canGoBack = controller.webView.canGoBack
            newState.canGoForward = controller.webView.canGoForward
            newState.backList = controller.webView.backForwardList.backList
            newState.forwardList = controller.webView.backForwardList.forwardList
//            DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) {
            Task { @MainActor in
                state = newState
                needsHistoryRefresh = false
            }
        }
        
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
    @Binding var textSelection: String?
    /// Unused on macOS (for now?).
    var obscuredInsets: EdgeInsets
    var bounces = true
    private var userContentController = WKUserContentController()
    
    @Environment(\.webViewMessageHandlers) private var webViewMessageHandlers
    
//    @State fileprivate var isWarm = false
    @State fileprivate var needsHistoryRefresh = false
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
                buildMenu: ((Any) -> Void)? = nil,
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
        configuration.applicationNameForUserAgent = "Safari/604.1"
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

//        refreshMessageHandlers(context: context)
//        refreshMessageHandlers(userContentController: context.webView?.configuration.userContentController, context: context)
//        updateUserScripts(userContentController: uiView.configuration.userContentController, coordinator: context.coordinator, forDomain: uiView.url, config: config)
        
//        refreshContentRules(userContentController: uiView.configuration.userContentController, coordinator: context.coordinator)

        // Can't disable on macOS.
//        uiView.scrollView.bounces = bounces
//        uiView.scrollView.alwaysBounceVertical = bounces
        
        refreshDarkModeSetting(webView: uiView)

        uiView.setValue(drawsBackground, forKey: "drawsBackground")
        
        if needsHistoryRefresh {
            var newState = state
            newState.isLoading = state.isLoading
            newState.isProvisionallyNavigating = state.isProvisionallyNavigating
            newState.canGoBack = uiView.canGoBack
            newState.canGoForward = uiView.canGoForward
            newState.backList = uiView.backForwardList.backList
            newState.forwardList = uiView.backForwardList.forwardList
            Task { @MainActor in
//            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                state = newState
                needsHistoryRefresh = false
            }
        }
    }
    
    public static func dismantleNSView(_ nsView: EnhancedWKWebView, coordinator: WebViewCoordinator) {
        for messageHandlerName in coordinator.messageHandlerNames {
            nsView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
        }
    }
}
#endif

extension WebView {
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
    
    @MainActor
    func refreshMessageHandlers(userContentController: WKUserContentController, context: Context) {
        let envHandlerNames = Set(webViewMessageHandlers.keys)
        let requiredHandlers = Set(Self.systemMessageHandlers).union(envHandlerNames)
        
        for messageHandlerName in requiredHandlers {
            if context.coordinator.registeredMessageHandlerNames.contains(messageHandlerName) { continue }
            // Sometimes we reuse an underlying WKWebView for a new SwiftUI component.
            userContentController.removeScriptMessageHandler(forName: messageHandlerName, contentWorld: .page)
            userContentController.add(context.coordinator, contentWorld: .page, name: messageHandlerName)
            context.coordinator.registeredMessageHandlerNames.insert(messageHandlerName)
        }
        
        for missing in context.coordinator.registeredMessageHandlerNames.subtracting(requiredHandlers) {
            userContentController.removeScriptMessageHandler(forName: missing)
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
        TextSelectionUserScript().userScript,
    ]
    
    fileprivate static var systemMessageHandlers: [String] {
        [
            "swiftUIWebViewBackgroundStatus",
            "swiftUIWebViewLocationChanged",
            "swiftUIWebViewImageUpdated",
            "swiftUIWebViewTextSelection",
        ]
    }
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
