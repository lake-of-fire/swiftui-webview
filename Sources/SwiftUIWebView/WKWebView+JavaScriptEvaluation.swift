import WebKit

extension WKWebView {
    /// Calls WebKit's Objective-C entry point directly. SDK 27 redirects the Swift
    /// overlay to libswiftWebKit for older deployment targets, but does not ship
    /// that library for embedding into apps running on older simulator runtimes.
    /// Keep frame, content-world, promise settlement, and error semantics in WebKit.
    @MainActor
    public func callAsyncJavaScriptUsingCompletionHandler(
        _ functionBody: String,
        arguments: [String: Any] = [:],
        in frame: WKFrameInfo? = nil,
        contentWorld: WKContentWorld
    ) async throws -> Any? {
        try await __callAsyncJavaScript(
            functionBody,
            arguments: arguments,
            inFrame: frame,
            in: contentWorld
        )
    }
}
