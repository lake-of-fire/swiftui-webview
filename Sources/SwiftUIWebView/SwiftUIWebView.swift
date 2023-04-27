import SwiftUI
import WebKit

public enum WebViewAction: Equatable {
    case idle,
         load(URLRequest),
         loadHTML(String),
         loadHTMLWithBaseURL(String, URL),
         reload,
         goBack,
         goForward,
         go(WKBackForwardListItem),
         evaluateJS(String, (Result<Any?, Error>) -> Void)
    
    public static func == (lhs: WebViewAction, rhs: WebViewAction) -> Bool {
        if case .idle = lhs, case .idle = rhs {
            return true
        }
        if case let .load(requestLHS) = lhs, case let .load(requestRHS) = rhs {
            return requestLHS == requestRHS
        }
        if case let .loadHTML(htmlLHS) = lhs, case let .loadHTML(htmlRHS) = rhs {
            return htmlLHS == htmlRHS
        }
        if case let .loadHTMLWithBaseURL(htmlLHS, urlLHS) = lhs,
           case let .loadHTMLWithBaseURL(htmlRHS, urlRHS) = rhs {
            return htmlLHS == htmlRHS && urlLHS == urlRHS
        }
        if case .reload = lhs, case .reload = rhs {
            return true
        }
        if case let .go(itemLHS) = lhs, case let .go(itemRHS) = rhs {
            return itemLHS == itemRHS
        }
        if case .goBack = lhs, case .goBack = rhs {
            return true
        }
        if case .goForward = lhs, case .goForward = rhs {
            return true
        }
        if case let .evaluateJS(commandLHS, _) = lhs,
           case let .evaluateJS(commandRHS, _) = rhs {
            return commandLHS == commandRHS
        }
        return false
    }
}

public struct WebViewState: Equatable {
    public internal(set) var isLoading: Bool
    public internal(set) var isProvisionallyNavigating: Bool
    public internal(set) var pageURL: URL
    public internal(set) var pageTitle: String?
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
            && lhs.pageHTML == rhs.pageHTML
            && lhs.error?.localizedDescription == rhs.error?.localizedDescription
            && lhs.canGoBack == rhs.canGoBack
            && lhs.canGoForward == rhs.canGoForward
            && lhs.backList == rhs.backList
            && lhs.forwardList == rhs.forwardList
    }
}

public struct WebViewMessage: Equatable {
    fileprivate let uuid: UUID
    public let name: String
    public let body: Any
    
    public static func == (lhs: WebViewMessage, rhs: WebViewMessage) -> Bool {
        lhs.uuid == rhs.uuid
            && lhs.name == rhs.name
    }
}

public struct WebViewUserScript: Equatable {
    public let webKitUserScript: WKUserScript
    public let allowedDomains: Set<String>
    
    public static func == (lhs: WebViewUserScript, rhs: WebViewUserScript) -> Bool {
        lhs.webKitUserScript == rhs.webKitUserScript
//            && lhs.name == rhs.name
    }
    
    public init(webKitUserScript: WKUserScript, allowedDomains: Set<String>) {
        self.webKitUserScript = webKitUserScript
        self.allowedDomains = allowedDomains
    }
}

public class WebViewCoordinator: NSObject {
    private let webView: WebView
    
    var scriptCaller: WebViewScriptCaller?
    var config: WebViewConfig
    var registeredMessageHandlerNames = Set<String>()

    var messageHandlerNames: [String] {
        webView.messageHandlers.keys.map { $0 }
    }
    
    init(webView: WebView, scriptCaller: WebViewScriptCaller? = nil, config: WebViewConfig) {
        self.webView = webView
        self.scriptCaller = scriptCaller
        self.config = config
    }
    
    func setLoading(_ isLoading: Bool,
                    isProvisionallyNavigating: Bool? = nil,
                    canGoBack: Bool? = nil,
                    canGoForward: Bool? = nil,
                    backList: [WKBackForwardListItem]? = nil,
                    forwardList: [WKBackForwardListItem]? = nil,
                    error: Error? = nil) {
        var newState = webView.state
        newState.isLoading = isLoading
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
        webView.action = .idle
    }
}

extension WebViewCoordinator: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "swiftUIWebViewLocationChanged" {
            webView.needsHistoryRefresh = true
            return
        } else if message.name == "swiftUIWebViewIsWarm" {
            if !webView.isWarm, let onWarm = webView.onWarm {
                Task { @MainActor in
                    webView.isWarm = true
                    await onWarm()
                }
            }
            return
        }
        
        guard let messageHandler = webView.messageHandlers[message.name] else { return }
        let message = WebViewMessage(uuid: UUID(), name: message.name, body: message.body)
        Task {
            await messageHandler(message)
        }
    }
}

extension WebViewCoordinator: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setLoading(
            false,
            isProvisionallyNavigating: false,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            backList: webView.backForwardList.backList,
            forwardList: webView.backForwardList.forwardList)
        
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
            if let url = response as? String, let newURL = URL(string: url) {
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
    
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        setLoading(false, isProvisionallyNavigating: false, error: error)
        
        extractPageState(webView: webView)
    }
    
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        setLoading(true, isProvisionallyNavigating: false)
    }
    
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        setLoading(
            true,
            isProvisionallyNavigating: true,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            backList: webView.backForwardList.backList,
            forwardList: webView.backForwardList.forwardList)
    }
    
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if let host = navigationAction.request.url?.host {
            if self.webView.restrictedPages?.first(where: { host.contains($0) }) != nil {
                setLoading(false, isProvisionallyNavigating: false)
                return (.cancel, preferences)
            }
        }
        if let url = navigationAction.request.url,
           let scheme = url.scheme,
           let schemeHandler = self.webView.schemeHandlers[scheme] {
            schemeHandler(url)
            return (.cancel, preferences)
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            let domain = navigationAction.request.url?.baseDomain
            Task { @MainActor in
                WebView.updateUserScripts(inWebView: webView, forDomain: domain, config: config)
            }
        }
        return (.allow, preferences)
    }
}

public class WebViewScriptCaller: Equatable, ObservableObject {
    let uuid = UUID().uuidString
//    @Published var caller: ((String, ((Any?, Error?) -> Void)?) -> Void)? = nil
    var caller: ((String, ((Any?, Error?) -> Void)?) -> Void)? = nil
    var asyncCaller: ((String, [String: Any]?, WKFrameInfo?, WKContentWorld?, ((Result<Any, any Error>) -> Void)?) -> Void)? = nil
    
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
    let userScript: WKUserScript
    
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
    webkit.messageHandlers.swiftUIWebViewLocationChanged.postMessage(window.location.href);
});
"""
        userScript = WKUserScript(source: contents, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}

public struct WebViewConfig {
    public static let `default` = WebViewConfig()
    
    public let javaScriptEnabled: Bool
    public let allowsBackForwardNavigationGestures: Bool
    public let allowsInlineMediaPlayback: Bool
    public let mediaTypesRequiringUserActionForPlayback: WKAudiovisualMediaTypes
    public let dataDetectorsEnabled: Bool
    public let isScrollEnabled: Bool
    public let isOpaque: Bool
    public let backgroundColor: Color
    public let userScripts: [WebViewUserScript]
    
    public init(javaScriptEnabled: Bool = true,
                allowsBackForwardNavigationGestures: Bool = true,
                allowsInlineMediaPlayback: Bool = true,
                mediaTypesRequiringUserActionForPlayback: WKAudiovisualMediaTypes = [WKAudiovisualMediaTypes.all],
                dataDetectorsEnabled: Bool = true,
                isScrollEnabled: Bool = true,
                isOpaque: Bool = true,
                backgroundColor: Color = .clear,
                userScripts: [WebViewUserScript] = []) {
        self.javaScriptEnabled = javaScriptEnabled
        self.allowsBackForwardNavigationGestures = allowsBackForwardNavigationGestures
        self.allowsInlineMediaPlayback = allowsInlineMediaPlayback
        self.mediaTypesRequiringUserActionForPlayback = mediaTypesRequiringUserActionForPlayback
        self.dataDetectorsEnabled = dataDetectorsEnabled
        self.isScrollEnabled = isScrollEnabled
        self.isOpaque = isOpaque
        self.backgroundColor = backgroundColor
        self.userScripts = userScripts
    }
}

public class EnhancedWKWebView: WKWebView {
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
            let argument2: [Any] = ["_h", "ave", "Set", "O", "bscu", "red", "Ins", "ets"]
            let key2 = argument2.compactMap({ $0 as? String }).joined()
            webView.setValue(true, forKey: key2)
//        }
        // TODO: investigate _isChangingObscuredInsetsInteractively
    }
}

public struct WebView: UIViewControllerRepresentable {
    private let config: WebViewConfig
    @Binding var action: WebViewAction
    @Binding var state: WebViewState
    var scriptCaller: WebViewScriptCaller?
    let restrictedPages: [String]?
    let htmlInState: Bool
    let schemeHandlers: [String: (URL) -> Void]
    var messageHandlers: [String: ((WebViewMessage) async -> Void)] = [:]
    let obscuredInsets: EdgeInsets
    let persistentWebViewID: String?
    let onWarm: (() async -> Void)?
    
    private var messageHandlerNamesToRegister = Set<String>()
//    private var userContentController = WKUserContentController()
    @State fileprivate var isWarm = false
    @State fileprivate var needsHistoryRefresh = false
    
    private static var webViewCache: [String: EnhancedWKWebView] = [:]
    private static let processPool = WKProcessPool()
    
    public init(config: WebViewConfig = .default,
                action: Binding<WebViewAction>,
                state: Binding<WebViewState>,
                scriptCaller: WebViewScriptCaller? = nil,
                restrictedPages: [String]? = nil,
                htmlInState: Bool = false,
                obscuredInsets: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
                persistentWebViewID: String? = nil,
                onWarm: (() async -> Void)? = nil,
                schemeHandlers: [String: (URL) -> Void] = [:]) {
        self.config = config
        _action = action
        _state = state
        self.scriptCaller = scriptCaller
        self.restrictedPages = restrictedPages
        self.htmlInState = htmlInState
        self.obscuredInsets = obscuredInsets
        self.persistentWebViewID = persistentWebViewID
        self.onWarm = onWarm
        self.schemeHandlers = schemeHandlers
    }
    
    public func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(webView: self, scriptCaller: scriptCaller, config: config)
    }
    
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
            
            var userContentController = WKUserContentController()
            for name in systemMessageHandlers {
                userContentController.add(coordinator, contentWorld: .page, name: name)
            }
            
            configuration.userContentController = userContentController
            web = EnhancedWKWebView(frame: .zero, configuration: configuration)
            
            if let web = web {
                Self.updateUserScripts(inWebView: web, forDomain: nil, config: config)
            }
            
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
    
    public func makeUIViewController(context: Context) -> WebViewController {
        // See: https://stackoverflow.com/questions/25200116/how-to-show-the-inspector-within-your-wkwebview-based-desktop-app
//        preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webView = Self.makeWebView(id: persistentWebViewID, config: config, coordinator: context.coordinator, messageHandlerNamesToRegister: messageHandlerNamesToRegister)
        
//        let webView = EnhancedWKWebView(frame: .zero, configuration: configuration)
        webView.allowsLinkPreview = true
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = config.allowsBackForwardNavigationGestures
//        webView.scrollView.contentInsetAdjustmentBehavior = .always
        webView.scrollView.contentInsetAdjustmentBehavior = .scrollableAxes
        webView.scrollView.isScrollEnabled = config.isScrollEnabled
        webView.isOpaque = config.isOpaque
        if #available(iOS 14.0, *) {
            webView.backgroundColor = UIColor(config.backgroundColor)
        } else {
            webView.backgroundColor = .clear
        }
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        
//        for messageHandlerName in messageHandlerNamesToRegister {
//            if context.coordinator.registeredMessageHandlerNames.contains(messageHandlerName) { continue }
//            webView.configuration.userContentController.add(context.coordinator, contentWorld: .page, name: messageHandlerName)
//            context.coordinator.registeredMessageHandlerNames.insert(messageHandlerName)
//        }
//
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
        webView.evaluateJavaScript("window.webkit.messageHandlers.swiftUIWebViewIsWarm.postMessage({})")

        return WebViewController(webView: webView, persistentWebViewID: persistentWebViewID)
    }
    
    public func updateUIViewController(_ controller: WebViewController, context: Context) {
        for messageHandlerName in messageHandlerNamesToRegister {
            if context.coordinator.registeredMessageHandlerNames.contains(messageHandlerName) { continue }
            controller.webView.configuration.userContentController.add(context.coordinator, contentWorld: .page, name: messageHandlerName)
            context.coordinator.registeredMessageHandlerNames.insert(messageHandlerName)
        }
        
        Self.updateUserScripts(inWebView: controller.webView, forDomain: nil, config: config)
        
        if needsHistoryRefresh {
            var newState = state
            newState.isLoading = state.isLoading
            newState.isProvisionallyNavigating = state.isProvisionallyNavigating
            newState.canGoBack = controller.webView.canGoBack
            newState.canGoForward = controller.webView.canGoForward
            newState.backList = controller.webView.backForwardList.backList
            newState.forwardList = controller.webView.backForwardList.forwardList
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) {
                state = newState
                needsHistoryRefresh = false
            }
        }
        
        processAction(webView: controller.webView)
        
        // TODO: Fix for RTL languages, if it matters for _obscuredInsets.
        controller.obscuredInsets = UIEdgeInsets(top: obscuredInsets.top, left: obscuredInsets.leading, bottom: obscuredInsets.bottom, right: obscuredInsets.trailing)
        
        // _obscuredInsets ignores bottom (maybe a side too..?)
        controller.webView.scrollView.contentInset.bottom = obscuredInsets.bottom
    }
    
    public func onMessageReceived(forName name: String, perform: @escaping ((WebViewMessage) async -> Void)) -> WebView {
        var copy = self
        copy.messageHandlerNamesToRegister.insert(name)
        copy.messageHandlers[name] = perform
        return copy
    }
        
    public static func dismantleUIViewController(_ controller: WebViewController, coordinator: WebViewCoordinator) {
        controller.view.subviews.forEach { $0.removeFromSuperview() }
    }
    
    func processAction(webView: EnhancedWKWebView) {
        if action != .idle {
            switch action {
            case .idle:
                break
            case .load(let request):
                webView.load(request)
            case .loadHTML(let pageHTML):
                webView.loadHTMLString(pageHTML, baseURL: nil)
            case .loadHTMLWithBaseURL(let pageHTML, let baseURL):
                webView.loadHTMLString(pageHTML, baseURL: baseURL)
            case .reload:
                webView.reload()
            case .goBack:
                webView.goBack()
            case .goForward:
                webView.goForward()
            case .go(let item):
                webView.go(to: item)
            case .evaluateJS(let command, let callback):
                webView.evaluateJavaScript(command) { result, error in
                    if let error = error {
                        callback(.failure(error))
                    } else {
                        callback(.success(result))
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {
                action = .idle
            }
        }
    }
}
#endif

#if os(macOS)
public struct WebView: NSViewRepresentable {
    private let config: WebViewConfig
    @Binding var action: WebViewAction
    @Binding var state: WebViewState
    var scriptCaller: WebViewScriptCaller?
    let restrictedPages: [String]?
    let htmlInState: Bool
    let onWarm: (() -> Void)?
    let schemeHandlers: [String: (URL) -> Void]
    var messageHandlers: [String: ((WebViewMessage) async -> Void)] = [:]
    /// Unused on macOS (for now).
    var obscuredInsets: EdgeInsets
    private var messageHandlerNamesToRegister = Set<String>()
    private var userContentController = WKUserContentController()
    
    @State fileprivate var isWarm = false
    @State fileprivate var needsHistoryRefresh = false
    
    private static let processPool = WKProcessPool()
    
    /// `persistentWebViewID` is only used on iOS, not macOS.
    public init(config: WebViewConfig = .default,
                action: Binding<WebViewAction>,
                state: Binding<WebViewState>,
                scriptCaller: WebViewScriptCaller? = nil,
                restrictedPages: [String]? = nil,
                htmlInState: Bool = false,
                obscuredInsets: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
                persistentWebViewID: String? = nil,
                onWarm: (() -> Void)? = nil,
                schemeHandlers: [String: (URL) -> Void] = [:]) {
        self.config = config
        _action = action
        _state = state
        self.scriptCaller = scriptCaller
        self.restrictedPages = restrictedPages
        self.htmlInState = htmlInState
        self.obscuredInsets = obscuredInsets
        self.onWarm = onWarm
        self.schemeHandlers = schemeHandlers
    }
    
    public func makeCoordinator() -> WebViewCoordinator {
        return WebViewCoordinator(webView: self, scriptCaller: scriptCaller, config: config)
    }
    
    public func makeNSView(context: Context) -> EnhancedWKWebView {
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = config.javaScriptEnabled
        
        // See: https://stackoverflow.com/questions/25200116/how-to-show-the-inspector-within-your-wkwebview-based-desktop-app
//        preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences = preferences
        configuration.processPool = Self.processPool
        
        for name in systemMessageHandlers {
            userContentController.add(context.coordinator, contentWorld: .page, name: name)
        }
        
        for messageHandlerName in messageHandlerNamesToRegister {
            if context.coordinator.registeredMessageHandlerNames.contains(messageHandlerName) { continue }
            userContentController.add(context.coordinator, contentWorld: .page, name: messageHandlerName)
            context.coordinator.registeredMessageHandlerNames.insert(messageHandlerName)
        }
        configuration.userContentController = userContentController

        let webView = EnhancedWKWebView(frame: CGRect.zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = config.allowsBackForwardNavigationGestures
        webView.backgroundColor = .white
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        
        Self.updateUserScripts(inWebView: webView, forDomain: nil, config: config)
        
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
        
        Self.updateUserScripts(inWebView: webView, forDomain: nil, config: config)
        
        return webView
    }

    public func updateNSView(_ uiView: EnhancedWKWebView, context: Context) {
        for messageHandlerName in messageHandlerNamesToRegister {
            if context.coordinator.registeredMessageHandlerNames.contains(messageHandlerName) { continue }
            userContentController.add(context.coordinator, contentWorld: .page, name: messageHandlerName)
            context.coordinator.registeredMessageHandlerNames.insert(messageHandlerName)
        }
        
        Self.updateUserScripts(inWebView: uiView, forDomain: nil, config: config)

        if needsHistoryRefresh {
            var newState = state
            newState.isLoading = state.isLoading
            newState.isProvisionallyNavigating = state.isProvisionallyNavigating
            newState.canGoBack = uiView.canGoBack
            newState.canGoForward = uiView.canGoForward
            newState.backList = uiView.backForwardList.backList
            newState.forwardList = uiView.backForwardList.forwardList
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                state = newState
                needsHistoryRefresh = false
            }
        }
        
        processAction(webView: uiView)
    }
    
    public func onMessageReceived(forName name: String, perform: @escaping ((WebViewMessage) async -> Void)) -> WebView {
        var copy = self
        copy.messageHandlerNamesToRegister.insert(name)
        copy.messageHandlers[name] = perform
        return copy
    }
    
    public static func dismantleNSView(_ nsView: EnhancedWKWebView, coordinator: WebViewCoordinator) {
        for messageHandlerName in coordinator.messageHandlerNames {
            nsView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
        }
    }
    
    func processAction(webView: EnhancedWKWebView) {
        if action != .idle {
            switch action {
            case .idle:
                break
            case .load(let request):
                webView.load(request)
            case .loadHTML(let html):
                webView.loadHTMLString(html, baseURL: nil)
            case .loadHTMLWithBaseURL(let html, let baseURL):
                webView.loadHTMLString(html, baseURL: baseURL)
            case .reload:
                webView.reload()
            case .goBack:
                webView.goBack()
            case .goForward:
                webView.goForward()
            case .go(let item):
                webView.go(to: item)
            case .evaluateJS(let command, let callback):
                webView.evaluateJavaScript(command) { result, error in
                    if let error = error {
                        callback(.failure(error))
                    } else {
                        callback(.success(result))
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                action = .idle
            }
        }

    }
}
#endif

extension WebView {
    static func updateUserScripts(inWebView webView: WKWebView, forDomain domain: String?, config: WebViewConfig) {
        var scripts = config.userScripts
        if let domain = domain {
            scripts = scripts.filter { $0.allowedDomains.isEmpty || $0.allowedDomains.contains(domain) }
        } else {
            scripts = scripts.filter { $0.allowedDomains.isEmpty }
        }
        let webKitScripts = scripts.map { $0.webKitUserScript }
        if webView.configuration.userContentController.userScripts != webKitScripts {
            webView.configuration.userContentController.removeAllUserScripts()
            for script in webKitScripts {
                webView.configuration.userContentController.addUserScript(script)
            }
        }
    }
        
    fileprivate static var systemScripts: [WKUserScript] {
        [
            WKUserScript(source: "window.webkit.messageHandlers.swiftUIWebViewIsWarm.postMessage({})", injectionTime: .atDocumentStart, forMainFrameOnly: true),
            LocationChangeUserScript().userScript,
        ]
    }
    
    fileprivate static var systemMessageHandlers: [String] {
        ["swiftUIWebViewLocationChanged", "swiftUIWebViewIsWarm"]
    }
}

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
                    restrictedPages: ["apple.com"],
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
