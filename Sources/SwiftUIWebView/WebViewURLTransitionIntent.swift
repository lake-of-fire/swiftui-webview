import Foundation

/// Native provenance for one canonical URL transition in one document binding.
/// It carries no application permission. Supersession is permanent, including
/// A → B → C → B when the deferred URL publications only observe the final B.
public final class WebViewURLTransitionIntent: @unchecked Sendable {
    public let id = UUID()
    public let destinationURL: URL
    public let javaScriptBindingToken: WebViewScriptCaller.JavaScriptBindingToken
    /// Baseline document observations carry provenance without requesting a
    /// successor selection. True transitions must keep their exact handoff.
    public let representsURLChange: Bool
    private let lock = NSLock()
    private var current = true

    internal init(destinationURL: URL,
                  javaScriptBindingToken: WebViewScriptCaller.JavaScriptBindingToken,
                  representsURLChange: Bool = true) {
        self.destinationURL = destinationURL
        self.javaScriptBindingToken = javaScriptBindingToken
        self.representsURLChange = representsURLChange
    }

    public var isCurrent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    internal func withdraw() {
        lock.lock()
        defer { lock.unlock() }
        current = false
    }
}

/// KVO records transitions synchronously before hopping to the main actor.
/// Script receipt reconciles the native WKWebView URL through this same owner,
/// so neither path depends on the order in which their actor tasks execute.
internal final class WebViewURLPublicationReceiptSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence: UInt64 = 0
    struct Receipt {
        let sequence: UInt64
        let intent: WebViewURLTransitionIntent?
    }
    private var webViewID: ObjectIdentifier?
    private var binding: WebViewScriptCaller.JavaScriptBindingToken?
    private var intent: WebViewURLTransitionIntent?

    static func canonicalURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    func configure(webViewID: ObjectIdentifier,
                   binding: WebViewScriptCaller.JavaScriptBindingToken?,
                   url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        guard self.webViewID != webViewID || self.binding != binding else { return }
        intent?.withdraw()
        self.webViewID = webViewID
        self.binding = binding
        intent = nil
        if let binding, let url {
            intent = WebViewURLTransitionIntent(destinationURL: Self.canonicalURL(url),
                                               javaScriptBindingToken: binding, representsURLChange: false)
        }
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        intent?.withdraw()
        intent = nil
        webViewID = nil
        binding = nil
    }

    func observe(_ url: URL, from sourceID: ObjectIdentifier) -> Receipt {
        lock.lock()
        defer { lock.unlock() }
        nextSequence &+= 1
        guard webViewID == sourceID, let binding else { return Receipt(sequence: nextSequence, intent: nil) }
        let destination = Self.canonicalURL(url)
        if let intent, intent.destinationURL == destination {
            return Receipt(sequence: nextSequence, intent: intent)
        }
        let isChange = intent != nil
        intent?.withdraw()
        let next = WebViewURLTransitionIntent(destinationURL: destination,
            javaScriptBindingToken: binding, representsURLChange: isChange)
        intent = next
        return Receipt(sequence: nextSequence, intent: next)
    }
}
