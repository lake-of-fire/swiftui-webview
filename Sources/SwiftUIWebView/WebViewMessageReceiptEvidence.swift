import Foundation

/// Native receipt metadata, captured before scheduling or trusted-action deferral.
public struct WebViewMessageReceipt: Sendable {
    public let name: String
    public let mainDocumentURL: URL?
    public let requestURL: URL?

    public init(name: String, mainDocumentURL: URL?, requestURL: URL?) {
        self.name = name
        self.mainDocumentURL = mainDocumentURL
        self.requestURL = requestURL
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
/// installing handlers. Providers are application-wide, not per-document state;
/// the result is captured afresh at each native receipt and cannot be replaced
/// while that message waits. No application/Realm dependency lives here.
@MainActor
public enum WebViewMessageReceiptCapture {
    public typealias Provider = @MainActor @Sendable (WebViewMessageReceipt) -> (any Sendable)?
    private static var providers: [String: Provider] = [:]

    public static func register(key: String, provider: @escaping Provider) {
        precondition(providers[key] == nil, "Receipt evidence provider must be installed once: \(key)")
        providers[key] = provider
    }

    public static func capture(_ receipt: WebViewMessageReceipt) -> WebViewMessageReceiptEvidence {
        let snapshot = providers.sorted { $0.key < $1.key }
        var values: [String: any Sendable] = [:]
        for (key, provider) in snapshot {
            if let value = provider(receipt) { values[key] = value }
        }
        return WebViewMessageReceiptEvidence(values: values)
    }
}
