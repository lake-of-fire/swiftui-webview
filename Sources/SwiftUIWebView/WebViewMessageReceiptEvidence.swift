import Foundation

/// Native receipt metadata, captured before scheduling or trusted-action deferral.
public struct WebViewMessageReceipt: Sendable {
    public let name: String
    public let mainDocumentURL: URL?
    public let requestURL: URL?
    /// Current URL of the owning native WebView, sampled at receipt. Unlike a
    /// frame request, this follows same-document history changes immediately.
    public let nativeDocumentURL: URL?
    /// Exact native caller/document binding sampled before invoking any app
    /// provider. Two views or two successive documents may have the same URL.
    /// Nil means no caller binding was available; consumers must not invent one
    /// later. This identifies the receipt owner, not permission to mutate data.
    public let javaScriptBindingToken: WebViewScriptCaller.JavaScriptBindingToken?
    /// Untrusted negative evidence copied from the raw message at native receipt.
    /// A reported restoration may withdraw an application's opening intent.
    /// False never proves a fresh visit or grants permission to create data.
    public let reportsBFCacheRestoration: Bool
    /// Native WebKit frame identity at receipt, independent of page payload.
    /// A child-frame restoration hint does not identify a restored main visit.
    public let isMainFrame: Bool
    public let urlTransitionIntent: WebViewURLTransitionIntent?

    public init(
        name: String,
        mainDocumentURL: URL?,
        requestURL: URL?,
        nativeDocumentURL: URL? = nil,
        javaScriptBindingToken: WebViewScriptCaller.JavaScriptBindingToken? = nil,
        reportsBFCacheRestoration: Bool = false,
        isMainFrame: Bool = false,
        urlTransitionIntent: WebViewURLTransitionIntent? = nil
    ) {
        self.name = name
        self.mainDocumentURL = mainDocumentURL
        self.requestURL = requestURL
        self.nativeDocumentURL = nativeDocumentURL
        self.javaScriptBindingToken = javaScriptBindingToken
        self.reportsBFCacheRestoration = reportsBFCacheRestoration
        self.isMainFrame = isMainFrame
        self.urlTransitionIntent = urlTransitionIntent
    }
}

/// Immutable app-owned values. The framework transports, but never authorizes,
/// these values. An application must validate its evidence at its final write.
public struct WebViewMessageReceiptEvidence: Sendable {
    private let values: [String: any Sendable]

    public init(values: [String: any Sendable]) { self.values = values }

    public func value<Value: Sendable>(for key: String, as type: Value.Type = Value.self) -> Value? {
        values[key] as? Value
    }
}

public enum WebViewMessageReceiptContext {
    @TaskLocal public static var evidence: WebViewMessageReceiptEvidence?
}

/// Configure named application evidence providers on the main actor before
/// installing handlers. Registered providers are fixed application-wide facts;
/// owner-specific providers belong to WebViewMessageHandlers instead. Results
/// are captured afresh at native receipt and cannot be replaced while waiting.
/// No application/Realm dependency lives here.
@MainActor
public enum WebViewMessageReceiptCapture {
    public typealias Provider = @MainActor @Sendable (WebViewMessageReceipt) -> (any Sendable)?
    private static var providers: [String: Provider] = [:]

    public static func register(key: String, provider: @escaping Provider) {
        precondition(providers[key] == nil, "Receipt evidence provider must be installed once: \(key)")
        providers[key] = provider
    }

    public static func capture(
        _ receipt: WebViewMessageReceipt,
        scopedProviders: [String: Provider] = [:]
    ) -> WebViewMessageReceiptEvidence {
        // Colliding registrations cannot select an authority by ordering.
        // Snapshot both collections before invoking any reentrant provider.
        let collisions = Set(providers.keys).intersection(scopedProviders.keys)
        let snapshot = providers.merging(scopedProviders) { _, _ in { _ in nil } }
            .filter { !collisions.contains($0.key) }
            .sorted { $0.key < $1.key }
        var values: [String: any Sendable] = [:]
        for (key, provider) in snapshot {
            if let value = provider(receipt) { values[key] = value }
        }
        return WebViewMessageReceiptEvidence(values: values)
    }
}
