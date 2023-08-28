import SwiftUI
import WebKit
import UniformTypeIdentifiers
import ZIPFoundation

public extension URL {
    var isEBookURL: Bool {
        return (isFileURL || scheme == "https" || scheme == "http" || scheme == "ebook" || scheme == "ebook-url") && pathExtension.lowercased() == "epub"
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
    public let webKitUserScript: WKUserScript
    public let allowedDomains: Set<String>
    
    public static func == (lhs: WebViewUserScript, rhs: WebViewUserScript) -> Bool {
        lhs.source == rhs.source
        && lhs.allowedDomains == rhs.allowedDomains
    }
    
    public init(source: String, injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool, in world: WKContentWorld = .defaultClient, allowedDomains: Set<String> = Set()) {
        self.source = source
        self.webKitUserScript = WKUserScript(source: source, injectionTime: injectionTime, forMainFrameOnly: forMainFrameOnly, in: world)
        self.allowedDomains = allowedDomains
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(allowedDomains)
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
    
    var messageHandlerNames: [String] {
        webView.messageHandlers.keys.map { $0 }
    }
    
    init(webView: WebView, navigator: WebViewNavigator, scriptCaller: WebViewScriptCaller? = nil, config: WebViewConfig) {
        self.webView = webView
        self.navigator = navigator
        self.scriptCaller = scriptCaller
        self.config = config
        
        // TODO: Make about:blank history initialization optional via configuration.
        #warning("confirm this sitll works")
//        if  webView.state.backList.isEmpty && webView.state.forwardList.isEmpty && webView.state.pageURL.absoluteString == "about:blank" {
//            Task { @MainActor in
//                webView.action = .load(URLRequest(url: URL(string: "about:blank")!))
//            }
//        }
    }
    
    @discardableResult func setLoading(_ isLoading: Bool,
                                       pageURL: URL? = nil,
                                       isProvisionallyNavigating: Bool? = nil,
                                       canGoBack: Bool? = nil,
                                       canGoForward: Bool? = nil,
                                       backList: [WKBackForwardListItem]? = nil,
                                       forwardList: [WKBackForwardListItem]? = nil,
                                       error: Error? = nil) -> WebViewState {
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
        if message.name == "swiftUIWebViewLocationChanged" {
            webView.needsHistoryRefresh = true
            return
        } else if message.name == "swiftUIWebViewEPUBJSInitialized" {
            if let url = message.webView?.url, let scheme = url.scheme, scheme == "ebook" || scheme == "ebook-url", url.absoluteString.hasPrefix("\(url.scheme ?? "")://"), url.isEBookURL, let loaderURL = URL(string: "\(scheme)://\(url.absoluteString.dropFirst("\(url.scheme ?? "")://".count))") {
                Task { @MainActor in
                    do {
                        try await _ = message.webView?.callAsyncJavaScript("window.loadEBook(url)", arguments: ["url": loaderURL.absoluteString], contentWorld: .page)
                    } catch {
                        print("Failed to initialize ePUB: \(error.localizedDescription)")
                        if let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String {
                            print(message)
                        }
                    }
                }
            }
        } else if message.name == "swiftUIWebViewImageUpdated" {
            guard let body = message.body as? [String: Any] else { return }
            if let imageURLRaw = body["imageURL"] as? String, let urlRaw = body["url"] as? String, let url = URL(string: urlRaw), let imageURL = URL(string: imageURLRaw), url == webView.state.pageURL {
                var newState = webView.state
                newState.pageImageURL = imageURL
                let targetState = newState
                Task { @MainActor in
                //                DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [webView] in
                    webView.state = targetState
                }
            }
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
        
        guard let messageHandler = webView.messageHandlers[message.name] else { return }
        let message = WebViewMessage(frameInfo: message.frameInfo, uuid: UUID(), name: message.name, body: message.body)
        Task {
            await messageHandler(message)
        }
    }
}

extension WebViewCoordinator: WKNavigationDelegate {
    @MainActor
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
        
        if let onNavigationFinished = self.webView.onNavigationFinished {
            onNavigationFinished(newState)
        }
        
        extractPageState(webView: webView)
    }
    
    private func extractPageState(webView: WKWebView) {
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
    
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        setLoading(false, isProvisionallyNavigating: false)
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        setLoading(false, isProvisionallyNavigating: false, error: error)
        
        extractPageState(webView: webView)
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let newState = setLoading(true, pageURL: webView.url, isProvisionallyNavigating: false)
        if let onNavigationCommitted = self.webView.onNavigationCommitted {
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
        if
            false,
                let url = navigationAction.request.url,
            navigationAction.targetFrame?.isMainFrame ?? false,
            url.isFileURL || url.absoluteString.hasPrefix("https://"),
            navigationAction.request.url?.pathExtension.lowercased() == "pdf",
            //           navigationAction.request.mainDocumentURL?.scheme != "pdf",
            let pdfJSPath = Bundle.module.path(forResource: "viewer", ofType: "html"), let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let pdfURL = URL(string: url.isFileURL ? "pdf://\(path)" : "pdf-url://\(url.absoluteString.dropFirst("https://".count))") {
            do {
                let pdfJSHTML = try String(contentsOfFile: pdfJSPath)
                webView.loadHTMLString(pdfJSHTML, baseURL: pdfURL)
            } catch { }
            return (.cancel, preferences)
        }
        
        if let url = navigationAction.request.url,
           let scheme = url.scheme,
           let schemeHandler = self.webView.schemeHandlers[scheme] {
            schemeHandler(url)
            return (.cancel, preferences)
        }
        
//        // TODO: Verify that restricting to main frame is correct. Recheck brave behavior.
        if navigationAction.targetFrame?.isMainFrame ?? false, let mainDocumentURL = navigationAction.request.mainDocumentURL {
            self.webView.updateUserScripts(userContentController: webView.configuration.userContentController, coordinator: self, forDomain: mainDocumentURL, config: config)
            
            self.webView.refreshContentRules(userContentController: webView.configuration.userContentController, coordinator: self)
        }
        
        return (.allow, preferences)
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let url = navigationResponse.response.url, self.webView.state.pageURL != url {
            var newState = self.webView.state
            newState.pageURL = url
            newState.pageTitle = nil
            newState.pageHTML = nil
            newState.error = nil
            self.webView.state = newState
        }
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
    
    public func load(_ request: URLRequest) {
        guard let webView = webView else { return }
        if let url = request.url, url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url)
        } else {
            webView.load(request)
        }
    }
    
    public func loadHTML(_ html: String, baseURL: URL? = nil) {
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

public class WebViewScriptCaller: Equatable, ObservableObject {
    let uuid = UUID().uuidString
//    @Published var caller: ((String, ((Any?, Error?) -> Void)?) -> Void)? = nil
    var caller: ((String, ((Any?, Error?) -> Void)?) -> Void)? = nil
    var asyncCaller: ((String, [String: Any]?, WKFrameInfo?, WKContentWorld?, ((Result<Any, any Error>) -> Void)?) async -> Void)? = nil
    
    public static func == (lhs: WebViewScriptCaller, rhs: WebViewScriptCaller) -> Bool {
        return lhs.uuid == rhs.uuid
    }

    @MainActor
    public func evaluateJavaScript(_ js: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        guard let caller = caller else {
            print("No caller set for WebViewScriptCaller \(uuid)") // TODO: Error
            return
        }
        caller(js, completionHandler)
    }
    
    @MainActor
    public func evaluateJavaScript(_ js: String, arguments: [String: Any]? = nil, in frame: WKFrameInfo? = nil, in world: WKContentWorld? = nil, completionHandler: ((Result<Any, any Error>) -> Void)? = nil) async {
        guard let asyncCaller = asyncCaller else {
            print("No asyncCaller set for WebViewScriptCaller \(uuid)") // TODO: Error
            return
        }
        await asyncCaller(js, arguments, frame, world, completionHandler)
    }
   
    public init() {
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
        userScript = WebViewUserScript(source: contents, injectionTime: .atDocumentStart, forMainFrameOnly: true)
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
    }
}).observe(document, {childList: true, subtree: true, attributes: true, attributeOldValue: false, attributeFilter: ['property', 'content']})
"""
        userScript = WebViewUserScript(source: contents, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
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
    
    public init(javaScriptEnabled: Bool = true,
                contentRules: String? = nil,
                allowsBackForwardNavigationGestures: Bool = true,
                allowsInlineMediaPlayback: Bool = true,
                mediaTypesRequiringUserActionForPlayback: WKAudiovisualMediaTypes = [WKAudiovisualMediaTypes.all],
                dataDetectorsEnabled: Bool = true,
                isScrollEnabled: Bool = true,
                pageZoom: CGFloat = 1,
                isOpaque: Bool = true,
                backgroundColor: Color = .clear,
                userScripts: [WebViewUserScript] = []) {
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
    }
}

fileprivate let kLeftArrowKeyCode:  UInt16  = 123
fileprivate let kRightArrowKeyCode: UInt16  = 124
fileprivate let kDownArrowKeyCode:  UInt16  = 125
fileprivate let kUpArrowKeyCode:    UInt16  = 126

public class EnhancedWKWebView: WKWebView {
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
        let argument: [Any] = ["_o", "bscu", "red", "Ins", "ets"]
        let key = argument.compactMap({ $0 as? String }).joined()
            webView.setValue(insets, forKey: key)
//        webView.safeAreaInsetsDidChange()
            let argument2: [Any] = ["_h", "ave", "Set", "O", "bscu", "red", "Ins", "ets"]
            let key2 = argument2.compactMap({ $0 as? String }).joined()
            webView.setValue(true, forKey: key2)
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
    let schemeHandlers: [String: (URL) -> Void]
    var messageHandlers: [String: ((WebViewMessage) async -> Void)] = [:]
    let ebookTextProcessor: ((String) -> String)?
    let onNavigationCommitted: ((WebViewState) -> Void)?
    let onNavigationFinished: ((WebViewState) -> Void)?
    let obscuredInsets: EdgeInsets
    var bounces = true
    let persistentWebViewID: String?
//    let onWarm: (() async -> Void)?
    
    private var messageHandlerNamesToRegister = Set<String>()
    private var userContentController = WKUserContentController()
//    @State fileprivate var isWarm = false
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
                schemeHandlers: [String: (URL) -> Void] = [:],
                messageHandlers: [String: (WebViewMessage) async -> Void] = [:],
                ebookTextProcessor: ((String) -> String)? = nil,
                onNavigationCommitted: ((WebViewState) -> Void)? = nil,
                onNavigationFinished: ((WebViewState) -> Void)? = nil) {
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
        for name in messageHandlers.keys.map({ $0 }) {
            self.messageHandlerNamesToRegister.insert(name)
        }
        self.messageHandlers = messageHandlers
        self.ebookTextProcessor = ebookTextProcessor
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
    }
    
    public func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(webView: self, navigator: navigator, scriptCaller: scriptCaller, config: config)
    }
    
    @MainActor
    private static func makeWebView(id: String?, config: WebViewConfig, coordinator: WebViewCoordinator, messageHandlerNamesToRegister: Set<String>) -> EnhancedWKWebView {
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
            configuration.allowsInlineMediaPlayback = config.allowsInlineMediaPlayback
            //        configuration.defaultWebpagePreferences.preferredContentMode = .mobile  // for font adjustment to work
            configuration.mediaTypesRequiringUserActionForPlayback = config.mediaTypesRequiringUserActionForPlayback
            configuration.dataDetectorTypes = [.all]
            configuration.defaultWebpagePreferences = preferences
            configuration.processPool = Self.processPool
            
            // For private mode later:
            //            let dataStore = WKWebsiteDataStore.nonPersistent()
            //            configuration.websiteDataStore = dataStore
            
            for scheme in ["pdf", "ebook"] {
                configuration.setURLSchemeHandler(GenericFileURLSchemeHandler(ebookTextProcessor: ebookTextProcessor), forURLScheme: scheme)
//                configuration.setURLSchemeHandler(GenericFileURLSchemeHandler(), forURLScheme: "\(scheme)-url")
            }
            
            web = EnhancedWKWebView(frame: .zero, configuration: configuration)
            
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
        }
        guard let web = web else { fatalError("Couldn't instantiate WKWebView for WebView.") }
        return web
    }
    
    @MainActor
    public func makeUIViewController(context: Context) -> WebViewController {
        // See: https://stackoverflow.com/questions/25200116/how-to-show-the-inspector-within-your-wkwebview-based-desktop-app
//        preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        let webView = Self.makeWebView(id: persistentWebViewID, config: config, coordinator: context.coordinator, messageHandlerNamesToRegister: messageHandlerNamesToRegister)
        refreshMessageHandlers(context: context)
        
        refreshContentRules(userContentController: webView.configuration.userContentController, coordinator: context.coordinator)

        webView.configuration.userContentController = userContentController
        webView.allowsLinkPreview = true
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = config.allowsBackForwardNavigationGestures
//        webView.scrollView.contentInsetAdjustmentBehavior = .always
        webView.scrollView.contentInsetAdjustmentBehavior = .scrollableAxes
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
        
        context.coordinator.navigator.webView = webView
        if context.coordinator.scriptCaller == nil, let scriptCaller = scriptCaller {
            context.coordinator.scriptCaller = scriptCaller
        }
        context.coordinator.scriptCaller?.caller = { webView.evaluateJavaScript($0, completionHandler: $1) }
        context.coordinator.scriptCaller?.asyncCaller = { js, args, frame, world, callback in
            let world = world ?? .defaultClient
            if let args = args {
                webView.callAsyncJavaScript(js, arguments: args, in: frame, in: world, completionHandler: callback)
            } else {
                webView.callAsyncJavaScript(js, in: frame, in: world, completionHandler: callback)
            }
        }
        
        // In case we retrieved a cached web view that is already warm but we don't know it.
//        webView.evaluateJavaScript("window.webkit.messageHandlers.swiftUIWebViewIsWarm.postMessage({})")

        return WebViewController(webView: webView, persistentWebViewID: persistentWebViewID)
    }
    
    @MainActor
    public func updateUIViewController(_ controller: WebViewController, context: Context) {
//        refreshMessageHandlers(context: context)
        updateUserScripts(userContentController: controller.webView.configuration.userContentController, coordinator: context.coordinator, forDomain: controller.webView.url, config: config)
        
        refreshContentRules(userContentController: controller.webView.configuration.userContentController, coordinator: context.coordinator)
        
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
        
        controller.webView.scrollView.bounces = bounces
        controller.webView.scrollView.alwaysBounceVertical = bounces
        
        // TODO: Fix for RTL languages, if it matters for _obscuredInsets.
        controller.obscuredInsets = UIEdgeInsets(top: obscuredInsets.top, left: obscuredInsets.leading, bottom: obscuredInsets.bottom, right: obscuredInsets.trailing)
        
        // _obscuredInsets ignores bottom (maybe a side too..?)
        controller.webView.scrollView.contentInset.bottom = obscuredInsets.bottom
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
    let schemeHandlers: [String: (URL) -> Void]
    var messageHandlers: [String: ((WebViewMessage) async -> Void)] = [:]
    let ebookTextProcessor: ((String) -> String)?
    let onNavigationCommitted: ((WebViewState) -> Void)?
    let onNavigationFinished: ((WebViewState) -> Void)?
    /// Unused on macOS (for now).
    var obscuredInsets: EdgeInsets
    var bounces = true
    private var messageHandlerNamesToRegister = Set<String>()
    private var userContentController = WKUserContentController()
    
//    @State fileprivate var isWarm = false
    @State fileprivate var needsHistoryRefresh = false
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
                schemeHandlers: [String: (URL) -> Void] = [:],
                messageHandlers: [String: (WebViewMessage) async -> Void] = [:],
                ebookTextProcessor: ((String) -> String)? = nil,
                onNavigationCommitted: ((WebViewState) -> Void)? = nil,
                onNavigationFinished: ((WebViewState) -> Void)? = nil) {
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
        for name in messageHandlers.keys.map({ $0 }) {
            self.messageHandlerNamesToRegister.insert(name)
        }
        self.messageHandlers = messageHandlers
        self.ebookTextProcessor = ebookTextProcessor
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
    }
    
    public func makeCoordinator() -> WebViewCoordinator {
        return WebViewCoordinator(webView: self, navigator: navigator, scriptCaller: scriptCaller, config: config)
    }
    
    @MainActor
    public func makeNSView(context: Context) -> EnhancedWKWebView {
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = config.javaScriptEnabled
        
        // See: https://stackoverflow.com/questions/25200116/how-to-show-the-inspector-within-your-wkwebview-based-desktop-app
//        preferences.setValue(true, forKey: "developerExtrasEnabled") // Wasn't working - revisit, because it would be great to have.
        
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences = preferences
        configuration.processPool = Self.processPool
        configuration.userContentController = userContentController
        refreshMessageHandlers(context: context)
        
        // For private mode later:
        //        let dataStore = WKWebsiteDataStore.nonPersistent()
        //        configuration.websiteDataStore = dataStore
        
        for scheme in ["pdf", "ebook"] {
            configuration.setURLSchemeHandler(GenericFileURLSchemeHandler(ebookTextProcessor: ebookTextProcessor), forURLScheme: scheme)
//            configuration.setURLSchemeHandler(GenericFileURLSchemeHandler(), forURLScheme: "\(scheme)-url")
        }

        let webView = EnhancedWKWebView(frame: CGRect.zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.pageZoom = config.pageZoom
        webView.allowsBackForwardNavigationGestures = config.allowsBackForwardNavigationGestures
        webView.layer?.backgroundColor = .white
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        
        context.coordinator.navigator.webView = webView
        if context.coordinator.scriptCaller == nil, let scriptCaller = scriptCaller {
            context.coordinator.scriptCaller = scriptCaller
        }
        context.coordinator.scriptCaller?.caller = { webView.evaluateJavaScript($0, completionHandler: $1) }
        context.coordinator.scriptCaller?.asyncCaller = { js, args, frame, world, callback in
            let world = world ?? .defaultClient
            if let args = args {
                webView.callAsyncJavaScript(js, arguments: args, in: frame, in: world, completionHandler: callback)
            } else {
                webView.callAsyncJavaScript(js, in: frame, in: world, completionHandler: callback)
            }
        }
        
        return webView
    }

    @MainActor
    public func updateNSView(_ uiView: EnhancedWKWebView, context: Context) {
//        refreshMessageHandlers(context: context)
        updateUserScripts(userContentController: uiView.configuration.userContentController, coordinator: context.coordinator, forDomain: uiView.url, config: config)
        
        refreshContentRules(userContentController: uiView.configuration.userContentController, coordinator: context.coordinator)

        // Can't disable on macOS.
//        uiView.scrollView.bounces = bounces
//        uiView.scrollView.alwaysBounceVertical = bounces
        
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

//public struct OnMessageReceivedModifier: ViewModifier {
//    var name: String
//    var perform: @escaping ((WebViewMessage) async -> Void)
//
//    public init(name: String, perform: ((WebViewMessage) async -> Void)) {
//        self.name = name
//        self.perform = perform
//    }
//
//    public func body(content: WebView) -> some View {
//        content
//    }
//}
//public extension WebView {
//    func onMessageReceived(forName name: String, perform: @escaping ((WebViewMessage) async -> Void)) -> WebView {
//        var copy = self
//        copy.messageHandlerNamesToRegister.insert(name)
//        copy.messageHandlers[name] = perform
//        return copy
//    }
//}
    
extension WebView {
//    @MainActor
//    func processAction(webView: EnhancedWKWebView) {
//        guard action != .idle else { return }
//        switch action {
//        case .idle:
//            break
//        case .load(let request):
//            if let url = request.url, url.isFileURL {
//                webView.loadFileURL(url, allowingReadAccessTo: url)
//            } else {
//                webView.load(request)
//            }
//            if let url = request.url {
//                Task { @MainActor in
//                    var newState = state
//                    newState.pageURL = url
//                    newState.pageTitle = nil
//                    newState.pageHTML = nil
//                    newState.error = nil
//                    state = newState
//                }
//            }
//        case .loadHTML(let pageHTML):
//            webView.loadHTMLString(pageHTML, baseURL: nil)
//        case .loadHTMLWithBaseURL(let pageHTML, let baseURL):
//            webView.loadHTMLString(pageHTML, baseURL: baseURL)
//        case .reload:
//            webView.reload()
//        case .goBack:
//            webView.goBack()
//        case .goForward:
//            webView.goForward()
//        case .go(let item):
//            webView.go(to: item)
//        case .evaluateJS(let command, let callback):
//            webView.evaluateJavaScript(command) { result, error in
//                if let error = error {
//                    callback(.failure(error))
//                } else {
//                    callback(.success(result))
//                }
//            }
//        }
//        //DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {
//        if action != .idle {
//            Task { @MainActor in
//                action = .idle
//            }
//        }
//    }

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
                            print(error.localizedDescription)
                        }
                        return
                    }
                    userContentController.add(ruleList)
                    coordinator.compiledContentRules[contentRules] = ruleList
                }
        }
    }
    
    @MainActor
    func refreshMessageHandlers(context: Context) {
        for messageHandlerName in Self.systemMessageHandlers + messageHandlerNamesToRegister {
            if context.coordinator.registeredMessageHandlerNames.contains(messageHandlerName) { continue }
            userContentController.add(context.coordinator, contentWorld: .page, name: messageHandlerName)
            context.coordinator.registeredMessageHandlerNames.insert(messageHandlerName)
        }
    }
    
    @MainActor
    func updateUserScripts(userContentController: WKUserContentController, coordinator: WebViewCoordinator, forDomain domain: URL?, config: WebViewConfig) {
        var scripts =  config.userScripts
        if let domain = domain?.domainURL.host {
            scripts = scripts.filter { $0.allowedDomains.isEmpty || $0.allowedDomains.contains(domain) }
        } else {
            scripts = scripts.filter { $0.allowedDomains.isEmpty }
        }
        let allScripts = Self.systemScripts + scripts
//        guard allScripts.hashValue != coordinator.lastInstalledScriptsHash else { return }
        userContentController.removeAllUserScripts()
        for script in allScripts {
            userContentController.addUserScript(script.webKitUserScript)
        }
//        coordinator.lastInstalledScriptsHash = allScripts.hashValue
    }
    
    fileprivate static let systemScripts = [
        LocationChangeUserScript().userScript,
        ImageChangeUserScript().userScript,
    ]
    
    fileprivate static var systemMessageHandlers: [String] {
        [
            "swiftUIWebViewLocationChanged",
            "swiftUIWebViewImageUpdated",
            "swiftUIWebViewEPUBJSInitialized",
        ]
    }
}

final class GenericFileURLSchemeHandler: NSObject, WKURLSchemeHandler {
    var ebookTextProcessor: ((String) -> String)? = nil
    
    enum CustomSchemeHandlerError: Error {
        case fileNotFound
    }

    init(ebookTextProcessor: ((String) -> String)? = nil) {
        self.ebookTextProcessor = ebookTextProcessor
        super.init()
    }
    
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        for (scheme, srcName) in [("ebook", "foliate-js")] { // TODO: "pdf"
            guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == scheme else { continue }
            
            if url.path == "/process-text" {
                if urlSchemeTask.request.httpMethod == "POST", let payload = urlSchemeTask.request.httpBody, let text = String(data: payload, encoding: .utf8) {
                    var respText = text
                    if let ebookTextProcessor = ebookTextProcessor {
                        respText = ebookTextProcessor(text)
                    }
                    if let respData = respText.data(using: .utf8) {
                        let resp = HTTPURLResponse(
                            url: url, mimeType: nil, expectedContentLength: respData.count, textEncodingName: "utf-8")
                        urlSchemeTask.didReceive(resp)
                        urlSchemeTask.didReceive(respData)
                        urlSchemeTask.didFinish()
                        return
                    }
                }
            } else if url.pathComponents.starts(with: ["/", "load"]) {
                let loadPath = "/" + url.pathComponents.dropFirst(2).joined(separator: "/")
                
                if let fileUrl = bundleURLFromWebURL(url),
                   let mimeType = mimeType(ofFileAtUrl: fileUrl),
                   let data = try? Data(contentsOf: fileUrl) {
                    // Viewer asset.
                    let response = HTTPURLResponse(
                        url: url,
                        mimeType: mimeType,
                        expectedContentLength: data.count, textEncodingName: nil)
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                    return
                } else if urlSchemeTask.request.value(forHTTPHeaderField: "IS-SWIFTUIWEBVIEW-VIEWER-FILE-REQUEST")?.lowercased() != "true",
                          let viewerHtmlPath = Bundle.module.path(forResource: "\(scheme)-viewer", ofType: "html", inDirectory: srcName), let path = loadPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let mimeType = mimeType(ofFileAtUrl: url) {
                    do {
                        let html = try String(contentsOfFile: viewerHtmlPath)
                        if let data = html.data(using: .utf8) {
                            let response = HTTPURLResponse(
                                url: url,
                                mimeType: mimeType,
                                expectedContentLength: data.count, textEncodingName: nil)
                            urlSchemeTask.didReceive(response)
                            urlSchemeTask.didReceive(data)
                            urlSchemeTask.didFinish()
                            return
                        }
                    } catch { }
                }/* else if url.absoluteString.hasPrefix("\(scheme)-url://"),
                  let remoteURL = URL(string: "https://\(url.absoluteString.dropFirst("\(scheme)-url://".count))"),
                  urlSchemeTask.request.mainDocumentURL == url,
                  let mimeType = mimeType(ofFileAtUrl: remoteURL) {
                  do {
                  let data = try Data(contentsOf: remoteURL)
                  let response = HTTPURLResponse(
                  url: url,
                  mimeType: mimeType,
                  expectedContentLength: data.count, textEncodingName: nil)
                  urlSchemeTask.didReceive(response)
                  urlSchemeTask.didReceive(data)
                  urlSchemeTask.didFinish()
                  } catch { }
                  }*/ else if
                    let path = loadPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                    let fileUrl = URL(string: "file://\(path)"),
                    let currentURL = URL(string: "\(scheme)://\(scheme)/load\(path)"),
                    urlSchemeTask.request.mainDocumentURL == currentURL, // Security check.
                    let mimeType = mimeType(ofFileAtUrl: fileUrl),
                    let data = try? Data(contentsOf: fileUrl) {
                      // User file.
                      let response = HTTPURLResponse(
                        url: url,
                        mimeType: mimeType,
                        expectedContentLength: data.count, textEncodingName: nil)
                      urlSchemeTask.didReceive(response)
                      urlSchemeTask.didReceive(data)
                      urlSchemeTask.didFinish()
                      return
                  }/* else if webView.url?.scheme == scheme, let webURL = webView.url, let epubURL = URL(string: "file://" + webURL.path), let archive = Archive(url: epubURL, accessMode: .read), let entry = archive[String(url.path.dropFirst())] {
                    var data = Data()
                    do {
                    let _ = try archive.extract(entry) { chunk in
                    data.append(chunk)
                    }
                    let mimeType = mimeType(ofFileAtUrl: url)
                    let response = HTTPURLResponse(
                    url: url,
                    mimeType: mimeType,
                    expectedContentLength: data.count, textEncodingName: nil)
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                    } catch { print("Failed to extract: \(error.localizedDescription)") }
                    }*/
            }
        }
        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
    }
    
    private func bundleURLFromWebURL(_ url: URL) -> URL? {
        guard url.path.hasPrefix("/load/viewer-assets/") else { return nil }
        let assetName = url.deletingPathExtension().lastPathComponent
        let assetExtension = url.pathExtension
        let assetDirectory = url.deletingLastPathComponent().path.deletingPrefix("/load/viewer-assets/")
        return Bundle.module.url(forResource: assetName, withExtension: assetExtension, subdirectory: assetDirectory)
//        return Bundle.module.url(
//            forResource: assetName,
//            withExtension: assetExtension,
//            subdirectory: "Resources")
    }

    private func mimeType(ofFileAtUrl url: URL) -> String? {
        return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

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

fileprivate extension String {
    func deletingPrefix(_ prefix: String) -> String {
        guard self.hasPrefix(prefix) else { return self }
        return String(self.dropFirst(prefix.count))
    }
}
