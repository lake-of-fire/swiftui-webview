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

/// Classifies a delegate receipt without rejecting untracked WebKit navigation.
/// Only an exact previously admitted receipt can be proven stale.
internal enum WebViewNavigationCallbackDisposition: Equatable {
    case current
    case stale
    case unknown
}

internal struct WebViewPoolContentNavigationGate<Navigation: AnyObject> {
    private final class WeakNavigation {
        weak var value: Navigation?

        init(_ value: Navigation) {
            self.value = value
        }
    }

    private struct PendingNavigation {
        let contentID: WebViewPoolContentID
        let navigation: Navigation
    }

    private var knownNavigations = [WeakNavigation]()
    private var latestNavigation: WeakNavigation?
    private var pendingNavigation: PendingNavigation?
    private(set) var readyContentID: WebViewPoolContentID?

    var pendingContentID: WebViewPoolContentID? {
        pendingNavigation?.contentID
    }

    mutating func setReadyContentID(_ contentID: WebViewPoolContentID?) {
        knownNavigations.removeAll()
        latestNavigation = nil
        pendingNavigation = nil
        readyContentID = contentID
    }

    mutating func beginKeyedNavigation(
        contentID: WebViewPoolContentID,
        navigation: Navigation
    ) {
        remember(navigation)
        latestNavigation = WeakNavigation(navigation)
        pendingNavigation = PendingNavigation(
            contentID: contentID,
            navigation: navigation
        )
        readyContentID = nil
    }

    mutating func beginUnkeyedNavigation(navigation: Navigation? = nil) {
        if let navigation {
            remember(navigation)
            latestNavigation = WeakNavigation(navigation)
        } else {
            compactKnownNavigations()
            latestNavigation = nil
        }
        pendingNavigation = nil
        readyContentID = nil
    }

    mutating func resetNavigationOwnership() {
        knownNavigations.removeAll()
        latestNavigation = nil
        pendingNavigation = nil
        readyContentID = nil
    }

    mutating func navigationCallbackDisposition(
        for navigation: Navigation?
    ) -> WebViewNavigationCallbackDisposition {
        guard let navigation else { return .unknown }
        compactKnownNavigations()
        if latestNavigation?.value === navigation {
            return .current
        }
        if knownNavigations.contains(where: { $0.value === navigation }) {
            return .stale
        }
        return .unknown
    }

    @discardableResult
    mutating func handleProvisionalNavigationStarted(
        _ navigation: Navigation?
    ) -> WebViewNavigationCallbackDisposition {
        admitNavigationCallback(navigation)
    }

    @discardableResult
    mutating func handleNavigationFinished(_ navigation: Navigation?) -> Bool {
        guard let navigation else { return false }
        defer { removeKnownNavigation(navigation) }
        guard let pendingNavigation,
              pendingNavigation.navigation === navigation else {
            return false
        }
        readyContentID = pendingNavigation.contentID
        self.pendingNavigation = nil
        return true
    }

    @discardableResult
    mutating func handleNavigationFailed(_ navigation: Navigation?) -> Bool {
        guard let navigation else { return false }
        defer { removeKnownNavigation(navigation) }
        guard let pendingNavigation,
              pendingNavigation.navigation === navigation else {
            return false
        }
        self.pendingNavigation = nil
        readyContentID = nil
        return true
    }

    mutating func cancelPendingNavigation() {
        pendingNavigation = nil
        compactKnownNavigations()
        // Pool reset preserves a completed content identity, but any navigation
        // that was current before reset no longer owns delegate publication.
        latestNavigation = nil
    }

    mutating func admitNavigationCallback(
        _ navigation: Navigation?
    ) -> WebViewNavigationCallbackDisposition {
        guard let navigation else {
            // A receiptless callback is still accepted by the delegate. Preserve
            // earlier admitted receipts as stale so they cannot resume afterward.
            beginUnkeyedNavigation()
            return .unknown
        }

        let disposition = navigationCallbackDisposition(for: navigation)
        guard disposition == .unknown else { return disposition }

        // The delegate already treats an unknown main-frame callback as current.
        // Record the same ownership decision so a previously admitted receipt is
        // stale if it resumes after this callback.
        pendingNavigation = nil
        readyContentID = nil
        remember(navigation)
        latestNavigation = WeakNavigation(navigation)
        return .current
    }

    private mutating func remember(_ navigation: Navigation) {
        compactKnownNavigations()
        if !knownNavigations.contains(where: { $0.value === navigation }) {
            knownNavigations.append(WeakNavigation(navigation))
        }
    }

    private mutating func compactKnownNavigations() {
        knownNavigations.removeAll { $0.value == nil }
        if latestNavigation?.value == nil {
            latestNavigation = nil
        }
    }

    private mutating func removeKnownNavigation(_ navigation: Navigation) {
        knownNavigations.removeAll {
            guard let value = $0.value else { return true }
            return value === navigation
        }
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
    public var warmUpCount: Int {
        didSet { rebalanceRetainedObjects() }
    }

    public var keepAliveCount: Int {
        didSet { rebalanceRetainedObjects() }
    }

    private var configuredTotalCountTarget: Int?

    /// Opts into a total pool size that includes both retained and currently leased web views.
    /// Set this to `nil` to use the legacy `warmUpCount + keepAliveCount` retained-view target.
    public var totalCountTarget: Int? {
        get { configuredTotalCountTarget }
        set {
            guard !isInvalidated else {
                configuredTotalCountTarget = 0
                return
            }
            configuredTotalCountTarget = newValue.map { max(0, $0) }
            rebalanceRetainedObjects()
        }
    }

    public var onEnqueue: ((EnhancedWKWebView) -> Void)?
    public var onDequeue: ((EnhancedWKWebView) -> Void)?
    public var defaultResetURL: URL?
    public var debugLabel: String?

    private var warmedUpObjects = [EnhancedWKWebView]()
    private var leasedObjectIdentifiers = Set<ObjectIdentifier>()
    private var creationClosure: (() -> EnhancedWKWebView)?
    private var isInvalidated = false

    private var targetRetainedCount: Int {
        guard !isInvalidated else { return 0 }
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
            for webView in warmedUpObjects {
                onDequeue?(webView)
                webView.resetForReuse(resetURL: nil)
            }
            warmedUpObjects.removeAll()
        }
    }

    /// Installs the long-lived factory used for proactive warming.
    ///
    /// The pool retains this closure until invalidation, so it should capture only
    /// immutable WebKit creation inputs rather than a SwiftUI view or coordinator.
    public func setCreationClosureIfNeeded(_ closure: @escaping () -> EnhancedWKWebView) {
        guard !isInvalidated else {
            log(event: "creationClosure.skip.invalidated")
            return
        }
        if creationClosure == nil {
            creationClosure = closure
            log(event: "creationClosure.set")
            prepareIfPossible()
        } else {
            log(event: "creationClosure.unchanged")
        }
    }

    public func prepareIfPossible() {
        guard !isInvalidated else {
            log(event: "prepare.skip.invalidated")
            return
        }
        guard let creationClosure else {
            log(event: "prepare.skip.noCreationClosure")
            return
        }
        log(event: "prepare.begin")
        while warmedUpObjects.count < targetRetainedCount {
            retainNewWebView(
                using: creationClosure,
                event: "prepare.created"
            )
        }
        log(event: "prepare.end")
    }

    private func retainNewWebView(
        using factory: () -> EnhancedWKWebView,
        event: String
    ) {
        let webView = factory()
        webView.warmUpIfNeeded(resetURL: defaultResetURL)
        warmedUpObjects.append(webView)
        onEnqueue?(webView)
        log(
            event: event,
            extra: ["webView": webViewIdentifier(webView)]
        )
    }

    private func rebalanceRetainedObjects() {
        guard !isInvalidated else { return }
        while warmedUpObjects.count > targetRetainedCount {
            let webView = warmedUpObjects.removeLast()
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
        guard !isInvalidated else {
            log(event: "dequeue.unpooled.invalidated")
            return createIfNeeded()
        }
        // `createIfNeeded` belongs only to this checkout. Retaining an arbitrary
        // caller fallback here can capture its SwiftUI view, navigator, bindings,
        // and even this pool through a prewarmer. Long-lived warming uses the
        // explicit `setCreationClosureIfNeeded(_:)` factory instead.
        //
        // When the retained target is empty, seed the checkout with the exact
        // current factory before proactive top-up. Otherwise `prepareIfPossible()`
        // could manufacture an older owner's WebView and immediately hand it to
        // this caller, bypassing the exact construction contract below.
        if warmedUpObjects.isEmpty,
           targetRetainedCount > 0,
           creationClosure != nil {
            retainNewWebView(
                using: createIfNeeded,
                event: "dequeue.seededCurrent"
            )
        }
        prepareIfPossible()
        let webView: EnhancedWKWebView
        let source: String
        if let preferredContentID,
           let exactIndex = warmedUpObjects.firstIndex(where: {
               $0.poolReadyContentID == preferredContentID
           }) {
            webView = warmedUpObjects.remove(at: exactIndex)
            source = "warmed.exactContent"
        } else if let warmed = warmedUpObjects.first {
            warmedUpObjects.removeFirst()
            webView = warmed
            source = "warmed"
        } else {
            // The retained factory owns proactive warming only. The caller's
            // fallback is the exact construction contract for this checkout and
            // may carry newer configuration or URL-scheme-handler ownership.
            webView = createIfNeeded()
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
        guard !warmedUpObjects.contains(where: { $0 === webView }) else {
            log(event: "enqueue.skip.duplicate", extra: ["webView": String(describing: webViewID)])
            return
        }
        if warmedUpObjects.count < targetRetainedCount {
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

    public func removeAll(resetURL: URL? = nil) {
        let effectiveResetURL = resetURL ?? defaultResetURL
        for webView in warmedUpObjects {
            onDequeue?(webView)
            webView.resetForReuse(resetURL: effectiveResetURL)
        }
        warmedUpObjects.removeAll()
        log(event: "removeAll")
    }

    /// Permanently releases this pool and breaks closures retained for future web-view creation.
    ///
    /// Call this when the feature owning the pool is torn down. Use `removeAll(resetURL:)`
    /// instead when the same pool will serve later views.
    public func invalidate(resetURL: URL? = nil) {
        isInvalidated = true
        configuredTotalCountTarget = 0
        removeAll(resetURL: resetURL)
        creationClosure = nil
        leasedObjectIdentifiers.removeAll()
        onEnqueue = nil
        onDequeue = nil
        log(event: "invalidate")
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
        cancelPendingPooledContentNavigation()
        stopLoading()
        if let resetURL {
            let navigation = load(URLRequest(url: resetURL))
            beginUnkeyedNavigation(navigation: navigation)
        }
    }

    func warmUpIfNeeded(resetURL: URL?) {
        if let resetURL {
            let navigation = load(URLRequest(url: resetURL))
            beginUnkeyedNavigation(navigation: navigation)
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
