import Foundation
import WebKit

#if os(iOS)
import UIKit
#endif

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
    public var warmUpCount: Int {
        didSet { prepareIfPossible() }
    }

    public var keepAliveCount: Int {
        didSet { prepareIfPossible() }
    }

    public var onEnqueue: ((EnhancedWKWebView) -> Void)?
    public var onDequeue: ((EnhancedWKWebView) -> Void)?
    public var defaultResetURL: URL?
    public var debugLabel: String?

    private var warmedUpObjects: [EnhancedWKWebView] = []
    private var creationClosure: (() -> EnhancedWKWebView)?

    private var targetCount: Int { warmUpCount + keepAliveCount }

    public init(warmUpCount: Int = 0, keepAliveCount: Int = 0) {
        self.warmUpCount = warmUpCount
        self.keepAliveCount = keepAliveCount
#if os(iOS)
        onEnqueue = { WarmWebViewShelf.shared.add($0) }
        onDequeue = { WarmWebViewShelf.shared.remove($0) }
#endif
    }

    deinit {
        for webView in warmedUpObjects {
            onDequeue?(webView)
            webView.resetForReuse(resetURL: nil)
        }
        warmedUpObjects.removeAll()
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
        while warmedUpObjects.count < targetCount {
            let webView = creationClosure()
            webView.warmUpIfNeeded(resetURL: defaultResetURL)
            warmedUpObjects.append(webView)
            onEnqueue?(webView)
            log(
                event: "prepare.created",
                extra: ["webView": webViewIdentifier(webView)]
            )
        }
        log(event: "prepare.end")
    }

    public func dequeue(createIfNeeded: @escaping () -> EnhancedWKWebView) -> EnhancedWKWebView {
        if creationClosure == nil {
            creationClosure = createIfNeeded
            log(event: "dequeue.creationClosure.set")
        }
        prepareIfPossible()
        let webView: EnhancedWKWebView
        let source: String
        if let warmed = warmedUpObjects.first {
            warmedUpObjects.removeFirst()
            webView = warmed
            source = "warmed"
        } else {
            webView = (creationClosure ?? createIfNeeded)()
            webView.warmUpIfNeeded(resetURL: defaultResetURL)
            source = "new"
        }
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
        if warmedUpObjects.count < targetCount {
            webView.resetForReuse(resetURL: effectiveResetURL)
            warmedUpObjects.append(webView)
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

    private func log(event: String, extra: [String: Any] = [:]) {
        guard let debugLabel else { return }
        var payload: [String: Any] = [
            "label": debugLabel,
            "pool": poolIdentifier,
            "target": targetCount,
            "warmUpCount": warmUpCount,
            "keepAliveCount": keepAliveCount,
            "warmedCount": warmedUpObjects.count
        ]
        for (key, value) in extra {
            payload[key] = value
        }
        debugPrint("# LOOKUPPREWARM \(event)", payload)
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
        if let resetURL {
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
