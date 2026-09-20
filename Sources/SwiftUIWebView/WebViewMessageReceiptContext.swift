import Foundation

/// Native receipt facts only. Page-provided payload fields are not admission evidence.
public struct WebViewMessageReceipt: Sendable {
    public let name: String
    public let requestURL: URL?
    public let mainDocumentURL: URL?

    public init(name: String, requestURL: URL?, mainDocumentURL: URL?) {
        self.name = name
        self.requestURL = requestURL
        self.mainDocumentURL = mainDocumentURL
    }
}

/// Immutable, namespaced values captured before asynchronous message dispatch.
public struct WebViewMessageReceiptContext: Sendable {
    public static let empty = Self(values: [:])
    fileprivate let values: [String: any Sendable]

    public func value<Value: Sendable>(for namespace: String, as type: Value.Type) -> Value? {
        values[namespace] as? Value
    }
}

/// Application adapters register stateless capture functions at handler construction.
/// Registrations cannot replace an existing namespace. Capture functions must not
/// retain a WebView owner and must be synchronous; final transaction validation
/// remains the application's responsibility.
@MainActor
public final class WebViewMessageReceiptCaptureRegistry {
    public static let shared = WebViewMessageReceiptCaptureRegistry()
    public typealias Capture = @MainActor @Sendable (WebViewMessageReceipt) -> (any Sendable)?

    private struct Registration {
        let messageNames: Set<String>
        let capture: Capture
    }
    private var registrations: [String: Registration] = [:]

    public init() {}

    @discardableResult
    public func register(namespace: String, messageNames: Set<String>, capture: @escaping Capture) -> Bool {
        guard !namespace.isEmpty, !messageNames.isEmpty, registrations[namespace] == nil else { return false }
        registrations[namespace] = Registration(messageNames: messageNames, capture: capture)
        return true
    }

    public func capture(_ receipt: WebViewMessageReceipt) -> WebViewMessageReceiptContext {
        var values: [String: any Sendable] = [:]
        for (namespace, registration) in registrations where registration.messageNames.contains(receipt.name) {
            if let value = registration.capture(receipt) {
                values[namespace] = value
            }
        }
        return WebViewMessageReceiptContext(values: values)
    }
}
