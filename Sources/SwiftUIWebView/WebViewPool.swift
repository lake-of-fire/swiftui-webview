import Foundation
import WebKit

#if os(iOS)
import UIKit
#endif

public struct WebViewPoolContentID: Equatable, Hashable, Sendable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

@MainActor
public final class WebViewPrewarmer: ObservableObject {
    public let pool: WebViewPool

    public init(
        warmUpCount: Int = 0,
        keepAliveCount: Int = 0,
        defaultResetURL: URL? = nil,
        debugLabel: String? = nil
    ) {
        pool = WebViewPool(
            warmUpCount: warmUpCount,
            keepAliveCount: keepAliveCount
        )
        pool.defaultResetURL = defaultResetURL
        pool.debugLabel = debugLabel
    }
}

@MainActor
public final class WebViewPool: ObservableObject {
    private struct RetainedWebView {
        var webView: EnhancedWKWebView
        var contentID: WebViewPoolContentID?
    }
    public var warmUpCount: Int {
        didSet {
            if configuredTotalCountTarget == nil {
                prepareIfPossible()
            } else {
                rebalanceRetainedObjects()
            }
        }
    }

    public var keepAliveCount: Int {
        didSet {
            if configuredTotalCountTarget == nil {
                prepareIfPossible()
            } else {
                rebalanceRetainedObjects()
            }
        }
    }

    private var configuredTotalCountTarget: Int?

    /// Opts into a total pool size that includes both retained and currently leased web views.
    /// Set this to `nil` to use the legacy `warmUpCount + keepAliveCount` retained-view target.
    public var totalCountTarget: Int? {
        get { configuredTotalCountTarget }
        set {
            configuredTotalCountTarget = newValue.map { max(0, $0) }
            rebalanceRetainedObjects()
        }
    }

    public var onEnqueue: ((EnhancedWKWebView) -> Void)?
    public var onDequeue: ((EnhancedWKWebView) -> Void)?
    public var defaultResetURL: URL?
    public var debugLabel: String?

    private var warmedUpObjects: [RetainedWebView] = []
    private var leasedObjectIdentifiers = Set<ObjectIdentifier>()
    private var creationClosure: (() -> EnhancedWKWebView)?

    private var targetRetainedCount: Int {
        if let configuredTotalCountTarget {
            return max(0, configuredTotalCountTarget - leasedObjectIdentifiers.count)
        }
        return max(0, warmUpCount) + max(0, keepAliveCount)
    }

    public var retainedCount: Int {
        warmedUpObjects.count
    }

    public var leasedCount: Int {
        leasedObjectIdentifiers.count
    }

    public var totalCount: Int {
        retainedCount + leasedCount
    }

    public init(warmUpCount: Int = 0, keepAliveCount: Int = 0) {
        self.warmUpCount = warmUpCount
        self.keepAliveCount = keepAliveCount
#if os(iOS)
        onEnqueue = { WarmWebViewShelf.shared.add($0) }
        onDequeue = { WarmWebViewShelf.shared.remove($0) }
#endif
    }

    deinit {
        MainActor.assumeIsolated {
            for retained in warmedUpObjects {
                onDequeue?(retained.webView)
                retained.webView.resetForReuse(resetURL: nil)
            }
            warmedUpObjects.removeAll()
        }
    }

    public func setCreationClosureIfNeeded(_ closure: @escaping () -> EnhancedWKWebView) {
        if creationClosure == nil {
            creationClosure = closure
            log(event: "creationClosure.set")
            prepareIfPossible()
        } else {
            log(event: "creationClosure.unchanged")
        }
    }

    public func prepareIfPossible() {
        guard let creationClosure else {
            log(event: "prepare.skip.noCreationClosure")
            return
        }
        log(event: "prepare.begin")
        while warmedUpObjects.count < targetRetainedCount {
            let webView = creationClosure()
            webView.warmUpIfNeeded(resetURL: defaultResetURL)
            warmedUpObjects.append(RetainedWebView(webView: webView, contentID: nil))
            onEnqueue?(webView)
            log(
                event: "prepare.created",
                extra: ["webView": webViewIdentifier(webView)]
            )
        }
        log(event: "prepare.end")
    }

    private func rebalanceRetainedObjects() {
        while warmedUpObjects.count > targetRetainedCount {
            let retained = warmedUpObjects.removeLast()
            let webView = retained.webView
            onDequeue?(webView)
            webView.resetForReuse(resetURL: defaultResetURL)
            log(
                event: "trim.released",
                extra: ["webView": webViewIdentifier(webView)]
            )
        }
        prepareIfPossible()
    }

#if os(iOS)
    public func attachWarmShelfIfNeeded(to window: UIWindow?) {
        WarmWebViewShelf.shared.attach(to: window)
        prepareIfPossible()
    }
#endif

    public func dequeue(createIfNeeded: @escaping () -> EnhancedWKWebView) -> EnhancedWKWebView {
        dequeue(preferredContentID: nil, createIfNeeded: createIfNeeded)
    }

    public func dequeue(
        preferredContentID: WebViewPoolContentID?,
        createIfNeeded: @escaping () -> EnhancedWKWebView
    ) -> EnhancedWKWebView {
        if creationClosure == nil {
            creationClosure = createIfNeeded
            log(event: "dequeue.creationClosure.set")
        }
        prepareIfPossible()
        let webView: EnhancedWKWebView
        let source: String
        if let preferredContentID,
           let exactIndex = warmedUpObjects.firstIndex(where: { $0.contentID == preferredContentID }) {
            webView = warmedUpObjects.remove(at: exactIndex).webView
            source = "warmed.exactContent"
        } else if let warmed = warmedUpObjects.first {
            warmedUpObjects.removeFirst()
            webView = warmed.webView
            source = "warmed"
        } else {
            webView = (creationClosure ?? createIfNeeded)()
            webView.warmUpIfNeeded(resetURL: defaultResetURL)
            source = "new"
        }
        leasedObjectIdentifiers.insert(ObjectIdentifier(webView))
        onDequeue?(webView)
        webView.isHidden = false
        log(
            event: "dequeue",
            extra: [
                "source": source,
                "webView": webViewIdentifier(webView)
            ]
        )
        return webView
    }

    public func enqueue(_ webView: EnhancedWKWebView, resetURL: URL? = nil) {
        let effectiveResetURL = resetURL ?? defaultResetURL
        let webViewID = ObjectIdentifier(webView)
        leasedObjectIdentifiers.remove(webViewID)
        guard !warmedUpObjects.contains(where: { $0.webView === webView }) else {
            log(event: "enqueue.skip.duplicate", extra: ["webView": String(describing: webViewID)])
            return
        }
        if warmedUpObjects.count < targetRetainedCount {
            webView.resetForReuse(resetURL: effectiveResetURL)
            let contentID = effectiveResetURL == nil ? webView.poolReadyContentID : nil
            warmedUpObjects.append(RetainedWebView(webView: webView, contentID: contentID))
            onEnqueue?(webView)
            log(
                event: "enqueue.retained",
                extra: ["webView": webViewIdentifier(webView)]
            )
        } else {
            webView.resetForReuse(resetURL: effectiveResetURL)
            log(
                event: "enqueue.dropped",
                extra: ["webView": webViewIdentifier(webView)]
            )
        }
    }

    public func removeAll(resetURL: URL? = nil) {
        let effectiveResetURL = resetURL ?? defaultResetURL
        for retained in warmedUpObjects {
            onDequeue?(retained.webView)
            retained.webView.resetForReuse(resetURL: effectiveResetURL)
        }
        warmedUpObjects.removeAll()
        log(event: "removeAll")
    }

    private func log(event: String, extra: [String: Any] = [:]) {
#if DEBUG
        guard let debugLabel else { return }
        var payload: [String: Any] = [
            "label": debugLabel,
            "pool": poolIdentifier,
            "targetRetained": targetRetainedCount,
            "targetTotal": configuredTotalCountTarget as Any,
            "warmUpCount": warmUpCount,
            "keepAliveCount": keepAliveCount,
            "warmedCount": warmedUpObjects.count,
            "leasedCount": leasedObjectIdentifiers.count
        ]
        for (key, value) in extra {
            payload[key] = value
        }
        debugPrint("# LOOKUPPREWARM \(event)", payload)
#endif
    }

    private var poolIdentifier: String {
        String(describing: ObjectIdentifier(self))
    }

    private func webViewIdentifier(_ webView: EnhancedWKWebView) -> String {
        String(describing: ObjectIdentifier(webView))
    }
}

private extension EnhancedWKWebView {
    func resetForReuse(resetURL: URL?) {
        stopLoading()
        poolPendingContentID = nil
        if let resetURL {
            poolReadyContentID = nil
            load(URLRequest(url: resetURL))
        }
    }

    func warmUpIfNeeded(resetURL: URL?) {
        if let resetURL {
            load(URLRequest(url: resetURL))
        }
    }
}

#if os(iOS)
@MainActor
final class WarmWebViewShelf {
    static let shared = WarmWebViewShelf()
    private(set) var hostView: UIView = {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }()

    private init() {}

    func attach(to window: UIWindow?) {
        guard let window else { return }
        if hostView.superview == nil {
            window.addSubview(hostView)
            hostView.frame = CGRect(x: -1000, y: -1000, width: 1, height: 1)
        }
    }

    func add(_ webView: WKWebView) {
        guard webView.superview !== hostView else { return }
        hostView.addSubview(webView)
        webView.isHidden = true
        webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    func remove(_ webView: WKWebView) {
        if webView.superview === hostView {
            webView.removeFromSuperview()
        }
        webView.isHidden = false
    }
}
#endif
