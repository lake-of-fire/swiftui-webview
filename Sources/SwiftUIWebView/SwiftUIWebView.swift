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
    public internal(set) var pageURL: URL
    public internal(set) var pageTitle: String?
    public internal(set) var pageHTML: String?
    public internal(set) var error: Error?
    public internal(set) var canGoBack: Bool
    public internal(set) var canGoForward: Bool
    
    public static let empty = WebViewState(isLoading: false,
                                           pageURL: URL(string: "about:blank")!,
                                           pageTitle: nil,
                                           pageHTML: nil,
                                           error: nil,
                                           canGoBack: false,
                                           canGoForward: false)
    
    public static func == (lhs: WebViewState, rhs: WebViewState) -> Bool {
        lhs.isLoading == rhs.isLoading
            && lhs.pageURL == rhs.pageURL
            && lhs.pageTitle == rhs.pageTitle
            && lhs.pageHTML == rhs.pageHTML
            && lhs.error?.localizedDescription == rhs.error?.localizedDescription
            && lhs.canGoBack == rhs.canGoBack
            && lhs.canGoForward == rhs.canGoForward
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

public class WebViewCoordinator: NSObject {
    private let webView: WebView
    var actionInProgress = false
    
    var scriptCaller: WebViewScriptCaller?
    var registeredMessageHandlerNames = Set<String>()

    var messageHandlerNames: [String] {
        webView.messageHandlers.keys.map { $0 }
    }
    
    init(webView: WebView, scriptCaller: WebViewScriptCaller? = nil) {
        self.webView = webView
        self.scriptCaller = scriptCaller
    }
    
    func setLoading(_ isLoading: Bool,
                    canGoBack: Bool? = nil,
                    canGoForward: Bool? = nil,
                    error: Error? = nil) {
        var newState = webView.state
        newState.isLoading = isLoading
        if let canGoBack = canGoBack {
            newState.canGoBack = canGoBack
        }
        if let canGoForward = canGoForward {
            newState.canGoForward = canGoForward
        }
        if let error = error {
            newState.error = error
        }
        webView.state = newState
        webView.action = .idle
        actionInProgress = false
    }
}

extension WebViewCoordinator: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "swiftUIWebViewLocationChanged" {
            webView.needsHistoryRefresh = true
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
        setLoading(false,
                 canGoBack: webView.canGoBack,
                 canGoForward: webView.canGoForward)
        
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
        setLoading(false)
    }
    
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        setLoading(false, error: error)
    }
    
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        setLoading(true)
    }
    
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      setLoading(true,
                 canGoBack: webView.canGoBack,
                 canGoForward: webView.canGoForward)
    }
    
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let host = navigationAction.request.url?.host {
            if self.webView.restrictedPages?.first(where: { host.contains($0) }) != nil {
                decisionHandler(.cancel)
                setLoading(false)
                return
            }
        }
        if let url = navigationAction.request.url,
           let scheme = url.scheme,
           let schemeHandler = self.webView.schemeHandlers[scheme] {
            schemeHandler(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

public class WebViewScriptCaller {
    let uuid = UUID().uuidString
    var caller: ((String, ((Any?, Error?) -> Void)?) -> Void)? = nil
    
    @MainActor public func evaluateJavaScript(_ js: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        guard let caller = caller else {
            print("No caller set for WebViewScriptCaller \(uuid)") // TODO: Error
            return
        }
        caller(js, completionHandler)
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
    public let userScripts: [WKUserScript]
    
    public init(javaScriptEnabled: Bool = true,
                allowsBackForwardNavigationGestures: Bool = true,
                allowsInlineMediaPlayback: Bool = true,
                mediaTypesRequiringUserActionForPlayback: WKAudiovisualMediaTypes = [],
                dataDetectorsEnabled: Bool = true,
                isScrollEnabled: Bool = true,
                isOpaque: Bool = true,
                backgroundColor: Color = .clear,
                userScripts: [WKUserScript] = []) {
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

#if os(iOS)
public struct WebView: UIViewRepresentable {
    private let config: WebViewConfig
    @Binding var action: WebViewAction
    @Binding var state: WebViewState
    var scriptCaller: WebViewScriptCaller?
    let restrictedPages: [String]?
    let htmlInState: Bool
    let schemeHandlers: [String: (URL) -> Void]
    var messageHandlers: [String: ((WebViewMessage) async -> Void)] = [:]
    @State private var messageHandlerNamesToRegister = Set<String>()
    private var userContentController = WKUserContentController()
    @State fileprivate var needsHistoryRefresh = false
    
    public init(config: WebViewConfig = .default,
                action: Binding<WebViewAction>,
                state: Binding<WebViewState>,
                scriptCaller: WebViewScriptCaller? = nil,
                restrictedPages: [String]? = nil,
                htmlInState: Bool = false,
                schemeHandlers: [String: (URL) -> Void] = [:]) {
        self.config = config
        _action = action
        _state = state
        self.scriptCaller = scriptCaller
        self.restrictedPages = restrictedPages
        self.htmlInState = htmlInState
        self.schemeHandlers = schemeHandlers
    }
    
    fileprivate func setupScripts(webView: WKWebView) {
        webView.configuration.userContentController.addUserScript(LocationChangeUserScript().userScript)
        webView.configuration.userContentController.add(context.coordinator, contentWorld: .page, name: "swiftUIWebViewLocationChanged")
        for userScript in userScripts {
            webView.configuration.userContentController.addUserScript(userScript)
        }
    }
    
    public func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(webView: self, scriptCaller: scriptCaller)
    }
    
    public func makeUIView(context: Context) -> WKWebView {
        let preferences = WKPreferences()
        preferences.javaScriptEnabled = config.javaScriptEnabled
                
        // See: https://stackoverflow.com/questions/25200116/how-to-show-the-inspector-within-your-wkwebview-based-desktop-app
        preferences.setValue(true, forKey: "developerExtrasEnabled")

        
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = config.allowsInlineMediaPlayback
        configuration.mediaTypesRequiringUserActionForPlayback = config.mediaTypesRequiringUserActionForPlayback
        configuration.dataDetectorTypes = [.all]
        configuration.preferences = preferences

        for userScript in config.userScripts {
            userContentController.addUserScript(userScript)
        }
        for messageHandlerName in messageHandlerNamesToRegister {
            if context.coordinator.registeredMessageHandlerNames.contains(messageHandlerName) { continue }
            userContentController.add(context.coordinator, contentWorld: .page, name: messageHandlerName)
            context.coordinator.registeredMessageHandlerNames.insert(messageHandlerName)
        }
        configuration.userContentController = userContentController
        
        let webView = WKWebView(frame: CGRect.zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = config.allowsBackForwardNavigationGestures
        webView.scrollView.isScrollEnabled = config.isScrollEnabled
        webView.isOpaque = config.isOpaque
        if #available(iOS 14.0, *) {
            webView.backgroundColor = UIColor(config.backgroundColor)
        } else {
            webView.backgroundColor = .clear
        }
                
        if context.coordinator.scriptCaller == nil, let scriptCaller = scriptCaller {
            context.coordinator.scriptCaller = scriptCaller
        }
        context.coordinator.scriptCaller?.caller = { webView.evaluateJavaScript($0, completionHandler: $1) }
        
        return webView
    }
    
    public func updateUIView(_ uiView: WKWebView, context: Context) {
        for messageHandlerName in messageHandlerNamesToRegister {
            userContentController.add(context.coordinator, contentWorld: .page, name: messageHandlerName)
        }
        messageHandlerNamesToRegister.removeAll()
        
        if needsHistoryRefresh {
            var newState = state
            newState.isLoading = state.isLoading
            newState.canGoBack = uiView.canGoBack
            newState.canGoForward = uiView.canGoForward
            state = newState
            needsHistoryRefresh = false
        }
        
//        if context.coordinator.scriptCaller == nil, let scriptCaller = scriptCaller {
//            context.coordinator.scriptCaller = scriptCaller
//        }
//        context.coordinator.scriptCaller?.caller = { webView.evaluateJavaScript($0, completionHandler: $1) }
        
        if action != .idle && !context.coordinator.actionInProgress {
            context.coordinator.actionInProgress = true
            switch action {
            case .idle:
                break
            case .load(let request):
                uiView.load(request)
            case .loadHTML(let pageHTML):
                uiView.loadHTMLString(pageHTML)
            case .loadHTMLWithBaseURL(let pageHTML, let baseURL):
                uiView.loadHTMLString(pageHTML, baseURL: baseURL)
            case .reload:
                uiView.reload()
            case .goBack:
                uiView.goBack()
            case .goForward:
                uiView.goForward()
            case .evaluateJS(let command, let callback):
                uiView.evaluateJavaScript(command) { result, error in
                    if let error = error {
                        callback(.failure(error))
                    } else {
                        callback(.success(result))
                    }
                }
            }
        }
    }
    
    public func onMessageReceived(forName name: String, perform: ((WebViewMessage) -> Void)?) -> WebView {
        var copy = self
        if var handlers = copy.messageHandlers[name], let perform = perform {
            handlers.append(perform)
        } else if let perform = perform {
            copy.messageHandlerNamesToRegister.insert(name)
            copy.messageHandlers[name] = [perform]
        }
        return copy
    }
    
    public static func dismantleUIView(_ uiView: WKWebView, coordinator: WebViewCoordinator) {
        for messageHandlerName in coordinator.messageHandlerNames {
            uiView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
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
    let schemeHandlers: [String: (URL) -> Void]
    var messageHandlers: [String: ((WebViewMessage) async -> Void)] = [:]
    private var messageHandlerNamesToRegister = Set<String>()
    private var userContentController = WKUserContentController()
    @State fileprivate var needsHistoryRefresh = false
    
    public init(config: WebViewConfig = .default,
                action: Binding<WebViewAction>,
                state: Binding<WebViewState>,
                scriptCaller: WebViewScriptCaller? = nil,
                restrictedPages: [String]? = nil,
                htmlInState: Bool = false,
                schemeHandlers: [String: (URL) -> Void] = [:]) {
        self.config = config
        _action = action
        _state = state
        self.scriptCaller = scriptCaller
        self.restrictedPages = restrictedPages
        self.htmlInState = htmlInState
        self.schemeHandlers = schemeHandlers
    }
    
    public func makeCoordinator() -> WebViewCoordinator {
        return WebViewCoordinator(webView: self, scriptCaller: scriptCaller)
    }
    
    public func makeNSView(context: Context) -> WKWebView {
        let preferences = WKPreferences()
        preferences.javaScriptEnabled = config.javaScriptEnabled
        
        // See: https://stackoverflow.com/questions/25200116/how-to-show-the-inspector-within-your-wkwebview-based-desktop-app
        preferences.setValue(true, forKey: "developerExtrasEnabled")

        
        let configuration = WKWebViewConfiguration()
        configuration.preferences = preferences
        
        userContentController.addUserScript(LocationChangeUserScript().userScript)
        userContentController.add(context.coordinator, contentWorld: .page, name: "swiftUIWebViewLocationChanged")
        for userScript in config.userScripts {
            userContentController.addUserScript(userScript)
        }
        for messageHandlerName in messageHandlerNamesToRegister {
            if context.coordinator.registeredMessageHandlerNames.contains(messageHandlerName) { continue }
            userContentController.add(context.coordinator, contentWorld: .page, name: messageHandlerName)
            context.coordinator.registeredMessageHandlerNames.insert(messageHandlerName)
        }
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: CGRect.zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = config.allowsBackForwardNavigationGestures
        
        if context.coordinator.scriptCaller == nil, let scriptCaller = scriptCaller {
            context.coordinator.scriptCaller = scriptCaller
        }
        context.coordinator.scriptCaller?.caller = { webView.evaluateJavaScript($0, completionHandler: $1) }
        
        return webView
    }

    public func updateNSView(_ uiView: WKWebView, context: Context) {
        for messageHandlerName in messageHandlerNamesToRegister {
            if context.coordinator.registeredMessageHandlerNames.contains(messageHandlerName) { continue }
            userContentController.add(context.coordinator, contentWorld: .page, name: messageHandlerName)
            context.coordinator.registeredMessageHandlerNames.insert(messageHandlerName)
        }
        
        if needsHistoryRefresh {
            var newState = state
            newState.isLoading = state.isLoading
            newState.canGoBack = uiView.canGoBack
            newState.canGoForward = uiView.canGoForward
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                state = newState
                needsHistoryRefresh = false
            }
        }
        
//        if context.coordinator.scriptCaller == nil, let scriptCaller = scriptCaller {
//            context.coordinator.scriptCaller = scriptCaller
//        }
//        context.coordinator.scriptCaller?.caller = { uiView.evaluateJavaScript($0, completionHandler: $1) }
        
        if action != .idle {
            switch action {
            case .idle:
                break
            case .load(let request):
                uiView.load(request)
            case .loadHTML(let html):
                uiView.loadHTMLString(html, baseURL: nil)
            case .loadHTMLWithBaseURL(let html, let baseURL):
                uiView.loadHTMLString(html, baseURL: baseURL)
            case .reload:
                uiView.reload()
            case .goBack:
                uiView.goBack()
            case .goForward:
                uiView.goForward()
            case .evaluateJS(let command, let callback):
                uiView.evaluateJavaScript(command) { result, error in
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
    
    public func onMessageReceived(forName name: String, perform: @escaping ((WebViewMessage) async -> Void)) -> WebView {
        var copy = self
        copy.messageHandlerNamesToRegister.insert(name)
        copy.messageHandlers[name] = perform
        return copy
    }
    
    public static func dismantleNSView(_ nsView: WKWebView, coordinator: WebViewCoordinator) {
        for messageHandlerName in coordinator.messageHandlerNames {
            nsView.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
        }
    }
}
#endif

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
