import Foundation
import WebKit

#if os(iOS)
import UIKit
#endif

private let webViewPoolBlankURL = URL(string: "about:blank")

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

    public func setCreationClosureIfNeeded(_ closure: @escaping () -> EnhancedWKWebView) {
        if creationClosure == nil {
            creationClosure = closure
            prepareIfPossible()
        }
    }

    public func prepareIfPossible() {
        guard let creationClosure else { return }
        while warmedUpObjects.count < targetCount {
            let webView = creationClosure()
            webView.warmUpIfNeeded()
            warmedUpObjects.append(webView)
            onEnqueue?(webView)
        }
    }

    public func dequeue(createIfNeeded: @escaping () -> EnhancedWKWebView) -> EnhancedWKWebView {
        if creationClosure == nil {
            creationClosure = createIfNeeded
        }
        prepareIfPossible()
        let webView: EnhancedWKWebView
        if let warmed = warmedUpObjects.first {
            warmedUpObjects.removeFirst()
            webView = warmed
        } else {
            webView = (creationClosure ?? createIfNeeded)()
            webView.warmUpIfNeeded()
        }
        onDequeue?(webView)
        webView.isHidden = false
        return webView
    }

    public func enqueue(_ webView: EnhancedWKWebView) {
        if warmedUpObjects.count < targetCount {
            webView.resetForReuse()
            warmedUpObjects.append(webView)
            onEnqueue?(webView)
        } else {
            webView.resetForReuse()
        }
    }
}

private extension EnhancedWKWebView {
    func resetForReuse() {
        stopLoading()
        if let blankURL = webViewPoolBlankURL {
            load(URLRequest(url: blankURL))
        }
    }

    func warmUpIfNeeded() {
        if let blankURL = webViewPoolBlankURL {
            load(URLRequest(url: blankURL))
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
