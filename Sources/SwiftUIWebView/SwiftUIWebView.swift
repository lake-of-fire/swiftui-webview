import SwiftUI
import WebKit
import UniformTypeIdentifiers
import OrderedCollections
import LRUCache
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@inline(__always)
private func readerLoadElapsedString(since start: Date?, now: Date = Date()) -> String {
    guard let start else { return "nil" }
    return String(format: "%.3fs", now.timeIntervalSince(start))
}

@inline(__always)
private func readerLoadLog(_ stage: String, _ metadata: [String: String] = [:]) {
    let loggedPrefixes = [
        "webViewNavigator.requestDeferredUntilAttached",
        "webViewNavigator.directLoad",
        "webViewNavigator.dataLoad",
        "webViewNavigator.htmlLoad",
        "webViewNavigator.pending",
        "webViewNavigator.preProvisionalWatchdog",
        "webViewNavigator.competingOperation",
        "webView.nav.",
        "webView.processTerminated",
        "readerDocState"
    ]
    guard loggedPrefixes.contains(where: { stage.hasPrefix($0) }) else { return }
    let fields = metadata
        .sorted { $0.key < $1.key }
        .map { key, value in "\(key)=\(value)" }
        .joined(separator: " ")
    let line = fields.isEmpty
        ? "# READERLOAD stage=\(stage)\n"
        : "# READERLOAD stage=\(stage) \(fields)\n"
    print(line, terminator: "")
    guard ProcessInfo.processInfo.environment["MANABI_READER_LOAD_DEBUG"] == "1" else { return }
    guard let data = line.data(using: .utf8) else { return }
    let path = ProcessInfo.processInfo.environment["MANABI_READER_LOAD_DEBUG_PATH"] ?? "/tmp/manabi-reader-load.log"
    let url = URL(fileURLWithPath: path)
    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url, options: .atomic)
    }
}

@inline(__always)
private func safeAreaLog(_ stage: String, _ metadata: [String: String] = [:]) {
    _ = stage
    _ = metadata
}

@inline(__always)
private func bookLog(_ stage: String, _ metadata: [String: String] = [:]) {
    _ = stage
    _ = metadata
}

@inline(__always)
private func popoverWebViewInsetLog(_ metadata: [String: String], force: Bool = false) {
    _ = metadata
    _ = force
}

private func popoverLogValue(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        guard let child = mirror.children.first else { return "nil" }
        return popoverLogValue(child.value)
    }
    switch value {
    case let value as String:
        return value.replacingOccurrences(of: "\n", with: "\\n")
    case let value as CGFloat:
        return String(format: "%.2f", Double(value))
    case let value as Double:
        return value.isFinite ? String(format: "%.2f", value) : "\(value)"
    case let value as Float:
        return value.isFinite ? String(format: "%.2f", Double(value)) : "\(value)"
    case let value as CGRect:
        return "{{\(String(format: "%.2f", value.origin.x)),\(String(format: "%.2f", value.origin.y))},{\(String(format: "%.2f", value.width)),\(String(format: "%.2f", value.height))}}"
    case let value as CGPoint:
        return "{\(String(format: "%.2f", value.x)),\(String(format: "%.2f", value.y))}"
    case let value as CGSize:
        return "{\(String(format: "%.2f", value.width)),\(String(format: "%.2f", value.height))}"
    case let value as [String: Any]:
        return "{" + value.keys.sorted().map { "\($0):\(popoverLogValue(value[$0] as Any))" }.joined(separator: ",") + "}"
    case let value as [Any]:
        return "[" + value.prefix(5).map { popoverLogValue($0) }.joined(separator: ",") + (value.count > 5 ? ",..." : "") + "]"
    default:
        return String(describing: value).replacingOccurrences(of: "\n", with: "\\n")
    }
}

#if os(iOS)
@discardableResult
private func applyTopScrollEdgeEffectHidden(_ isHidden: Bool, in view: UIView) -> (applied: Int, changed: Int) {
    var appliedCount = 0
    var changedCount = 0
    if #available(iOS 26.0, *), let scrollView = view as? UIScrollView {
        if scrollView.topEdgeEffect.isHidden != isHidden {
            changedCount += 1
        }
        scrollView.topEdgeEffect.isHidden = isHidden
        appliedCount += 1
    }
    for subview in view.subviews {
        let result = applyTopScrollEdgeEffectHidden(isHidden, in: subview)
        appliedCount += result.applied
        changedCount += result.changed
    }
    return (appliedCount, changedCount)
}

private func applyTopScrollEdgeEffectHidden(_ isHidden: Bool, to webView: WKWebView, reason: String) {
    let descendantResult = applyTopScrollEdgeEffectHidden(isHidden, in: webView)
    var ancestorCount = 0
    var changedAncestorCount = 0
    var ancestor = webView.superview
    while let view = ancestor {
        if #available(iOS 26.0, *), let scrollView = view as? UIScrollView {
            if scrollView.topEdgeEffect.isHidden != isHidden {
                changedAncestorCount += 1
            }
            scrollView.topEdgeEffect.isHidden = isHidden
            ancestorCount += 1
        }
        ancestor = view.superview
    }
    let changedCount = descendantResult.changed + changedAncestorCount
    guard changedCount > 0 else { return }
}
#endif

@inline(__always)
private func isEpubLikeURL(_ url: URL?) -> Bool {
    guard let url else { return false }
    let absoluteString = url.absoluteString.lowercased()
    return absoluteString.hasPrefix("ebook://") || url.pathExtension.lowercased() == "epub"
}

@inline(__always)
private func navigationTypeDescription(_ navigationType: WKNavigationType) -> String {
    switch navigationType {
    case .linkActivated: return "linkActivated"
    case .formSubmitted: return "formSubmitted"
    case .backForward: return "backForward"
    case .reload: return "reload"
    case .formResubmitted: return "formResubmitted"
    case .other: return "other"
    @unknown default: return "unknown"
    }
}

private let readerLoadCommitGapWarningThreshold: TimeInterval = 0.750
private let readerLoadStaleLoadingStateThreshold: Double = 0.050
private let internalReaderLoaderStartedAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.startedAt."
private let internalReaderLoaderResponseAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.responseAt."
private let internalReaderLoaderDataAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.dataAt."
private let internalReaderLoaderFinishedAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.finishedAt."
private let activeInternalReaderLoaderTraceIDKey = "SwiftUIWebView.activeInternalReaderLoader.traceID"
private let activeInternalReaderLoaderURLKey = "SwiftUIWebView.activeInternalReaderLoader.url"
private let readerLoadVerboseUIViewControllerLoggingEnabled =
    ProcessInfo.processInfo.environment["MANABI_READERLOAD_VERBOSE_UIVIEWCONTROLLER"] == "1"
private let readerLoadCorrelationMaxAge: TimeInterval = 30
private let readerLoadPreProvisionalWarningThreshold: TimeInterval = 2.0

@inline(__always)
private func readerLoadCorrelationTimestamp(
    forKey key: String,
    baseline: Date?,
    now: Date
) -> Date? {
    let timestamp = UserDefaults.standard.double(forKey: key)
    guard timestamp > 0 else { return nil }
    let resolved = Date(timeIntervalSince1970: timestamp)
    if let baseline, resolved.timeIntervalSince(baseline) < -0.050 {
        return nil
    }
    guard now.timeIntervalSince(resolved) <= readerLoadCorrelationMaxAge else {
        return nil
    }
    return resolved
}

@inline(__always)
private func clearReaderLoaderCorrelationTimestamps(for urlString: String) {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: internalReaderLoaderStartedAtKeyPrefix + urlString)
    defaults.removeObject(forKey: internalReaderLoaderResponseAtKeyPrefix + urlString)
    defaults.removeObject(forKey: internalReaderLoaderDataAtKeyPrefix + urlString)
    defaults.removeObject(forKey: internalReaderLoaderFinishedAtKeyPrefix + urlString)
}

@inline(__always)
private func readerLoadSceneStateString(for webView: WKWebView?) -> String {
    #if os(iOS)
    guard let scene = webView?.window?.windowScene else { return "nil" }
    switch scene.activationState {
    case .unattached:
        return "unattached"
    case .foregroundActive:
        return "foregroundActive"
    case .foregroundInactive:
        return "foregroundInactive"
    case .background:
        return "background"
    @unknown default:
        return "unknown"
    }
    #else
    return "unsupported"
    #endif
}

@inline(__always)
private func canonicalContentURLForReaderLoader(_ url: URL?) -> URL? {
    guard let url,
          url.scheme?.lowercased() == "internal",
          url.host?.lowercased() == "local",
          url.path == "/load/reader",
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let readerURLValue = components.queryItems?.first(where: { $0.name == "reader-url" })?.value
    else {
        return nil
    }
    if let decoded = readerURLValue.removingPercentEncoding, let resolved = URL(string: decoded) {
        return resolved
    }
    return URL(string: readerURLValue)
}

@inline(__always)
private func isInternalReaderLoaderURL(_ url: URL?) -> Bool {
    guard let url else { return false }
    return url.scheme?.lowercased() == "internal"
        && url.host?.lowercased() == "local"
        && url.path == "/load/reader"
}

@inline(__always)
private func readerLoadObjectIDString(_ value: AnyObject?) -> String {
    guard let value else { return "nil" }
    return String(describing: ObjectIdentifier(value))
}

@MainActor private let webViewProcessPool = WKProcessPool()

@globalActor
public actor WebViewActor {
    public static let shared = WebViewActor()
}

public struct WebViewMessageHandlersKey: EnvironmentKey {
    public static let defaultValue: WebViewMessageHandlers = .init()
}

public extension EnvironmentValues {
    var webViewMessageHandlers: WebViewMessageHandlers {
        get { self[WebViewMessageHandlersKey.self] }
        set { self[WebViewMessageHandlersKey.self] = newValue }
    }
}

public struct WebViewMessageHandlers: Sendable {
    public let handlers: OrderedDictionary<String, @Sendable (WebViewMessage) async -> Void>
    
    public init(_ handlers: OrderedDictionary<String, @Sendable (WebViewMessage) async -> Void> = [:]) {
        self.handlers = handlers
    }
    
    public init(_ pairs: [(String, @Sendable (WebViewMessage) async -> Void)]) {
        self.init(OrderedDictionary(uniqueKeysWithValues: pairs))
    }
    
    public func composing(_ other: WebViewMessageHandlers) -> WebViewMessageHandlers {
        var merged = handlers
        for (k, h) in other.handlers {
            if let existing = merged[k] {
                merged[k] = { @Sendable message in
                    await existing(message)
                    await h(message)
                }
            } else {
                merged[k] = h
            }
        }
        return WebViewMessageHandlers(merged)
    }
    
    public static func + (lhs: WebViewMessageHandlers, rhs: WebViewMessageHandlers) -> WebViewMessageHandlers {
        lhs.composing(rhs)
    }
    
    public func updating(_ name: String, handler: @Sendable @escaping (WebViewMessage) async -> Void) -> WebViewMessageHandlers {
        var copy = handlers
        copy[name] = handler
        return WebViewMessageHandlers(copy)
    }
}

#if os(iOS)
public typealias BuildMenuType = (UIMenuBuilder) -> Void
#elseif os(macOS)
public typealias BuildMenuType = (Any) -> Void
#endif

public enum WebViewPaginationMode: Int, CaseIterable, Sendable {
    case unpaginated = 0
    case leftToRight = 1
    case rightToLeft = 2
    case topToBottom = 3
    case bottomToTop = 4

    public var usesViewHeightAsPageLength: Bool {
        switch self {
        case .leftToRight, .rightToLeft, .unpaginated:
            true
        case .topToBottom, .bottomToTop:
            false
        }
    }

    public var isPaginated: Bool {
        self != .unpaginated
    }
}

public struct WebViewPaginationConfiguration: Equatable, Sendable {
    public static let disabled = WebViewPaginationConfiguration(mode: .unpaginated)

    public let mode: WebViewPaginationMode
    public let storedPageLength: CGFloat
    public let effectivePageLength: CGFloat
    public let gapBetweenPages: CGFloat
    public let behavesLikeColumns: Bool
    public let layoutSize: CGSize

    public init(
        mode: WebViewPaginationMode,
        storedPageLength: CGFloat = 0,
        effectivePageLength: CGFloat = 0,
        gapBetweenPages: CGFloat = 0,
        behavesLikeColumns: Bool = true,
        layoutSize: CGSize = .zero
    ) {
        self.mode = mode
        self.storedPageLength = storedPageLength
        self.effectivePageLength = effectivePageLength
        self.gapBetweenPages = gapBetweenPages
        self.behavesLikeColumns = behavesLikeColumns
        self.layoutSize = layoutSize
    }

    public var usesViewLength: Bool {
        storedPageLength == 0
    }

    public func resolvingEffectivePageLength(using fallbackLayoutSize: CGSize) -> WebViewPaginationConfiguration {
        let resolvedLayoutSize = resolvedLayoutSize(using: fallbackLayoutSize)
        let resolvedEffectivePageLength: CGFloat
        if !mode.isPaginated {
            resolvedEffectivePageLength = 0
        } else if storedPageLength == 0 {
            resolvedEffectivePageLength = mode.usesViewHeightAsPageLength
                ? resolvedLayoutSize.height
                : resolvedLayoutSize.width
        } else {
            resolvedEffectivePageLength = storedPageLength
        }
        return WebViewPaginationConfiguration(
            mode: mode,
            storedPageLength: mode.isPaginated ? storedPageLength : 0,
            effectivePageLength: resolvedEffectivePageLength,
            gapBetweenPages: mode.isPaginated ? gapBetweenPages : 0,
            behavesLikeColumns: mode.isPaginated ? behavesLikeColumns : true,
            layoutSize: resolvedLayoutSize
        )
    }

    public func structuralIdentity(using fallbackLayoutSize: CGSize) -> WebViewPaginationStructuralIdentity {
        let resolved = resolvingEffectivePageLength(using: fallbackLayoutSize)
        return WebViewPaginationStructuralIdentity(
            mode: resolved.mode,
            storedPageLength: resolved.storedPageLength,
            gapBetweenPages: resolved.gapBetweenPages,
            behavesLikeColumns: resolved.behavesLikeColumns,
            layoutSize: resolved.layoutSize
        )
    }

    public var dictionaryRepresentation: [String: String] {
        [
            "mode": "\(mode.rawValue)",
            "storedPageLength": "\(storedPageLength)",
            "effectivePageLength": "\(effectivePageLength)",
            "gapBetweenPages": "\(gapBetweenPages)",
            "behavesLikeColumns": "\(behavesLikeColumns)",
            "layoutWidth": "\(layoutSize.width)",
            "layoutHeight": "\(layoutSize.height)",
            "usesViewLength": "\(usesViewLength)"
        ]
    }

    private func resolvedLayoutSize(using fallbackLayoutSize: CGSize) -> CGSize {
        let candidate = layoutSize == .zero ? fallbackLayoutSize : layoutSize
        return CGSize(width: max(0, candidate.width), height: max(0, candidate.height))
    }
}

public struct WebViewPaginationStructuralIdentity: Equatable, Sendable {
    public let mode: WebViewPaginationMode
    public let storedPageLength: CGFloat
    public let gapBetweenPages: CGFloat
    public let behavesLikeColumns: Bool
    public let layoutSize: CGSize
}

public enum WebViewPaginationVisibleUnitKind: String, Codable, Equatable, Sendable {
    case singlePage
    case pageSpread
    case paginatedRowSet
}

public enum WebViewPaginationVisibleUnitAxis: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

public struct WebViewPaginationVisibleUnit: Codable, Equatable, Sendable {
    public let kind: WebViewPaginationVisibleUnitKind
    public let axis: WebViewPaginationVisibleUnitAxis
    public let visiblePageCount: Int
    public let primarySpacing: CGFloat
    public let currentUnitIndex: Int?
    public let leadingPageIndex: Int?
    public let trailingPageIndex: Int?
    public let hasLeadingSingleton: Bool
    public let hasTrailingSingleton: Bool
    public let spreadPagesAllowedForViewport: Bool

    public init(
        kind: WebViewPaginationVisibleUnitKind,
        axis: WebViewPaginationVisibleUnitAxis,
        visiblePageCount: Int,
        primarySpacing: CGFloat = 0,
        currentUnitIndex: Int?,
        leadingPageIndex: Int?,
        trailingPageIndex: Int?,
        hasLeadingSingleton: Bool,
        hasTrailingSingleton: Bool,
        spreadPagesAllowedForViewport: Bool
    ) {
        self.kind = kind
        self.axis = axis
        self.visiblePageCount = visiblePageCount
        self.primarySpacing = primarySpacing
        self.currentUnitIndex = currentUnitIndex
        self.leadingPageIndex = leadingPageIndex
        self.trailingPageIndex = trailingPageIndex
        self.hasLeadingSingleton = hasLeadingSingleton
        self.hasTrailingSingleton = hasTrailingSingleton
        self.spreadPagesAllowedForViewport = spreadPagesAllowedForViewport
    }

    public static let singlePage = WebViewPaginationVisibleUnit(
        kind: .singlePage,
        axis: .horizontal,
        visiblePageCount: 1,
        primarySpacing: 0,
        currentUnitIndex: nil,
        leadingPageIndex: nil,
        trailingPageIndex: nil,
        hasLeadingSingleton: false,
        hasTrailingSingleton: false,
        spreadPagesAllowedForViewport: false
    )

    public var dictionaryRepresentation: [String: String] {
        [
            "visibleUnitKind": kind.rawValue,
            "visibleUnitAxis": axis.rawValue,
            "visiblePageCount": "\(visiblePageCount)",
            "primarySpacing": "\(primarySpacing)",
            "currentUnitIndex": currentUnitIndex.map(String.init) ?? "nil",
            "leadingPageIndex": leadingPageIndex.map(String.init) ?? "nil",
            "trailingPageIndex": trailingPageIndex.map(String.init) ?? "nil",
            "hasLeadingSingleton": "\(hasLeadingSingleton)",
            "hasTrailingSingleton": "\(hasTrailingSingleton)",
            "spreadPagesAllowedForViewport": "\(spreadPagesAllowedForViewport)"
        ]
    }
}

public enum WebViewPaginationPageLabelDisplayMode: String, Codable, Equatable, Sendable {
    case singleLabel
    case multipleLabels
}

public struct WebViewPaginationPageLabelPolicy: Codable, Equatable, Sendable {
    public let displayMode: WebViewPaginationPageLabelDisplayMode
    public let usesPhysicalPageLabels: Bool

    public init(
        displayMode: WebViewPaginationPageLabelDisplayMode,
        usesPhysicalPageLabels: Bool
    ) {
        self.displayMode = displayMode
        self.usesPhysicalPageLabels = usesPhysicalPageLabels
    }

    public static let singleLabel = WebViewPaginationPageLabelPolicy(
        displayMode: .singleLabel,
        usesPhysicalPageLabels: false
    )

    public var dictionaryRepresentation: [String: String] {
        [
            "pageLabelDisplayMode": displayMode.rawValue,
            "usesPhysicalPageLabels": "\(usesPhysicalPageLabels)"
        ]
    }
}

public struct WebViewPaginationStateEnrichment: Codable, Equatable, Sendable {
    public let visibleUnit: WebViewPaginationVisibleUnit?
    public let pageLabelPolicy: WebViewPaginationPageLabelPolicy?

    public init(
        visibleUnit: WebViewPaginationVisibleUnit? = nil,
        pageLabelPolicy: WebViewPaginationPageLabelPolicy? = nil
    ) {
        self.visibleUnit = visibleUnit
        self.pageLabelPolicy = pageLabelPolicy
    }
}

public struct WebViewPaginationState: Equatable, Sendable {
    public let desiredConfiguration: WebViewPaginationConfiguration
    public let appliedConfiguration: WebViewPaginationConfiguration?
    public let pageCount: Int?
    public let visibleUnit: WebViewPaginationVisibleUnit?
    public let pageLabelPolicy: WebViewPaginationPageLabelPolicy?
    public let mountedHostIdentifier: String?
    public let appliedHostIdentifier: String?
    public let isAppliedToMountedHost: Bool
    public let usedViewLengthInference: Bool
    public let lastApplyReason: String?
    public let lastUpdatedAt: Date?

    public init(
        desiredConfiguration: WebViewPaginationConfiguration,
        appliedConfiguration: WebViewPaginationConfiguration?,
        pageCount: Int?,
        visibleUnit: WebViewPaginationVisibleUnit? = nil,
        pageLabelPolicy: WebViewPaginationPageLabelPolicy? = nil,
        mountedHostIdentifier: String?,
        appliedHostIdentifier: String?,
        isAppliedToMountedHost: Bool,
        usedViewLengthInference: Bool,
        lastApplyReason: String?,
        lastUpdatedAt: Date?
    ) {
        self.desiredConfiguration = desiredConfiguration
        self.appliedConfiguration = appliedConfiguration
        self.pageCount = pageCount
        self.visibleUnit = visibleUnit
        self.pageLabelPolicy = pageLabelPolicy
        self.mountedHostIdentifier = mountedHostIdentifier
        self.appliedHostIdentifier = appliedHostIdentifier
        self.isAppliedToMountedHost = isAppliedToMountedHost
        self.usedViewLengthInference = usedViewLengthInference
        self.lastApplyReason = lastApplyReason
        self.lastUpdatedAt = lastUpdatedAt
    }

    public var dictionaryRepresentation: [String: String] {
        var values = desiredConfiguration.dictionaryRepresentation
        values["pageCount"] = pageCount.map(String.init) ?? "nil"
        values.merge(visibleUnit?.dictionaryRepresentation ?? [:], uniquingKeysWith: { _, rhs in rhs })
        values.merge(pageLabelPolicy?.dictionaryRepresentation ?? [:], uniquingKeysWith: { _, rhs in rhs })
        values["mountedHostIdentifier"] = mountedHostIdentifier ?? "nil"
        values["appliedHostIdentifier"] = appliedHostIdentifier ?? "nil"
        values["isAppliedToMountedHost"] = "\(isAppliedToMountedHost)"
        values["lastApplyReason"] = lastApplyReason ?? "nil"
        values["lastUpdatedAt"] = lastUpdatedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        return values
    }

    public static func == (lhs: WebViewPaginationState, rhs: WebViewPaginationState) -> Bool {
        lhs.desiredConfiguration == rhs.desiredConfiguration
        && lhs.appliedConfiguration == rhs.appliedConfiguration
        && lhs.pageCount == rhs.pageCount
        && lhs.visibleUnit == rhs.visibleUnit
        && lhs.pageLabelPolicy == rhs.pageLabelPolicy
        && lhs.mountedHostIdentifier == rhs.mountedHostIdentifier
        && lhs.appliedHostIdentifier == rhs.appliedHostIdentifier
        && lhs.isAppliedToMountedHost == rhs.isAppliedToMountedHost
        && lhs.usedViewLengthInference == rhs.usedViewLengthInference
        && lhs.lastApplyReason == rhs.lastApplyReason
    }

    public func applying(_ enrichment: WebViewPaginationStateEnrichment?) -> WebViewPaginationState {
        guard let enrichment else { return self }
        return WebViewPaginationState(
            desiredConfiguration: desiredConfiguration,
            appliedConfiguration: appliedConfiguration,
            pageCount: pageCount,
            visibleUnit: enrichment.visibleUnit ?? visibleUnit,
            pageLabelPolicy: enrichment.pageLabelPolicy ?? pageLabelPolicy,
            mountedHostIdentifier: mountedHostIdentifier,
            appliedHostIdentifier: appliedHostIdentifier,
            isAppliedToMountedHost: isAppliedToMountedHost,
            usedViewLengthInference: usedViewLengthInference,
            lastApplyReason: lastApplyReason,
            lastUpdatedAt: lastUpdatedAt
        )
    }
}

public enum WebViewPaginationError: Error, LocalizedError {
    case missingSelector(String)

    public var errorDescription: String? {
        switch self {
        case .missingSelector(let selectorName):
            "Missing WKWebView pagination selector: \(selectorName)"
        }
    }
}

@inline(__always)
private func webViewPaginationDebugLog(_ stage: String, _ metadata: [String: Any] = [:]) {
    #if DEBUG
    guard ProcessInfo.processInfo.environment["MANABI_WEBVIEW_PAGINATION_DEBUG"] == "1" else { return }
    var payload = metadata
    payload["stage"] = stage
    Swift.debugPrint("# WEBVIEWPAGINATION", payload)
    #endif
}

@inline(__always)
func webViewLayoutDebugLog(_ stage: String, _ metadata: [String: Any] = [:]) {
    _ = stage
    _ = metadata
}

func webViewLayoutRounded(_ value: CGFloat) -> Double {
    Double((value * 100).rounded() / 100)
}

func webViewLayoutSizeString(_ size: CGSize) -> String {
    "\(webViewLayoutRounded(size.width))x\(webViewLayoutRounded(size.height))"
}

func webViewLayoutPointString(_ point: CGPoint) -> String {
    "\(webViewLayoutRounded(point.x)),\(webViewLayoutRounded(point.y))"
}

func webViewLayoutPaginationPayload(
    configuration: WebViewPaginationConfiguration,
    reason: String
) -> [String: Any] {
    [
        "reason": reason,
        "mode": configuration.mode.rawValue,
        "storedPageLength": webViewLayoutRounded(configuration.storedPageLength),
        "effectivePageLength": webViewLayoutRounded(configuration.effectivePageLength),
        "gapBetweenPages": webViewLayoutRounded(configuration.gapBetweenPages),
        "behavesLikeColumns": configuration.behavesLikeColumns,
        "layoutSize": webViewLayoutSizeString(configuration.layoutSize),
        "usesViewLength": configuration.usesViewLength
    ]
}

#if os(iOS)
@MainActor
func webViewLayoutInsetsString(_ insets: UIEdgeInsets) -> String {
    "t:\(webViewLayoutRounded(insets.top)) l:\(webViewLayoutRounded(insets.left)) b:\(webViewLayoutRounded(insets.bottom)) r:\(webViewLayoutRounded(insets.right))"
}

@MainActor
func webViewLayoutScrollPayload(webView: WKWebView, configuration: WebViewPaginationConfiguration? = nil) -> [String: Any] {
    let scrollView = webView.scrollView
    var payload: [String: Any] = [
        "host": WebViewPaginationController.hostIdentifier(for: webView),
        "url": webView.url?.absoluteString ?? "nil",
        "webBounds": webViewLayoutSizeString(webView.bounds.size),
        "scrollBounds": webViewLayoutSizeString(scrollView.bounds.size),
        "contentSize": webViewLayoutSizeString(scrollView.contentSize),
        "contentOffset": webViewLayoutPointString(scrollView.contentOffset),
        "contentInset": webViewLayoutInsetsString(scrollView.contentInset),
        "adjustedInset": webViewLayoutInsetsString(scrollView.adjustedContentInset),
        "zoomScale": webViewLayoutRounded(scrollView.zoomScale),
        "isDragging": scrollView.isDragging,
        "isDecelerating": scrollView.isDecelerating,
        "isTracking": scrollView.isTracking
    ]
    if let configuration {
        payload.merge(
            webViewLayoutPaginationPayload(configuration: configuration, reason: "state"),
            uniquingKeysWith: { lhs, _ in lhs }
        )
    }
    return payload
}

@MainActor
func webViewLayoutShouldLog(webView: WKWebView, configuration: WebViewPaginationConfiguration? = nil) -> Bool {
    if configuration?.mode.isPaginated == true {
        return true
    }
    let urlString = webView.url?.absoluteString ?? ""
    return urlString.hasPrefix("ebook://") || urlString.contains("ebook/")
}
#endif

public struct WebViewState: Equatable, Sendable {
    public internal(set) var isLoading: Bool
    public internal(set) var isProvisionallyNavigating: Bool
    public internal(set) var loadingProgress: Double?
    public internal(set) var pageURL: URL
    public internal(set) var pageTitle: String?
    public internal(set) var pageImageURL: URL?
    public internal(set) var pageIconURL: URL?
    public internal(set) var pageHTML: String?
    public internal(set) var hasReaderRenderReady: Bool
    public internal(set) var mainFrameHTTPStatusCode: Int?
    public internal(set) var error: Error?
    public internal(set) var canGoBack: Bool
    public internal(set) var canGoForward: Bool
    public internal(set) var backList: [WKBackForwardListItem]
    public internal(set) var forwardList: [WKBackForwardListItem]
    public internal(set) var paginationState: WebViewPaginationState?
    
    public static let empty = WebViewState(
        isLoading: false,
        isProvisionallyNavigating: false,
        loadingProgress: nil,
        pageURL: URL(string: "about:blank")!,
        pageTitle: nil,
        pageImageURL: nil,
        pageIconURL: nil,
        pageHTML: nil,
        hasReaderRenderReady: false,
        mainFrameHTTPStatusCode: nil,
        error: nil,
        canGoBack: false,
        canGoForward: false,
        backList: [],
        forwardList: [],
        paginationState: nil)
    
    public static func == (lhs: WebViewState, rhs: WebViewState) -> Bool {
        lhs.isLoading == rhs.isLoading
        && lhs.isProvisionallyNavigating == rhs.isProvisionallyNavigating
        && lhs.loadingProgress == rhs.loadingProgress
        && lhs.pageURL == rhs.pageURL
        && lhs.pageTitle == rhs.pageTitle
        && lhs.pageImageURL == rhs.pageImageURL
        && lhs.pageIconURL == rhs.pageIconURL
        && lhs.pageHTML == rhs.pageHTML
        && lhs.hasReaderRenderReady == rhs.hasReaderRenderReady
        && lhs.mainFrameHTTPStatusCode == rhs.mainFrameHTTPStatusCode
        && lhs.error?.localizedDescription == rhs.error?.localizedDescription
        && lhs.canGoBack == rhs.canGoBack
        && lhs.canGoForward == rhs.canGoForward
        && lhs.backList == rhs.backList
        && lhs.forwardList == rhs.forwardList
        && lhs.paginationState == rhs.paginationState
    }
}

public struct WebViewMessage: Equatable, @unchecked Sendable {
    public let frameInfo: WKFrameInfo
    fileprivate let uuid: UUID
    public let name: String
    public let body: Any
    public let isMainFrame: Bool
    public let requestURL: URL?
    public let mainDocumentURL: URL?

    @MainActor
    public init(frameInfo: WKFrameInfo, uuid: UUID, name: String, body: Any) {
        self.frameInfo = frameInfo
        self.uuid = uuid
        self.name = name
        self.body = body
        self.isMainFrame = frameInfo.isMainFrame
        self.requestURL = frameInfo.request.url
        self.mainDocumentURL = frameInfo.request.mainDocumentURL
    }
    
    public static func == (lhs: WebViewMessage, rhs: WebViewMessage) -> Bool {
        lhs.uuid == rhs.uuid
        && lhs.name == rhs.name && lhs.frameInfo == rhs.frameInfo
    }
}

public struct WebViewNativeLookupHitTarget {
    public let elementID: String
    public let rects: [CGRect]
    public let coordinateOriginInWindow: CGPoint?
    public let lookupPayload: [String: Any]?
    public let frameInfo: WKFrameInfo?
    public let nativeLookupFrameKey: String?
    public let debugUsedInflatedHitRect: Bool?
    public let debugHitRects: [CGRect]
    public let debugDistance: CGFloat?
    public let debugCenterDistance: CGFloat?
    public let debugHitTestPoint: CGPoint?
    public let debugHitTestRebaseX: CGFloat?
    public let debugHitTestRebaseY: CGFloat?

    public init(
        elementID: String,
        rects: [CGRect],
        coordinateOriginInWindow: CGPoint? = nil,
        lookupPayload: [String: Any]? = nil,
        frameInfo: WKFrameInfo? = nil,
        nativeLookupFrameKey: String? = nil,
        debugUsedInflatedHitRect: Bool? = nil,
        debugHitRects: [CGRect] = [],
        debugDistance: CGFloat? = nil,
        debugCenterDistance: CGFloat? = nil,
        debugHitTestPoint: CGPoint? = nil,
        debugHitTestRebaseX: CGFloat? = nil,
        debugHitTestRebaseY: CGFloat? = nil
    ) {
        self.elementID = elementID
        self.rects = rects
        self.coordinateOriginInWindow = coordinateOriginInWindow
        self.lookupPayload = lookupPayload
        self.frameInfo = frameInfo
        self.nativeLookupFrameKey = nativeLookupFrameKey
        self.debugUsedInflatedHitRect = debugUsedInflatedHitRect
        self.debugHitRects = debugHitRects
        self.debugDistance = debugDistance
        self.debugCenterDistance = debugCenterDistance
        self.debugHitTestPoint = debugHitTestPoint
        self.debugHitTestRebaseX = debugHitTestRebaseX
        self.debugHitTestRebaseY = debugHitTestRebaseY
    }

    public var projectedRectsForCurrentHitTestOverlay: [CGRect] {
        projectedRectsForCurrentHitTestOverlay(topExpansion: 0)
    }

    public func projectedRectsForCurrentHitTestOverlay(topExpansion: CGFloat) -> [CGRect] {
        let rebaseX = debugHitTestRebaseX ?? 0
        let rebaseY = debugHitTestRebaseY ?? 0
        return rects
            .filter { !$0.isNull && !$0.isEmpty }
            .map { rect in
                var projectedRect = rect.offsetBy(dx: -rebaseX, dy: -rebaseY)
                projectedRect.origin.y -= topExpansion
                projectedRect.size.height += topExpansion
                return projectedRect
            }
    }
}

public struct WebViewNativeLookupHit {
    public let elementID: String
    public let point: CGPoint
    public let rects: [CGRect]
    public let coordinateOriginInWindow: CGPoint?
    public let lookupPayload: [String: Any]?
    public let debugUsedInflatedHitRect: Bool?
    public let debugHitRects: [CGRect]
    public let debugDistance: CGFloat?
    public let debugCenterDistance: CGFloat?
    public let debugHitTestPoint: CGPoint?
    public let debugHitTestRebaseX: CGFloat?
    public let debugHitTestRebaseY: CGFloat?
    public let frameInfo: WKFrameInfo?

    public init(
        elementID: String,
        point: CGPoint,
        rects: [CGRect] = [],
        coordinateOriginInWindow: CGPoint? = nil,
        lookupPayload: [String: Any]? = nil,
        debugUsedInflatedHitRect: Bool? = nil,
        debugHitRects: [CGRect] = [],
        debugDistance: CGFloat? = nil,
        debugCenterDistance: CGFloat? = nil,
        debugHitTestPoint: CGPoint? = nil,
        debugHitTestRebaseX: CGFloat? = nil,
        debugHitTestRebaseY: CGFloat? = nil,
        frameInfo: WKFrameInfo? = nil
    ) {
        self.elementID = elementID
        self.point = point
        self.rects = rects
        self.coordinateOriginInWindow = coordinateOriginInWindow
        self.lookupPayload = lookupPayload
        self.debugUsedInflatedHitRect = debugUsedInflatedHitRect
        self.debugHitRects = debugHitRects
        self.debugDistance = debugDistance
        self.debugCenterDistance = debugCenterDistance
        self.debugHitTestPoint = debugHitTestPoint
        self.debugHitTestRebaseX = debugHitTestRebaseX
        self.debugHitTestRebaseY = debugHitTestRebaseY
        self.frameInfo = frameInfo
    }
}

public final class WebViewNativeLookupHitTestStore {
    private static let strictOverlayCaptureDefaultsKey = "NativeLookupStrictOverlayCapture"

    private struct Entry {
        let target: WebViewNativeLookupHitTarget
        let rects: [CGRect]
        let hitRects: [CGRect]
    }

    private struct Candidate {
        let target: WebViewNativeLookupHitTarget
        let rect: CGRect
        let hitRect: CGRect
        let hitTestPoint: CGPoint
        let hitTestRebaseX: CGFloat
        let hitTestRebaseY: CGFloat
        let distance: CGFloat
        let centerDistance: CGFloat
        let area: CGFloat
        let index: Int
    }

    private let hitSlop: CGFloat
    private var entries: [Entry] = []
    private var nativeTouchElementID: String?
    private var suppressUnhandledTapUntil: TimeInterval = 0
    private var webTextSelectionActive = false
    private var webTextSelectionTextLength = 0
    private var webTextSelectionUpdatedAt: TimeInterval?
    public var onHit: ((WebViewNativeLookupHit) -> Void)?
    public var onActiveTargetTouchDown: ((WebViewNativeLookupHitTarget) -> Void)?
    public var onTouchDownHitCancelled: ((WebViewNativeLookupHitTarget) -> Void)?
    public var onOverlaySegmentHitObserved: ((WebViewNativeLookupHitTarget, CGPoint, CGSize) -> Void)?
    public var onNativeTouchStreamFinished: ((String) -> Void)?
    public var onPressedTargetHandoffCompleted: ((String?) -> Void)?
    public var onActiveLookupBlankTap: (() -> Void)?
    public var onExternalTouchInteractionCancelled: ((String) -> Void)?
    public var activeLookupElementID: (() -> String?)?
    public var activeElementID: String?
    public var showsPressedTargetOverlay = false
    public var isEnabled = true {
        didSet {
            if !isEnabled {
                removeAllTargets()
            }
        }
    }
    public var targetCount: Int { entries.count }
    public var activeNativeTouchElementID: String? { nativeTouchElementID }
    public var shouldSuppressUnhandledTapForNativeLookup: Bool {
        nativeTouchElementID != nil || Date().timeIntervalSinceReferenceDate < suppressUnhandledTapUntil
    }
    public var webTextSelectionDiagnostics: [String: Any] {
        [
            "webTextSelectionActive": webTextSelectionActive,
            "webTextSelectionTextLength": webTextSelectionTextLength,
            "webTextSelectionAgeMs": webTextSelectionUpdatedAt.map {
                (Date().timeIntervalSinceReferenceDate - $0) * 1_000
            } as Any,
        ]
    }
    public var hasActiveWebTextSelection: Bool { webTextSelectionActive }
    public var capturesSegmentTouchesInOverlay =
        UserDefaults.standard.bool(forKey: WebViewNativeLookupHitTestStore.strictOverlayCaptureDefaultsKey)

    public init(hitSlop: CGFloat = 3) {
        self.hitSlop = hitSlop
    }

    public func updateTargets(
        _ targets: [WebViewNativeLookupHitTarget],
        viewportSize _: CGSize? = nil,
        viewportOrigin _: CGPoint = .zero
    ) {
        guard isEnabled else {
            entries.removeAll()
            return
        }
        entries = makeEntries(for: targets)
    }

    public func updateTargets(
        _ targets: [WebViewNativeLookupHitTarget],
        replacingNativeLookupFrameKey frameKey: String
    ) {
        guard isEnabled else {
            entries.removeAll()
            return
        }
        let replacementEntries = makeEntries(for: targets)
        entries.removeAll { $0.target.nativeLookupFrameKey == frameKey }
        entries.append(contentsOf: replacementEntries)
    }

    public func removeAllTargets() {
        entries.removeAll()
        nativeTouchElementID = nil
        suppressUnhandledTapUntil = 0
    }

    public func closeActiveLookupFromBlankTap() {
        onActiveLookupBlankTap?()
    }

    public func updateWebTextSelection(active: Bool, textLength: Int, source: String) {
        webTextSelectionActive = active
        webTextSelectionTextLength = textLength
        webTextSelectionUpdatedAt = Date().timeIntervalSinceReferenceDate
    }

    public func cancelActiveTouchInteraction(reason: String) {
        onExternalTouchInteractionCancelled?(reason)
    }

    public func beginNativeTouchStream(on target: WebViewNativeLookupHitTarget) {
        nativeTouchElementID = target.elementID
        suppressUnhandledTapUntil = Date().timeIntervalSinceReferenceDate + 0.5
    }

    public func finishNativeTouchStream(reason: String) {
        if nativeTouchElementID != nil {
            suppressUnhandledTapUntil = Date().timeIntervalSinceReferenceDate + 0.5
        }
        nativeTouchElementID = nil
        onNativeTouchStreamFinished?(reason)
    }

    public func hitTarget(
        at point: CGPoint,
        in containerSize: CGSize? = nil,
        coordinateViewWindowMinY: CGFloat? = nil,
        coordinateViewWindowOrigin: CGPoint? = nil
    ) -> WebViewNativeLookupHitTarget? {
        guard isEnabled else { return nil }
        let exactCandidate = bestCandidate(
            at: point,
            usingInflatedRects: false,
            containerSize: containerSize,
            coordinateViewWindowMinY: coordinateViewWindowMinY,
            coordinateViewWindowOrigin: coordinateViewWindowOrigin
        )
        if let exactCandidate {
            return target(
                for: exactCandidate,
                usedInflatedHitRect: false
            )
        }
        return bestCandidate(
            at: point,
            usingInflatedRects: true,
            containerSize: containerSize,
            coordinateViewWindowMinY: coordinateViewWindowMinY,
            coordinateViewWindowOrigin: coordinateViewWindowOrigin
        ).map {
            target(
                for: $0,
                usedInflatedHitRect: true
            )
        }
    }

    public func exactHitTarget(
        at point: CGPoint,
        in containerSize: CGSize? = nil,
        coordinateViewWindowMinY: CGFloat? = nil,
        coordinateViewWindowOrigin: CGPoint? = nil
    ) -> WebViewNativeLookupHitTarget? {
        guard isEnabled else { return nil }
        return bestCandidate(
            at: point,
            usingInflatedRects: false,
            containerSize: containerSize,
            coordinateViewWindowMinY: coordinateViewWindowMinY,
            coordinateViewWindowOrigin: coordinateViewWindowOrigin
        ).map {
            target(
                for: $0,
                usedInflatedHitRect: false
            )
        }
    }

    private func rebasedHitTestPoint(
        _ point: CGPoint,
        containerSize: CGSize?,
        coordinateViewWindowMinY: CGFloat?,
        coordinateViewWindowOrigin: CGPoint?,
        targetCoordinateOriginInWindow: CGPoint?
    ) -> (point: CGPoint, rebaseX: CGFloat, rebaseY: CGFloat) {
        if let containerSize,
           containerSize.width <= 1 || containerSize.height <= 1 {
            return (point, 0, 0)
        }
        guard let targetCoordinateOriginInWindow else {
            return (point, 0, 0)
        }
        let rebaseX: CGFloat
        if let coordinateViewWindowOrigin,
           coordinateViewWindowOrigin.x.isFinite,
           targetCoordinateOriginInWindow.x.isFinite {
            rebaseX = coordinateViewWindowOrigin.x - targetCoordinateOriginInWindow.x
        } else {
            rebaseX = 0
        }
        let rebaseY: CGFloat
        if let coordinateViewWindowOrigin,
           coordinateViewWindowOrigin.y.isFinite,
           targetCoordinateOriginInWindow.y.isFinite {
            rebaseY = coordinateViewWindowOrigin.y - targetCoordinateOriginInWindow.y
        } else if let coordinateViewWindowMinY,
                  coordinateViewWindowMinY.isFinite,
                  targetCoordinateOriginInWindow.y.isFinite {
            rebaseY = coordinateViewWindowMinY - targetCoordinateOriginInWindow.y
        } else {
            rebaseY = 0
        }
        return (
            CGPoint(x: point.x + rebaseX, y: point.y + rebaseY),
            rebaseX,
            rebaseY
        )
    }

    private func bestCandidate(
        at point: CGPoint,
        usingInflatedRects: Bool,
        containerSize: CGSize? = nil,
        coordinateViewWindowMinY: CGFloat? = nil,
        coordinateViewWindowOrigin: CGPoint? = nil
    ) -> Candidate? {
        var best: Candidate?
        for (index, entry) in entries.enumerated() {
            let rebased = rebasedHitTestPoint(
                point,
                containerSize: containerSize,
                coordinateViewWindowMinY: coordinateViewWindowMinY,
                coordinateViewWindowOrigin: coordinateViewWindowOrigin,
                targetCoordinateOriginInWindow: entry.target.coordinateOriginInWindow
            )
            let searchRects = usingInflatedRects ? entry.hitRects : entry.rects
            guard searchRects.contains(where: { $0.contains(rebased.point) }) else { continue }
            guard let candidate = bestRectCandidate(
                for: entry,
                point: rebased.point,
                rebaseX: rebased.rebaseX,
                rebaseY: rebased.rebaseY,
                usingInflatedRects: usingInflatedRects,
                index: index
            ) else { continue }
            if isBetter(candidate, than: best) {
                best = candidate
            }
        }
        return best
    }

    private func bestRectCandidate(
        for entry: Entry,
        point: CGPoint,
        rebaseX: CGFloat,
        rebaseY: CGFloat,
        usingInflatedRects: Bool,
        index: Int
    ) -> Candidate? {
        let searchRects = usingInflatedRects ? entry.hitRects : entry.rects
        return searchRects
            .enumerated()
            .filter { _, hitRect in hitRect.contains(point) }
            .map { rectIndex, hitRect in
                let rect = entry.rects[rectIndex]
                return Candidate(
                    target: entry.target,
                    rect: rect,
                    hitRect: hitRect,
                    hitTestPoint: point,
                    hitTestRebaseX: rebaseX,
                    hitTestRebaseY: rebaseY,
                    distance: distance(from: point, to: rect),
                    centerDistance: hypot(point.x - hitRect.midX, point.y - hitRect.midY),
                    area: hitRect.width * hitRect.height,
                    index: index
                )
            }
            .min { lhs, rhs in isBetter(lhs, than: rhs) }
    }

    private func isBetter(_ candidate: Candidate, than other: Candidate?) -> Bool {
        guard let other else { return true }
        if candidate.distance != other.distance {
            return candidate.distance < other.distance
        }
        if candidate.centerDistance != other.centerDistance {
            return candidate.centerDistance < other.centerDistance
        }
        if candidate.area != other.area {
            return candidate.area < other.area
        }
        return candidate.index < other.index
    }

    private func target(
        for candidate: Candidate,
        usedInflatedHitRect: Bool
    ) -> WebViewNativeLookupHitTarget {
        WebViewNativeLookupHitTarget(
            elementID: candidate.target.elementID,
            rects: candidate.target.rects,
            coordinateOriginInWindow: candidate.target.coordinateOriginInWindow,
            lookupPayload: candidate.target.lookupPayload,
            frameInfo: candidate.target.frameInfo,
            nativeLookupFrameKey: candidate.target.nativeLookupFrameKey,
            debugUsedInflatedHitRect: usedInflatedHitRect,
            debugHitRects: [candidate.hitRect],
            debugDistance: candidate.distance,
            debugCenterDistance: candidate.centerDistance,
            debugHitTestPoint: candidate.hitTestPoint,
            debugHitTestRebaseX: candidate.hitTestRebaseX,
            debugHitTestRebaseY: candidate.hitTestRebaseY
        )
    }

    private func makeEntries(for targets: [WebViewNativeLookupHitTarget]) -> [Entry] {
        targets.compactMap { target in
            let rects = target.rects
                .filter { !$0.isNull && !$0.isEmpty }
            let hitRects = rects.map { $0.insetBy(dx: -hitSlop, dy: -hitSlop) }
            guard !hitRects.isEmpty else { return nil }
            return Entry(target: target, rects: rects, hitRects: hitRects)
        }
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx: CGFloat
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0
        }
        let dy: CGFloat
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0
        }
        if dx == 0 {
            return dy
        }
        if dy == 0 {
            return dx
        }
        return hypot(dx, dy)
    }

    public func containsTarget(at point: CGPoint, in containerSize: CGSize? = nil) -> Bool {
        hitTarget(at: point, in: containerSize) != nil
    }

    public func containsExactTarget(at point: CGPoint, in containerSize: CGSize? = nil) -> Bool {
        exactHitTarget(at: point, in: containerSize) != nil
    }

    public func containsClaimableTarget(at point: CGPoint, in containerSize: CGSize? = nil) -> Bool {
        hitTarget(at: point, in: containerSize) != nil
    }

    public func diagnostics(
        at point: CGPoint,
        limit: Int = 5,
        in containerSize: CGSize? = nil,
        coordinateViewWindowMinY: CGFloat? = nil,
        coordinateViewWindowOrigin: CGPoint? = nil
    ) -> [[String: Any]] {
        guard isEnabled else {
            return [
                [
                    "mode": "disabled",
                    "candidates": []
                ]
            ]
        }
        let exact = diagnosticCandidates(
            at: point,
            usingInflatedRects: false,
            limit: limit,
            containerSize: containerSize,
            coordinateViewWindowMinY: coordinateViewWindowMinY,
            coordinateViewWindowOrigin: coordinateViewWindowOrigin
        )
        let inflated = diagnosticCandidates(
            at: point,
            usingInflatedRects: true,
            limit: limit,
            containerSize: containerSize,
            coordinateViewWindowMinY: coordinateViewWindowMinY,
            coordinateViewWindowOrigin: coordinateViewWindowOrigin
        )
        return [
            [
                "mode": "exact",
                "candidates": exact
            ],
            [
                "mode": "inflated",
                "candidates": inflated
            ]
        ]
    }

    private func diagnosticCandidates(
        at point: CGPoint,
        usingInflatedRects: Bool,
        limit: Int,
        containerSize: CGSize?,
        coordinateViewWindowMinY: CGFloat?,
        coordinateViewWindowOrigin: CGPoint?
    ) -> [[String: Any]] {
        var candidates: [(candidate: Candidate, hitRect: CGRect)] = []
        for (entryIndex, entry) in entries.enumerated() {
            let rebased = rebasedHitTestPoint(
                point,
                containerSize: containerSize,
                coordinateViewWindowMinY: coordinateViewWindowMinY,
                coordinateViewWindowOrigin: coordinateViewWindowOrigin,
                targetCoordinateOriginInWindow: entry.target.coordinateOriginInWindow
            )
            let searchRects = usingInflatedRects ? entry.hitRects : entry.rects
            for (rectIndex, hitRect) in searchRects.enumerated() {
                let rect = entry.rects[rectIndex]
                let candidate = Candidate(
                    target: entry.target,
                    rect: rect,
                    hitRect: hitRect,
                    hitTestPoint: rebased.point,
                    hitTestRebaseX: rebased.rebaseX,
                    hitTestRebaseY: rebased.rebaseY,
                    distance: distance(from: rebased.point, to: rect),
                    centerDistance: hypot(rebased.point.x - hitRect.midX, rebased.point.y - hitRect.midY),
                    area: hitRect.width * hitRect.height,
                    index: entryIndex
                )
                candidates.append((candidate, hitRect))
            }
        }
        candidates.sort { lhs, rhs in isBetter(lhs.candidate, than: rhs.candidate) }
        return candidates.prefix(limit).map { item in
            let candidate = item.candidate
            let hitRect = item.hitRect
            return [
                "elementID": candidate.target.elementID,
                "surface": candidate.target.lookupPayload?["surface"] as? String ?? "",
                "kind": usingInflatedRects ? "inflated" : "exact",
                "contains": hitRect.contains(candidate.hitTestPoint),
                "distance": candidate.distance,
                "centerDistance": candidate.centerDistance,
                "hitTestX": candidate.hitTestPoint.x,
                "hitTestY": candidate.hitTestPoint.y,
                "hitTestRebaseX": candidate.hitTestRebaseX,
                "hitTestRebaseY": candidate.hitTestRebaseY,
                "rectX": candidate.rect.minX,
                "rectW": candidate.rect.width,
                "rectY": candidate.rect.minY,
                "rectH": candidate.rect.height,
            ] as [String : Any]
        }
    }

    public func handleTap(
        at point: CGPoint,
        in containerSize: CGSize? = nil,
        coordinateViewWindowMinY: CGFloat? = nil,
        coordinateViewWindowOrigin: CGPoint? = nil
    ) -> Bool {
        let exactCandidate = bestCandidate(
            at: point,
            usingInflatedRects: false,
            containerSize: containerSize,
            coordinateViewWindowMinY: coordinateViewWindowMinY,
            coordinateViewWindowOrigin: coordinateViewWindowOrigin
        )
        let inflatedCandidate = exactCandidate == nil
            ? bestCandidate(
                at: point,
                usingInflatedRects: true,
                containerSize: containerSize,
                coordinateViewWindowMinY: coordinateViewWindowMinY,
                coordinateViewWindowOrigin: coordinateViewWindowOrigin
            )
            : nil
        guard let candidate = exactCandidate ?? inflatedCandidate else {
            return false
        }
        let target = target(
            for: candidate,
            usedInflatedHitRect: exactCandidate == nil
        )
        onHit?(WebViewNativeLookupHit(
            elementID: target.elementID,
            point: point,
            rects: target.rects,
            coordinateOriginInWindow: target.coordinateOriginInWindow,
            lookupPayload: target.lookupPayload,
            debugUsedInflatedHitRect: target.debugUsedInflatedHitRect,
            debugHitRects: target.debugHitRects,
            debugDistance: target.debugDistance,
            debugCenterDistance: target.debugCenterDistance,
            debugHitTestPoint: target.debugHitTestPoint,
            debugHitTestRebaseX: target.debugHitTestRebaseX,
            debugHitTestRebaseY: target.debugHitTestRebaseY,
            frameInfo: target.frameInfo
        ))
        return true
    }

    public func handleTap(
        on target: WebViewNativeLookupHitTarget,
        at point: CGPoint,
        in containerSize: CGSize? = nil,
        coordinateViewWindowMinY: CGFloat? = nil,
        coordinateViewWindowOrigin: CGPoint? = nil
    ) -> Bool {
        let rebased = rebasedHitTestPoint(
            point,
            containerSize: containerSize,
            coordinateViewWindowMinY: coordinateViewWindowMinY,
            coordinateViewWindowOrigin: coordinateViewWindowOrigin,
            targetCoordinateOriginInWindow: target.coordinateOriginInWindow
        )
        onHit?(WebViewNativeLookupHit(
            elementID: target.elementID,
            point: point,
            rects: target.rects,
            coordinateOriginInWindow: target.coordinateOriginInWindow,
            lookupPayload: target.lookupPayload,
            debugUsedInflatedHitRect: target.debugUsedInflatedHitRect,
            debugHitRects: target.debugHitRects,
            debugDistance: target.debugDistance,
            debugCenterDistance: target.debugCenterDistance,
            debugHitTestPoint: rebased.point,
            debugHitTestRebaseX: rebased.rebaseX,
            debugHitTestRebaseY: rebased.rebaseY,
            frameInfo: target.frameInfo
        ))
        return true
    }

    public func completePressedTargetHandoff(elementID: String?) {
        onPressedTargetHandoffCompleted?(elementID)
    }

    static func debugPointString(_ point: CGPoint) -> String {
        "{\(point.x), \(point.y)}"
    }

    static func debugSizeString(_ size: CGSize) -> String {
        "{\(size.width), \(size.height)}"
    }

    static func debugRectStrings<S: Sequence>(_ rects: S) -> [String] where S.Element == CGRect {
        rects.map { "{{\($0.origin.x), \($0.origin.y)}, {\($0.width), \($0.height)}}" }
    }
}

public struct WebViewUserScript: Equatable, Hashable, Sendable {
    public let source: String
    public let injectionTime: WKUserScriptInjectionTime
    public let isForMainFrameOnly: Bool
    public let world: WKContentWorld?
    public let allowedDomains: Set<String>
    
    @MainActor
    public lazy var webKitUserScript: WKUserScript = {
        return WKUserScript(
            source: source,
            injectionTime: injectionTime,
            forMainFrameOnly: isForMainFrameOnly,
            in: world ?? .page
        )
    }()
    
    public static func == (lhs: WebViewUserScript, rhs: WebViewUserScript) -> Bool {
        lhs.source == rhs.source
        && lhs.injectionTime == rhs.injectionTime
        && lhs.isForMainFrameOnly == rhs.isForMainFrameOnly
        && lhs.world == rhs.world
        && lhs.allowedDomains == rhs.allowedDomains
    }
    
    public init(
        source: String,
        injectionTime: WKUserScriptInjectionTime,
        forMainFrameOnly: Bool,
        in world: WKContentWorld? = nil,
        allowedDomains: Set<String> = Set()
    ) {
        self.source = source
        self.injectionTime = injectionTime
        self.isForMainFrameOnly = forMainFrameOnly
        self.world = world
        self.allowedDomains = allowedDomains
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(injectionTime)
        hasher.combine(isForMainFrameOnly)
        hasher.combine(world)
        hasher.combine(allowedDomains)
    }
}

public enum DarkModeSetting: String, CaseIterable, Identifiable, Sendable {
    case system
    case darkModeOverride
    case alwaysLightMode
    
    public var id: String { self.rawValue }
    
    public var title: String {
        switch self {
        case .system:
            return "Use System Setting"
        case .darkModeOverride:
            return "Always Dark Mode"
        case .alwaysLightMode:
            return "Always Light Mode"
        }
    }
}

@MainActor
public final class WebViewPaginationController {
    private weak var webView: WKWebView?
    private(set) public var desiredConfiguration: WebViewPaginationConfiguration = .disabled
    private(set) public var lastAppliedConfiguration: WebViewPaginationConfiguration?
    private(set) public var lastAppliedIdentity: WebViewPaginationStructuralIdentity?
    private(set) public var lastAppliedHostIdentifier: String?
    private(set) public var lastPageCount: Int?
    private(set) public var lastApplyReason: String?
    private(set) public var lastUpdatedAt: Date?

    public init() {}

    public func attach(webView: WKWebView) -> WebViewPaginationState {
        self.webView = webView
        return currentState(reason: "attach")
    }

    public func detach() -> WebViewPaginationState {
        webView = nil
        return currentState(reason: "detach")
    }

    public func apply(
        _ configuration: WebViewPaginationConfiguration,
        reason: String
    ) throws -> WebViewPaginationState {
        desiredConfiguration = configuration
        lastApplyReason = reason
        lastUpdatedAt = Date()

        guard let webView else {
            return currentState(reason: reason)
        }

        let hostIdentifier = Self.hostIdentifier(for: webView)
        let resolved = configuration.resolvingEffectivePageLength(using: webView.bounds.size)
        let identity = resolved.structuralIdentity(using: webView.bounds.size)
        let shouldApply = identity != lastAppliedIdentity || hostIdentifier != lastAppliedHostIdentifier
        #if os(iOS)
        if webViewLayoutShouldLog(webView: webView, configuration: resolved) {
            var layoutPayload = webViewLayoutPaginationPayload(configuration: resolved, reason: reason)
            layoutPayload["host"] = hostIdentifier
            layoutPayload["willApply"] = shouldApply
            layoutPayload.merge(webViewLayoutScrollPayload(webView: webView), uniquingKeysWith: { lhs, _ in lhs })
            webViewLayoutDebugLog("pagination.apply.begin", layoutPayload)
        }
        #endif
        if shouldApply {
            try applySelectors(resolved, to: webView)
            lastAppliedConfiguration = resolved
            lastAppliedIdentity = identity
            lastAppliedHostIdentifier = hostIdentifier
            webViewPaginationDebugLog(
                "apply",
                [
                    "host": hostIdentifier,
                    "reason": reason,
                    "mode": resolved.mode.rawValue,
                    "storedPageLength": resolved.storedPageLength,
                    "effectivePageLength": resolved.effectivePageLength,
                    "gapBetweenPages": resolved.gapBetweenPages,
                    "behavesLikeColumns": resolved.behavesLikeColumns,
                    "layoutSize": "\(resolved.layoutSize.width)x\(resolved.layoutSize.height)"
                ]
            )
        } else {
            webViewPaginationDebugLog(
                "apply.skipped",
                [
                    "host": hostIdentifier,
                    "reason": reason,
                    "mode": resolved.mode.rawValue
                ]
            )
        }
        lastPageCount = try queryPageCount(on: webView)
        #if os(iOS)
        if webViewLayoutShouldLog(webView: webView, configuration: resolved) {
            var layoutPayload = webViewLayoutPaginationPayload(configuration: resolved, reason: reason)
            layoutPayload["host"] = hostIdentifier
            layoutPayload["applied"] = shouldApply
            layoutPayload["pageCount"] = lastPageCount ?? -1
            layoutPayload.merge(webViewLayoutScrollPayload(webView: webView), uniquingKeysWith: { lhs, _ in lhs })
            webViewLayoutDebugLog("pagination.apply.end", layoutPayload)
        }
        #endif
        return currentState(reason: reason)
    }

    public func refreshReadback(reason: String) throws -> WebViewPaginationState {
        lastApplyReason = reason
        lastUpdatedAt = Date()
        if let webView {
            lastPageCount = try queryPageCount(on: webView)
            #if os(iOS)
            let configuration = lastAppliedConfiguration ?? desiredConfiguration
            if webViewLayoutShouldLog(webView: webView, configuration: configuration) {
                var layoutPayload = webViewLayoutPaginationPayload(configuration: configuration, reason: reason)
                layoutPayload["host"] = Self.hostIdentifier(for: webView)
                layoutPayload["pageCount"] = lastPageCount ?? -1
                layoutPayload.merge(webViewLayoutScrollPayload(webView: webView), uniquingKeysWith: { lhs, _ in lhs })
                webViewLayoutDebugLog("pagination.readback", layoutPayload)
            }
            #endif
        } else {
            lastPageCount = nil
        }
        return currentState(reason: reason)
    }

    public func currentState(reason: String? = nil) -> WebViewPaginationState {
        let mountedHostIdentifier = webView.map(Self.hostIdentifier(for:))
        return WebViewPaginationState(
            desiredConfiguration: desiredConfiguration,
            appliedConfiguration: lastAppliedConfiguration,
            pageCount: lastPageCount,
            mountedHostIdentifier: mountedHostIdentifier,
            appliedHostIdentifier: lastAppliedHostIdentifier,
            isAppliedToMountedHost: mountedHostIdentifier != nil && mountedHostIdentifier == lastAppliedHostIdentifier,
            usedViewLengthInference: (lastAppliedConfiguration ?? desiredConfiguration).usesViewLength,
            lastApplyReason: reason ?? lastApplyReason,
            lastUpdatedAt: lastUpdatedAt
        )
    }

    public static func hostIdentifier(for webView: WKWebView) -> String {
        String(describing: ObjectIdentifier(webView))
    }

    private func applySelectors(_ configuration: WebViewPaginationConfiguration, to webView: WKWebView) throws {
        try setInt(configuration.mode.rawValue, selectorName: PrivatePaginationSelector.setPaginationMode.name, on: webView)
        try setBool(configuration.behavesLikeColumns, selectorName: PrivatePaginationSelector.setPaginationBehavesLikeColumns.name, on: webView)
        try setDouble(configuration.storedPageLength, selectorName: PrivatePaginationSelector.setPageLength.name, on: webView)
        try setDouble(configuration.gapBetweenPages, selectorName: PrivatePaginationSelector.setGapBetweenPages.name, on: webView)
    }

    private func queryPageCount(on webView: WKWebView) throws -> Int {
        let selectorName = PrivatePaginationSelector.pageCount.name
        let selector = Selector(selectorName)
        guard webView.responds(to: selector) else {
            throw WebViewPaginationError.missingSelector(selectorName)
        }
        typealias Function = @convention(c) (AnyObject, Selector) -> Int
        let implementation = webView.method(for: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(webView, selector)
    }

    private func setInt(_ value: Int, selectorName: String, on webView: WKWebView) throws {
        let selector = Selector(selectorName)
        guard webView.responds(to: selector) else {
            throw WebViewPaginationError.missingSelector(selectorName)
        }
        typealias Function = @convention(c) (AnyObject, Selector, Int) -> Void
        let implementation = webView.method(for: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        function(webView, selector, value)
    }

    private func setBool(_ value: Bool, selectorName: String, on webView: WKWebView) throws {
        let selector = Selector(selectorName)
        guard webView.responds(to: selector) else {
            throw WebViewPaginationError.missingSelector(selectorName)
        }
        typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Void
        let implementation = webView.method(for: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        function(webView, selector, value)
    }

    private func setDouble(_ value: CGFloat, selectorName: String, on webView: WKWebView) throws {
        let selector = Selector(selectorName)
        guard webView.responds(to: selector) else {
            throw WebViewPaginationError.missingSelector(selectorName)
        }
        typealias Function = @convention(c) (AnyObject, Selector, Double) -> Void
        let implementation = webView.method(for: selector)
        let function = unsafeBitCast(implementation, to: Function.self)
        function(webView, selector, Double(value))
    }

    private enum PrivatePaginationSelector {
        case setPaginationMode
        case setPaginationBehavesLikeColumns
        case setPageLength
        case setGapBetweenPages
        case pageCount

        var name: String {
            switch self {
            case .setPaginationMode:
                return Self.decode([
                    95, 115, 101, 116, 80, 97, 103, 105, 110, 97, 116, 105, 111, 110, 77, 111, 100, 101, 58
                ])
            case .setPaginationBehavesLikeColumns:
                return Self.decode([
                    95, 115, 101, 116, 80, 97, 103, 105, 110, 97, 116, 105, 111, 110, 66, 101, 104, 97, 118, 101,
                    115, 76, 105, 107, 101, 67, 111, 108, 117, 109, 110, 115, 58
                ])
            case .setPageLength:
                return Self.decode([
                    95, 115, 101, 116, 80, 97, 103, 101, 76, 101, 110, 103, 116, 104, 58
                ])
            case .setGapBetweenPages:
                return Self.decode([
                    95, 115, 101, 116, 71, 97, 112, 66, 101, 116, 119, 101, 101, 110, 80, 97, 103, 101, 115, 58
                ])
            case .pageCount:
                return Self.decode([
                    95, 112, 97, 103, 101, 67, 111, 117, 110, 116
                ])
            }
        }

        private static func decode(_ codeUnits: [UInt8]) -> String {
            String(decoding: codeUnits, as: UTF8.self)
        }
    }
}

@MainActor
public class WebViewCoordinator: NSObject {
    private let webView: WebView
    
    var navigator: WebViewNavigator
    var scriptCaller: WebViewScriptCaller?
    var config: WebViewConfig
    var lifecycleConfig: WebViewLifecycleConfig = .default
    weak var webViewPool: WebViewPool?
    var registeredMessageHandlerNames = Set<String>()
    weak var lastUserContentController: WKUserContentController?
    weak var lastUserScriptsContentController: WKUserContentController?
    var lastInstalledScriptsSignature: String?
    var lastAppliedConfigurationState: WebViewConfigurationState?
    var compiledContentRules = [String: WKContentRuleList]()
    var lastAppliedContentRules: String?
    var shouldReapplyContentRulesAfterLoad = false
    private var urlObservation: NSKeyValueObservation?
    private var estimatedProgressObservation: NSKeyValueObservation?
    private var isLoadingObservation: NSKeyValueObservation?
#if os(iOS)
    private var sampledPageTopColorObservation: WebViewStringKeyPathObserver<WKWebView, UIColor>?
#endif
    private var latestIsLoading = false
    private var latestEstimatedProgress = 0.0
    private var lastProgressUpdateTime: CFTimeInterval = 0
    private var lastEmittedProgress: Double?
    private var pendingProgressUpdateTask: Task<Void, Never>?
    private var loadingProgressUpdateGeneration: Int = 0
    private var pendingPaginationApplyTask: Task<Void, Never>?
    private var pendingPaginationStateTask: Task<Void, Never>?
    private var pendingWebViewBindingTask: Task<Void, Never>?
    private var lastEpubReaderDocStateSignature: String?
    private var lastMainFrameNavigationRequestURL: URL?
    private var lastMainFrameNavigationSourceURL: URL?
    private var lastMainFrameNavigationMainDocumentURL: URL?
    private var lastMainFrameNavigationType: WKNavigationType?
    var lastHostUpdateContextSignature: String?
    private let progressUpdateMinimumInterval: CFTimeInterval = 0.12
    private let progressUpdateMinimumDelta: Double = 0.01
#if os(iOS)
    private weak var snapshotHostController: WebViewController?
    weak var hostLayoutController: WebViewController?
    private var awaitingSnapshotReload = false
    private var snapshotReloadCommitted = false
    private var snapshotReloadDocumentReady = false
    private var pendingSnapshotRestore = false
    private var activeSnapshotCacheKey: WebViewSnapshotCacheKey?
#endif

#if os(iOS)
    @MainActor
    private func reapplyHostObscuredInsetsForNavigation(_ reason: String) {
        hostLayoutController?.reapplyObscuredInsets(reason: reason)
    }
#endif
    
    // UIScrollViewDelegate
    internal enum NavigationScrollAxis: Equatable {
        case vertical
        case horizontal
    }
    internal var lastContentOffset: CGPoint = .zero
    internal var accumulatedScrollOffset: CGFloat = 0
    internal var navigationScrollAxis: NavigationScrollAxis = .vertical
    internal var horizontalForwardSign: CGFloat = 1
#if os(iOS)
    internal var lastLayoutScrollPageSignature: String?
#endif
    internal var lastEnvHandlerNames: OrderedSet<String>? = nil
    public let paginationController = WebViewPaginationController()
    
    var onNavigationCommitted: ((WebViewState) -> Void)?
    var onNavigationFinished: ((WebViewState) -> Void)?
    var onNavigationFailed: ((WebViewState) -> Void)?
    var onURLChanged: ((WebViewState) -> Void)?
    var onNavigationAction: ((WKNavigationAction) async -> WKNavigationActionPolicy?)?
    var messageHandlers: WebViewMessageHandlers
    var messageHandlerNames: [String] {
        messageHandlers.handlers.keys.map { $0 }
    }
    var hideNavigationDueToScroll: Binding<Bool>
    var textSelection: Binding<String?>

#if os(iOS)
    private func logLookupPerf(_ message: String) {
        _ = message
    }

    @MainActor
    func unloadWebViewIfNeeded(controller: WebViewController) {
        guard lifecycleConfig.autoUnloadOnDisappear else { return }
        guard let pool = webViewPool else { return }
        guard !controller.isWebViewUnloaded else { return }

        Task { @MainActor in
            logLookupPerf("webview.unload.start url=\(controller.webView.url?.absoluteString ?? "<nil>")")
            let metrics = controller.snapshotSizeMetrics()
            logLookupPerf(
                "webview.unload.snapshot.prepare current=\(metrics.current) lastKnown=\(metrics.lastKnown) override=\(metrics.shouldOverride)"
            )
            let snapshot = await controller.captureSnapshot()
            if let snapshot {
                let size = snapshot.size
                logLookupPerf("webview.unload.snapshot.captured size=\(size)")
                if size.width > 2, size.height > 2 {
                    controller.showSnapshotOverlay(snapshot)
                    logLookupPerf("webview.unload.snapshot.overlay.shown")
                    snapshotHostController = controller
                    if let cacheKey = lifecycleConfig.snapshotCacheKey {
                        WebViewSnapshotCache.storeSnapshot(snapshot, height: size.height, for: cacheKey)
                        logLookupPerf(
                            "webview.unload.snapshot.cached widthBucket=\(cacheKey.widthBucket) htmlLength=\(cacheKey.htmlLength) height=\(size.height)"
                        )
                    }
                } else {
                    logLookupPerf("webview.unload.snapshot.skipped size=\(size)")
                }
            }
            tearDownBindingsForDetachedWebView(controller.webView)
            controller.detachWebView()
            pool.enqueue(controller.webView, resetURL: lifecycleConfig.idleLoadURL)
            controller.isWebViewUnloaded = true
            logLookupPerf("webview.unload.enqueued")
        }
    }

    @MainActor
    func prepareForReloadIfNeeded(controller: WebViewController) {
        guard lifecycleConfig.autoUnloadOnDisappear else { return }
        guard controller.isWebViewUnloaded else { return }
        guard snapshotHostController != nil else { return }
        logLookupPerf("webview.reload.prepare")
        pendingSnapshotRestore = true
        awaitingSnapshotReload = true
        snapshotReloadCommitted = false
        snapshotReloadDocumentReady = false
        snapshotHostController = snapshotHostController ?? controller
    }

    @MainActor
    private func cancelSnapshotReload() {
        logLookupPerf("webview.reload.cancel")
        pendingSnapshotRestore = false
        awaitingSnapshotReload = false
        snapshotReloadCommitted = false
        snapshotReloadDocumentReady = false
        snapshotHostController?.clearSnapshotOverlay()
        snapshotHostController = nil
    }

    @MainActor
    private func maybeHideSnapshotOverlay() {
        guard awaitingSnapshotReload else { return }
        guard snapshotReloadCommitted, snapshotReloadDocumentReady else { return }
        logLookupPerf("webview.reload.snapshot.hide")
        snapshotHostController?.clearSnapshotOverlay()
        snapshotHostController = nil
        awaitingSnapshotReload = false
        snapshotReloadCommitted = false
        snapshotReloadDocumentReady = false
    }

    @MainActor
    func applyCachedSnapshotIfAvailable(controller: WebViewController) {
        guard lifecycleConfig.autoUnloadOnDisappear else { return }
        guard pendingSnapshotRestore else { return }
        guard let cacheKey = lifecycleConfig.snapshotCacheKey else { return }
        guard activeSnapshotCacheKey != cacheKey else { return }
        guard let entry = WebViewSnapshotCache.entry(for: cacheKey),
              let image = entry.image else { return }

        logLookupPerf(
            "webview.reload.snapshot.cacheHit widthBucket=\(cacheKey.widthBucket) htmlLength=\(cacheKey.htmlLength) height=\(entry.height.map { String(describing: $0) } ?? "nil")"
        )
        snapshotHostController = controller
        controller.showSnapshotOverlay(image)
        pendingSnapshotRestore = false
        awaitingSnapshotReload = true
        snapshotReloadCommitted = false
        snapshotReloadDocumentReady = false
        activeSnapshotCacheKey = cacheKey
    }

    @MainActor
    func markSnapshotRestoreIfNeeded() {
        guard lifecycleConfig.autoUnloadOnDisappear else { return }
        pendingSnapshotRestore = true
    }
#endif
    
    init(
        webView: WebView,
        navigator: WebViewNavigator,
        scriptCaller: WebViewScriptCaller? = nil,
        config: WebViewConfig,
        messageHandlers: WebViewMessageHandlers,
        onNavigationCommitted: ((WebViewState) -> Void)?,
        onNavigationFinished: ((WebViewState) -> Void)?,
        onNavigationFailed: ((WebViewState) -> Void)?,
        onURLChanged: ((WebViewState) -> Void)? = nil,
        onNavigationAction: ((WKNavigationAction) async -> WKNavigationActionPolicy?)? = nil,
        hideNavigationDueToScroll: Binding<Bool>,
        textSelection: Binding<String?>
    ) {
        self.webView = webView
        self.navigator = navigator
        self.scriptCaller = scriptCaller
        self.config = config
        self.messageHandlers = messageHandlers
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onURLChanged = onURLChanged
        self.onNavigationAction = onNavigationAction
        self.hideNavigationDueToScroll = hideNavigationDueToScroll
        self.textSelection = textSelection
        
        // TODO: Make about:blank history initialization optional via configuration.
        //        if  webView.state.backList.isEmpty && webView.state.forwardList.isEmpty && webView.state.pageURL.absoluteString == "about:blank" {
        //            Task { @MainActor in
        //                webView.action = .load(URLRequest(url: URL(string: "about:blank")!))
        //            }
        //        }
    }
    
    deinit {
        urlObservation?.invalidate()
    }

    @MainActor
    private func invalidateWebViewObservations() {
        urlObservation?.invalidate()
        urlObservation = nil
        estimatedProgressObservation?.invalidate()
        estimatedProgressObservation = nil
        isLoadingObservation?.invalidate()
        isLoadingObservation = nil
#if os(iOS)
        sampledPageTopColorObservation?.invalidate()
        sampledPageTopColorObservation = nil
#endif
        pendingProgressUpdateTask?.cancel()
        pendingProgressUpdateTask = nil
        pendingPaginationApplyTask?.cancel()
        pendingPaginationApplyTask = nil
        pendingPaginationStateTask?.cancel()
        pendingPaginationStateTask = nil
        pendingWebViewBindingTask?.cancel()
        pendingWebViewBindingTask = nil
        lastHostUpdateContextSignature = nil
        lastEmittedProgress = nil
        lastProgressUpdateTime = 0
    }

    @MainActor
    private func clearScriptCallerBinding() {
        scriptCaller?.asyncCaller = nil
    }

    @MainActor
    private func removeMessageHandlers(for webView: WKWebView?) {
        guard let userContentController = webView?.configuration.userContentController else {
            registeredMessageHandlerNames.removeAll()
            lastEnvHandlerNames = nil
            lastUserContentController = nil
            return
        }
        for messageHandlerName in registeredMessageHandlerNames {
            userContentController.removeScriptMessageHandler(forName: messageHandlerName)
            userContentController.removeScriptMessageHandler(forName: messageHandlerName, contentWorld: .page)
        }
        registeredMessageHandlerNames.removeAll()
        lastEnvHandlerNames = nil
        lastUserContentController = nil
    }

    @MainActor
    func tearDownBindingsForDetachedWebView(_ webView: WKWebView?) {
        pendingWebViewBindingTask?.cancel()
        pendingWebViewBindingTask = nil
        let isCurrentWebView = webView == nil || navigator.webView === webView
        removeMessageHandlers(for: webView)
        guard isCurrentWebView else {
            return
        }
        lastUserScriptsContentController = nil
        lastInstalledScriptsSignature = nil
        lastAppliedConfigurationState = nil
        navigator.webView = nil
        clearScriptCallerBinding()
        invalidateWebViewObservations()
        schedulePaginationStateUpdate(paginationController.detach())
    }

    @MainActor
    private func schedulePaginationStateUpdate(_ paginationState: WebViewPaginationState) {
        pendingPaginationStateTask?.cancel()
        pendingPaginationStateTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            var newState = self.webView.state
            newState.paginationState = paginationState.applying(self.navigator.paginationStateEnrichment)
            if newState != self.webView.state {
                self.webView.state = newState
            }
            self.pendingPaginationStateTask = nil
        }
    }

    @MainActor
    func scheduleWebViewBinding(_ webView: WKWebView, paginationReason: String) {
        pendingWebViewBindingTask?.cancel()
        pendingWebViewBindingTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.setWebView(webView)
            self.applyPaginationConfigurationIfNeeded(reason: paginationReason)
            self.pendingWebViewBindingTask = nil
        }
    }

    @MainActor
    func schedulePaginationConfigurationApply(reason: String, for webView: WKWebView) {
        let mountedHostIdentifier = paginationController.currentState().mountedHostIdentifier
        let targetHostIdentifier = WebViewPaginationController.hostIdentifier(for: webView)
        guard mountedHostIdentifier == targetHostIdentifier else { return }

        pendingPaginationApplyTask?.cancel()
        pendingPaginationApplyTask = Task { @MainActor [weak self, weak webView] in
            await Task.yield()
            guard let self, let webView else { return }
            let currentMountedHostIdentifier = self.paginationController.currentState().mountedHostIdentifier
            let currentTargetHostIdentifier = WebViewPaginationController.hostIdentifier(for: webView)
            guard currentMountedHostIdentifier == currentTargetHostIdentifier else {
                self.pendingPaginationApplyTask = nil
                return
            }
            self.applyPaginationConfigurationIfNeeded(reason: reason)
            self.pendingPaginationApplyTask = nil
        }
    }
    
    @MainActor
    func setWebView(_ webView: WKWebView) {
        navigator.logAttachmentEvent("coordinator.setWebView.beforeAssign", webView: webView)
        navigator.webView = webView
        (webView as? EnhancedWKWebView)?.onDidMoveToWindow = { [weak navigator, weak webView] isAttached in
            guard let navigator, let webView else { return }
            Task { @MainActor in
                navigator.logAttachmentEvent("enhancedWKWebView.didMove attached=\(isAttached)", webView: webView)
                navigator.handleWindowAttachmentChanged(isAttached: isAttached, webView: webView)
            }
        }
        #if os(macOS)
        navigator.handleWindowAttachmentChanged(isAttached: webView.window != nil || webView.superview != nil, webView: webView)
        #endif
        schedulePaginationStateUpdate(paginationController.attach(webView: webView))
        navigator.handleWindowAttachmentChanged(isAttached: webView.window != nil || webView.superview != nil, webView: webView)

        invalidateWebViewObservations()

        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, change in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let maybeNewURL = change.newValue, let newURL = maybeNewURL, newURL != webView.url else { return }
                _ = setLoading(
                    false,
                    pageURL: newURL,
                    canGoBack: webView.canGoBack,
                    canGoForward: webView.canGoForward,
                    backList: webView.backForwardList.backList,
                    forwardList: webView.backForwardList.forwardList)
            }
        }

        estimatedProgressObservation = webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, change in
            guard let self else { return }
            guard let progress = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.updateLoadingProgress(
                    isLoading: nil,
                    estimatedProgress: progress,
                    source: "estimatedProgressKVO"
                )
            }
        }

        isLoadingObservation = webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, change in
            guard let self else { return }
            guard let isLoading = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.updateLoadingProgress(
                    isLoading: isLoading,
                    estimatedProgress: nil,
                    source: "isLoadingKVO"
                )
            }
        }

#if os(iOS)
        if config.usesSampledPageTopColorForUnderPageBackground,
           manabiCanUseSampledPageTopColorBackground() {
            sampledPageTopColorObservation = WebViewStringKeyPathObserver(
                object: webView,
                keyPath: "_sampl\("edPageTopC")olor"
            ) { [weak self, weak webView] observedColor in
                guard let self else { return }
                Task { @MainActor [weak self, weak webView] in
                    guard let self, let webView else { return }
                    let sampledColor = webView.sampledPageTopColor
                    webView.logManabiSampledPageTopDOMProbe(reason: "sampledPageTopColor.changed")
                    if #available(iOS 15.0, *) {
                        self.applySampledPageTopColorChange(
                            webView: webView,
                            observedColor: observedColor,
                            reason: "sampledPageTopColor.changed"
                        )
                    }
                }
            }
        }
#endif
    }

#if os(iOS)
    @MainActor
    private func beginSampledPageTopColorNavigation(_ webView: WKWebView, reason: String) {
        webView.applyUnderPageFallbackBackgroundColor(config: config, reason: reason)
    }

    @available(iOS 15.0, *)
    @MainActor
    private func applySampledPageTopColorChange(webView: WKWebView, observedColor: UIColor?, reason: String) {
        guard observedColor != nil else {
            webView.applyUnderPageFallbackBackgroundColor(config: config, reason: reason)
            return
        }

        webView.applyUnderPageBackgroundColor(config: config, allowSampledPageTopColor: true)
        if let resolvedUnderPageColor = webView.resolvedUnderPageBackgroundColor(
            config: config,
            allowSampledPageTopColor: true
        ) {
            webView.scrollView.backgroundColor = resolvedUnderPageColor
        }
        webView.applyConfiguredBackgroundForReaderDocumentIfNeeded(
            config: config,
            reason: reason
        )
    }
#endif

    @MainActor
    func applyPaginationConfigurationIfNeeded(reason: String) {
        do {
            let paginationState = try paginationController.apply(config.paginationConfiguration, reason: reason)
            schedulePaginationStateUpdate(paginationState)
        } catch {
            webViewPaginationDebugLog(
                "apply.error",
                [
                    "reason": reason,
                    "error": error.localizedDescription,
                    "host": paginationController.currentState().mountedHostIdentifier ?? "nil"
                ]
            )
            #if os(iOS)
            if let webView = navigator.webView {
                var payload = webViewLayoutScrollPayload(
                    webView: webView,
                    configuration: paginationController.currentState().appliedConfiguration ?? config.paginationConfiguration
                )
                payload["reason"] = reason
                payload["error"] = error.localizedDescription
                webViewLayoutDebugLog("pagination.apply.error", payload)
            }
            #endif
        }
    }

    @MainActor
    func refreshPaginationReadback(reason: String) {
        do {
            let paginationState = try paginationController.refreshReadback(reason: reason)
            schedulePaginationStateUpdate(paginationState)
        } catch {
            webViewPaginationDebugLog(
                "readback.error",
                [
                    "reason": reason,
                    "error": error.localizedDescription,
                    "host": paginationController.currentState().mountedHostIdentifier ?? "nil"
                ]
            )
            #if os(iOS)
            if let webView = navigator.webView {
                var payload = webViewLayoutScrollPayload(
                    webView: webView,
                    configuration: paginationController.currentState().appliedConfiguration ?? config.paginationConfiguration
                )
                payload["reason"] = reason
                payload["error"] = error.localizedDescription
                webViewLayoutDebugLog("pagination.readback.error", payload)
            }
            #endif
        }
    }

    @MainActor
    private func logEpubNavigationTransition(_ stage: String, webView: WKWebView, requestURL: URL? = nil) {
#if DEBUG
        let currentURL = webView.url
        let targetURL = requestURL ?? lastMainFrameNavigationRequestURL ?? navigator.activeReaderLoadRequestURL(for: currentURL)
        let sourceURL = lastMainFrameNavigationSourceURL ?? self.webView.state.pageURL
        let isRelevant = isEpubLikeURL(targetURL) || isEpubLikeURL(currentURL) || isEpubLikeURL(sourceURL)
        guard isRelevant else { return }

        let backList = webView.backForwardList.backList
        let forwardList = webView.backForwardList.forwardList
        let navigationType = lastMainFrameNavigationType.map(navigationTypeDescription) ?? "nil"
#endif
    }
    
    @discardableResult func setLoading(
        _ isLoading: Bool,
        pageURL: URL? = nil,
        isProvisionallyNavigating: Bool? = nil,
        canGoBack: Bool? = nil,
        canGoForward: Bool? = nil,
        backList: [WKBackForwardListItem]? = nil,
        forwardList: [WKBackForwardListItem]? = nil,
        error: Error? = nil
    ) -> WebViewState {
        var newState = webView.state
        newState.isLoading = isLoading
        var pageURLChanged = false
        if let pageURL {
            if pageURL != webView.state.pageURL {
                pageURLChanged = true
            }
            newState.pageURL = pageURL
        }
        if let isProvisionallyNavigating {
            newState.isProvisionallyNavigating = isProvisionallyNavigating
        }
        if let canGoBack {
            newState.canGoBack = canGoBack
        }
        if let canGoForward {
            newState.canGoForward = canGoForward
        }
        if let backList {
            newState.backList = backList
        }
        if let forwardList {
            newState.forwardList = forwardList
        }
        if let error {
            newState.error = error
        }
        //        debugPrint("# new state:", newState, "old:", webView.state)
        webView.state = newState
        
        if pageURLChanged {
            onURLChanged?(newState)
        }

        updateLoadingProgress(
            isLoading: isLoading,
            estimatedProgress: navigator.webView?.estimatedProgress,
            source: "setLoading"
        )
            
        return newState
    }

    @MainActor
    private func updateLoadingProgress(isLoading: Bool?, estimatedProgress: Double?, source: String) {
        loadingProgressUpdateGeneration &+= 1
        let generation = loadingProgressUpdateGeneration
        let previousLatestIsLoading = latestIsLoading
        let previousLatestEstimatedProgress = latestEstimatedProgress
        if let isLoading {
            latestIsLoading = isLoading
        }
        if let estimatedProgress {
            latestEstimatedProgress = estimatedProgress
        }

        let clampedProgress = max(0, min(latestEstimatedProgress, 1))
        let progress: Double? = latestIsLoading ? clampedProgress : nil
        let now = CFAbsoluteTimeGetCurrent()

        let shouldDeferUntilProvisionalStart = isInternalReaderLoaderURL(navigator.readerLoadRequestedURL)
            && navigator.readerLoadProvisionalStartedAt == nil
            && source != "setLoading"
        if shouldDeferUntilProvisionalStart {
            pendingProgressUpdateTask?.cancel()
            pendingProgressUpdateTask = nil
            return
        }

        let shouldEmitImmediately: Bool
        if progress == nil || lastEmittedProgress == nil {
            shouldEmitImmediately = true
        } else if let lastEmittedProgress, progress ?? 0 < lastEmittedProgress {
            shouldEmitImmediately = true
        } else if let lastEmittedProgress, abs((progress ?? 0) - lastEmittedProgress) >= progressUpdateMinimumDelta {
            shouldEmitImmediately = true
        } else {
            let elapsed = now - lastProgressUpdateTime
            shouldEmitImmediately = elapsed >= progressUpdateMinimumInterval
        }

        if shouldEmitImmediately {
            emitLoadingProgress(progress, now: now)
        } else {
            scheduleLoadingProgressUpdate(progress, now: now, generation: generation)
        }
    }

    @MainActor
    private func scheduleLoadingProgressUpdate(_ progress: Double?, now: CFTimeInterval, generation: Int) {
        pendingProgressUpdateTask?.cancel()
        let elapsed = now - lastProgressUpdateTime
        let delay = max(0, progressUpdateMinimumInterval - elapsed)
        guard delay > 0 else {
            emitLoadingProgress(progress, now: CFAbsoluteTimeGetCurrent())
            return
        }
        pendingProgressUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            guard self.loadingProgressUpdateGeneration == generation else { return }
            let currentProgress: Double? = self.latestIsLoading
                ? max(0, min(self.latestEstimatedProgress, 1))
                : nil
            self.emitLoadingProgress(currentProgress, now: CFAbsoluteTimeGetCurrent())
        }
    }

    @MainActor
    private func emitLoadingProgress(_ progress: Double?, now: CFTimeInterval) {
        pendingProgressUpdateTask?.cancel()
        pendingProgressUpdateTask = nil

        guard webView.state.loadingProgress != progress else { return }
        let previousProgress = webView.state.loadingProgress

        lastProgressUpdateTime = now
        lastEmittedProgress = progress

        var newState = webView.state
        newState.loadingProgress = progress
        webView.state = newState
        readerLoadLog(
            "webView.loadingProgress.emit",
            [
                "currentURL": navigator.webView?.url?.absoluteString ?? "nil",
                "isLoading": "\(webView.state.isLoading)",
                "nextProgress": progress.map { String(format: "%.3f", $0) } ?? "nil",
                "previousProgress": previousProgress.map { String(format: "%.3f", $0) } ?? "nil"
            ]
        )
    }

    @MainActor
    fileprivate func forceClearLoadingIndicators(reason: String, pageURL: URL?) {
        let effectivePageURL = pageURL ?? navigator.webView?.url ?? webView.state.pageURL
        let hadLoadingState = webView.state.isLoading || webView.state.loadingProgress != nil || latestIsLoading
        guard hadLoadingState else {
            return
        }

        pendingProgressUpdateTask?.cancel()
        pendingProgressUpdateTask = nil
        latestIsLoading = false
        latestEstimatedProgress = 0
        lastProgressUpdateTime = CFAbsoluteTimeGetCurrent()
        lastEmittedProgress = nil

        var newState = setLoading(
            false,
            pageURL: effectivePageURL,
            isProvisionallyNavigating: false,
            canGoBack: navigator.webView?.canGoBack,
            canGoForward: navigator.webView?.canGoForward,
            backList: navigator.webView?.backForwardList.backList,
            forwardList: navigator.webView?.backForwardList.forwardList
        )
        newState.loadingProgress = nil
        webView.state = newState

        readerLoadLog(
            "webView.loadingProgress.forceClear.end",
            [
                "effectivePageURL": effectivePageURL.absoluteString,
                "elapsedSinceDataLoadIssued": navigator.readerLoadDirectDataElapsedString(),
                "isLoading": "\(webView.state.isLoading)",
                "loadingProgress": webView.state.loadingProgress.map { String(format: "%.3f", $0) } ?? "nil",
                "reason": reason
            ]
        )
    }
}

struct WebViewConfigurationState: Equatable {
    var webViewID: ObjectIdentifier
    var userScriptsDomainKey: String?
    var userScriptsSignature: String
    var visualSignature: String
    var scrollBehaviorSignature: String
    var contentRulesSignature: String?
    var messageHandlersSignature: String
    var paginationSignature: String
}

extension WebViewCoordinator: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "swiftUIWebViewBackgroundStatus", let hasBackground = message.body as? Bool {
            webView.drawsBackground = !hasBackground
            return
        } else if message.name == "swiftUIWebViewLocationChanged" {
            guard let urlString = message.body as? String,
                  let newURL = URL(string: urlString),
                  let wk = navigator.webView else { return }
            
            Task { @MainActor in
                let newState = setLoading(
                    webView.state.isLoading,
                    pageURL: newURL,
                    canGoBack: wk.canGoBack,
                    canGoForward: wk.canGoForward,
                    backList: wk.backForwardList.backList,
                    forwardList: wk.backForwardList.forwardList
                )
            }
            return
        } else if message.name == "swiftUIWebViewImageUpdated" {
            guard let body = message.body as? [String: Any] else { return }
            if let imageURLRaw = body["imageURL"] as? String, let urlRaw = body["url"] as? String, let url = URL(string: urlRaw), let imageURL = URL(string: imageURLRaw), url == webView.state.pageURL {
                Task { @MainActor in
                    guard webView.state.pageURL == url else { return }
                    var newState = webView.state
                    newState.pageImageURL = imageURL
                    let targetState = newState
                    //                DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [webView] in
                    webView.state = targetState
                }
            }
        } else if message.name == "swiftUIWebViewPageIconUpdated" {
            guard let body = message.body as? [String: Any] else { return }
            if let imageURLRaw = body["pageIconURL"] as? String, let urlRaw = body["url"] as? String, let url = URL(string: urlRaw), let imageURL = URL(string: imageURLRaw), url == webView.state.pageURL {
                Task { @MainActor in
                    guard webView.state.pageURL == url else { return }
                    var newState = webView.state
                    newState.pageIconURL = imageURL
                    let targetState = newState
                    webView.state = targetState
                }
            }
        } else if message.name == "swiftUIWebViewUnhandledTap" {
            let suppressForNativeLookup = navigator.nativeLookupHitTesting.shouldSuppressUnhandledTapForNativeLookup
            let hasActiveLookup = navigator.nativeLookupHitTesting.activeLookupElementID?() != nil
            print(
                "# POPOVER native.unhandledTap",
                "suppress=\(suppressForNativeLookup)",
                "hasActiveLookup=\(hasActiveLookup)",
                "activeNativeTouchElementID=\(String(describing: navigator.nativeLookupHitTesting.activeNativeTouchElementID))",
                "targetCount=\(navigator.nativeLookupHitTesting.targetCount)",
                "body=\(popoverLogValue(message.body as Any))"
            )
            if suppressForNativeLookup {
                return
            }
            if hasActiveLookup {
                navigator.nativeLookupHitTesting.closeActiveLookupFromBlankTap()
                return
            }
            if let body = message.body as? [String: Any],
               let requestedHideNavigation = body["hideNavigationDueToScroll"] as? Bool {
                withAnimation(.easeOut(duration: 0.18)) {
                    hideNavigationDueToScroll.wrappedValue = requestedHideNavigation
                }
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    hideNavigationDueToScroll.wrappedValue.toggle()
                }
            }
            return
        } else if message.name == "swiftUIWebViewTextSelection" {
            guard let body = message.body as? [String: String], let text = body["text"] as? String else {
                return
            }
            textSelection.wrappedValue = text
        } else if message.name == "readerDocState" {
            guard let body = message.body as? [String: Any] else { return }
            let href = body["href"] as? String ?? "nil"
            let reason = body["reason"] as? String ?? "unknown"
            let readyState = body["readyState"] as? String ?? "unknown"
            let elapsedMs = body["elapsedMs"].map { String(describing: $0) } ?? "nil"
            let hasReaderContentBool = body["hasReaderContent"] as? Bool ?? false
            let hasReaderContent = body["hasReaderContent"].map { String(describing: $0) } ?? "nil"
            let hasReaderRenderReady = body["hasReaderRenderReady"] as? Bool
            let manabiFontPending = body["manabiFontPending"].map { String(describing: $0) } ?? "nil"
            let manabiFontReady = body["manabiFontReady"].map { String(describing: $0) } ?? "nil"
            let bodyLoading = body["bodyLoading"].map { String(describing: $0) } ?? "nil"
            let hasCustomFontStyle = body["hasCustomFontStyle"].map { String(describing: $0) } ?? "nil"
            let hasCustomFontGate = body["hasCustomFontGate"].map { String(describing: $0) } ?? "nil"
            let fontsStatus = body["fontsStatus"].map { String(describing: $0) } ?? "nil"
            let bodyDisplay = body["bodyDisplay"] as? String ?? "nil"
            let bodyVisibility = body["bodyVisibility"] as? String ?? "nil"
            let bodyOpacity = body["bodyOpacity"].map { String(describing: $0) } ?? "nil"
            let hasVisibleFoliateView = body["hasVisibleFoliateView"].map { String(describing: $0) } ?? "nil"
            let visibleMarkAsReadButtonCount = body["visibleMarkAsReadButtonCount"].map { String(describing: $0) } ?? "nil"
            let readerContentTextLength = body["readerContentTextLength"].map { String(describing: $0) } ?? "nil"
            let readerContentRectDescription = (body["readerContentRect"] as? [String: Any]).map { String(describing: $0) } ?? "nil"
            let readerStageRectDescription = (body["readerStageRect"] as? [String: Any]).map { String(describing: $0) } ?? "nil"
            let foliateViewRectDescription = (body["foliateViewRect"] as? [String: Any]).map { String(describing: $0) } ?? "nil"
            let centerElementDescription = (body["elementAtCenter"] as? [String: Any]).map { String(describing: $0) } ?? "nil"
            let centerClosestReaderContentDescription = (body["centerClosestReaderContent"] as? [String: Any]).map { String(describing: $0) } ?? "nil"
            let isEBookDocState = webView.state.pageURL.absoluteString.hasPrefix("ebook://") || href.hasPrefix("ebook://")
            if isEBookDocState {
                let epubSignature = [
                    href,
                    readyState,
                    hasReaderContent,
                    String(describing: hasReaderRenderReady),
                    hasVisibleFoliateView,
                    visibleMarkAsReadButtonCount,
                    readerContentTextLength,
                    bodyDisplay,
                    bodyVisibility,
                    bodyOpacity,
                    manabiFontPending,
                    manabiFontReady,
                    bodyLoading,
                    fontsStatus,
                    readerContentRectDescription,
                    foliateViewRectDescription,
                    centerElementDescription
                ].joined(separator: "|")
                if lastEpubReaderDocStateSignature != epubSignature {
                    lastEpubReaderDocStateSignature = epubSignature
                    readerLoadLog(
                        "readerDocState",
                        [
                            "bodyDisplay": bodyDisplay,
                            "bodyLoading": bodyLoading,
                            "bodyOpacity": bodyOpacity,
                            "bodyVisibility": bodyVisibility,
                            "currentURL": webView.state.pageURL.absoluteString,
                            "elapsedMs": elapsedMs,
                            "fontsStatus": fontsStatus,
                            "hasReaderContent": hasReaderContent,
                            "hasReaderRenderReady": String(describing: hasReaderRenderReady),
                            "hasVisibleFoliateView": hasVisibleFoliateView,
                            "href": href,
                            "manabiFontPending": manabiFontPending,
                            "manabiFontReady": manabiFontReady,
                            "readerContentTextLength": readerContentTextLength,
                            "readyState": readyState,
                            "reason": reason,
                            "visibleMarkAsReadButtonCount": visibleMarkAsReadButtonCount
                        ]
                    )
                }
            }
            if let hasReaderRenderReady,
               webView.state.hasReaderRenderReady != hasReaderRenderReady {
                var newState = webView.state
                newState.hasReaderRenderReady = hasReaderRenderReady
                webView.state = newState
            }
        }
        /* else if message.name == "swiftUIWebViewIsWarm" {
         if !webView.isWarm, let onWarm = webView.onWarm {
         Task { @MainActor in
         webView.isWarm = true
         await onWarm()
         }
         }
         return
         }*/
        
        guard let messageHandler = messageHandlers.handlers[message.name] else { return }
        let message = WebViewMessage(frameInfo: message.frameInfo, uuid: UUID(), name: message.name, body: message.body)
        //        debugPrint("# RECV:", message.name, message.frameInfo.isMainFrame, message.frameInfo.request.url, message.frameInfo.securityOrigin.description)
        Task {
            await messageHandler(message)
        }
    }

}

extension WebViewCoordinator: WKUIDelegate {
    /// Suppress `target=_blank` and load in same view
    /// See: https://nemecek.be/blog/1/how-to-open-target_blank-links-in-wkwebview-in-ios
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let frame = navigationAction.targetFrame,
           frame.isMainFrame {
            return nil
        }
        webView.load(navigationAction.request)
        return nil
    }
    
#if os(macOS)
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let urls = FileManager.default.urls(for: .documentDirectory, in: .allDomainsMask)
        // for Japanese names.
        let name = suggestedFilename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "cannotencode"
        return URL(string: name, relativeTo: urls[0])
    }
    
    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.resolvesAliases = true
        
        func handleResult(_ result: NSApplication.ModalResponse) {
            if result == NSApplication.ModalResponse.OK {
                if let url = openPanel.url {
                    completionHandler([url])
                }
            } else if result == NSApplication.ModalResponse.cancel {
                completionHandler(nil)
            }
        }
        
        if let window = webView.window {
            openPanel.beginSheetModal(for: window, completionHandler: handleResult)
        } else { // web view is somehow not in a window? Fall back to begin
            openPanel.begin(completionHandler: handleResult)
        }
    }
#endif
}

extension WebViewCoordinator: WKNavigationDelegate {
    @MainActor
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
#if os(iOS)
        reapplyHostObscuredInsetsForNavigation("navigationFinish")
#endif
#if DEBUG
#endif
        logEpubNavigationTransition("finish", webView: webView)
        let finishNow = Date()
        let activeRequestURL = navigator.activeReaderLoadRequestURL(for: webView.url)
        readerLoadLog(
            "webView.nav.finish",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "elapsedSinceDataLoadIssued": navigator.readerLoadDirectDataElapsedString(now: finishNow),
                "elapsedSinceDataLoadReturned": navigator.readerLoadDirectDataReturnedElapsedString(now: finishNow),
                "elapsedSinceCommit": readerLoadElapsedString(since: navigator.readerLoadCommittedAt, now: finishNow),
                "elapsedSinceNavigatorLoad": readerLoadElapsedString(since: navigator.readerLoadRequestedAt, now: finishNow),
                "requestURL": activeRequestURL?.absoluteString ?? "nil",
                "traceID": navigator.readerLoadTraceID ?? "nil"
            ]
        )
        if isInternalReaderLoaderURL(activeRequestURL) {
            let issueGap = navigator.readerLoadIssuedAt.map { finishNow.timeIntervalSince($0) } ?? 0
            let provisionalGap: TimeInterval
            if let issuedAt = navigator.readerLoadIssuedAt,
               let provisionalStartedAt = navigator.readerLoadProvisionalStartedAt {
                provisionalGap = provisionalStartedAt.timeIntervalSince(issuedAt)
            } else {
                provisionalGap = 0
            }
            let commitGap: TimeInterval
            if let provisionalStartedAt = navigator.readerLoadProvisionalStartedAt,
               let committedAt = navigator.readerLoadCommittedAt {
                commitGap = committedAt.timeIntervalSince(provisionalStartedAt)
            } else {
                commitGap = 0
            }
            let finishGap = navigator.readerLoadCommittedAt.map { finishNow.timeIntervalSince($0) } ?? 0
            readerLoadLog(
                "webView.nav.loaderSummary",
                [
                    "commitGap": String(format: "%.3fs", commitGap),
                    "finishGap": String(format: "%.3fs", finishGap),
                    "issueToFinishGap": String(format: "%.3fs", issueGap),
                    "provisionalGap": String(format: "%.3fs", provisionalGap),
                    "requestURL": activeRequestURL?.absoluteString ?? "nil",
                    "traceID": navigator.readerLoadTraceID ?? "nil"
                ]
            )
            if let requestURL = activeRequestURL?.absoluteString {
                clearReaderLoaderCorrelationTimestamps(for: requestURL)
            }
        }
        navigator.clearReaderLoadTrace()
        //                debugPrint("# didFinish nav", webView.url)
        let newState = setLoading(
            false,
            pageURL: webView.url,
            isProvisionallyNavigating: false,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            backList: webView.backForwardList.backList,
            forwardList: webView.backForwardList.forwardList)
        // TODO: Move to an init postMessage callback
        /*
         if let url = webView.url, let scheme = url.scheme, scheme == "pdf" || scheme == "pdf-url", url.absoluteString.hasPrefix("\(url.scheme ?? "")://"), url.pathExtension.lowercased() == "pdf", let loaderURL = URL(string: "\(scheme)://\(url.absoluteString.dropFirst("\(url.scheme ?? "")://".count))") {
         // TODO: Escaping? Use async eval for passing object data.
         let jsString = "pdfjsLib.getDocument('\(loaderURL.absoluteString)').promise.then(doc => { PDFViewerApplication.load(doc); });"
         webView.evaluateJavaScript(jsString, completionHandler: nil)
         }
         */
        
        onNavigationFinished?(newState)

        if shouldReapplyContentRulesAfterLoad {
            shouldReapplyContentRulesAfterLoad = false
            self.webView.refreshContentRules(
                userContentController: webView.configuration.userContentController,
                coordinator: self
            )
        }

#if os(iOS)
        if #available(iOS 15.0, *) {
            webView.logManabiSampledPageTopDOMProbe(reason: "navigation.finish")
            webView.applyUnderPageFallbackBackgroundColor(config: config, reason: "navigation.finish")
            webView.applyConfiguredBackgroundForReaderDocumentIfNeeded(config: config, reason: "navigation.finish")
        }
#endif

#if os(iOS)
        if awaitingSnapshotReload {
            snapshotReloadDocumentReady = true
            logLookupPerf("webview.reload.nav.finish")
            maybeHideSnapshotOverlay()
        }
#endif
        
        extractPageState(webView: webView)
        refreshPaginationReadback(reason: "navigation-finished")
    }
    
    private func extractPageState(webView: WKWebView) {
        // TODO: Also get window location to confirm state matches JS result
        webView.evaluateJavaScript("document.title") { (response, error) in
            if let title = response as? String {
                var newState = self.webView.state
                newState.pageTitle = title
                self.webView.state = newState
            }
        }
        
        webView.evaluateJavaScript("document.URL.toString()") { (response, error) in
            if let url = response as? String, let newURL = URL(string: url), self.webView.state.pageURL != newURL {
                let now = Date()
                readerLoadLog(
                    "webView.pageURLUpdatedFromDocument",
                    [
                        "documentURL": newURL.absoluteString,
                        "elapsedSinceCommit": readerLoadElapsedString(since: self.navigator.readerLoadCommittedAt, now: now),
                        "elapsedSinceNavigatorLoad": readerLoadElapsedString(since: self.navigator.readerLoadRequestedAt, now: now),
                        "previousPageURL": self.webView.state.pageURL.absoluteString
                    ]
                )
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

        webView.evaluateJavaScript(
            """
            (function() {
                const body = document.body;
                const html = document.documentElement;
                const bodyStyle = body ? window.getComputedStyle(body) : null;
                const readerContent = document.getElementById("reader-content");
                const readerContentRect = readerContent?.getBoundingClientRect?.() ?? null;
                const readerContentStyle = readerContent ? window.getComputedStyle(readerContent) : null;
                const readerStage = document.getElementById("reader-stage");
                const foliateView = readerStage?.querySelector?.("foliate-view") ?? document.querySelector("foliate-view");
                const foliateViewStyle = foliateView ? window.getComputedStyle(foliateView) : null;
                const foliateViewRect = foliateView?.getBoundingClientRect?.() ?? null;
                const bodyText = (body?.innerText || "").trim();
                const bodyHTML = body?.innerHTML || "";
                const readerContentText = (readerContent?.textContent || "").trim();
                const hasReaderModeContent = !!readerContent;
                const hasVisibleReaderModeContent = !!readerContent
                    && !!readerContentRect
                    && readerContentRect.width > 1
                    && readerContentRect.height > 1
                    && readerContentStyle?.visibility !== 'hidden'
                    && readerContentStyle?.display !== 'none'
                    && Number.parseFloat(readerContentStyle?.opacity || "1") > 0.01
                    && readerContentText.length > 0;
                const hasVisibleFoliateView = !!foliateView
                    && !!foliateViewRect
                    && foliateViewRect.width > 1
                    && foliateViewRect.height > 1
                    && foliateViewStyle?.visibility !== 'hidden'
                    && foliateViewStyle?.display !== 'none'
                    && Number.parseFloat(foliateViewStyle?.opacity || "1") > 0.01;
                return {
                    documentURL: document.URL.toString(),
                    readyState: document.readyState,
                    bodyChildElementCount: body?.childElementCount || 0,
                    bodyTextLength: bodyText.length,
                    bodyHTMLLength: bodyHTML.length,
                    hasReaderRenderReady:
                        ((((html?.dataset?.manabiReaderRenderReady === '1' || body?.dataset?.manabiReaderRenderReady === '1')
                        && hasReaderModeContent)
                        || hasVisibleReaderModeContent)
                        || hasVisibleFoliateView)
                        && (html?.dataset?.manabiFontPending ?? null) !== '1'
                        && bodyStyle?.visibility !== 'hidden'
                        && bodyStyle?.display !== 'none'
                        && Number.parseFloat(bodyStyle?.opacity || "1") > 0.01,
                    hasMeaningfulBodyContent: bodyText.length > 0 || bodyHTML.replace(/\\s+/g, "").length > 0,
                    titleLength: (document.title || "").length
                };
            })();
            """
        ) { response, error in
            guard error == nil, let summary = response as? [String: Any] else { return }
            let mapped = summary.reduce(into: [String: String]()) { partialResult, entry in
                partialResult[entry.key] = String(describing: entry.value)
            }
            let hasMeaningfulBodyContent = summary["hasMeaningfulBodyContent"] as? Bool ?? false
            if let hasReaderRenderReady = summary["hasReaderRenderReady"] as? Bool,
               self.webView.state.hasReaderRenderReady != hasReaderRenderReady {
                var newState = self.webView.state
                newState.hasReaderRenderReady = hasReaderRenderReady
                self.webView.state = newState
            }
            _ = hasMeaningfulBodyContent
            _ = mapped
        }
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task {
            scriptCaller?.removeAllMultiTargetFrames()
        }
        _ = setLoading(
            false,
            pageURL: webView.url,
            isProvisionallyNavigating: false,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            backList: webView.backForwardList.backList,
            forwardList: webView.backForwardList.forwardList,
            error: error
        )
        let now = Date()
        readerLoadLog(
            "webView.nav.failProvisional",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "elapsedSinceNavigatorLoad": readerLoadElapsedString(since: navigator.readerLoadRequestedAt, now: now),
                "error": error.localizedDescription,
                "requestURL": navigator.activeReaderLoadRequestURL(for: webView.url)?.absoluteString ?? "nil",
                "traceID": navigator.readerLoadTraceID ?? "nil"
            ]
        )
        navigator.clearReaderLoadTrace()
#if os(iOS)
        if awaitingSnapshotReload {
            cancelSnapshotReload()
        }
#endif
    }
    
    @MainActor
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        readerLoadLog(
            "webView.processTerminated",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "processPoolID": readerLoadObjectIDString(webView.configuration.processPool),
                "webViewID": readerLoadObjectIDString(webView)
            ]
        )
        setLoading(false, isProvisionallyNavigating: false)
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task {
            scriptCaller?.removeAllMultiTargetFrames()
        }
        let newState = setLoading(false, isProvisionallyNavigating: false, error: error)
        let now = Date()
        readerLoadLog(
            "webView.nav.fail",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "elapsedSinceNavigatorLoad": readerLoadElapsedString(since: navigator.readerLoadRequestedAt, now: now),
                "error": error.localizedDescription,
                "requestURL": navigator.activeReaderLoadRequestURL(for: webView.url)?.absoluteString ?? "nil",
                "traceID": navigator.readerLoadTraceID ?? "nil"
            ]
        )
        if let requestURL = navigator.activeReaderLoadRequestURL(for: webView.url)?.absoluteString,
           isInternalReaderLoaderURL(navigator.activeReaderLoadRequestURL(for: webView.url)) {
            clearReaderLoaderCorrelationTimestamps(for: requestURL)
        }
        navigator.clearReaderLoadTrace()
        
        extractPageState(webView: webView)
        
        onNavigationFailed?(newState)
#if os(iOS)
        if awaitingSnapshotReload {
            cancelSnapshotReload()
        }
#endif
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
#if os(iOS)
        reapplyHostObscuredInsetsForNavigation("navigationCommit")
#endif
        Task {
            scriptCaller?.removeAllMultiTargetFrames()
        }
#if DEBUG
#endif
        logEpubNavigationTransition("commit", webView: webView)
        let commitNow = Date()
        navigator.invalidateReaderLoadTraceIfMismatched(with: webView.url)
        navigator.readerLoadCommittedAt = commitNow
        navigator.updateInternalLoaderCorrelation(for: webView.url, now: commitNow)
        let activeRequestURL = navigator.activeReaderLoadRequestURL(for: webView.url)
        readerLoadLog(
            "webView.nav.commit",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "elapsedSinceDataLoadIssued": navigator.readerLoadDirectDataElapsedString(now: commitNow),
                "elapsedSinceDataLoadReturned": navigator.readerLoadDirectDataReturnedElapsedString(now: commitNow),
                "elapsedSinceNavigatorLoad": readerLoadElapsedString(since: navigator.readerLoadRequestedAt, now: commitNow),
                "elapsedSinceProvisionalStart": readerLoadElapsedString(since: navigator.readerLoadProvisionalStartedAt, now: commitNow),
                "requestURL": activeRequestURL?.absoluteString ?? "nil",
                "traceID": navigator.readerLoadTraceID ?? "nil"
            ]
        )
        var newState = setLoading(
            true,
            pageURL: webView.url,
            isProvisionallyNavigating: false
        )
        newState.pageImageURL = nil
        newState.pageIconURL = nil
        newState.pageTitle = nil
        newState.pageHTML = nil
        newState.hasReaderRenderReady = false
        newState.error = nil
        onNavigationCommitted?(newState)
#if os(iOS)
        webView.applyUnderPageFallbackBackgroundColor(config: config, reason: "navigation.commit")
        if #available(iOS 15.0, *) {
            webView.logManabiSampledPageTopDOMProbe(reason: "navigation.commit")
            webView.applyConfiguredBackgroundForReaderDocumentIfNeeded(config: config, reason: "navigation.commit")
        }
#endif
#if os(iOS)
        if awaitingSnapshotReload {
            snapshotReloadCommitted = true
            logLookupPerf("webview.reload.nav.commit")
        }
#endif
        refreshPaginationReadback(reason: "navigation-committed")
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigator.nativeLookupHitTesting.removeAllTargets()
#if os(iOS)
        reapplyHostObscuredInsetsForNavigation("navigationStart")
#endif
#if DEBUG
#endif
        logEpubNavigationTransition("start", webView: webView)
        let provisionalNow = Date()
        navigator.invalidateReaderLoadTraceIfMismatched(with: webView.url)
        navigator.readerLoadProvisionalStartedAt = provisionalNow
        navigator.updateInternalLoaderCorrelation(for: webView.url, now: provisionalNow)
        let activeRequestURL = navigator.activeReaderLoadRequestURL(for: webView.url)
        readerLoadLog(
            "webView.nav.provisionalStart",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "elapsedSinceDataLoadIssued": navigator.readerLoadDirectDataElapsedString(now: provisionalNow),
                "elapsedSinceDataLoadReturned": navigator.readerLoadDirectDataReturnedElapsedString(now: provisionalNow),
                "elapsedSinceIssued": readerLoadElapsedString(since: navigator.readerLoadIssuedAt, now: provisionalNow),
                "elapsedSinceNavigatorLoad": readerLoadElapsedString(since: navigator.readerLoadRequestedAt, now: provisionalNow),
                "requestURL": activeRequestURL?.absoluteString ?? "nil",
                "traceID": navigator.readerLoadTraceID ?? "nil"
            ]
        )
        if let currentURL = webView.url?.absoluteString, isInternalReaderLoaderURL(URL(string: currentURL)) {
            if let loaderStartTimestamp = navigator.readerLoadInternalLoaderStartedAt {
                readerLoadLog(
                    "webView.nav.provisionalStart.afterInternalSchemeStart",
                    [
                        "elapsed": String(format: "%.3fs", provisionalNow.timeIntervalSince(loaderStartTimestamp)),
                        "requestURL": currentURL,
                        "traceID": navigator.readerLoadTraceID ?? "nil"
                    ]
                )
                if let loaderResponseTimestamp = navigator.readerLoadInternalLoaderResponseAt {
                    readerLoadLog(
                        "webView.nav.provisionalStart.afterInternalSchemeResponse",
                        [
                            "elapsed": String(format: "%.3fs", provisionalNow.timeIntervalSince(loaderResponseTimestamp)),
                            "requestURL": currentURL,
                            "traceID": navigator.readerLoadTraceID ?? "nil"
                        ]
                    )
                }
                if let loaderDataTimestamp = navigator.readerLoadInternalLoaderDataAt {
                    readerLoadLog(
                        "webView.nav.provisionalStart.afterInternalSchemeData",
                        [
                            "elapsed": String(format: "%.3fs", provisionalNow.timeIntervalSince(loaderDataTimestamp)),
                            "requestURL": currentURL,
                            "traceID": navigator.readerLoadTraceID ?? "nil"
                        ]
                    )
                }
                if let loaderFinishTimestamp = navigator.readerLoadInternalLoaderFinishedAt {
                    readerLoadLog(
                        "webView.nav.provisionalStart.afterInternalSchemeFinish",
                        [
                            "elapsed": String(format: "%.3fs", provisionalNow.timeIntervalSince(loaderFinishTimestamp)),
                            "requestURL": currentURL,
                            "traceID": navigator.readerLoadTraceID ?? "nil"
                        ]
                    )
                }
            } else {
                readerLoadLog(
                    "webView.nav.provisionalStart.beforeInternalSchemeStart",
                    [
                        "requestURL": currentURL,
                        "traceID": navigator.readerLoadTraceID ?? "nil"
                    ]
                )
            }
        }
        if navigator.pendingRequest?.url == webView.url {
            if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || !navigator.shouldLoadFallbackOnAttach {
            }
            navigator.pendingRequest = nil
            navigator.cancelPendingRequestLoadTask()
        }
#if os(iOS)
        beginSampledPageTopColorNavigation(webView, reason: "navigation.start")
        pendingSnapshotRestore = false
#endif
        _ = setLoading(
            true,
            isProvisionallyNavigating: true,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            backList: webView.backForwardList.backList,
            forwardList: webView.backForwardList.forwardList)
        var newState = self.webView.state
        newState.mainFrameHTTPStatusCode = nil
        self.webView.state = newState
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let startedAt = Date()
#if DEBUG
#endif
        let requestURL = navigationAction.request.url
        if navigationAction.targetFrame?.isMainFrame == true {
            lastMainFrameNavigationSourceURL = webView.url ?? self.webView.state.pageURL
            lastMainFrameNavigationRequestURL = requestURL
            lastMainFrameNavigationMainDocumentURL = navigationAction.request.mainDocumentURL
            lastMainFrameNavigationType = navigationAction.navigationType
            logEpubNavigationTransition("decide", webView: webView, requestURL: requestURL)
        }
        let isInternalLocalRequest = requestURL?.scheme?.lowercased() == "internal"
            && requestURL?.host?.lowercased() == "local"
        if let requestURL, isInternalLocalRequest {
            readerLoadLog(
                "webView.nav.decidePolicyAction",
                [
                    "currentURL": webView.url?.absoluteString ?? "nil",
                    "mainFrame": "\(navigationAction.targetFrame?.isMainFrame ?? false)",
                    "mainDocumentURL": navigationAction.request.mainDocumentURL?.absoluteString ?? "nil",
                    "navigationType": "\(navigationAction.navigationType.rawValue)",
                    "requestURL": requestURL.absoluteString
                ]
            )
        }
        let isMainDocumentNavigation = navigationAction.targetFrame?.isMainFrame == true
        let isInternalReaderLoaderNavigation = isMainDocumentNavigation && isInternalReaderLoaderURL(requestURL)
        if isMainDocumentNavigation,
           let requestedURL = requestURL,
           let loaderRequestedURL = navigator.readerLoadRequestedURL,
           let canonicalLoaderURL = canonicalContentURLForReaderLoader(loaderRequestedURL),
           requestedURL == canonicalLoaderURL,
           navigationAction.navigationType == .other {
            readerLoadLog(
                "webView.nav.cancelLateCanonicalRedirect",
                [
                    "canonicalURL": requestedURL.absoluteString,
                    "loaderURL": loaderRequestedURL.absoluteString,
                    "elapsedSinceNavigatorLoad": readerLoadElapsedString(since: navigator.readerLoadRequestedAt),
                    "navigationType": "\(navigationAction.navigationType.rawValue)"
                ]
            )
            return (.cancel, preferences)
        }
        if let decision = await onNavigationAction?(navigationAction) {
            if isInternalReaderLoaderNavigation {
                readerLoadLog(
                    "webView.nav.decidePolicyReturn",
                    [
                        "decision": "\(decision.rawValue)",
                        "elapsed": readerLoadElapsedString(since: startedAt),
                        "requestURL": requestURL?.absoluteString ?? "nil",
                        "source": "onNavigationAction"
                    ]
                )
            }
            return (decision, preferences)
        }
        if let host = navigationAction.request.url?.host, let blockedHosts = self.webView.blockedHosts {
            if blockedHosts.contains(where: { host.contains($0) }) {
                setLoading(false, isProvisionallyNavigating: false)
                if isInternalReaderLoaderNavigation {
                    readerLoadLog(
                        "webView.nav.decidePolicyReturn",
                        [
                            "decision": "\(WKNavigationActionPolicy.cancel.rawValue)",
                            "elapsed": readerLoadElapsedString(since: startedAt),
                            "requestURL": requestURL?.absoluteString ?? "nil",
                            "source": "blockedHost"
                        ]
                    )
                }
                return (.cancel, preferences)
            }
        }
        
        // ePub loader
        // TODO: Instead, issue a redirect from file:// to epub:// likewise for pdf to reuse code here.
        
        if isMainDocumentNavigation {
            let effectiveMainDocumentURL = navigationAction.request.mainDocumentURL ?? navigationAction.request.url
            self.webView.updateUserScripts(
                userContentController: webView.configuration.userContentController,
                coordinator: self,
                forDomain: effectiveMainDocumentURL,
                config: config
            )
            scriptCaller?.removeAllMultiTargetFrames()
            if !isInternalReaderLoaderNavigation {
                var newState = self.webView.state
                newState.pageURL = effectiveMainDocumentURL ?? newState.pageURL
                newState.pageTitle = nil
                newState.isProvisionallyNavigating = false
                newState.pageImageURL = nil
                newState.pageIconURL = nil
                newState.pageHTML = nil
                newState.hasReaderRenderReady = false
                newState.error = nil
                self.webView.state = newState
            }
        }
        
        // Only apply content rules for main frame navigations.
        if isMainDocumentNavigation {
            if navigator.consumeContentRulesBypass() {
                shouldReapplyContentRulesAfterLoad = true
                self.webView.refreshContentRules(
                    userContentController: webView.configuration.userContentController,
                    coordinator: self,
                    overrideRules: nil
                )
            } else if lastAppliedContentRules != config.contentRules {
                self.webView.refreshContentRules(
                    userContentController: webView.configuration.userContentController,
                    coordinator: self
                )
            }
        }
        if isInternalReaderLoaderNavigation {
            readerLoadLog(
                "webView.nav.decidePolicyReturn",
                [
                    "decision": "\(WKNavigationActionPolicy.allow.rawValue)",
                    "elapsed": readerLoadElapsedString(since: startedAt),
                    "requestURL": requestURL?.absoluteString ?? "nil",
                    "source": "defaultAllow"
                ]
            )
        }
        return (.allow, preferences)
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let response = navigationResponse.response as? HTTPURLResponse {
#if DEBUG
#endif
            if navigationResponse.isForMainFrame {
                var newState = self.webView.state
                newState.mainFrameHTTPStatusCode = response.statusCode
                self.webView.state = newState
            }
        }
        return .allow
    }
}

public class WebViewNavigator: NSObject, ObservableObject {
    fileprivate struct ReaderLoadTrace {
        let id: UUID
        var requestURL: URL?
        var requestedAt: Date
        var issuedAt: Date?
        var provisionalStartedAt: Date?
        var committedAt: Date?
        var directDataIssuedAt: Date?
        var directDataReturnedAt: Date?
        var internalLoaderStartedAt: Date?
        var internalLoaderResponseAt: Date?
        var internalLoaderDataAt: Date?
        var internalLoaderFinishedAt: Date?
    }

    fileprivate var pendingRequest: URLRequest?
    fileprivate var pendingHTML: (html: String, baseURL: URL?)?
    fileprivate var pendingDataLoad: (data: Data, mimeType: String, characterEncodingName: String, baseURL: URL)?
    fileprivate var lastLoadedRequest: URLRequest?
    fileprivate var lastLoadedHTML: (html: String, baseURL: URL?)?
    fileprivate var lastLoadedDataLoad: (data: Data, mimeType: String, characterEncodingName: String, baseURL: URL)?
    @MainActor fileprivate var pendingRequestSetAt: Date?
    @MainActor fileprivate var pendingHTMLSetAt: Date?
    @MainActor fileprivate var pendingDataLoadSetAt: Date?
    @Published public private(set) var hasAttachedWebView = false
    public var debugIdentifier: String?
    public var debugObjectID: String {
        String(describing: ObjectIdentifier(self))
    }
    @MainActor private var bypassContentRulesForNextNavigation = false
    @MainActor private var pendingRequestLoadGeneration: Int = 0
    @MainActor private var pendingRequestLoadTask: Task<Void, Never>?
    @MainActor private var attachFallbackLoadGeneration: Int = 0
    @MainActor private var attachFallbackLoadTask: Task<Void, Never>?
    @MainActor private var preProvisionalWarningGeneration: Int = 0
    @MainActor private var preProvisionalWarningTask: Task<Void, Never>?
    @MainActor private var currentReaderLoadTrace: ReaderLoadTrace?
    public var attachFallbackURL: URL?
    public var attachFallbackDelayNanoseconds: UInt64 = 250_000_000
    public var shouldLoadFallbackOnAttach = true
    public var paginationStateEnrichment: WebViewPaginationStateEnrichment?
    public let nativeLookupHitTesting = WebViewNativeLookupHitTestStore()
    @MainActor fileprivate var forceClearLoadingIndicatorsHandler: ((String, URL?) -> Void)?

    public struct DebugLoadSnapshot {
        public let currentWebViewURL: String
        public let lastRequestURL: String
        public let lastDataLoadBaseURL: String
        public let lastHTMLBaseURL: String
        public let hasAttachedWebView: Bool
        public let isLoading: Bool
    }

    @MainActor
    public var debugLoadSnapshot: DebugLoadSnapshot {
        DebugLoadSnapshot(
            currentWebViewURL: webView?.url?.absoluteString ?? "nil",
            lastRequestURL: lastLoadedRequest?.url?.absoluteString ?? "nil",
            lastDataLoadBaseURL: lastLoadedDataLoad?.baseURL.absoluteString ?? "nil",
            lastHTMLBaseURL: lastLoadedHTML?.baseURL?.absoluteString ?? "nil",
            hasAttachedWebView: hasAttachedWebView,
            isLoading: webView?.isLoading ?? false
        )
    }

    @MainActor
    public var isReadyForDirectLoad: Bool {
        guard let webView else { return false }
        return webView.window != nil && webView.superview != nil
    }

    @MainActor
    fileprivate func logAttachmentEvent(_ source: String, webView: WKWebView?) {
        readerLoadLog(
            "webViewNavigator.attachmentState",
            [
                "currentURL": webView?.url?.absoluteString ?? "nil",
                "elapsedSinceIssued": readerLoadElapsedString(since: readerLoadIssuedAt),
                "elapsedSinceRequested": readerLoadElapsedString(since: readerLoadRequestedAt),
                "hasAttachedWebView": "\(hasAttachedWebView)",
                "hasSuperview": "\(webView?.superview != nil)",
                "hasWindow": "\(webView?.window != nil)",
                "isReadyForRequest": "\(webView.map { $0.window != nil && $0.superview != nil } ?? false)",
                "requestURL": readerLoadRequestedURL?.absoluteString ?? "nil",
                "sceneState": readerLoadSceneStateString(for: webView),
                "source": source,
                "traceID": currentReaderLoadTrace?.id.uuidString ?? "nil",
                "webViewID": readerLoadObjectIDString(webView)
            ]
        )
    }

    @MainActor fileprivate var readerLoadTraceID: String? {
        currentReaderLoadTrace?.id.uuidString
    }

    @MainActor fileprivate var readerLoadRequestedAt: Date? {
        currentReaderLoadTrace?.requestedAt
    }

    @MainActor fileprivate var readerLoadRequestedURL: URL? {
        currentReaderLoadTrace?.requestURL
    }

    @MainActor fileprivate var readerLoadIssuedAt: Date? {
        get { currentReaderLoadTrace?.issuedAt }
        set {
            currentReaderLoadTrace?.issuedAt = newValue
            syncActiveInternalReaderLoaderSignal()
            schedulePreProvisionalWarningIfNeeded()
        }
    }

    @MainActor fileprivate var readerLoadProvisionalStartedAt: Date? {
        get { currentReaderLoadTrace?.provisionalStartedAt }
        set {
            currentReaderLoadTrace?.provisionalStartedAt = newValue
            syncActiveInternalReaderLoaderSignal()
            if newValue != nil {
                cancelPreProvisionalWarningTask()
            }
        }
    }

    @MainActor fileprivate var readerLoadCommittedAt: Date? {
        get { currentReaderLoadTrace?.committedAt }
        set { currentReaderLoadTrace?.committedAt = newValue }
    }

    @MainActor fileprivate var readerLoadDirectDataIssuedAt: Date? {
        currentReaderLoadTrace?.directDataIssuedAt
    }

    @MainActor fileprivate func readerLoadDirectDataElapsedString(now: Date = Date()) -> String {
        readerLoadElapsedString(since: readerLoadDirectDataIssuedAt, now: now)
    }

    @MainActor fileprivate var readerLoadDirectDataReturnedAt: Date? {
        currentReaderLoadTrace?.directDataReturnedAt
    }

    @MainActor fileprivate func readerLoadDirectDataReturnedElapsedString(now: Date = Date()) -> String {
        readerLoadElapsedString(since: readerLoadDirectDataReturnedAt, now: now)
    }

    @MainActor fileprivate var readerLoadInternalLoaderStartedAt: Date? {
        currentReaderLoadTrace?.internalLoaderStartedAt
    }

    @MainActor fileprivate var readerLoadInternalLoaderResponseAt: Date? {
        currentReaderLoadTrace?.internalLoaderResponseAt
    }

    @MainActor fileprivate var readerLoadInternalLoaderDataAt: Date? {
        currentReaderLoadTrace?.internalLoaderDataAt
    }

    @MainActor fileprivate var readerLoadInternalLoaderFinishedAt: Date? {
        currentReaderLoadTrace?.internalLoaderFinishedAt
    }

    @MainActor
    private func syncActiveInternalReaderLoaderSignal() {
        let defaults = UserDefaults.standard
        if let trace = currentReaderLoadTrace,
           let requestURL = trace.requestURL,
           isInternalReaderLoaderURL(requestURL),
           trace.issuedAt != nil,
           trace.provisionalStartedAt == nil {
            defaults.set(trace.id.uuidString, forKey: activeInternalReaderLoaderTraceIDKey)
            defaults.set(requestURL.absoluteString, forKey: activeInternalReaderLoaderURLKey)
        } else {
            defaults.removeObject(forKey: activeInternalReaderLoaderTraceIDKey)
            defaults.removeObject(forKey: activeInternalReaderLoaderURLKey)
        }
    }

    @MainActor
    private func cancelPreProvisionalWarningTask() {
        preProvisionalWarningGeneration &+= 1
        preProvisionalWarningTask?.cancel()
        preProvisionalWarningTask = nil
    }

    @MainActor
    private func schedulePreProvisionalWarningIfNeeded() {
        cancelPreProvisionalWarningTask()
        guard let trace = currentReaderLoadTrace,
              let requestURL = trace.requestURL,
              isInternalReaderLoaderURL(requestURL),
              trace.issuedAt != nil,
              trace.provisionalStartedAt == nil else {
            syncActiveInternalReaderLoaderSignal()
            return
        }
        syncActiveInternalReaderLoaderSignal()
        let generation = preProvisionalWarningGeneration
        preProvisionalWarningTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(readerLoadPreProvisionalWarningThreshold * 1_000_000_000))
            guard let self,
                  !Task.isCancelled,
                  self.preProvisionalWarningGeneration == generation,
                  let currentTrace = self.currentReaderLoadTrace,
                  currentTrace.id == trace.id,
                  currentTrace.provisionalStartedAt == nil,
                  let issuedAt = currentTrace.issuedAt else { return }
            let now = Date()
            readerLoadLog(
                "webViewNavigator.preProvisionalWatchdog",
                [
                    "currentURL": self.webView?.url?.absoluteString ?? "nil",
                    "elapsedSinceIssued": String(format: "%.3fs", now.timeIntervalSince(issuedAt)),
                    "estimatedProgress": self.webView.map { String(format: "%.3f", $0.estimatedProgress) } ?? "nil",
                    "hasSuperview": "\(self.webView?.superview != nil)",
                    "hasWindow": "\(self.webView?.window != nil)",
                    "isLoading": "\(self.webView?.isLoading ?? false)",
                    "requestURL": currentTrace.requestURL?.absoluteString ?? "nil",
                    "sceneState": readerLoadSceneStateString(for: self.webView),
                    "traceID": currentTrace.id.uuidString
                ]
            )
        }
    }

    @MainActor
    fileprivate func logCompetingOperationIfNeeded(_ operation: String, metadata: [String: String] = [:]) {
        guard let trace = currentReaderLoadTrace,
              let requestURL = trace.requestURL,
              isInternalReaderLoaderURL(requestURL),
              let issuedAt = trace.issuedAt,
              trace.provisionalStartedAt == nil else { return }
        var payload = metadata
        payload["currentURL"] = webView?.url?.absoluteString ?? "nil"
        payload["elapsedSinceIssued"] = String(format: "%.3fs", Date().timeIntervalSince(issuedAt))
        payload["estimatedProgress"] = webView.map { String(format: "%.3f", $0.estimatedProgress) } ?? "nil"
        payload["hasSuperview"] = "\(webView?.superview != nil)"
        payload["hasWindow"] = "\(webView?.window != nil)"
        payload["isLoading"] = "\(webView?.isLoading ?? false)"
        payload["requestURL"] = requestURL.absoluteString
        payload["sceneState"] = readerLoadSceneStateString(for: webView)
        payload["traceID"] = trace.id.uuidString
        readerLoadLog("webViewNavigator.competingOperation.\(operation)", payload)
    }

    @MainActor
    @discardableResult
    private func beginReaderLoadTrace(for requestURL: URL?) -> Date {
        let now = Date()
        cancelPreProvisionalWarningTask()
        currentReaderLoadTrace = ReaderLoadTrace(
            id: UUID(),
            requestURL: requestURL,
            requestedAt: now,
            issuedAt: nil,
            provisionalStartedAt: nil,
            committedAt: nil,
            directDataIssuedAt: nil,
            directDataReturnedAt: nil,
            internalLoaderStartedAt: nil,
            internalLoaderResponseAt: nil,
            internalLoaderDataAt: nil,
            internalLoaderFinishedAt: nil
        )
        syncActiveInternalReaderLoaderSignal()
        return now
    }

    @MainActor
    private func beginReaderLoadTrace(for request: URLRequest) {
        let traceRequestedAt = beginReaderLoadTrace(for: request.url)
        readerLoadLog(
            "webViewNavigator.loadRequest",
            [
                "attached": "\(webView != nil)",
                "hasSuperview": "\(webView?.superview != nil)",
                "hasWindow": "\(webView?.window != nil)",
                "requestedAt": String(format: "%.3f", traceRequestedAt.timeIntervalSince1970),
                "url": request.url?.absoluteString ?? "nil"
            ]
        )
    }

    @MainActor
    fileprivate func clearReaderLoadTrace() {
        cancelPreProvisionalWarningTask()
        currentReaderLoadTrace = nil
        syncActiveInternalReaderLoaderSignal()
    }

    @MainActor
    fileprivate func readerLoadTraceMatches(currentURL: URL?) -> Bool {
        guard let currentURL, let requestURL = readerLoadRequestedURL else { return false }
        if requestURL == currentURL {
            return true
        }
        if let currentCanonical = canonicalContentURLForReaderLoader(currentURL), currentCanonical == requestURL {
            return true
        }
        if let requestedCanonical = canonicalContentURLForReaderLoader(requestURL), requestedCanonical == currentURL {
            return true
        }
        return false
    }

    @MainActor
    fileprivate func activeReaderLoadRequestURL(for currentURL: URL?) -> URL? {
        readerLoadTraceMatches(currentURL: currentURL) ? readerLoadRequestedURL : nil
    }

    @MainActor
    private func shouldRetainReaderLoadTrace(for currentURL: URL?) -> Bool {
        guard readerLoadRequestedURL != nil else { return false }
        guard let currentURL else { return true }
        if currentURL.absoluteString == "about:blank" {
            return true
        }
        return false
    }

    @MainActor
    fileprivate func invalidateReaderLoadTraceIfMismatched(with currentURL: URL?) {
        guard readerLoadRequestedURL != nil else { return }
        guard !shouldRetainReaderLoadTrace(for: currentURL) else { return }
        guard !readerLoadTraceMatches(currentURL: currentURL) else { return }
        clearReaderLoadTrace()
    }

    @MainActor
    fileprivate func updateInternalLoaderCorrelation(for currentURL: URL?, now: Date) {
        guard let currentURL, isInternalReaderLoaderURL(currentURL) else { return }
        let currentURLString = currentURL.absoluteString
        let correlationBaseline = readerLoadIssuedAt ?? readerLoadRequestedAt
        currentReaderLoadTrace?.internalLoaderStartedAt = readerLoadCorrelationTimestamp(
            forKey: internalReaderLoaderStartedAtKeyPrefix + currentURLString,
            baseline: correlationBaseline,
            now: now
        )
        currentReaderLoadTrace?.internalLoaderResponseAt = readerLoadCorrelationTimestamp(
            forKey: internalReaderLoaderResponseAtKeyPrefix + currentURLString,
            baseline: correlationBaseline,
            now: now
        )
        currentReaderLoadTrace?.internalLoaderDataAt = readerLoadCorrelationTimestamp(
            forKey: internalReaderLoaderDataAtKeyPrefix + currentURLString,
            baseline: correlationBaseline,
            now: now
        )
        currentReaderLoadTrace?.internalLoaderFinishedAt = readerLoadCorrelationTimestamp(
            forKey: internalReaderLoaderFinishedAtKeyPrefix + currentURLString,
            baseline: correlationBaseline,
            now: now
        )
    }

    @MainActor
    private func logPreIssueLoadState(for request: URLRequest, reason: String) {
        guard let webView else { return }
        let estimatedProgress = webView.estimatedProgress
        let isLoading = webView.isLoading
        readerLoadLog(
            "webViewNavigator.preIssueState",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "estimatedProgress": String(format: "%.3f", estimatedProgress),
                "hasSuperview": "\(webView.superview != nil)",
                "hasWindow": "\(webView.window != nil)",
                "isLoading": "\(isLoading)",
                "reason": reason,
                "requestURL": request.url?.absoluteString ?? "nil",
                "sceneState": readerLoadSceneStateString(for: webView),
                "traceID": readerLoadTraceID ?? "nil",
                "webViewID": readerLoadObjectIDString(webView)
            ]
        )
        let hasPotentialStaleLoad = isLoading
            || (estimatedProgress > readerLoadStaleLoadingStateThreshold && estimatedProgress < 0.999)
        guard hasPotentialStaleLoad else { return }
        readerLoadLog(
            "webViewNavigator.preIssueState.anomaly",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "estimatedProgress": String(format: "%.3f", estimatedProgress),
                "isLoading": "\(isLoading)",
                "reason": reason,
                "requestURL": request.url?.absoluteString ?? "nil"
            ]
        )
    }

    @MainActor
    private func recoverFromStaleAboutBlankIfNeeded(
        for request: URLRequest,
        on webView: WKWebView,
        reason: String
    ) -> Bool {
        guard isInternalReaderLoaderURL(request.url),
              webView.url?.absoluteString == "about:blank"
        else {
            return false
        }

        let estimatedProgress = webView.estimatedProgress
        let isLoading = webView.isLoading
        let hasInFlightAboutBlankLoad = isLoading
            || (estimatedProgress > readerLoadStaleLoadingStateThreshold && estimatedProgress < 0.999)
        guard hasInFlightAboutBlankLoad else {
            return false
        }

        readerLoadLog(
            "webViewNavigator.staleAboutBlankDetected",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "estimatedProgress": String(format: "%.3f", estimatedProgress),
                "isLoading": "\(isLoading)",
                "reason": reason,
                "requestURL": request.url?.absoluteString ?? "nil",
                "sceneState": readerLoadSceneStateString(for: webView),
                "webViewID": readerLoadObjectIDString(webView)
            ]
        )

        logCompetingOperationIfNeeded(
            "stopLoading",
            metadata: [
                "reason": reason,
                "targetURL": request.url?.absoluteString ?? "nil"
            ]
        )
        webView.stopLoading()
        readerLoadLog(
            "webViewNavigator.staleAboutBlankStopLoading",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "estimatedProgress": String(format: "%.3f", webView.estimatedProgress),
                "isLoading": "\(webView.isLoading)",
                "reason": reason,
                "requestURL": request.url?.absoluteString ?? "nil"
            ]
        )
        return false
    }

    @MainActor
    private func markReaderLoadIssued(for request: URLRequest, reason: String) {
        let now = Date()
        readerLoadIssuedAt = now
        readerLoadLog(
            "webViewNavigator.requestIssued",
            [
                "currentURL": webView?.url?.absoluteString ?? "nil",
                "elapsedSinceNavigatorLoad": readerLoadElapsedString(since: readerLoadRequestedAt, now: now),
                "estimatedProgress": webView.map { String(format: "%.3f", $0.estimatedProgress) } ?? "nil",
                "hasSuperview": "\(webView?.superview != nil)",
                "hasWindow": "\(webView?.window != nil)",
                "isLoading": "\(webView?.isLoading ?? false)",
                "prewarmCompleted": "false",
                "prewarmElapsed": "nil",
                "prewarmState": "idle",
                "prewarmWebViewID": "nil",
                "processPoolID": readerLoadObjectIDString(webView?.configuration.processPool),
                "reason": reason,
                "requestURL": readerLoadRequestedURL?.absoluteString ?? "nil",
                "traceID": readerLoadTraceID ?? "nil",
                "webViewID": readerLoadObjectIDString(webView),
                "url": request.url?.absoluteString ?? "nil"
            ]
        )
    }

    @MainActor
    public func forceClearLoadingIndicators(reason: String, pageURL: URL? = nil) {
        readerLoadLog(
            "webViewNavigator.forceClearLoadingIndicators.requested",
            [
                "currentURL": webView?.url?.absoluteString ?? "nil",
                "hasHandler": "\(forceClearLoadingIndicatorsHandler != nil)",
                "pageURL": pageURL?.absoluteString ?? "nil",
                "reason": reason
            ]
        )
        forceClearLoadingIndicatorsHandler?(reason, pageURL)
    }

    @MainActor
    func cancelPendingRequestLoadTask() {
        pendingRequestLoadGeneration &+= 1
        pendingRequestLoadTask?.cancel()
        pendingRequestLoadTask = nil
    }

    @MainActor
    private func cancelAttachFallbackLoadTask(reason: String? = nil) {
        attachFallbackLoadGeneration &+= 1
        attachFallbackLoadTask?.cancel()
        attachFallbackLoadTask = nil
        if let reason {
            readerLoadLog(
                "webViewNavigator.attachFallbackCanceled",
                [
                    "reason": reason,
                    "pendingRequest": pendingRequest?.url?.absoluteString ?? "nil",
                    "hasPendingHTML": "\(pendingHTML != nil)",
                    "hasPendingDataLoad": "\(pendingDataLoad != nil)"
                ]
            )
        }
    }

    @MainActor
    private func scheduleAttachFallbackLoad(on webView: WKWebView) {
        cancelAttachFallbackLoadTask()
        let generation = attachFallbackLoadGeneration
        let fallbackURL = attachFallbackURL ?? URL(string: "about:blank")!
        let delayNanoseconds = attachFallbackDelayNanoseconds
        readerLoadLog(
            "webViewNavigator.attachFallbackScheduled",
            [
                "delayMs": "\(delayNanoseconds / 1_000_000)",
                "url": fallbackURL.absoluteString
            ]
        )
        attachFallbackLoadTask = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            guard self.attachFallbackLoadGeneration == generation else { return }
            if let requestedURL = self.readerLoadRequestedURL,
               requestedURL.absoluteString != fallbackURL.absoluteString,
               self.readerLoadProvisionalStartedAt == nil,
               (self.readerLoadIssuedAt != nil || webView.isLoading) {
                readerLoadLog(
                    "webViewNavigator.attachFallbackSuppressed",
                    [
                        "reason": "requestInFlight",
                        "url": fallbackURL.absoluteString,
                        "requestURL": requestedURL.absoluteString,
                        "currentURL": webView.url?.absoluteString ?? "nil",
                        "elapsedSinceIssued": readerLoadElapsedString(since: self.readerLoadIssuedAt),
                        "isLoading": "\(webView.isLoading)"
                    ]
                )
                self.attachFallbackLoadTask = nil
                return
            }
            guard self.pendingRequest == nil, self.pendingHTML == nil, self.pendingDataLoad == nil else {
                readerLoadLog(
                    "webViewNavigator.attachFallbackSuppressed",
                    [
                        "reason": "pendingContentArrived",
                        "url": fallbackURL.absoluteString,
                        "pendingRequest": self.pendingRequest?.url?.absoluteString ?? "nil",
                        "hasPendingHTML": "\(self.pendingHTML != nil)",
                        "hasPendingDataLoad": "\(self.pendingDataLoad != nil)"
                    ]
                )
                self.attachFallbackLoadTask = nil
                return
            }
            guard webView.window != nil || webView.superview != nil else {
                readerLoadLog(
                    "webViewNavigator.attachFallbackSuppressed",
                    [
                        "reason": "webViewNotAttached",
                        "url": fallbackURL.absoluteString
                    ]
                )
                self.attachFallbackLoadTask = nil
                return
            }
            readerLoadLog(
                "webViewNavigator.attachFallbackShown",
                [
                    "url": fallbackURL.absoluteString
                ]
            )
            webView.load(URLRequest(url: fallbackURL))
            self.attachFallbackLoadTask = nil
        }
    }

    @MainActor
    private func schedulePendingRequestLoadRetry(
        request: URLRequest,
        webView: WKWebView,
        attempt: Int,
        generation: Int
    ) {
        pendingRequestLoadTask?.cancel()
        pendingRequestLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var currentAttempt = attempt
            while currentAttempt <= 60 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                guard self.pendingRequestLoadGeneration == generation else { return }
                if self.shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
                }
                guard self.pendingRequest?.url == request.url else { return }
                if webView.window != nil && webView.superview != nil {
                    if self.shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
                    }
                    if let url = request.url, url.isFileURL {
                        webView.loadFileURL(url, allowingReadAccessTo: url)
                    } else {
                        webView.load(request)
                    }
                    self.pendingRequestLoadGeneration &+= 1
                    self.pendingRequestLoadTask = nil
                    return
                }
                currentAttempt += 1
            }
            if self.shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
            }
            self.pendingRequestLoadTask = nil
        }
    }

    @MainActor
    private func issuePendingRequestLoad(_ request: URLRequest, on webView: WKWebView, restartIfSameURL: Bool, diagnosticsReason: String) {
        logPreIssueLoadState(for: request, reason: "issuePendingRequestLoad:\(diagnosticsReason)")
        if recoverFromStaleAboutBlankIfNeeded(
            for: request,
            on: webView,
            reason: "issuePendingRequestLoad:\(diagnosticsReason)"
        ) {
            return
        }
        let disposition = PendingRequestLoadDisposition.resolve(
            requestURL: request.url,
            hasWindow: webView.window != nil,
            hasSuperview: webView.superview != nil,
            currentURL: webView.url,
            isLoading: webView.isLoading,
            restartIfSameURL: restartIfSameURL
        )
        if shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
        }
        switch disposition {
        case .deferUntilAttached:
            if shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
            }
            return
        case .skipAlreadyLoading:
            if shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
            }
            let nextGeneration = pendingRequestLoadGeneration
            if shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
            }
            if webView.url == request.url {
                markReaderLoadIssued(for: request, reason: "reload:\(diagnosticsReason)")
                logCompetingOperationIfNeeded(
                    "reload",
                    metadata: [
                        "reason": diagnosticsReason,
                        "targetURL": request.url?.absoluteString ?? "nil"
                    ]
                )
                webView.reload()
            } else if let url = request.url, url.isFileURL {
                markReaderLoadIssued(for: request, reason: "loadFileURL:\(diagnosticsReason)")
                webView.loadFileURL(url, allowingReadAccessTo: url)
            } else {
                markReaderLoadIssued(for: request, reason: "loadRequest:\(diagnosticsReason)")
                webView.load(request)
            }
            self.schedulePendingRequestLoadRetry(
                request: request,
                webView: webView,
                attempt: 1,
                generation: nextGeneration
            )
            return
        case .loadFileURL:
            guard let url = request.url else { return }
            markReaderLoadIssued(for: request, reason: "loadFileURL:\(diagnosticsReason)")
            readerLoadLog(
                "webViewNavigator.loadFileURLBegin",
                [
                    "currentURL": webView.url?.absoluteString ?? "nil",
                    "reason": diagnosticsReason,
                    "url": url.absoluteString
                ]
            )
            webView.loadFileURL(url, allowingReadAccessTo: url)
            readerLoadLog(
                "webViewNavigator.loadFileURLEnd",
                [
                    "currentURL": webView.url?.absoluteString ?? "nil",
                    "elapsedSinceIssued": readerLoadElapsedString(since: readerLoadIssuedAt),
                    "reason": diagnosticsReason,
                    "url": url.absoluteString
                ]
            )
        case .loadRequest:
            markReaderLoadIssued(for: request, reason: "loadRequest:\(diagnosticsReason)")
            readerLoadLog(
                "webViewNavigator.loadRequestBegin",
                [
                    "currentURL": webView.url?.absoluteString ?? "nil",
                    "reason": diagnosticsReason,
                    "url": request.url?.absoluteString ?? "nil"
                ]
            )
            webView.load(request)
            readerLoadLog(
                "webViewNavigator.loadRequestEnd",
                [
                    "currentURL": webView.url?.absoluteString ?? "nil",
                    "elapsedSinceIssued": readerLoadElapsedString(since: readerLoadIssuedAt),
                    "reason": diagnosticsReason,
                    "url": request.url?.absoluteString ?? "nil"
                ]
            )
        }
        self.cancelPendingRequestLoadTask()
    }

    @MainActor
    func handleWindowAttachmentChanged(isAttached: Bool, webView: WKWebView) {
        logAttachmentEvent("handleWindowAttachmentChanged", webView: webView)
        let isReadyForRequest = webView.window != nil && webView.superview != nil
        if shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
        }
        guard isAttached, let request = pendingRequest else { return }
        if shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
        }
        guard webView.navigationDelegate != nil else {
            if shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
            }
            return
        }
        issuePendingRequestLoad(request, on: webView, restartIfSameURL: true, diagnosticsReason: "windowAttachmentChanged")
    }
    
    @MainActor
    weak var webView: WKWebView? {
        didSet {
            let shouldLogDiagnostics = ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1"
            || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1"
            let nextHasAttachedWebView = webView != nil
            if hasAttachedWebView != nextHasAttachedWebView {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.hasAttachedWebView = nextHasAttachedWebView
                }
            }
            readerLoadLog(
                "webView.navigatorBindingChanged",
                [
                    "navigatorID": readerLoadObjectIDString(self),
                    "newProcessPoolID": readerLoadObjectIDString(webView?.configuration.processPool),
                    "newURL": webView?.url?.absoluteString ?? "nil",
                    "newWebViewID": readerLoadObjectIDString(webView),
                    "oldWebViewID": readerLoadObjectIDString(oldValue)
                ]
            )
            if shouldLogDiagnostics || !shouldLoadFallbackOnAttach {
            }
            guard let webView else { return }
            if let request = pendingRequest {
                cancelAttachFallbackLoadTask(reason: "pendingRequestFlushedOnAttach")
                readerLoadLog(
                    "webViewNavigator.pendingRequestFlush",
                    [
                        "url": request.url?.absoluteString ?? "nil",
                        "elapsedSincePendingSet": readerLoadElapsedString(since: pendingRequestSetAt),
                        "webViewID": readerLoadObjectIDString(webView),
                        "hasSuperview": "\(webView.superview != nil)",
                        "hasWindow": "\(webView.window != nil)"
                    ]
                )
                if shouldLogDiagnostics || !shouldLoadFallbackOnAttach {
                }
                if webView.window == nil || webView.superview == nil {
                    if shouldLogDiagnostics || !shouldLoadFallbackOnAttach {
                    }
                    return
                }
                issuePendingRequestLoad(request, on: webView, restartIfSameURL: true, diagnosticsReason: "webViewDidSet.attached")
                pendingRequestSetAt = nil
                return
            }
            if let pendingDataLoad {
                cancelAttachFallbackLoadTask(reason: "pendingDataLoadFlushedOnAttach")
                readerLoadLog(
                    "webViewNavigator.pendingDataLoadFlush",
                    [
                        "baseURL": pendingDataLoad.baseURL.absoluteString,
                        "bytes": "\(pendingDataLoad.data.count)",
                        "elapsedSincePendingSet": readerLoadElapsedString(since: pendingDataLoadSetAt),
                        "webViewID": readerLoadObjectIDString(webView),
                        "hasSuperview": "\(webView.superview != nil)",
                        "hasWindow": "\(webView.window != nil)"
                    ]
                )
                if shouldLogDiagnostics || !shouldLoadFallbackOnAttach {
                }
                webView.load(
                    pendingDataLoad.data,
                    mimeType: pendingDataLoad.mimeType,
                    characterEncodingName: pendingDataLoad.characterEncodingName,
                    baseURL: pendingDataLoad.baseURL
                )
                self.pendingDataLoad = nil
                self.pendingDataLoadSetAt = nil
                return
            }
            if let pendingHTML {
                cancelAttachFallbackLoadTask(reason: "pendingHTMLFlushedOnAttach")
                readerLoadLog(
                    "webViewNavigator.pendingHTMLFlush",
                    [
                        "baseURL": pendingHTML.baseURL?.absoluteString ?? "nil",
                        "htmlLength": "\(pendingHTML.html.count)",
                        "elapsedSincePendingSet": readerLoadElapsedString(since: pendingHTMLSetAt),
                        "webViewID": readerLoadObjectIDString(webView),
                        "hasSuperview": "\(webView.superview != nil)",
                        "hasWindow": "\(webView.window != nil)"
                    ]
                )
                if shouldLogDiagnostics || !shouldLoadFallbackOnAttach {
                }
                webView.loadHTMLString(pendingHTML.html, baseURL: pendingHTML.baseURL)
                self.pendingHTML = nil
                self.pendingHTMLSetAt = nil
                return
            }
            guard shouldLoadFallbackOnAttach else {
                return
            }
            scheduleAttachFallbackLoad(on: webView)
        }
    }
    
    @MainActor
    public var backForwardList: WKBackForwardList {
        return webView?.backForwardList ?? WKBackForwardList()
    }
    
    @MainActor
    public func load(_ request: URLRequest) {
        lastLoadedRequest = request
        lastLoadedHTML = nil
        lastLoadedDataLoad = nil
        cancelAttachFallbackLoadTask(reason: "explicitRequestLoad")
        beginReaderLoadTrace(for: request)
        if let webView = webView {
            logPreIssueLoadState(for: request, reason: "navigator.load")
            if webView.window == nil || webView.superview == nil {
                pendingRequest = request
                pendingRequestSetAt = Date()
                readerLoadLog(
                    "webViewNavigator.requestDeferredUntilAttached",
                    [
                        "url": request.url?.absoluteString ?? "nil",
                        "hasSuperview": "\(webView.superview != nil)",
                        "hasWindow": "\(webView.window != nil)"
                    ]
                )
                return
            }
            if recoverFromStaleAboutBlankIfNeeded(for: request, on: webView, reason: "navigator.load") {
                return
            }
            if let url = request.url, url.isFileURL {
                markReaderLoadIssued(for: request, reason: "navigator.loadFileURL")
                logCompetingOperationIfNeeded(
                    "loadFileURL",
                    metadata: [
                        "reason": "navigator.loadFileURL",
                        "targetURL": url.absoluteString
                    ]
                )
                readerLoadLog(
                    "webViewNavigator.directLoadFileURLBegin",
                    [
                        "currentURL": webView.url?.absoluteString ?? "nil",
                        "hasSuperview": "\(webView.superview != nil)",
                        "hasWindow": "\(webView.window != nil)",
                        "reason": "navigator.loadFileURL",
                        "sceneState": readerLoadSceneStateString(for: webView),
                        "url": url.absoluteString
                    ]
                )
                webView.loadFileURL(url, allowingReadAccessTo: url)
                readerLoadLog(
                    "webViewNavigator.directLoadFileURLEnd",
                    [
                        "currentURL": webView.url?.absoluteString ?? "nil",
                        "elapsedSinceIssued": readerLoadElapsedString(since: readerLoadIssuedAt),
                        "reason": "navigator.loadFileURL",
                        "sceneState": readerLoadSceneStateString(for: webView),
                        "url": url.absoluteString
                    ]
                )
            } else {
                markReaderLoadIssued(for: request, reason: "navigator.loadRequest")
                readerLoadLog(
                    "webViewNavigator.directLoadRequestBegin",
                    [
                        "currentURL": webView.url?.absoluteString ?? "nil",
                        "hasSuperview": "\(webView.superview != nil)",
                        "hasWindow": "\(webView.window != nil)",
                        "reason": "navigator.loadRequest",
                        "sceneState": readerLoadSceneStateString(for: webView),
                        "url": request.url?.absoluteString ?? "nil"
                    ]
                )
                webView.load(request)
                readerLoadLog(
                    "webViewNavigator.directLoadRequestEnd",
                    [
                        "currentURL": webView.url?.absoluteString ?? "nil",
                        "elapsedSinceIssued": readerLoadElapsedString(since: readerLoadIssuedAt),
                        "reason": "navigator.loadRequest",
                        "sceneState": readerLoadSceneStateString(for: webView),
                        "url": request.url?.absoluteString ?? "nil"
                    ]
                )
            }
        } else {
            pendingRequest = request
            pendingRequestSetAt = Date()
        }
    }
    
    @MainActor
    public func load(_ data: Data, mimeType: String, characterEncodingName: String, baseURL: URL) {
        lastLoadedDataLoad = (data: data, mimeType: mimeType, characterEncodingName: characterEncodingName, baseURL: baseURL)
        lastLoadedRequest = nil
        lastLoadedHTML = nil
        cancelAttachFallbackLoadTask(reason: "explicitDataLoad")
        let traceRequestedAt = beginReaderLoadTrace(for: baseURL)
        readerLoadIssuedAt = traceRequestedAt
        currentReaderLoadTrace?.directDataIssuedAt = traceRequestedAt
        readerLoadProvisionalStartedAt = nil
        readerLoadCommittedAt = nil
        readerLoadLog(
            "webViewNavigator.dataLoadIssued",
            [
                "baseURL": baseURL.absoluteString,
                "bytes": "\(data.count)",
                "hasSuperview": "\(webView?.superview != nil)",
                "hasWindow": "\(webView?.window != nil)",
                "mimeType": mimeType
            ]
        )
        logCompetingOperationIfNeeded(
            "loadData",
            metadata: [
                "baseURL": baseURL.absoluteString,
                "bytes": "\(data.count)"
            ]
        )
        guard let webView else {
            pendingDataLoad = (data: data, mimeType: mimeType, characterEncodingName: characterEncodingName, baseURL: baseURL)
            pendingDataLoadSetAt = Date()
            return
        }
        readerLoadLog(
            "webViewNavigator.dataLoadDirect",
            [
                "baseURL": baseURL.absoluteString,
                "bytes": "\(data.count)",
                "traceID": currentReaderLoadTrace?.id.uuidString ?? "nil",
                "webViewID": readerLoadObjectIDString(webView),
                "hasSuperview": "\(webView.superview != nil)",
                "hasWindow": "\(webView.window != nil)"
            ]
        )
        webView.load(
            data,
            mimeType: mimeType,
            characterEncodingName: characterEncodingName,
            baseURL: baseURL
        )
        currentReaderLoadTrace?.directDataReturnedAt = Date()
        readerLoadLog(
            "webViewNavigator.dataLoadReturned",
            [
                "baseURL": baseURL.absoluteString,
                "elapsedSinceDataLoadIssued": readerLoadDirectDataElapsedString(),
                "traceID": currentReaderLoadTrace?.id.uuidString ?? "nil",
                "webViewID": readerLoadObjectIDString(webView)
            ]
        )
    }

    @MainActor
    public func loadHTML(_ html: String, baseURL: URL? = nil) {
        //                debugPrint("# WebViewNavigator.loadHTML(...)", html.prefix(100), baseURL)
        lastLoadedHTML = (html: html, baseURL: baseURL)
        lastLoadedRequest = nil
        lastLoadedDataLoad = nil
        cancelAttachFallbackLoadTask(reason: "explicitHTMLLoad")
        let traceRequestedAt = beginReaderLoadTrace(for: baseURL)
        readerLoadIssuedAt = traceRequestedAt
        readerLoadProvisionalStartedAt = nil
        readerLoadCommittedAt = nil
        readerLoadLog(
            "webViewNavigator.htmlLoadIssued",
            [
                "baseURL": baseURL?.absoluteString ?? "nil",
                "bytes": "\(html.utf8.count)",
                "hasSuperview": "\(webView?.superview != nil)",
                "hasWindow": "\(webView?.window != nil)"
        ]
        )
        logCompetingOperationIfNeeded(
            "loadHTML",
            metadata: [
                "baseURL": baseURL?.absoluteString ?? "nil",
                "bytes": "\(html.utf8.count)"
            ]
        )
        guard let webView else {
            pendingHTML = (html: html, baseURL: baseURL)
            pendingHTMLSetAt = Date()
            return
        }
        readerLoadLog(
            "webViewNavigator.htmlLoadDirect",
            [
                "baseURL": baseURL?.absoluteString ?? "nil",
                "bytes": "\(html.utf8.count)",
                "webViewID": readerLoadObjectIDString(webView),
                "hasSuperview": "\(webView.superview != nil)",
                "hasWindow": "\(webView.window != nil)"
            ]
        )
        webView.loadHTMLString(html, baseURL: baseURL)
    }
    
    @MainActor
    public func reload() {
        logCompetingOperationIfNeeded("reload", metadata: [:])
        webView?.reload()
    }

    @MainActor
    public func reloadLast() {
        if let lastLoadedHTML {
            loadHTML(lastLoadedHTML.html, baseURL: lastLoadedHTML.baseURL)
            return
        }
        if let lastLoadedDataLoad {
            load(
                lastLoadedDataLoad.data,
                mimeType: lastLoadedDataLoad.mimeType,
                characterEncodingName: lastLoadedDataLoad.characterEncodingName,
                baseURL: lastLoadedDataLoad.baseURL
            )
            return
        }
        if let lastLoadedRequest {
            load(lastLoadedRequest)
            return
        }
        reload()
    }

    @MainActor
    func prepareForReloadAfterReattach() {
        logCompetingOperationIfNeeded("prepareForReloadAfterReattach", metadata: [:])
        if let lastLoadedHTML {
            pendingHTML = lastLoadedHTML
        } else if let lastLoadedDataLoad {
            pendingDataLoad = lastLoadedDataLoad
        } else if let lastLoadedRequest {
            pendingRequest = lastLoadedRequest
        }
    }

    @MainActor
    public func reloadWithoutContentRules() {
        bypassContentRulesForNextNavigation = true
        logCompetingOperationIfNeeded("reloadWithoutContentRules", metadata: [:])
        webView?.reload()
    }

    @MainActor
    func consumeContentRulesBypass() -> Bool {
        let value = bypassContentRulesForNextNavigation
        bypassContentRulesForNextNavigation = false
        return value
    }

    @MainActor
    func peekContentRulesBypass() -> Bool {
        bypassContentRulesForNextNavigation
    }
    
    @MainActor
    public func go(_ item: WKBackForwardListItem) {
        webView?.go(to: item)
    }
    
    @MainActor
    public func goBack() {
        webView?.goBack()
    }
    
    @MainActor
    public func goForward() {
        webView?.goForward()
    }

    @MainActor
    public func withAttachedWebView<T>(
        _ operation: (WKWebView) async throws -> T
    ) async rethrows -> T? {
        guard let webView else { return nil }
        return try await operation(webView)
    }

    public override init() {
        super.init()
    }
}

enum ScriptCallerError: Error {
    case evaluationTimedOut
}

@MainActor
public class WebViewScriptCaller: /*Equatable,*/ Identifiable, ObservableObject {
    struct JavaScriptEvaluationResult: @unchecked Sendable {
        let value: Any?

        init(_ value: Any?) {
            self.value = value
        }
    }

    public let id = UUID().uuidString
    //    @Published var caller: ((String, ((Any?, Error?) -> Void)?) -> Void)? = nil
    //    var caller: (@Sendable (String, ((Any?, Error?) -> Void)?) -> Void)? = nil
    /// Indicates whether the backing WKWebView has registered an async JavaScript caller.
    @Published public private(set) var hasAsyncCaller = false
    private var asyncCallerReadinessGeneration = 0

    var asyncCaller: ( @Sendable
                       (
                        String,
                        [String: any Sendable]?,
                        WKFrameInfo?,
                        WKContentWorld?
                       ) async throws -> JavaScriptEvaluationResult
    )? = nil {
        didSet {
            asyncCallerReadinessGeneration += 1
            let generation = asyncCallerReadinessGeneration
            let isReady = asyncCaller != nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.asyncCallerReadinessGeneration == generation else { return }
                if self.hasAsyncCaller != isReady {
                    self.hasAsyncCaller = isReady
                }
            }
        }
    }
    
    private var multiTargetFrames = [String: WKFrameInfo]()
    private var framesByCanonicalURL = [String: WKFrameInfo]()
    private var lastKnownMainFrame: WKFrameInfo?
    
    //    public static func == (lhs: WebViewScriptCaller, rhs: WebViewScriptCaller) -> Bool {
    //        return lhs.id == rhs.id
    //    }

    private func canonicalizedURL(_ url: URL) -> URL {
        if url.scheme?.lowercased() == "internal",
           url.host?.lowercased() == "local",
           url.path == "/load/reader",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let readerURLValue = components.queryItems?.first(where: { $0.name == "reader-url" })?.value {
            if let decoded = readerURLValue.removingPercentEncoding, let resolved = URL(string: decoded) {
                return resolved
            } else if let resolved = URL(string: readerURLValue) {
                return resolved
            }
        }
        return url
    }

    private func canonicalFrameKey(for url: URL?) -> String? {
        guard let url else { return nil }
        let resolved = canonicalizedURL(url)
        var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? resolved.absoluteString
    }

    private func normalizeJavaScriptResult(_ value: Any?) -> Any? {
        switch value {
        case nil, is NSNull:
            return nil
        case let string as NSString:
            return String(string)
        case let url as URL:
            return url.absoluteString
        case let number as NSNumber:
            return number
        case let dict as NSDictionary:
            return dict as? [String: Any]
        case let array as NSArray:
            return array as? [Any]
        default:
            return value
        }
    }

    //    @MainActor
    @discardableResult
    public func evaluateJavaScript(
        _ js: String,
        arguments: [String: any Sendable]? = nil,
        in frame: WKFrameInfo? = nil,
        duplicateInMultiTargetFrames: Bool = false,
        in world: WKContentWorld? = nil
    ) async throws -> Any? {
        guard let asyncCaller else {
            print("No asyncCaller set for WebViewScriptCaller \(id)") // TODO: Error
            throw ScriptCallerError.evaluationTimedOut
        }

        let primitiveArguments: [String: any Sendable]? = arguments?.mapValues {
            if let set = $0 as? Set<AnyHashable> {
                return Array(set) as! any Sendable
            }
            return $0
        }
        var primaryError: Error?
        var result: Any?

        do {
            //            result = try await asyncCaller(js, primitiveArguments, frame, world)
            result = try await asyncCaller(js, primitiveArguments, frame, world).value
        } catch {
            primaryError = error
        }

        if duplicateInMultiTargetFrames {
            await { @MainActor [weak self] in
                guard let self else { return }
                for (uuid, targetFrame) in multiTargetFrames.filter({ !$0.value.isMainFrame }) {
                    if targetFrame == frame { continue }
                    do {
                        _ = try await asyncCaller(js, primitiveArguments, targetFrame, world)
                    } catch {
                        if let error = error as? WKError, error.code == .javaScriptInvalidFrameTarget {
                            multiTargetFrames.removeValue(forKey: uuid)
                        } else {
                            print(error)
                        }
                    }
                }
            }()
        }
        if var primaryError {
            var handled = false
            var nsError = primaryError as NSError
            if nsError.domain == WKError.errorDomain,
               nsError.code == WKError.javaScriptResultTypeIsUnsupported.rawValue {
                // WK sometimes classifies simple primitives (e.g. window.location.href) as "unsupported";
                // coerce them instead of aborting the readability pipeline.
                let trimmed = js.trimmingCharacters(in: .whitespacesAndNewlines)
                // Coerce common primitives (like window.location.href) instead of failing the whole pipeline.
                if trimmed == "window.location.href" || trimmed.contains("window.location.href") {
                    do {
                        result = try await asyncCaller(
                            "(function () { try { return String(window.location && window.location.href) } catch (_) { return null } })();",
                            primitiveArguments,
                            frame,
                            world
                        ).value
                        handled = true
#if DEBUG
#endif
                    } catch {
                        primaryError = error
                        nsError = error as NSError
                    }
                }
                if !handled {
                    // Treat unsupported result types as a benign nil so DOM snapshot can continue.
                    result = nil
                    handled = true
#if DEBUG
#endif
                }
            } else if nsError.domain == WKError.errorDomain,
                      nsError.code == WKError.javaScriptInvalidFrameTarget.rawValue {
                // Stale WKFrameInfo from a prior navigation can trigger "invalid frame" even after we pick a URL match.
                // Drop the cached main frame so we fall back to the current main frame next time instead of hard‑failing.
                if let frame, frame == lastKnownMainFrame {
                    lastKnownMainFrame = nil
                }
                result = nil
                handled = true
#if DEBUG
#endif
            } else if nsError.domain == WKError.errorDomain,
                      nsError.code == WKError.javaScriptExceptionOccurred.rawValue,
                      nsError.userInfo["WKJavaScriptExceptionMessage"] as? String == "Cannot execute JavaScript in this document" {
                result = nil
                handled = true
            }
            if !handled {
#if DEBUG
#endif
                throw primaryError
            }
        }
        return normalizeJavaScriptResult(result)
    }

    public func evaluateJavaScriptInMultiTargetFrames(
        _ js: String,
        arguments: [String: any Sendable]? = nil,
        in world: WKContentWorld? = nil
    ) async throws -> [Any?] {
        guard let asyncCaller else {
            print("No asyncCaller set for WebViewScriptCaller \(id)") // TODO: Error
            throw ScriptCallerError.evaluationTimedOut
        }

        let primitiveArguments: [String: any Sendable]? = arguments?.mapValues {
            if let set = $0 as? Set<AnyHashable> {
                return Array(set) as! any Sendable
            }
            return $0
        }

        var results = [Any?]()
        results.append(try await asyncCaller(js, primitiveArguments, nil, world).value)

        await { @MainActor [weak self] in
            guard let self else { return }
            for (uuid, targetFrame) in multiTargetFrames.filter({ !$0.value.isMainFrame }) {
                do {
                    let result = try await asyncCaller(js, primitiveArguments, targetFrame, world).value
                    results.append(result)
                } catch {
                    if let error = error as? WKError, error.code == .javaScriptInvalidFrameTarget {
                        multiTargetFrames.removeValue(forKey: uuid)
                    } else {
                        print(error)
                    }
                }
            }
        }()

        return results.map(normalizeJavaScriptResult)
    }

    /// Returns whether the frame was already added.
    @MainActor
    public func addMultiTargetFrame(_ frame: WKFrameInfo, uuid: String, canonicalURL: URL? = nil) -> Bool {
        var inserted = true
        if multiTargetFrames.keys.contains(uuid) && multiTargetFrames[uuid]?.request.url == frame.request.url {
            inserted = false
        }
        multiTargetFrames[uuid] = frame
        let resolvedCanonicalURL = canonicalURL ?? frame.request.mainDocumentURL ?? frame.request.url
        if let key = canonicalFrameKey(for: resolvedCanonicalURL) {
            framesByCanonicalURL[key] = frame
        }
        if frame.isMainFrame {
            lastKnownMainFrame = frame
        }
        if frame.request.url == nil {
#if DEBUG
#endif
        }
#if DEBUG
#endif
        return inserted
    }
    
    @MainActor
    public func removeAllMultiTargetFrames() {
        if !multiTargetFrames.isEmpty || !framesByCanonicalURL.isEmpty {
#if DEBUG
#endif
        }
        multiTargetFrames.removeAll()
        framesByCanonicalURL.removeAll()
    }

    @MainActor
    public func frame(for url: URL?) -> WKFrameInfo? {
        if let key = canonicalFrameKey(for: url), let frame = framesByCanonicalURL[key] {
            return frame
        }
        if let mainFrame = lastKnownMainFrame {
            return mainFrame
        }
        if let anyFrame = multiTargetFrames.values.first {
            return anyFrame
        }
        return nil
    }

    @MainActor
    public func frame(forUUID uuid: String) -> WKFrameInfo? {
        multiTargetFrames[uuid]
    }

    @MainActor
    public var mainFrameInfo: WKFrameInfo? {
        lastKnownMainFrame
    }
    
    public init() {
    }
}

@MainActor
fileprivate struct WebViewBackgroundStatusUserScript {
    let userScript: WebViewUserScript
    
    init() {
        let contents = """
(function() {
    const isEbook = window.top.location.origin.startsWith('ebook://');
    if (isEbook) {
        return;
    }

    let lastReportedBackground = null;

    function checkBodyBackground() {
        const body = document.body;
        if (!body) return;

        const computedStyle = window.getComputedStyle(body);
        const bgColor = computedStyle.getPropertyValue('background-color');
        const bgImage = computedStyle.getPropertyValue('background-image');

        const hasBackground = bgColor !== 'rgba(0, 0, 0, 0)' || bgImage !== 'none';

        if (hasBackground !== lastReportedBackground) {
            lastReportedBackground = hasBackground;
            if (window.webkit) {
                window.webkit.messageHandlers.swiftUIWebViewBackgroundStatus.postMessage(hasBackground);
            }
        }
    }

    const observer = new MutationObserver((mutations) => {
        checkBodyBackground();
        mutations.forEach((mutation) => {
            if (mutation.type === 'childList' && document.body) {
                checkBodyBackground();
                observeBodyStyle();
            } else if (mutation.type === 'attributes' && mutation.target === document.body) {
                checkBodyBackground();
            }
        });
    });

    function observeBodyStyle() {
        if (document.body) {
            const bodyObserver = new MutationObserver((mutations) => {
                mutations.forEach((mutation) => {
                    if (mutation.type === 'attributes' && mutation.attributeName.startsWith('style')) {
                        checkBodyBackground();
                    }
                });
            });
            bodyObserver.observe(document.body, { attributes: true, attributeFilter: ['style'] });
        }
    }

    if (document.body) {
        checkBodyBackground();
        observeBodyStyle();
    } else {
        observer.observe(document.documentElement, { childList: true, subtree: true });
    }
})()
"""
        userScript = WebViewUserScript(
            source: contents,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
    }
}

@MainActor
fileprivate struct LocationChangeUserScript {
    let userScript: WebViewUserScript
    
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
    if (window.webkit) {
        window.webkit.messageHandlers.swiftUIWebViewLocationChanged.postMessage(window.location.href);
    }
});
"""
        userScript = WebViewUserScript(
            source: contents,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
    }
}

@MainActor
fileprivate struct ImageChangeUserScript {
    let userScript: WebViewUserScript
    
    init() {
        let contents = """
var lastURL;
new MutationObserver(function(mutations) {
    let node = document.querySelector('head meta[property="og:image"]')
    if (node && window.webkit) {
        let url = node.getAttribute('content')
        if (lastURL === url) { return }
        window.webkit.messageHandlers.swiftUIWebViewImageUpdated.postMessage({
            imageURL: url, url: window.location.href})
        lastURL = url
    } else if (window.webkit) {
        let node = document.querySelector('#reader-header img')
        if (node && window.webkit) {
            let url = node.getAttribute('src')
            if (lastURL === url) { return }
            window.webkit.messageHandlers.swiftUIWebViewImageUpdated.postMessage({
                imageURL: url, url: window.location.href})
            lastURL = url
        }
    }
}).observe(document, {childList: true, subtree: true, attributes: true, attributeOldValue: false, attributeFilter: ['property', 'content']})
"""
        userScript = WebViewUserScript(
            source: contents,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
    }
}

@MainActor
fileprivate struct PageIconChangeUserScript {
    let userScript: WebViewUserScript
    
    init() {
        let contents = """
(function () {
    var lastURL = null;

    function resolveURL(url) {
        if (!url) return null;
        try {
            return new URL(url, window.location.origin).href;
        } catch (e) {
            return null;
        }
    }

    function getFaviconURL() {
        // Define the selectors in the order of preference.
        const selectors = [
            'link[rel="apple-touch-icon"]',
            'link[rel="shortcut icon"]',
            'link[rel="icon"]'
        ];

        for (let selector of selectors) {
            let element = document.querySelector(selector);
            if (element && element.getAttribute('href')) {
                return resolveURL(element.getAttribute('href'));
            }
        }
        return null;
    }

    function sendFaviconUpdate() {
        const url = getFaviconURL();
        if (url && url !== lastURL && window.webkit?.messageHandlers?.swiftUIWebViewPageIconUpdated) {
            window.webkit.messageHandlers.swiftUIWebViewPageIconUpdated.postMessage({
                pageIconURL: url,
                url: window.location.href,
            });
            lastURL = url;
        }
    }

    function init() {
        sendFaviconUpdate();

        new MutationObserver(() => {
            sendFaviconUpdate();
        }).observe(document.head, {
            childList: true,
            subtree: false, // Only need to observe the immediate head children
            attributes: true,
            attributeFilter: ['rel', 'href']
        });
    }

    if (document.readyState === 'complete') {
        init();
    } else {
        document.addEventListener('DOMContentLoaded', init);
    }
})();
"""
        userScript = WebViewUserScript(
            source: contents,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
    }
}

@MainActor
fileprivate struct ReaderDocStateUserScript {
    let userScript: WebViewUserScript

    init() {
        let contents = """
(function () {
    try {
        const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.readerDocState;
        if (!handler || typeof handler.postMessage !== "function") { return; }
        const bootstrapNow = (typeof performance !== "undefined" && typeof performance.now === "function")
            ? performance.now.bind(performance)
            : () => Date.now();
        const bootstrapStartedAt = bootstrapNow();
        let stateMachine = { stopped: false, attempts: 0 };
        let rafHandle = { value: 0 };
        let timeoutHandle = { value: 0 };
        let observer = new MutationObserver(() => {
            postState("mutation");
        });
        function rounded(value) {
            if (typeof value !== "number" || !Number.isFinite(value)) { return null; }
            return Math.round(value * 1000) / 1000;
        }
        function describeNode(node) {
            if (!node || typeof node.getBoundingClientRect !== "function") { return null; }
            const rect = node.getBoundingClientRect();
            const style = window.getComputedStyle(node);
            return {
                tag: node.tagName || null,
                id: node.id || null,
                className: typeof node.className === "string" ? node.className : null,
                textLength: (node.textContent || "").trim().length,
                display: style.display,
                visibility: style.visibility,
                opacity: style.opacity,
                color: style.color,
                backgroundColor: style.backgroundColor,
                rect: {
                    x: rounded(rect.x),
                    y: rounded(rect.y),
                    width: rounded(rect.width),
                    height: rounded(rect.height)
                }
            };
        }
        function currentState(reason) {
            const html = document.documentElement;
            const body = document.body;
            const readerContent = document.getElementById("reader-content");
            const readerStage = document.getElementById("reader-stage");
            const foliateView = readerStage?.querySelector?.("foliate-view") ?? document.querySelector("foliate-view");
            const bodyStyle = body ? window.getComputedStyle(body) : null;
            const htmlStyle = html ? window.getComputedStyle(html) : null;
            const readerContentStyle = readerContent ? window.getComputedStyle(readerContent) : null;
            const foliateViewStyle = foliateView ? window.getComputedStyle(foliateView) : null;
            const bodyRect = body?.getBoundingClientRect?.() ?? null;
            const readerContentRect = readerContent?.getBoundingClientRect?.() ?? null;
            const readerStageRect = readerStage?.getBoundingClientRect?.() ?? null;
            const foliateViewRect = foliateView?.getBoundingClientRect?.() ?? null;
            const centerX = Math.max(0, Math.round(window.innerWidth / 2));
            const centerY = Math.max(0, Math.round(window.innerHeight / 2));
            const elementAtCenter = document.elementFromPoint(centerX, centerY);
            const readerContentText = (readerContent?.textContent || "").trim();
            const hasReaderModeContent = !!readerContent;
            const hasVisibleReaderModeContent = !!readerContent
                && !!readerContentRect
                && readerContentRect.width > 1
                && readerContentRect.height > 1
                && readerContentStyle?.visibility !== 'hidden'
                && readerContentStyle?.display !== 'none'
                && Number.parseFloat(readerContentStyle?.opacity || "1") > 0.01
                && readerContentText.length > 0;
            const hasVisibleFoliateView = !!foliateView
                && !!foliateViewRect
                && foliateViewRect.width > 1
                && foliateViewRect.height > 1
                && foliateViewStyle?.visibility !== 'hidden'
                && foliateViewStyle?.display !== 'none'
                && Number.parseFloat(foliateViewStyle?.opacity || "1") > 0.01;
            return {
                href: window.location.href,
                elapsedMs: rounded(bootstrapNow() - bootstrapStartedAt),
                readyState: document.readyState,
                hasBody: !!body,
                hasReaderContent: hasReaderModeContent || hasVisibleFoliateView,
                hasReadabilityGlobal: typeof window.manabi_readability === 'function',
                manabiFontPending: html?.dataset?.manabiFontPending ?? null,
                manabiFontReady: html?.dataset?.manabiFontReady ?? null,
                bodyLoading: body?.classList?.contains?.("loading") ?? false,
                hasCustomFontStyle: !!document.getElementById("manabi-custom-fonts-inline"),
                hasCustomFontGate: !!document.getElementById("manabi-custom-font-gate"),
                fontsStatus: document.fonts?.status ?? null,
                bodyClassName: body?.className ?? null,
                bodyDisplay: bodyStyle?.display ?? null,
                bodyVisibility: bodyStyle?.visibility ?? null,
                bodyOpacity: bodyStyle?.opacity ?? null,
                bodyRect: bodyRect ? {
                    width: rounded(bodyRect.width),
                    height: rounded(bodyRect.height)
                } : null,
                htmlDisplay: htmlStyle?.display ?? null,
                htmlVisibility: htmlStyle?.visibility ?? null,
                htmlOpacity: htmlStyle?.opacity ?? null,
                readerContentRect: readerContentRect ? {
                    x: rounded(readerContentRect.x),
                    y: rounded(readerContentRect.y),
                    width: rounded(readerContentRect.width),
                    height: rounded(readerContentRect.height)
                } : null,
                readerStageRect: readerStageRect ? {
                    x: rounded(readerStageRect.x),
                    y: rounded(readerStageRect.y),
                    width: rounded(readerStageRect.width),
                    height: rounded(readerStageRect.height)
                } : null,
                foliateViewRect: foliateViewRect ? {
                    x: rounded(foliateViewRect.x),
                    y: rounded(foliateViewRect.y),
                    width: rounded(foliateViewRect.width),
                    height: rounded(foliateViewRect.height)
                } : null,
                hasVisibleFoliateView,
                readerContentChildCount: readerContent?.childElementCount ?? null,
                readerContentTextLength: readerContentText.length,
                visibleMarkAsReadButtonCount: Array.from(document.querySelectorAll(".mnb-tracking-button")).filter((button) => {
                    const style = window.getComputedStyle(button);
                    return style.display !== "none"
                        && style.visibility !== "hidden"
                        && Number.parseFloat(style.opacity || "1") > 0.01;
                }).length,
                hasReaderRenderReady:
                    ((((html?.dataset?.manabiReaderRenderReady === '1'
                    || body?.dataset?.manabiReaderRenderReady === '1')
                    && hasReaderModeContent)
                    || hasVisibleReaderModeContent)
                    || hasVisibleFoliateView)
                    && (html?.dataset?.manabiFontPending ?? null) !== '1'
                    && bodyStyle?.visibility !== 'hidden'
                    && bodyStyle?.display !== 'none'
                    && Number.parseFloat(bodyStyle?.opacity || "1") > 0.01,
                viewport: {
                    innerWidth: window.innerWidth,
                    innerHeight: window.innerHeight,
                    scrollX: rounded(window.scrollX),
                    scrollY: rounded(window.scrollY)
                },
                elementAtCenter: describeNode(elementAtCenter),
                centerClosestReaderContent: describeNode(elementAtCenter?.closest?.("#reader-content") ?? null),
                reason,
                attempts: stateMachine.attempts
            };
        }
        function stopPolling() {
            if (stateMachine.stopped) { return; }
            stateMachine.stopped = true;
            try { observer.disconnect(); } catch (_error) {}
            if (rafHandle.value) { cancelAnimationFrame(rafHandle.value); }
            if (timeoutHandle.value) { clearTimeout(timeoutHandle.value); }
        }
        function postState(reason) {
            const state = currentState(reason);
            handler.postMessage(state);
            if (state.hasReaderRenderReady) {
                stopPolling();
                return true;
            }
            return false;
        }
        let attempts = 0;
        function scheduleNextTick() {
            if (stateMachine.stopped || stateMachine.attempts >= 80) { return; }
            stateMachine.attempts += 1;
            rafHandle.value = requestAnimationFrame(() => {
                timeoutHandle.value = setTimeout(() => {
                    if (!postState("poll")) {
                        scheduleNextTick();
                    }
                }, 25);
            });
        }
        if (document.documentElement) {
            observer.observe(document.documentElement, {
                childList: true,
                subtree: true,
                attributes: true,
                attributeFilter: ["data-manabi-reader-render-ready", "class", "style"]
            });
        }
        document.addEventListener("readystatechange", () => { postState("readystatechange"); });
        document.addEventListener("DOMContentLoaded", () => { postState("domcontentloaded"); });
        window.addEventListener("load", () => { postState("load"); });
        if (!postState("initial")) {
            scheduleNextTick();
        }
    } catch (e) { /* noop */ }
})();
"""
        userScript = WebViewUserScript(
            source: contents,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .page
        )
    }
}

@MainActor
fileprivate struct ReaderBootstrapPingUserScript {
    let userScript: WebViewUserScript

    init() {
        let contents = """
(function () {
    try {
        const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.readerBootstrapPing;
        if (!handler || typeof handler.postMessage !== "function") { return; }
        handler.postMessage({
            href: window.location.href,
            readyState: document.readyState
        });
    } catch (e) { /* noop */ }
})();
"""
        userScript = WebViewUserScript(
            source: contents,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
    }
}

@MainActor
fileprivate struct UnhandledTapUserScript {
    let userScript: WebViewUserScript
    
    init() {
        let contents = """
(function() {
    const handlerName = 'swiftUIWebViewUnhandledTap';
    if (!window.webkit?.messageHandlers?.[handlerName]) {
        return;
    }

    const interactiveSelectors = '#nav-bar,#progress-wrapper,.nav-relocate-button,.nav-section-progress,mnb-seg,mnb-seg *,a[href],button,input,textarea,select,summary,label,[role="button"],[role="link"],[role="menuitem"],[role="tab"],[contenteditable="true"]';
    const MOVE_THRESHOLD = 8;
    const LONG_PRESS_THRESHOLD_MS = 450;
    const activePointers = new Map();

    function logPopover(stage, payload = {}) {
        void stage;
        void payload;
    }

    function isEbookPage() {
        try {
            if (window.manabi_isEbook === true) {
                return true;
            }
            if (window.location?.origin?.startsWith('ebook://')) {
                return true;
            }
            return window.top?.location?.origin?.startsWith('ebook://') === true;
        } catch (_error) {
            return window.manabi_isEbook === true
                || window.location?.origin?.startsWith('ebook://') === true;
        }
    }

    if (isEbookPage()) {
        return;
    }

    function selectionText() {
        const sel = window.getSelection();
        if (!sel || sel.rangeCount === 0) {
            return '';
        }
        return sel.toString() || '';
    }

    function elementLooksInteractive(element) {
        if (!element || !(element instanceof Element)) {
            return false;
        }
        if (element.matches(interactiveSelectors) || element.closest(interactiveSelectors)) {
            return true;
        }
        if (element.hasAttribute('onclick')) {
            return true;
        }
        if (element.tabIndex >= 0 && element.getAttribute('tabindex') !== '-1') {
            return true;
        }
        return false;
    }

    function pathContainsInteractive(path) {
        if (!Array.isArray(path)) return false;
        return path.some(node => elementLooksInteractive(node));
    }

    function registerPointer(event) {
        const path = event.composedPath ? event.composedPath() : [];
        if (pathContainsInteractive(path)) {
            logPopover('pointerDown.skipInteractive', {
                pointerId: event.pointerId,
                clientX: event.clientX ?? null,
                clientY: event.clientY ?? null,
                targetTag: event.target?.tagName?.toLowerCase?.() ?? null,
                targetClosestSegment: event.target?.closest?.('mnb-seg')?.getAttribute?.('id') ?? null,
            });
            return;
        }
        activePointers.set(event.pointerId, {
            startX: event.clientX ?? 0,
            startY: event.clientY ?? 0,
            moved: false,
            suppressUnhandledTap: false,
            startTime: performance.now(),
            startSelection: selectionText(),
        });
        logPopover('pointerDown.track', {
            pointerId: event.pointerId,
            clientX: event.clientX ?? null,
            clientY: event.clientY ?? null,
            targetTag: event.target?.tagName?.toLowerCase?.() ?? null,
            activePointerCount: activePointers.size,
        });
    }

    window.__manabiSuppressCurrentUnhandledTapHideNavigation = function(clientX, clientY) {
        const x = Number(clientX);
        const y = Number(clientY);
        if (!Number.isFinite(x) || !Number.isFinite(y)) {
            logPopover('suppressCurrent.invalidPoint', {
                clientX,
                clientY,
                activePointerCount: activePointers.size,
            });
            return false;
        }
        let bestDistance = null;
        for (const entry of activePointers.values()) {
            const distance = Math.hypot(x - entry.startX, y - entry.startY);
            bestDistance = bestDistance === null ? distance : Math.min(bestDistance, distance);
            if (distance <= MOVE_THRESHOLD) {
                entry.suppressUnhandledTap = true;
                logPopover('suppressCurrent.marked', {
                    clientX: x,
                    clientY: y,
                    pointerStartX: entry.startX,
                    pointerStartY: entry.startY,
                    distance,
                    activePointerCount: activePointers.size,
                });
                return true;
            }
        }
        logPopover('suppressCurrent.noMatchingPointer', {
            clientX: x,
            clientY: y,
            bestDistance,
            activePointerCount: activePointers.size,
        });
        return false;
    };

    window.__manabiSuppressActiveUnhandledTapHideNavigation = function(reason, payload = {}) {
        let markedCount = 0;
        for (const entry of activePointers.values()) {
            entry.suppressUnhandledTap = true;
            markedCount += 1;
        }
        logPopover('suppressActive.marked', {
            reason: reason ?? null,
            markedCount,
            activePointerCount: activePointers.size,
            ...payload,
        });
        return markedCount > 0;
    };

    function handlePointerDown(event) {
        if (event.defaultPrevented || event.button > 0) {
            return;
        }
        registerPointer(event);
    }

    function handlePointerMove(event) {
        const entry = activePointers.get(event.pointerId);
        if (!entry) return;
        const dx = (event.clientX ?? 0) - entry.startX;
        const dy = (event.clientY ?? 0) - entry.startY;
        if (Math.hypot(dx, dy) > MOVE_THRESHOLD) {
            entry.moved = true;
        }
    }

    function handlePointerUp(event) {
        const entry = activePointers.get(event.pointerId);
        activePointers.delete(event.pointerId);
        if (!entry || event.defaultPrevented) {
            logPopover('pointerUp.skipMissingOrPrevented', {
                pointerId: event.pointerId,
                hasEntry: !!entry,
                defaultPrevented: event.defaultPrevented === true,
                clientX: event.clientX ?? null,
                clientY: event.clientY ?? null,
            });
            return;
        }
        const duration = performance.now() - entry.startTime;
        const newSelection = selectionText();
        const selectionChanged = newSelection.length > 0 && newSelection !== entry.startSelection;
        if (entry.moved || duration > LONG_PRESS_THRESHOLD_MS || selectionChanged) {
            logPopover('pointerUp.skipGesture', {
                pointerId: event.pointerId,
                moved: entry.moved === true,
                duration,
                longPressThreshold: LONG_PRESS_THRESHOLD_MS,
                selectionChanged,
                suppressUnhandledTap: entry.suppressUnhandledTap === true,
            });
            return;
        }
        if (entry.suppressUnhandledTap === true) {
            logPopover('pointerUp.suppressedByLookupBlankDismiss', {
                pointerId: event.pointerId,
                duration,
                clientX: event.clientX ?? null,
                clientY: event.clientY ?? null,
                targetTag: event.target?.tagName?.toLowerCase?.() ?? null,
                targetClosestSegment: event.target?.closest?.('mnb-seg')?.getAttribute?.('id') ?? null,
            });
            return;
        }
        logPopover('pointerUp.postUnhandledTap', {
            pointerId: event.pointerId,
            duration,
            clientX: event.clientX ?? null,
            clientY: event.clientY ?? null,
            targetTag: event.target?.tagName?.toLowerCase?.() ?? null,
            targetClosestSegment: event.target?.closest?.('mnb-seg')?.getAttribute?.('id') ?? null,
        });
        window.webkit.messageHandlers[handlerName].postMessage({
            frame: window === window.top ? 'top' : 'child',
            targetTag: event.target?.tagName?.toLowerCase?.() ?? null,
            targetClosestSegment: event.target?.closest?.('mnb-seg')?.getAttribute?.('id') ?? null,
            clientX: event.clientX ?? null,
            clientY: event.clientY ?? null
        });
    }

    function handlePointerCancel(event) {
        activePointers.delete(event.pointerId);
    }

    let lastScrollPosition = { x: window.scrollX || 0, y: window.scrollY || 0 };
    let accumulatedScroll = { value: 0 };
    const SCROLL_THRESHOLD = 24;
    function postHideNavigationForScroll(hidden, reason) {
        try {
            window.webkit.messageHandlers[handlerName].postMessage({
                frame: window === window.top ? 'top' : 'child',
                targetTag: null,
                targetClosestSegment: null,
                clientX: null,
                clientY: null,
                hideNavigationDueToScroll: hidden,
                reason
            });
        } catch (_error) {}
    }

    function handleDocumentScroll() {
        const currentX = window.scrollX || 0;
        const currentY = window.scrollY || 0;
        const dx = currentX - lastScrollPosition.x;
        const dy = currentY - lastScrollPosition.y;
        lastScrollPosition.x = currentX;
        lastScrollPosition.y = currentY;

        const delta = Math.abs(dy) >= Math.abs(dx) ? dy : dx;
        if (Math.abs(delta) < 0.5) {
            return;
        }
        accumulatedScroll.value += delta;
        if (accumulatedScroll.value > SCROLL_THRESHOLD) {
            postHideNavigationForScroll(true, 'documentScrollDown');
            accumulatedScroll.value = 0;
        } else if (accumulatedScroll.value < -SCROLL_THRESHOLD) {
            postHideNavigationForScroll(false, 'documentScrollUp');
            accumulatedScroll.value = 0;
        }
    }

    window.addEventListener('pointerdown', handlePointerDown, { capture: true, passive: true });
    window.addEventListener('pointermove', handlePointerMove, { capture: true, passive: true });
    window.addEventListener('pointerup', handlePointerUp, { capture: true, passive: true });
    window.addEventListener('pointercancel', handlePointerCancel, { capture: true, passive: true });
    window.addEventListener('scroll', handleDocumentScroll, { capture: true, passive: true });
})();
"""
        userScript = WebViewUserScript(
            source: contents,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false,
            in: .page
        )
    }
}

@MainActor
fileprivate struct TextSelectionUserScript {
    let userScript: WebViewUserScript
    
    init() {
        let contents = """
            (function() {
                let lastSentText = null;
            
                function sendSelectedTextAndHTML() {
                    const selection = window.getSelection();
                    if (!selection || selection.rangeCount === 0) {
                        if (lastSentText !== null) {
                            window.webkit.messageHandlers.swiftUIWebViewTextSelection.postMessage({
                                text: null,
                            });
                            lastSentText = null;
                        }
                        return;
                    }
            
                    const selectedText = selection.toString();
                    if (selectedText === '') {
                        if (lastSentText !== null) {
                            window.webkit.messageHandlers.swiftUIWebViewTextSelection.postMessage({
                                text: null,
                            });
                            lastSentText = null;
                        }
                        return;
                    }
            
                    if (selectedText === lastSentText) {
                        return;
                    }
                    
                    lastSentText = selectedText;
                    window.webkit.messageHandlers.swiftUIWebViewTextSelection.postMessage({
                        text: selectedText,
                    });
                }
                document.addEventListener('selectionchange', sendSelectedTextAndHTML);
            })(); 
            """
        userScript = WebViewUserScript(
            source: contents,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
    }
}

public struct WebViewConfig: Sendable {
    public static let `default` = WebViewConfig()
    
    public let javaScriptEnabled: Bool
    public let contentRules: String?
    public let allowsBackForwardNavigationGestures: Bool
    public let allowsInlineMediaPlayback: Bool
    public let mediaTypesRequiringUserActionForPlayback: WKAudiovisualMediaTypes
    public let dataDetectorsEnabled: Bool
    public let isScrollEnabled: Bool
    public let pageZoom: CGFloat
    public let isOpaque: Bool
    public let backgroundColor: Color
    public let usesSampledPageTopColorForUnderPageBackground: Bool
    public let usesConfiguredBackgroundForReaderDocuments: Bool
    public let adjustsScrollViewContentInsetsForSafeArea: Bool
    public let hidesTopScrollEdgeEffect: Bool
    public let nativeLookupHitTestingEnabled: Bool
    public let userScripts: [WebViewUserScript]
    public let darkModeSetting: DarkModeSetting
    public let paginationConfiguration: WebViewPaginationConfiguration
    
    public init(
        javaScriptEnabled: Bool = true,
        contentRules: String? = nil,
        allowsBackForwardNavigationGestures: Bool = true,
        allowsInlineMediaPlayback: Bool = true,
        mediaTypesRequiringUserActionForPlayback: WKAudiovisualMediaTypes = [WKAudiovisualMediaTypes.all],
        dataDetectorsEnabled: Bool = true,
        isScrollEnabled: Bool = true,
        pageZoom: CGFloat = 1,
        isOpaque: Bool = true,
        backgroundColor: Color = .clear,
        usesSampledPageTopColorForUnderPageBackground: Bool = false,
        usesConfiguredBackgroundForReaderDocuments: Bool = false,
        adjustsScrollViewContentInsetsForSafeArea: Bool = true,
        hidesTopScrollEdgeEffect: Bool = false,
        nativeLookupHitTestingEnabled: Bool = true,
        userScripts: [WebViewUserScript] = [],
        darkModeSetting: DarkModeSetting = .system,
        paginationConfiguration: WebViewPaginationConfiguration = .disabled
    ) {
        self.javaScriptEnabled = javaScriptEnabled
        self.contentRules = contentRules
        self.allowsBackForwardNavigationGestures = allowsBackForwardNavigationGestures
        self.allowsInlineMediaPlayback = allowsInlineMediaPlayback
        self.mediaTypesRequiringUserActionForPlayback = mediaTypesRequiringUserActionForPlayback
        self.dataDetectorsEnabled = dataDetectorsEnabled
        self.isScrollEnabled = isScrollEnabled
        self.pageZoom = pageZoom
        self.isOpaque = isOpaque
        self.backgroundColor = backgroundColor
        self.usesSampledPageTopColorForUnderPageBackground = usesSampledPageTopColorForUnderPageBackground
        self.usesConfiguredBackgroundForReaderDocuments = usesConfiguredBackgroundForReaderDocuments
        self.adjustsScrollViewContentInsetsForSafeArea = adjustsScrollViewContentInsetsForSafeArea
        self.hidesTopScrollEdgeEffect = hidesTopScrollEdgeEffect
        self.nativeLookupHitTestingEnabled = nativeLookupHitTestingEnabled
        self.userScripts = userScripts
        self.darkModeSetting = darkModeSetting
        self.paginationConfiguration = paginationConfiguration
    }

    public func withHidesTopScrollEdgeEffect(_ hidesTopScrollEdgeEffect: Bool) -> WebViewConfig {
        WebViewConfig(
            javaScriptEnabled: javaScriptEnabled,
            contentRules: contentRules,
            allowsBackForwardNavigationGestures: allowsBackForwardNavigationGestures,
            allowsInlineMediaPlayback: allowsInlineMediaPlayback,
            mediaTypesRequiringUserActionForPlayback: mediaTypesRequiringUserActionForPlayback,
            dataDetectorsEnabled: dataDetectorsEnabled,
            isScrollEnabled: isScrollEnabled,
            pageZoom: pageZoom,
            isOpaque: isOpaque,
            backgroundColor: backgroundColor,
            usesSampledPageTopColorForUnderPageBackground: usesSampledPageTopColorForUnderPageBackground,
            usesConfiguredBackgroundForReaderDocuments: usesConfiguredBackgroundForReaderDocuments,
            adjustsScrollViewContentInsetsForSafeArea: adjustsScrollViewContentInsetsForSafeArea,
            hidesTopScrollEdgeEffect: hidesTopScrollEdgeEffect,
            nativeLookupHitTestingEnabled: nativeLookupHitTestingEnabled,
            userScripts: userScripts,
            darkModeSetting: darkModeSetting,
            paginationConfiguration: paginationConfiguration
        )
    }
}

public struct WebViewLifecycleConfig: Sendable, Equatable {
    public static let `default` = WebViewLifecycleConfig()

    public var autoUnloadOnDisappear: Bool
    public var unloadOnlyWhenRemovedFromHierarchy: Bool
    public var snapshotCacheKey: WebViewSnapshotCacheKey?
    public var idleLoadURL: URL?

    public init(
        autoUnloadOnDisappear: Bool = false,
        unloadOnlyWhenRemovedFromHierarchy: Bool = false,
        snapshotCacheKey: WebViewSnapshotCacheKey? = nil,
        idleLoadURL: URL? = nil
    ) {
        self.autoUnloadOnDisappear = autoUnloadOnDisappear
        self.unloadOnlyWhenRemovedFromHierarchy = unloadOnlyWhenRemovedFromHierarchy
        self.snapshotCacheKey = snapshotCacheKey
        self.idleLoadURL = idleLoadURL
    }
}

public enum WebViewSnapshotColorScheme: Int, Sendable {
    case light
    case dark
    case unspecified
}

public struct WebViewSnapshotCacheKey: Hashable, Sendable {
    public let htmlHash: Int
    public let htmlLength: Int
    public let widthBucket: Int
    public let colorScheme: WebViewSnapshotColorScheme

    public init(
        htmlHash: Int,
        htmlLength: Int,
        width: CGFloat,
        colorScheme: WebViewSnapshotColorScheme = .unspecified
    ) {
        self.htmlHash = htmlHash
        self.htmlLength = htmlLength
        self.widthBucket = Int((width * 10).rounded())
        self.colorScheme = colorScheme
    }

    public init(htmlHash: Int, width: CGFloat, colorScheme: WebViewSnapshotColorScheme = .unspecified) {
        self.init(htmlHash: htmlHash, htmlLength: 0, width: width, colorScheme: colorScheme)
    }

    public init(htmlHash: Int, width: CGFloat, colorScheme: ColorScheme) {
        self.init(htmlHash: htmlHash, htmlLength: 0, width: width, colorScheme: colorScheme)
    }

    public init(htmlHash: Int, htmlLength: Int, width: CGFloat, colorScheme: ColorScheme) {
        let scheme: WebViewSnapshotColorScheme
        switch colorScheme {
        case .light:
            scheme = .light
        case .dark:
            scheme = .dark
        @unknown default:
            scheme = .unspecified
        }
        self.init(htmlHash: htmlHash, htmlLength: htmlLength, width: width, colorScheme: scheme)
    }
}

#if os(iOS)
public struct WebViewSnapshotCacheEntry {
    public var image: UIImage?
    public var height: CGFloat?
    public var updatedAt: Date

    public init(image: UIImage?, height: CGFloat?, updatedAt: Date = Date()) {
        self.image = image
        self.height = height
        self.updatedAt = updatedAt
    }
}

@MainActor private let webViewSnapshotCache = LRUCache<WebViewSnapshotCacheKey, WebViewSnapshotCacheEntry>()

public enum WebViewSnapshotCache {
    @MainActor
    public static func entry(for key: WebViewSnapshotCacheKey) -> WebViewSnapshotCacheEntry? {
        webViewSnapshotCache.value(forKey: key)
    }

    @MainActor
    public static func snapshotImage(for key: WebViewSnapshotCacheKey) -> UIImage? {
        webViewSnapshotCache.value(forKey: key)?.image
    }

    @MainActor
    public static func cachedHeight(for key: WebViewSnapshotCacheKey) -> CGFloat? {
        webViewSnapshotCache.value(forKey: key)?.height
    }

    @MainActor
    public static func storeHeight(_ height: CGFloat, for key: WebViewSnapshotCacheKey) {
        var entry = webViewSnapshotCache.value(forKey: key) ?? WebViewSnapshotCacheEntry(image: nil, height: nil)
        entry.height = height
        entry.updatedAt = Date()
        webViewSnapshotCache.setValue(entry, forKey: key)
    }

    @MainActor
    public static func storeSnapshot(_ image: UIImage, height: CGFloat, for key: WebViewSnapshotCacheKey) {
        var entry = webViewSnapshotCache.value(forKey: key) ?? WebViewSnapshotCacheEntry(image: nil, height: nil)
        entry.image = image
        entry.height = height
        entry.updatedAt = Date()
        webViewSnapshotCache.setValue(entry, forKey: key)
    }
}
#endif

fileprivate let kLeftArrowKeyCode:  UInt16  = 123
fileprivate let kRightArrowKeyCode: UInt16  = 124
fileprivate let kDownArrowKeyCode:  UInt16  = 125
fileprivate let kUpArrowKeyCode:    UInt16  = 126

enum PendingRequestLoadDisposition: Equatable {
    case deferUntilAttached
    case loadRequest
    case loadFileURL
    case skipAlreadyLoading

    static func resolve(
        requestURL: URL?,
        hasWindow: Bool,
        hasSuperview: Bool,
        currentURL: URL?,
        isLoading: Bool,
        restartIfSameURL: Bool
    ) -> PendingRequestLoadDisposition {
        guard hasWindow, hasSuperview else {
            return .deferUntilAttached
        }
        if restartIfSameURL, currentURL == requestURL, isLoading {
            return .skipAlreadyLoading
        }
        if requestURL?.isFileURL == true {
            return .loadFileURL
        }
        return .loadRequest
    }
}

public class EnhancedWKWebView: WKWebView {
    var persistedUserScriptsSignature: String?
    var persistedAppliedContentRules: String?
#if os(iOS)
    var hidesTopScrollEdgeEffect = false
#endif

    public override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public var onDidMoveToWindow: ((Bool) -> Void)?

#if os(macOS)
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onDidMoveToWindow?(window != nil || superview != nil)
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onDidMoveToWindow?(window != nil || superview != nil)
    }
#elseif os(iOS)
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        applyTopScrollEdgeEffectHidden(hidesTopScrollEdgeEffect, to: self, reason: "didMoveToWindow")
        onDidMoveToWindow?(window != nil || superview != nil)
    }

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        applyTopScrollEdgeEffectHidden(hidesTopScrollEdgeEffect, to: self, reason: "didMoveToSuperview")
        onDidMoveToWindow?(window != nil || superview != nil)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        applyTopScrollEdgeEffectHidden(hidesTopScrollEdgeEffect, to: self, reason: "layoutSubviews")
    }
#endif

#if os(iOS)
    var buildMenu: BuildMenuType?
#endif
    
#if os(macOS)
    public override var isOpaque: Bool {
        return true
    }
    
    public override func keyDown(with event: NSEvent) {
        //                    print(">> key \(event.keyCode)")
        switch event.keyCode {
        case kLeftArrowKeyCode, kRightArrowKeyCode, kDownArrowKeyCode, kUpArrowKeyCode:
            return
        default:
            super.keyDown(with: event)
        }
    }
#elseif os(iOS)
    override open func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        buildMenu?(builder)
    }
#endif
}

#if os(iOS)
private final class NativeLookupHitTestOverlayView: UIView {
    private enum PressedSegmentStyle {
        static let pressedStrokeAlpha: CGFloat = 0.8
        static let strokeWidth: CGFloat = 1
        static let cornerRadius: CGFloat = 5
        static let inset: CGFloat = 0.5
        static let lookupAttachmentTopExpansion: CGFloat = 0
    }

    weak var store: WebViewNativeLookupHitTestStore?
    private let pressedSegmentLayer = CAShapeLayer()
    private var clearPressedSegmentWorkItem: DispatchWorkItem?
    private var pressedSegmentElementID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false
        pressedSegmentLayer.fillColor = UIColor.clear.cgColor
        pressedSegmentLayer.lineWidth = PressedSegmentStyle.strokeWidth
        pressedSegmentLayer.strokeColor = tintColor.withAlphaComponent(PressedSegmentStyle.pressedStrokeAlpha).cgColor
        pressedSegmentLayer.contentsScale = UIScreen.main.scale
        layer.addSublayer(pressedSegmentLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pressedSegmentLayer.frame = bounds
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        pressedSegmentLayer.strokeColor = tintColor.withAlphaComponent(PressedSegmentStyle.pressedStrokeAlpha).cgColor
    }

    func showPressedTarget(_ target: WebViewNativeLookupHitTarget) {
        clearPressedSegmentWorkItem?.cancel()
        clearPressedSegmentWorkItem = nil
        pressedSegmentElementID = target.elementID
        let path = CGMutablePath()
        var visualRects: [CGRect] = []
        var strokeRects: [CGRect] = []
        for visualRect in target.projectedRectsForCurrentHitTestOverlay(
            topExpansion: PressedSegmentStyle.lookupAttachmentTopExpansion
        ) {
            let strokeRect = visualRect.insetBy(dx: PressedSegmentStyle.inset, dy: PressedSegmentStyle.inset)
            visualRects.append(visualRect)
            strokeRects.append(strokeRect)
            let radius = min(PressedSegmentStyle.cornerRadius, strokeRect.width / 2, strokeRect.height / 2)
            path.addRoundedRect(in: strokeRect, cornerWidth: radius, cornerHeight: radius)
        }
        let windowFrame = convert(bounds, to: nil)
        let visualWindowRects = visualRects.map { convert($0, to: nil) }
        let strokeWindowRects = strokeRects.map { convert($0, to: nil) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pressedSegmentLayer.strokeColor = tintColor.withAlphaComponent(PressedSegmentStyle.pressedStrokeAlpha).cgColor
        pressedSegmentLayer.path = path
        pressedSegmentLayer.opacity = 1
        CATransaction.commit()
    }
    func clearPressedTarget() {
        clearPressedSegmentWorkItem?.cancel()
        clearPressedSegmentWorkItem = nil
        clearPressedTargetImmediately()
    }

    func clearPressedTarget(after delay: TimeInterval) {
        clearPressedSegmentWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.clearPressedTargetImmediately()
        }
        clearPressedSegmentWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func clearPressedTarget(matching elementID: String?) {
        guard elementID == nil || pressedSegmentElementID == elementID else {
            return
        }
        clearPressedTarget()
    }

    private func clearPressedTargetImmediately() {
        pressedSegmentElementID = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pressedSegmentLayer.path = nil
        pressedSegmentLayer.opacity = 0
        CATransaction.commit()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let overlayWindowOrigin = convert(CGPoint.zero, to: nil)
        let target = store?.hitTarget(
            at: point,
            in: bounds.size,
            coordinateViewWindowOrigin: overlayWindowOrigin
        )
        if let target {
            let capturesSegmentTouches = store?.capturesSegmentTouchesInOverlay == true
            let hasActiveWebTextSelection = store?.hasActiveWebTextSelection == true
            if hasActiveWebTextSelection {
                return false
            }
            //store?.onOverlaySegmentHitObserved?(target, point, bounds.size)
            if capturesSegmentTouches {
                store?.onOverlaySegmentHitObserved?(target, point, bounds.size)
                return true
            }
        }
        return false
    }
}

private final class NativeLookupHitTestTapGestureRecognizer: UIGestureRecognizer {
    private static let segmentTapMovementTolerance: CGFloat = 10
    private static let segmentLongPressDriftTolerance: CGFloat = 24
    private static let segmentSwipeMovementTolerance: CGFloat = 4
    private static let segmentTapMaximumDuration: TimeInterval = 0.42
    private static let segmentTapPressedFallbackDuration: TimeInterval = 1.0

    weak var store: WebViewNativeLookupHitTestStore?
    weak var coordinateView: NativeLookupHitTestOverlayView?
    weak var clientCoordinateView: UIView?
    private var touchStartPoint: CGPoint?
    private var touchStartWindowPoint: CGPoint?
    private var touchStartTime: TimeInterval?
    private var touchStartTarget: WebViewNativeLookupHitTarget?
    private var touchStartWasActiveTarget = false
    private var touchStartPressedVisualCleared = false
    private var touchStartIsInsideTarget = false
    private var touchHasMoved = false
    private var touchLatestPoint: CGPoint?
    private weak var touchStartOverlay: NativeLookupHitTestOverlayView?
    private var tapExpirationWorkItem: DispatchWorkItem?
    private var suppressedCompetingTapRecognizers: [(recognizer: UIGestureRecognizer, wasEnabled: Bool)] = []

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = true
        delaysTouchesBegan = true
        delaysTouchesEnded = true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible,
              touches.count == 1,
              event.allTouches?.count == 1,
              let touch = touches.first,
              let coordinateView else {
            logTouchDeliveryVerdict(
                stage: "touchesBegan.invalidTouchSet",
                verdict: "passThrough.allowed",
                reason: "invalidTouchSet",
                extra: [
                    "touchCount": touches.count,
                    "allTouchCount": event.allTouches?.count as Any,
                    "segmentTargetTouchesReachWebKit": true,
                ]
            )
            state = .failed
            return
        }
        let point = touch.location(in: coordinateView)
        let hitTestView = coordinateView
        let hitPoint = point
        let rawClientPoint = clientCoordinateView.map { touch.location(in: $0) }
        let windowPoint = touch.location(in: nil)
        let hitTestViewWindowOrigin = hitTestView.convert(CGPoint.zero, to: nil)
        guard let target = store?.hitTarget(
            at: hitPoint,
            in: hitTestView.bounds.size,
            coordinateViewWindowOrigin: hitTestViewWindowOrigin
        ) else {
            logTouchDeliveryVerdict(
                stage: "touchesBegan.noSegmentTarget",
                verdict: "passThrough.allowed",
                reason: "noSegmentTarget",
                point: point,
                coordinateView: coordinateView,
                extra: [
                    "hitPoint": Self.debugPointString(hitPoint),
                    "rawWebViewPoint": rawClientPoint.map(Self.debugPointString) as Any,
                    "hitBasis": "overlay",
                    "nearest": store?.diagnostics(
                        at: hitPoint,
                        limit: 3,
                        in: hitTestView.bounds.size,
                        coordinateViewWindowOrigin: hitTestViewWindowOrigin
                    ) as Any,
                    "nativeLookupEnabled": store?.isEnabled as Any,
                    "targetCount": store?.targetCount as Any,
                    "segmentTargetTouchesReachWebKit": true,
                ]
            )
            state = .failed
            return
        }
        if store?.hasActiveWebTextSelection == true {
            logTouchDeliveryVerdict(
                stage: "touchesBegan.textSelectionActivePassThrough",
                verdict: "passThrough.allowed",
                reason: "webTextSelectionActive",
                target: target,
                point: point,
                coordinateView: coordinateView,
                extra: [
                    "hitPoint": Self.debugPointString(hitPoint),
                    "rawWebViewPoint": rawClientPoint.map(Self.debugPointString) as Any,
                    "hitBasis": "overlay",
                    "nativeLookupEnabled": store?.isEnabled as Any,
                    "targetCount": store?.targetCount as Any,
                    "segmentTargetTouchesReachWebKit": true,
                ].merging(store?.webTextSelectionDiagnostics ?? [:]) { _, new in new }
            )
            state = .failed
            return
        }
        store?.beginNativeTouchStream(on: target)
        logTouchDeliveryVerdict(
            stage: "touchesBegan.nativeCandidate",
            verdict: "pending.nativeRecognizerHoldingWebKitTouches",
            reason: "segmentTarget",
            target: target,
            point: point,
            coordinateView: coordinateView,
            extra: [
                "hitPoint": Self.debugPointString(hitPoint),
                "rawWebViewPoint": rawClientPoint.map(Self.debugPointString) as Any,
                "hitBasis": "overlay",
                "nativeLookupEnabled": store?.isEnabled as Any,
                "targetCount": store?.targetCount as Any,
                "nearest": store?.diagnostics(
                    at: hitPoint,
                    limit: 3,
                    in: hitTestView.bounds.size,
                    coordinateViewWindowOrigin: hitTestViewWindowOrigin
                ) as Any,
                "segmentTargetTouchesReachWebKit": "pendingTapDecision",
            ]
        )
        suppressCompetingWebKitTapRecognizers(
            reason: "segmentTarget",
            target: target,
            point: point,
            coordinateView: coordinateView
        )
        touchStartPoint = point
        touchStartWindowPoint = windowPoint
        touchStartTime = event.timestamp
        touchStartTarget = target
        touchStartIsInsideTarget = true
        touchHasMoved = false
        touchLatestPoint = point
        let activeLookupElementID = store?.activeLookupElementID?()
        let activeHighlightElementID = store?.activeElementID
        let hadActiveLookup = activeLookupElementID != nil
        touchStartWasActiveTarget =
            activeLookupElementID == target.elementID
            || activeHighlightElementID == target.elementID
        if store?.showsPressedTargetOverlay == true {
            touchStartOverlay = coordinateView
            touchStartOverlay?.showPressedTarget(target)
        } else {
            touchStartOverlay = nil
            coordinateView.clearPressedTarget()
        }
        if hadActiveLookup {
            logTouchDeliveryVerdict(
                stage: "touchesBegan.activeLookupPendingTapDecision",
                verdict: touchStartWasActiveTarget
                    ? "popover.dismissPendingTouchEnd"
                    : "popover.updatePendingTouchEnd",
                reason: touchStartWasActiveTarget ? "sameActiveTargetCandidate" : "activeLookupMoveCandidate",
                target: target,
                point: point,
                coordinateView: coordinateView,
                extra: [
                    "activeLookupElementID": activeLookupElementID as Any,
                    "activeHighlightElementID": activeHighlightElementID as Any,
                ]
            )
            if touchStartWasActiveTarget {
                logTouchDeliveryVerdict(
                    stage: "touchesBegan.activeLookupDismissPending",
                    verdict: "popover.dismissPendingTouchEnd",
                    reason: "sameActiveTargetCandidate",
                    target: target,
                    point: point,
                    coordinateView: coordinateView,
                    extra: [
                        "activeLookupElementID": activeLookupElementID as Any,
                        "activeHighlightElementID": activeHighlightElementID as Any,
                        "segmentTargetTouchesReachWebKit": "pendingTapDecision",
                    ]
                )
            } else {
                logTouchDeliveryVerdict(
                    stage: "touchesBegan.activeLookupDispatchPending",
                    verdict: "popover.updatePendingTouchEnd",
                    reason: "activeLookupMoveCandidate",
                    target: target,
                    point: point,
                    coordinateView: coordinateView,
                    extra: [
                        "activeLookupElementID": activeLookupElementID as Any,
                        "activeHighlightElementID": activeHighlightElementID as Any,
                        "lookupDispatchedOnTouchDown": false,
                        "completedOnTouchDown": false,
                        "hitPoint": Self.debugPointString(hitPoint),
                        "rawWebViewPoint": rawClientPoint.map(Self.debugPointString) as Any,
                        "hitBasis": "overlay",
                        "nearest": store?.diagnostics(
                            at: hitPoint,
                            limit: 3,
                            in: hitTestView.bounds.size,
                            coordinateViewWindowOrigin: hitTestViewWindowOrigin
                        ) as Any,
                        "segmentTargetTouchesReachWebKit": "pendingTapDecision",
                    ]
                )
            }
        } else {
            logTouchDeliveryVerdict(
                stage: "touchesBegan.nativeLookupPending",
                verdict: "nativeLookupPendingTouchEnd",
                reason: "segmentTarget",
                target: target,
                point: point,
                coordinateView: coordinateView,
                extra: [
                    "lookupDispatchedOnTouchDown": false,
                    "completedOnTouchDown": false,
                    "hitPoint": Self.debugPointString(hitPoint),
                    "rawWebViewPoint": rawClientPoint.map(Self.debugPointString) as Any,
                    "hitBasis": "overlay",
                    "nearest": store?.diagnostics(
                        at: hitPoint,
                        limit: 3,
                        in: hitTestView.bounds.size,
                        coordinateViewWindowOrigin: hitTestViewWindowOrigin
                    ) as Any,
                    "segmentTargetTouchesReachWebKit": "pendingTapDecision",
                ]
            )
        }
        tapExpirationWorkItem?.cancel()
        tapExpirationWorkItem = nil
        if store?.capturesSegmentTouchesInOverlay != true {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.state == .possible else { return }
                self.failGesture(reason: "timeout")
            }
            tapExpirationWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.segmentTapMaximumDuration, execute: workItem)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start = touchStartPoint,
              let windowStart = touchStartWindowPoint,
              let touch = touches.first,
              let coordinateView else { return }
        let point = touch.location(in: coordinateView)
        touchLatestPoint = point
        touchHasMoved = true
        let windowPoint = touch.location(in: nil)
        let dx = windowPoint.x - windowStart.x
        let dy = windowPoint.y - windowStart.y
        let movement = hypot(dx, dy)
        let horizontalMovement = abs(dx)
        let verticalMovement = abs(dy)
        let isSwipeLikeMovement =
            horizontalMovement > Self.segmentSwipeMovementTolerance
            && horizontalMovement > verticalMovement * 1.2
        let exceededTapMovement = movement > Self.segmentTapMovementTolerance
        let exceededLongPressDrift = movement > Self.segmentLongPressDriftTolerance
        let isInsideStartTarget = touchStartTarget.map {
            Self.point(point, isInside: $0)
        } ?? false
        logTouchDeliveryVerdict(
            stage: "touchesMoved",
            verdict: isSwipeLikeMovement
                ? "passThrough.failurePending"
                : (isInsideStartTarget ? "nativeRecognizerInsideTarget" : "nativeRecognizerOutsideTarget"),
            reason: isSwipeLikeMovement ? "swipeMovement" : (isInsideStartTarget ? "insideTarget" : "outsideTarget"),
            target: touchStartTarget,
            point: point,
            coordinateView: coordinateView,
            extra: [
                "start": Self.debugPointString(start),
                "point": Self.debugPointString(point),
                "windowStart": Self.debugPointString(windowStart),
                "windowPoint": Self.debugPointString(windowPoint),
                "movement": movement,
                "dx": dx,
                "dy": dy,
                "tapTolerance": Self.segmentTapMovementTolerance,
                "longPressDriftTolerance": Self.segmentLongPressDriftTolerance,
                "swipeMovementTolerance": Self.segmentSwipeMovementTolerance,
                "isSwipeLikeMovement": isSwipeLikeMovement,
                "exceededTapMovement": exceededTapMovement,
                "exceededLongPressDrift": exceededLongPressDrift,
                "isInsideStartTarget": isInsideStartTarget,
            ]
        )
        if isInsideStartTarget != touchStartIsInsideTarget {
            touchStartIsInsideTarget = isInsideStartTarget
            if isInsideStartTarget, let target = touchStartTarget, store?.showsPressedTargetOverlay == true {
                touchStartPressedVisualCleared = false
                touchStartOverlay?.showPressedTarget(target)
            } else {
                clearPressedVisualForMovementIfNeeded(payload: [
                    "reason": "outsideTarget",
                    "start": Self.debugPointString(start),
                    "point": Self.debugPointString(point),
                    "windowStart": Self.debugPointString(windowStart),
                    "windowPoint": Self.debugPointString(windowPoint),
                    "movement": movement,
                    "dx": dx,
                    "dy": dy,
                    "tapTolerance": Self.segmentTapMovementTolerance,
                    "swipeMovementTolerance": Self.segmentSwipeMovementTolerance,
                    "isSwipeLikeMovement": isSwipeLikeMovement,
                    "exceededTapMovement": exceededTapMovement,
                    "isInsideStartTarget": isInsideStartTarget,
                ])
            }
        }
        if isSwipeLikeMovement {
            clearPressedVisualForMovementIfNeeded(payload: [
                "start": Self.debugPointString(start),
                "point": Self.debugPointString(point),
                "windowStart": Self.debugPointString(windowStart),
                "windowPoint": Self.debugPointString(windowPoint),
                "movement": movement,
                "dx": dx,
                "dy": dy,
                "tapTolerance": Self.segmentTapMovementTolerance,
                "swipeMovementTolerance": Self.segmentSwipeMovementTolerance,
                "isSwipeLikeMovement": isSwipeLikeMovement,
                "exceededTapMovement": exceededTapMovement,
                "isInsideStartTarget": isInsideStartTarget,
            ])
            failGesture(reason: "movement", payload: [
                "start": Self.debugPointString(start),
                "point": Self.debugPointString(point),
                "windowStart": Self.debugPointString(windowStart),
                "windowPoint": Self.debugPointString(windowPoint),
                "movement": movement,
                "dx": dx,
                "dy": dy,
                "tapTolerance": Self.segmentTapMovementTolerance,
                "longPressDriftTolerance": Self.segmentLongPressDriftTolerance,
                "swipeMovementTolerance": Self.segmentSwipeMovementTolerance,
                "isSwipeLikeMovement": isSwipeLikeMovement,
                "exceededTapMovement": exceededTapMovement,
                "exceededLongPressDrift": exceededLongPressDrift,
                "isInsideStartTarget": isInsideStartTarget,
            ])
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start = touchStartPoint,
              let windowStart = touchStartWindowPoint,
              let startedAt = touchStartTime,
              let target = touchStartTarget,
              let touch = touches.first,
              let coordinateView else {
            logTouchDeliveryVerdict(
                stage: "touchesEnded.missingTrackingState",
                verdict: "passThrough.allowed",
                reason: "missingTrackingState",
                extra: [
                    "segmentTargetTouchesReachWebKit": true,
                ]
            )
            resetTrackingState()
            state = .failed
            return
        }
        let duration = event.timestamp - startedAt
        if store?.capturesSegmentTouchesInOverlay != true,
           duration > Self.segmentTapMaximumDuration {
            logTouchDeliveryVerdict(
                stage: "touchesEnded.durationExceeded",
                verdict: "passThrough.allowedAfterRecognizerFailure",
                reason: "durationExceeded",
                target: target,
                coordinateView: coordinateView,
                extra: [
                    "duration": duration,
                    "maximumDuration": Self.segmentTapMaximumDuration,
                    "segmentTargetTouchesReachWebKit": true,
                ]
            )
            resetTrackingState()
            state = .failed
            return
        }
        let point = touch.location(in: coordinateView)
        let hitTestView = coordinateView
        let hitPoint = point
        let rawClientPoint = clientCoordinateView.map { touch.location(in: $0) }
        let windowPoint = touch.location(in: nil)
        let hitTestViewWindowOrigin = hitTestView.convert(CGPoint.zero, to: nil)
        let movement = hypot(windowPoint.x - windowStart.x, windowPoint.y - windowStart.y)
        let endTarget = store?.hitTarget(
            at: hitPoint,
            in: hitTestView.bounds.size,
            coordinateViewWindowOrigin: hitTestViewWindowOrigin
        )
        let endedInsideStartTarget = Self.point(point, isInside: target)
            && endTarget?.elementID == target.elementID
        logTouchDeliveryVerdict(
            stage: "touchesEnded.endTarget",
            verdict: endTarget?.elementID == target.elementID
                ? "nativeEndTargetMatchesStart"
                : "nativeEndTargetChangedOrMissing",
            reason: "endTargetCheck",
            target: target,
            point: point,
            coordinateView: coordinateView,
            extra: [
                "movement": movement,
                "duration": duration,
                "startTargetID": target.elementID,
                "endTargetID": endTarget?.elementID as Any,
                "endedInsideStartTarget": endedInsideStartTarget,
                "endTargetRect": endTarget?.rects.first.map {
                    WebViewNativeLookupHitTestStore.debugRectStrings([$0]).first ?? ""
                } as Any,
                "hitPoint": Self.debugPointString(hitPoint),
                "rawWebViewPoint": rawClientPoint.map(Self.debugPointString) as Any,
                "hitBasis": "overlay",
                "nearest": store?.diagnostics(
                    at: hitPoint,
                    limit: 5,
                    in: hitTestView.bounds.size,
                    coordinateViewWindowOrigin: hitTestViewWindowOrigin
                ) as Any,
            ].merging(store?.webTextSelectionDiagnostics ?? [:]) { _, new in new }
        )
        guard endedInsideStartTarget else {
            logTouchDeliveryVerdict(
                stage: "touchesEnded.nativeLookupFailed",
                verdict: "passThrough.allowedAfterRecognizerFailure",
                reason: "endedOutsideStartTarget",
                target: target,
                point: point,
                coordinateView: coordinateView,
                extra: [
                    "movement": movement,
                    "duration": duration,
                    "start": Self.debugPointString(start),
                    "point": Self.debugPointString(point),
                    "windowStart": Self.debugPointString(windowStart),
                    "windowPoint": Self.debugPointString(windowPoint),
                    "endTargetID": endTarget?.elementID as Any,
                    "endedInsideStartTarget": endedInsideStartTarget,
                    "segmentTargetTouchesReachWebKit": true,
                ].merging(store?.webTextSelectionDiagnostics ?? [:]) { _, new in new }
            )
            resetTrackingState()
            state = .failed
            return
        }
        if store?.hasActiveWebTextSelection == true {
            logTouchDeliveryVerdict(
                stage: "touchesEnded.textSelectionActivePassThrough",
                verdict: "passThrough.allowedAfterTextSelection",
                reason: "webTextSelectionActive",
                target: target,
                point: point,
                coordinateView: coordinateView,
                extra: [
                    "movement": movement,
                    "duration": duration,
                    "startTargetID": target.elementID,
                    "endTargetID": endTarget?.elementID as Any,
                    "hitPoint": Self.debugPointString(hitPoint),
                    "rawWebViewPoint": rawClientPoint.map(Self.debugPointString) as Any,
                    "hitBasis": "overlay",
                    "segmentTargetTouchesReachWebKit": true,
                ].merging(store?.webTextSelectionDiagnostics ?? [:]) { _, new in new }
            )
            resetTrackingState()
            state = .failed
            return
        }
        if touchStartWasActiveTarget {
            store?.onActiveTargetTouchDown?(target)
        } else {
            logTouchDeliveryVerdict(
                stage: "touchesEnded.beforeNativeLookupDispatch",
                verdict: "nativeLookupDispatchPending",
                reason: "beforeHandleTap",
                target: target,
                point: point,
                coordinateView: coordinateView,
                extra: [
                    "movement": movement,
                    "duration": duration,
                    "startTargetID": target.elementID,
                    "endTargetID": endTarget?.elementID as Any,
                    "hitPoint": Self.debugPointString(hitPoint),
                    "rawWebViewPoint": rawClientPoint.map(Self.debugPointString) as Any,
                    "hitBasis": "overlay",
                ].merging(store?.webTextSelectionDiagnostics ?? [:]) { _, new in new }
            )
            guard store?.handleTap(
                on: target,
                at: hitPoint,
                in: hitTestView.bounds.size,
                coordinateViewWindowOrigin: hitTestViewWindowOrigin
            ) == true else {
                logTouchDeliveryVerdict(
                    stage: "touchesEnded.nativeLookupFailed",
                    verdict: "passThrough.allowedAfterRecognizerFailure",
                    reason: "nativeLookupFailed",
                    target: target,
                    point: point,
                    coordinateView: coordinateView,
                    extra: [
                        "movement": movement,
                        "duration": duration,
                        "hitPoint": Self.debugPointString(hitPoint),
                        "rawWebViewPoint": rawClientPoint.map(Self.debugPointString) as Any,
                        "hitBasis": "overlay",
                        "endTargetID": endTarget?.elementID as Any,
                        "segmentTargetTouchesReachWebKit": true,
                    ].merging(store?.webTextSelectionDiagnostics ?? [:]) { _, new in new }
                )
                resetTrackingState()
                state = .failed
                return
            }
        }
        logTouchDeliveryVerdict(
            stage: "touchesEnded.nativeRecognized",
            verdict: "passThrough.blockedForTapLookup",
            reason: touchStartWasActiveTarget ? "sameActiveTargetDismiss" : "nativeLookupTap",
            target: target,
            point: point,
            coordinateView: coordinateView,
            extra: [
                "movement": movement,
                "duration": duration,
                "hitPoint": Self.debugPointString(hitPoint),
                "rawWebViewPoint": rawClientPoint.map(Self.debugPointString) as Any,
                "hitBasis": "overlay",
                "lookupDispatchedOnTouchDown": false,
                "segmentTargetTouchesReachWebKit": "touchStreamMayArrive_clickRecognizerBlocked",
                "webkitTapRecognizersRequireNativeLookupFailure": true,
            ].merging(store?.webTextSelectionDiagnostics ?? [:]) { _, new in new }
        )
        if touchStartWasActiveTarget {
            touchStartOverlay?.clearPressedTarget()
        } else {
            touchStartOverlay?.clearPressedTarget(after: Self.segmentTapPressedFallbackDuration)
        }
        resetTrackingState(clearPressedTarget: false)
        state = .recognized
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        logTouchDeliveryVerdict(
            stage: "touchesCancelled",
            verdict: "passThrough.allowedAfterCancellation",
            reason: "touchesCancelled",
            extra: [
                "touchCount": touches.count,
                "segmentTargetTouchesReachWebKit": true,
            ]
        )
        resetTrackingState()
        state = .failed
    }

    override func reset() {
        if state == .possible,
           let target = touchStartTarget,
           let point = touchStartPoint,
           let coordinateView {
            let latestPoint = touchLatestPoint ?? point
            let latestPointIsInsideStartTarget = Self.point(latestPoint, isInside: target)
            logTouchDeliveryVerdict(
                stage: "reset.dropPendingNativeLookup",
                verdict: "pendingLookupDroppedBeforeTapEnd",
                reason: "unexpectedRecognizerReset",
                target: target,
                point: latestPoint,
                coordinateView: coordinateView,
                extra: [
                    "lookupDispatchedOnReset": false,
                    "segmentTargetTouchesReachWebKit": true,
                    "touchHasMoved": touchHasMoved,
                    "latestPointIsInsideStartTarget": latestPointIsInsideStartTarget,
                ]
            )
            var shouldHoldPressedTargetForHandoff = false
            if touchStartWasActiveTarget {
                if touchHasMoved || !touchStartIsInsideTarget || !latestPointIsInsideStartTarget {
                    touchStartOverlay?.clearPressedTarget()
                    store?.onTouchDownHitCancelled?(target)
                    logTouchDeliveryVerdict(
                        stage: "reset.skipActiveTargetOutsideTarget",
                        verdict: "pendingLookupDroppedOutsideTarget",
                        reason: touchHasMoved ? "touchMovedBeforeReset" : "outsideStartTarget",
                        target: target,
                        point: latestPoint,
                        coordinateView: coordinateView,
                        extra: [
                            "lookupDispatchedOnReset": false,
                            "segmentTargetTouchesReachWebKit": true,
                            "touchHasMoved": touchHasMoved,
                            "touchStartIsInsideTarget": touchStartIsInsideTarget,
                            "latestPointIsInsideStartTarget": latestPointIsInsideStartTarget,
                        ]
                    )
                } else if store?.hasActiveWebTextSelection == true {
                    logTouchDeliveryVerdict(
                        stage: "reset.skipActiveTargetTextSelectionActive",
                        verdict: "pendingLookupDroppedForTextSelection",
                        reason: "webTextSelectionActive",
                        target: target,
                        point: point,
                        coordinateView: coordinateView,
                        extra: [
                            "lookupDispatchedOnReset": false,
                            "segmentTargetTouchesReachWebKit": true,
                        ].merging(store?.webTextSelectionDiagnostics ?? [:]) { _, new in new }
                    )
                } else {
                    store?.onActiveTargetTouchDown?(target)
                }
            } else {
                if touchHasMoved || !touchStartIsInsideTarget || !latestPointIsInsideStartTarget {
                    touchStartOverlay?.clearPressedTarget()
                    store?.onTouchDownHitCancelled?(target)
                    logTouchDeliveryVerdict(
                        stage: "reset.skipDispatchOutsideTarget",
                        verdict: "pendingLookupDroppedOutsideTarget",
                        reason: touchHasMoved ? "touchMovedBeforeReset" : "outsideStartTarget",
                        target: target,
                        point: latestPoint,
                        coordinateView: coordinateView,
                        extra: [
                            "lookupDispatchedOnReset": false,
                            "segmentTargetTouchesReachWebKit": true,
                            "touchHasMoved": touchHasMoved,
                            "touchStartIsInsideTarget": touchStartIsInsideTarget,
                            "latestPointIsInsideStartTarget": latestPointIsInsideStartTarget,
                        ]
                    )
                } else if store?.hasActiveWebTextSelection == true {
                    logTouchDeliveryVerdict(
                        stage: "reset.skipDispatchTextSelectionActive",
                        verdict: "pendingLookupDroppedForTextSelection",
                        reason: "webTextSelectionActive",
                        target: target,
                        point: point,
                        coordinateView: coordinateView,
                        extra: [
                            "lookupDispatchedOnReset": false,
                            "segmentTargetTouchesReachWebKit": true,
                        ].merging(store?.webTextSelectionDiagnostics ?? [:]) { _, new in new }
                    )
                } else {
                    let coordinateViewWindowOrigin = coordinateView.convert(CGPoint.zero, to: nil)
                    let didDispatchLookup = store?.handleTap(
                        on: target,
                        at: latestPoint,
                        in: coordinateView.bounds.size,
                        coordinateViewWindowOrigin: coordinateViewWindowOrigin
                    ) == true
                    logTouchDeliveryVerdict(
                        stage: "reset.dispatchPendingNativeLookup",
                        verdict: didDispatchLookup
                            ? "pendingLookupDispatchedDuringRecognizerReset"
                            : "pendingLookupDispatchFailedDuringRecognizerReset",
                        reason: "unexpectedRecognizerReset",
                        target: target,
                        point: latestPoint,
                        coordinateView: coordinateView,
                        extra: [
                            "lookupDispatchedOnReset": didDispatchLookup,
                            "segmentTargetTouchesReachWebKit": false,
                            "touchHasMoved": touchHasMoved,
                            "latestPointIsInsideStartTarget": latestPointIsInsideStartTarget,
                        ]
                    )
                    shouldHoldPressedTargetForHandoff = didDispatchLookup
                    if didDispatchLookup {
                        touchStartOverlay?.clearPressedTarget(after: Self.segmentTapPressedFallbackDuration)
                    }
                }
            }
            resetTrackingState(clearPressedTarget: !shouldHoldPressedTargetForHandoff)
            return
        }
        resetTrackingState()
    }

    func cancelForExternalPageMotion(reason: String) {
        guard touchStartTarget != nil || touchStartOverlay != nil else { return }
        clearPressedVisualForMovementIfNeeded(payload: [
            "reason": reason,
            "movement": "externalPageMotion",
        ])
        failGesture(reason: reason, payload: [
            "reason": reason,
            "movement": "externalPageMotion",
        ])
    }

    private func resetTrackingState(clearPressedTarget: Bool = true) {
        tapExpirationWorkItem?.cancel()
        tapExpirationWorkItem = nil
        touchStartPoint = nil
        touchStartWindowPoint = nil
        touchStartTime = nil
        touchStartTarget = nil
        touchStartWasActiveTarget = false
        touchStartPressedVisualCleared = false
        touchStartIsInsideTarget = false
        touchHasMoved = false
        touchLatestPoint = nil
        restoreSuppressedCompetingTapRecognizers(reason: "resetTrackingState")
        store?.finishNativeTouchStream(reason: "resetTrackingState")
        if clearPressedTarget {
            touchStartOverlay?.clearPressedTarget()
        }
        touchStartOverlay = nil
    }

    private func suppressCompetingWebKitTapRecognizers(
        reason: String,
        target: WebViewNativeLookupHitTarget,
        point: CGPoint,
        coordinateView: NativeLookupHitTestOverlayView
    ) {
        guard suppressedCompetingTapRecognizers.isEmpty,
              let rootView = view else { return }
        var recognizers: [UIGestureRecognizer] = []
        var seen = Set<ObjectIdentifier>()
        func collect(in candidate: UIView) {
            if let candidateRecognizers = candidate.gestureRecognizers {
                for recognizer in candidateRecognizers where recognizer !== self {
                    let typeName = String(describing: type(of: recognizer))
                    guard recognizer is UITapGestureRecognizer || typeName.contains("Tap") else { continue }
                    let identifier = ObjectIdentifier(recognizer)
                    guard seen.insert(identifier).inserted else { continue }
                    recognizers.append(recognizer)
                }
            }
            for subview in candidate.subviews {
                collect(in: subview)
            }
        }
        collect(in: rootView)
        recognizers = recognizers.filter(\.isEnabled)
        guard !recognizers.isEmpty else { return }
        suppressedCompetingTapRecognizers = recognizers.map { ($0, $0.isEnabled) }
        for recognizer in recognizers {
            recognizer.isEnabled = false
        }
        logTouchDeliveryVerdict(
            stage: "recognizer.suppressCompetingTaps",
            verdict: "webkitTapRecognizersDisabledForNativeCandidate",
            reason: reason,
            target: target,
            point: point,
            coordinateView: coordinateView,
            extra: [
                "suppressedCount": recognizers.count,
                "suppressedTypes": recognizers.prefix(12).map { String(describing: type(of: $0)) },
                "segmentTargetTouchesReachWebKit": "tapRecognizersDisabledDuringNativeDecision"
            ]
        )
    }

    private func restoreSuppressedCompetingTapRecognizers(reason: String) {
        guard !suppressedCompetingTapRecognizers.isEmpty else { return }
        let restored = suppressedCompetingTapRecognizers
        suppressedCompetingTapRecognizers.removeAll()
        for (recognizer, wasEnabled) in restored {
            recognizer.isEnabled = wasEnabled
        }
    }

    private func clearPressedVisualForMovementIfNeeded(payload _: [String: Any]) {
        guard !touchStartPressedVisualCleared else { return }
        touchStartPressedVisualCleared = true
        touchStartOverlay?.clearPressedTarget()
    }

    private static func point(_ point: CGPoint, isInside target: WebViewNativeLookupHitTarget) -> Bool {
        target.projectedRectsForCurrentHitTestOverlay.contains { rect in
            !rect.isNull && !rect.isEmpty && rect.contains(point)
        }
    }

    private func failGesture(reason: String, payload: [String: Any] = [:]) {
        var mergedPayload = payload
        mergedPayload["stage"] = "failGesture.\(reason)"
        logTouchDeliveryVerdict(
            stage: "failGesture.\(reason)",
            verdict: "passThrough.allowedAfterRecognizerFailure",
            reason: reason,
            target: touchStartTarget,
            coordinateView: coordinateView,
            extra: payload.merging(["segmentTargetTouchesReachWebKit": true]) { current, _ in current }
        )
        resetTrackingState()
        state = .failed
    }

    private func logTouchDeliveryVerdict(
        stage: String,
        verdict: String,
        reason: String,
        target: WebViewNativeLookupHitTarget? = nil,
        point: CGPoint? = nil,
        coordinateView: NativeLookupHitTestOverlayView? = nil,
        extra: [String: Any] = [:]
    ) {
        var payload: [String: Any] = [
            "verdict": verdict,
            "reason": reason
        ]
        if let movement = extra["movement"] {
            payload["movement"] = movement
        }
        if let duration = extra["duration"] {
            payload["duration"] = duration
        }
        if let targetCount = extra["targetCount"] {
            payload["targetCount"] = targetCount
        }
        if let activeLookupElementID = extra["activeLookupElementID"] {
            payload["active"] = activeLookupElementID
        }
        if let activeHighlightElementID = extra["activeHighlightElementID"] {
            payload["highlight"] = activeHighlightElementID
        }
        if let lookupDispatchedOnTouchDown = extra["lookupDispatchedOnTouchDown"] {
            payload["downDispatch"] = lookupDispatchedOnTouchDown
        }
        if let completedOnTouchDown = extra["completedOnTouchDown"] {
            payload["downComplete"] = completedOnTouchDown
        }
        if let segmentTargetTouchesReachWebKit = extra["segmentTargetTouchesReachWebKit"] {
            payload["webTouches"] = segmentTargetTouchesReachWebKit
        }
        if let nativeLookupEnabled = extra["nativeLookupEnabled"] {
            payload["enabled"] = nativeLookupEnabled
        }
        if let nearest = extra["nearest"] {
            payload["nearest"] = nearest
        }
        if let hitPoint = extra["hitPoint"] {
            payload["hitPoint"] = hitPoint
        }
        if let hitBasis = extra["hitBasis"] {
            payload["hitBasis"] = hitBasis
        }
        if let point {
            payload["point"] = Self.debugPointString(point)
        }
        if let coordinateView {
            payload["size"] = Self.debugSizeString(coordinateView.bounds.size)
        }
        if let target {
            payload["id"] = target.elementID
            payload["rect"] = target.rects.first.map {
                WebViewNativeLookupHitTestStore.debugRectStrings([$0]).first ?? ""
            } as Any
            payload["selectedPoint"] = target.debugHitTestPoint.map(Self.debugPointString) as Any
            payload["rebaseX"] = target.debugHitTestRebaseX as Any
            payload["rebaseY"] = target.debugHitTestRebaseY as Any
            payload["inflated"] = target.debugUsedInflatedHitRect as Any
            payload["payload"] = target.lookupPayload != nil
            payload["frame"] = target.frameInfo != nil
        }
        for (key, value) in extra where payload[key] == nil {
            payload[key] = value
        }
        payload["stage"] = stage
        print(
            "# POPOVER native.gesture",
            payload.keys.sorted()
                .map { "\($0)=\(popoverLogValue(payload[$0] as Any))" }
                .joined(separator: " ")
        )
    }

    private static func debugPointString(_ point: CGPoint) -> String {
        "{\(point.x), \(point.y)}"
    }

    private static func debugSizeString(_ size: CGSize) -> String {
        "{\(size.width), \(size.height)}"
    }
}

public class WebViewController: UIViewController {
    var webView: EnhancedWKWebView
    private var webViewConstraints: [NSLayoutConstraint] = []
    private var nativeLookupHitTestOverlayConstraints: [NSLayoutConstraint] = []
    private var snapshotImageView: UIImageView?
    private let nativeLookupHitTestOverlayView = NativeLookupHitTestOverlayView()
    private let nativeLookupHitTestGestureRecognizer = NativeLookupHitTestTapGestureRecognizer()
    private var nativeLookupTapFailureRequirementRecognizerIDs: Set<ObjectIdentifier> = []
    private var earlySuppressedNativeLookupTapRecognizers: [(recognizer: UIGestureRecognizer, wasEnabled: Bool)] = []
    private var capturesNativeLookupSegmentTouchesInOverlay = false
    private var lastKnownWebViewSize: CGSize = .zero
    private var lastAppliedAdditionalSafeAreaInsets = UIEdgeInsets.zero
    private var lastAppliedObscuredInsets = UIEdgeInsets.zero
    private var lastAppliedWebKitObscuredInsets: UIEdgeInsets?
    var isWebViewUnloaded = false
    var onViewDidAppear: (() -> Void)?
    var onViewWillDisappear: (() -> Void)?
    var onViewDidDisappear: (() -> Void)?
    var onWillMoveToNoParent: (() -> Void)?
    var onReplaceWebView: ((EnhancedWKWebView, EnhancedWKWebView) -> Void)?
    var obscuredInsets = UIEdgeInsets.zero {
        didSet {
            updateObscuredInsets()
        }
    }
    
    public init(webView: EnhancedWKWebView) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
        attachWebView(webView)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateObscuredInsets(reason: "viewDidLayoutSubviews")
        if nativeLookupHitTestGestureRecognizer.view != nil {
            configureNativeLookupTapFailureRequirements(reason: "viewDidLayoutSubviews")
        }
        let size = webView.bounds.size
        if size.width > 1, size.height > 1 {
            lastKnownWebViewSize = size
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onViewDidAppear?()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onViewDidDisappear?()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onViewWillDisappear?()
    }

    public override func willMove(toParent parent: UIViewController?) {
        super.willMove(toParent: parent)
        guard parent == nil else { return }
        onWillMoveToNoParent?()
    }
    
    override public func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateObscuredInsets(reason: "viewSafeAreaInsetsDidChange")
    }

    @MainActor
    func applyHostLayout(
        additionalSafeAreaInsets: UIEdgeInsets,
        obscuredInsets: UIEdgeInsets
    ) -> (changedAdditionalSafeAreaInsets: Bool, changedObscuredInsets: Bool) {
        let changedAdditionalSafeAreaInsets = lastAppliedAdditionalSafeAreaInsets != additionalSafeAreaInsets
        if changedAdditionalSafeAreaInsets {
            self.additionalSafeAreaInsets = additionalSafeAreaInsets
            lastAppliedAdditionalSafeAreaInsets = additionalSafeAreaInsets
        }

        let changedObscuredInsets = lastAppliedObscuredInsets != obscuredInsets
        if changedObscuredInsets {
            self.obscuredInsets = obscuredInsets
            lastAppliedObscuredInsets = obscuredInsets
        }
        safeAreaLog(
            "webViewController.applyHostLayout",
            [
                "additionalTop": "\(additionalSafeAreaInsets.top)",
                "additionalBottom": "\(additionalSafeAreaInsets.bottom)",
                "changedAdditional": "\(changedAdditionalSafeAreaInsets)",
                "changedObscured": "\(changedObscuredInsets)",
                "controllerAdditionalTop": "\(self.additionalSafeAreaInsets.top)",
                "controllerAdditionalBottom": "\(self.additionalSafeAreaInsets.bottom)",
                "controllerObscuredTop": "\(self.obscuredInsets.top)",
                "controllerObscuredBottom": "\(self.obscuredInsets.bottom)",
                "inputObscuredTop": "\(obscuredInsets.top)",
                "inputObscuredBottom": "\(obscuredInsets.bottom)",
                "lastAppliedAdditionalTop": "\(lastAppliedAdditionalSafeAreaInsets.top)",
                "lastAppliedAdditionalBottom": "\(lastAppliedAdditionalSafeAreaInsets.bottom)",
                "lastAppliedObscuredTop": "\(lastAppliedObscuredInsets.top)",
                "lastAppliedObscuredBottom": "\(lastAppliedObscuredInsets.bottom)",
                "viewWindowSafeAreaTop": "\(view.window?.safeAreaInsets.top ?? 0)",
                "viewWindowSafeAreaBottom": "\(view.window?.safeAreaInsets.bottom ?? 0)",
                "webViewID": readerLoadObjectIDString(webView)
            ]
        )
        if changedAdditionalSafeAreaInsets || changedObscuredInsets {
            view.setNeedsLayout()
            webView.setNeedsLayout()
            webView.scrollView.setNeedsLayout()
            updateObscuredInsets(reason: "applyHostLayout.changed")
        }

        return (changedAdditionalSafeAreaInsets, changedObscuredInsets)
    }
    
    private func applyObscuredInsets(_ insets: UIEdgeInsets, reason: String) {
        guard let webView = view.subviews.compactMap({ $0 as? WKWebView }).first else { return }
        let hasUsableWebViewBounds = webView.bounds.width > 1 && webView.bounds.height > 1
        let hasNonZeroInsets =
            insets.top > 0
            || insets.left > 0
            || insets.bottom > 0
            || insets.right > 0
        if !hasUsableWebViewBounds && hasNonZeroInsets {
            return
        }
        if lastAppliedWebKitObscuredInsets == insets {
            syncManabiChromeInsetsToPage(webView: webView, insets: insets, reason: reason)
            return
        }
        //        let insets = UIEdgeInsets(top: obscuredInsets.top, left: obscuredInsets.left, bottom: 200, right: obscuredInsets.right)
        let contentInsetsKey = ["obsc", "uredCon", "tentIn", "sets"].joined()
        let legacyInsetsKey = ["o", "bscu", "red", "Ins", "ets"].joined()
        let key: String
        if webView.responds(to: NSSelectorFromString("setObscuredContentInsets:")) {
            key = contentInsetsKey
        } else {
            key = legacyInsetsKey
        }
        webView.setValue(insets, forKey: key)
        var scrollViewInsets = webView.scrollView.contentInset
        if scrollViewInsets.top != insets.top {
            let previousAdjustedTop = webView.scrollView.adjustedContentInset.top
            let wasPinnedToTop = webView.scrollView.contentOffset.y <= -previousAdjustedTop + 1
            scrollViewInsets.top = insets.top
            webView.scrollView.contentInset = scrollViewInsets
            if wasPinnedToTop {
                webView.scrollView.contentOffset.y = -webView.scrollView.adjustedContentInset.top
            }
        }
        scrollViewInsets = webView.scrollView.contentInset
        if scrollViewInsets.bottom != insets.bottom {
            let scrollView = webView.scrollView
            let previousMaxOffsetY = max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            let wasPinnedToBottom = scrollView.contentOffset.y >= previousMaxOffsetY - 1
            scrollViewInsets.bottom = insets.bottom
            scrollView.contentInset = scrollViewInsets
            if wasPinnedToBottom {
                let newMaxOffsetY = max(
                    -scrollView.adjustedContentInset.top,
                    scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
                )
                scrollView.contentOffset.y = newMaxOffsetY
            }
        }
        scrollViewInsets = webView.scrollView.contentInset
        if scrollViewInsets.left != insets.left || scrollViewInsets.right != insets.right {
            let previousAdjustedLeft = webView.scrollView.adjustedContentInset.left
            let wasPinnedToLeading = webView.scrollView.contentOffset.x <= -previousAdjustedLeft + 1
            scrollViewInsets.left = insets.left
            scrollViewInsets.right = insets.right
            webView.scrollView.contentInset = scrollViewInsets
            if wasPinnedToLeading {
                webView.scrollView.contentOffset.x = -webView.scrollView.adjustedContentInset.left
            }
        }
        lastAppliedWebKitObscuredInsets = insets
        syncManabiChromeInsetsToPage(webView: webView, insets: insets, reason: reason)

        // WebKit treats _obscuredInsets as the content inset/visible-content-rect input.
        // Do not also mirror it into minimum/maximum viewport insets; that changes viewport
        // sizing semantics and can move CSS/visual viewport behavior independently.
        safeAreaLog(
            "webViewController.applyObscuredInsets",
            [
                "appliedTop": "\(insets.top)",
                "appliedBottom": "\(insets.bottom)",
                "appliedLeft": "\(insets.left)",
                "appliedRight": "\(insets.right)",
                "controllerObscuredTop": "\(obscuredInsets.top)",
                "controllerObscuredBottom": "\(obscuredInsets.bottom)",
                "scrollAdjustedContentInsetTop": "\(webView.scrollView.adjustedContentInset.top)",
                "scrollAdjustedContentInsetBottom": "\(webView.scrollView.adjustedContentInset.bottom)",
                "scrollContentInsetTop": "\(webView.scrollView.contentInset.top)",
                "scrollContentInsetBottom": "\(webView.scrollView.contentInset.bottom)",
                "windowSafeAreaTop": "\(view.window?.safeAreaInsets.top ?? 0)",
                "windowSafeAreaBottom": "\(view.window?.safeAreaInsets.bottom ?? 0)",
                "webViewID": readerLoadObjectIDString(webView)
            ]
        )
        debugPrint(
            "# BOTTOM stage=webViewController.applyObscuredInsets reason=\(reason) appliedBottom=\(insets.bottom) scrollContentInsetBottom=\(webView.scrollView.contentInset.bottom) scrollAdjustedContentInsetBottom=\(webView.scrollView.adjustedContentInset.bottom) scrollIndicatorInsetBottom=\(webView.scrollView.verticalScrollIndicatorInsets.bottom) contentOffsetY=\(webView.scrollView.contentOffset.y) contentSizeHeight=\(webView.scrollView.contentSize.height) boundsHeight=\(webView.scrollView.bounds.height) webViewID=\(readerLoadObjectIDString(webView))"
        )
        if webViewLayoutShouldLog(webView: webView) {
            var payload = webViewLayoutScrollPayload(webView: webView)
            payload["reason"] = reason
            payload["appliedInsets"] = webViewLayoutInsetsString(insets)
            payload["controllerInsets"] = webViewLayoutInsetsString(obscuredInsets)
            payload["windowSafeArea"] = webViewLayoutInsetsString(view.window?.safeAreaInsets ?? .zero)
            webViewLayoutDebugLog("obscuredInsets.apply", payload)
        }
        
        //            webView.setValue(insets, forKey: "unobscuredSafeAreaInsets")
        //            webView.setValue(insets, forKey: "obscuredInsets")
        //        webView.safeAreaInsetsDidChange()
        // TODO: investigate _isChangingObscuredInsetsInteractively
    }

    private func syncManabiChromeInsetsToPage(
        webView: WKWebView,
        insets: UIEdgeInsets,
        reason: String
    ) {
        guard insets.top.isFinite else { return }
#if DEBUG
        print(
            "# POPOVER webview.chromeInsets.sync",
            "reason=\(reason)",
            "top=\(insets.top)",
            "bottom=\(insets.bottom)",
            "webViewFrame=\(webView.frame)",
            "webViewBounds=\(webView.bounds)",
            "webViewSafeAreaTop=\(webView.safeAreaInsets.top)",
            "url=\(webView.url?.absoluteString ?? "nil")"
        )
#endif
        let escapedReason = reason
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let script = """
        (() => {
          const existing = window.__manabiChromeInsets || {};
          window.__manabiChromeInsets = {
            ...existing,
            obscuredTopInset: \(insets.top),
            obscuredTopInsetSource: 'webview-obscured-insets:\(escapedReason)',
            revision: Date.now()
          };
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func updateObscuredInsets(reason: String = "unknown") {
        let insets = UIEdgeInsets(
            top: obscuredInsets.top,
            left: obscuredInsets.left,
            bottom: obscuredInsets.bottom,
            right: obscuredInsets.right
        )
        safeAreaLog(
            "webViewController.updateObscuredInsets",
            [
                "top": "\(insets.top)",
                "bottom": "\(insets.bottom)",
                "reason": reason,
                "viewWindowSafeAreaTop": "\(view.window?.safeAreaInsets.top ?? 0)",
                "viewWindowSafeAreaBottom": "\(view.window?.safeAreaInsets.bottom ?? 0)",
                "webViewID": readerLoadObjectIDString(webView)
            ]
        )
        applyObscuredInsets(insets, reason: reason)
    }

    @MainActor
    func reapplyObscuredInsets(reason: String) {
        updateObscuredInsets(reason: reason)
        view.setNeedsLayout()
        webView.setNeedsLayout()
        webView.scrollView.setNeedsLayout()
    }

    @MainActor
    func replaceWebView(_ newWebView: EnhancedWKWebView) {
        let previousWebView = webView
        onReplaceWebView?(previousWebView, newWebView)
        detachWebView()
        webView = newWebView
        attachWebView(newWebView)
        isWebViewUnloaded = false
        updateObscuredInsets(reason: "replaceWebView")
    }

    @MainActor
    func setNativeLookupHitTestStore(_ store: WebViewNativeLookupHitTestStore) {
        let previousCaptureMode = capturesNativeLookupSegmentTouchesInOverlay
        capturesNativeLookupSegmentTouchesInOverlay = store.capturesSegmentTouchesInOverlay
        nativeLookupHitTestOverlayView.store = store
        nativeLookupHitTestGestureRecognizer.store = store
        nativeLookupHitTestGestureRecognizer.coordinateView = nativeLookupHitTestOverlayView
        if previousCaptureMode != capturesNativeLookupSegmentTouchesInOverlay,
           nativeLookupHitTestOverlayView.superview != nil || nativeLookupHitTestGestureRecognizer.view != nil {
            attachNativeLookupHitTestOverlay()
        }
        store.onOverlaySegmentHitObserved = { [weak self] target, point, containerSize in
            self?.suppressCompetingTapRecognizersFromOverlayHitTest(
                target: target,
                point: point,
                containerSize: containerSize
            )
        }
        store.onNativeTouchStreamFinished = { [weak self] reason in
            self?.restoreEarlySuppressedNativeLookupTapRecognizers(reason: reason)
        }
        store.onPressedTargetHandoffCompleted = { [weak self] elementID in
            DispatchQueue.main.async { [weak self] in
                self?.nativeLookupHitTestOverlayView.clearPressedTarget(matching: elementID)
            }
        }
        store.onExternalTouchInteractionCancelled = { [weak self] reason in
            guard let self else { return }
            self.nativeLookupHitTestOverlayView.clearPressedTarget()
            self.nativeLookupHitTestGestureRecognizer.cancelForExternalPageMotion(reason: reason)
        }
    }

    private func suppressCompetingTapRecognizersFromOverlayHitTest(
        target: WebViewNativeLookupHitTarget,
        point: CGPoint,
        containerSize: CGSize
    ) {
        guard earlySuppressedNativeLookupTapRecognizers.isEmpty else {
            return
        }
        var recognizers: [UIGestureRecognizer] = []
        var seen = Set<ObjectIdentifier>()
        func collect(in candidate: UIView) {
            if let candidateRecognizers = candidate.gestureRecognizers {
                for recognizer in candidateRecognizers where recognizer !== nativeLookupHitTestGestureRecognizer {
                    let typeName = String(describing: type(of: recognizer))
                    guard recognizer.isEnabled,
                          (recognizer is UITapGestureRecognizer || typeName.contains("Tap")) else { continue }
                    let identifier = ObjectIdentifier(recognizer)
                    guard seen.insert(identifier).inserted else { continue }
                    recognizers.append(recognizer)
                }
            }
            for subview in candidate.subviews {
                collect(in: subview)
            }
        }
        collect(in: webView)
        guard !recognizers.isEmpty else {
            return
        }
        earlySuppressedNativeLookupTapRecognizers = recognizers.map { ($0, $0.isEnabled) }
        for recognizer in recognizers {
            recognizer.isEnabled = false
        }
    }

    private func restoreEarlySuppressedNativeLookupTapRecognizers(reason: String) {
        guard !earlySuppressedNativeLookupTapRecognizers.isEmpty else {
            return
        }
        let restored = earlySuppressedNativeLookupTapRecognizers
        earlySuppressedNativeLookupTapRecognizers.removeAll()
        for (recognizer, wasEnabled) in restored {
            recognizer.isEnabled = wasEnabled
        }
    }

    @MainActor
    func detachWebView() {
        NSLayoutConstraint.deactivate(webViewConstraints)
        webViewConstraints.removeAll()
        NSLayoutConstraint.deactivate(nativeLookupHitTestOverlayConstraints)
        nativeLookupHitTestOverlayConstraints.removeAll()
        nativeLookupHitTestOverlayView.removeFromSuperview()
        webView.removeFromSuperview()
    }

    @MainActor
    func showSnapshotOverlay(_ image: UIImage) {
        clearSnapshotOverlay()
        let imageView = UIImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleToFill
        view.addSubview(imageView)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: imageView.topAnchor),
            view.leftAnchor.constraint(equalTo: imageView.leftAnchor),
            view.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
            view.rightAnchor.constraint(equalTo: imageView.rightAnchor)
        ])
        snapshotImageView = imageView
    }

    @MainActor
    func clearSnapshotOverlay() {
        snapshotImageView?.removeFromSuperview()
        snapshotImageView = nil
    }

    @MainActor
    func snapshotSizeMetrics() -> (current: CGSize, lastKnown: CGSize, shouldOverride: Bool) {
        let current = webView.bounds.size
        let lastKnown = lastKnownWebViewSize
        let shouldOverride = (current.width < 2 || current.height < 2)
            && lastKnown.width > 2
            && lastKnown.height > 2
        return (current, lastKnown, shouldOverride)
    }

    @MainActor
    func captureSnapshot() async -> UIImage? {
        let metrics = snapshotSizeMetrics()
        let originalBounds = webView.bounds
        var didOverride = false
        if metrics.shouldOverride {
            webView.bounds = CGRect(origin: .zero, size: metrics.lastKnown)
            webView.layoutIfNeeded()
            webView.scrollView.layoutIfNeeded()
            didOverride = true
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let image = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
        if didOverride {
            webView.bounds = originalBounds
            webView.layoutIfNeeded()
        }
        return image
    }

    @MainActor
    private func attachWebView(_ webView: EnhancedWKWebView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        if let snapshotImageView {
            view.insertSubview(webView, belowSubview: snapshotImageView)
        } else {
            view.addSubview(webView)
        }
        webViewConstraints = [
            view.topAnchor.constraint(equalTo: webView.topAnchor),
            view.leftAnchor.constraint(equalTo: webView.leftAnchor),
            view.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            view.rightAnchor.constraint(equalTo: webView.rightAnchor)
        ]
        NSLayoutConstraint.activate(webViewConstraints)
        readerLoadLog(
            "webViewController.attachWebView",
            [
                "controllerHasWindow": "\(view.window != nil)",
                "webViewHasSuperview": "\(webView.superview != nil)",
                "webViewHasWindow": "\(webView.window != nil)",
                "webViewID": readerLoadObjectIDString(webView)
            ]
        )
    }

    @MainActor
    private func attachNativeLookupHitTestOverlay() {
        NSLayoutConstraint.deactivate(nativeLookupHitTestOverlayConstraints)
        nativeLookupHitTestOverlayConstraints.removeAll()
        nativeLookupHitTestOverlayView.removeFromSuperview()
        nativeLookupHitTestOverlayView.translatesAutoresizingMaskIntoConstraints = false
        let capturesSegmentTouchesInOverlay = capturesNativeLookupSegmentTouchesInOverlay
        let recognizerHostView: UIView = capturesSegmentTouchesInOverlay
            ? nativeLookupHitTestOverlayView
            : webView
        if nativeLookupHitTestGestureRecognizer.view !== recognizerHostView {
            nativeLookupHitTestGestureRecognizer.view?.removeGestureRecognizer(nativeLookupHitTestGestureRecognizer)
            recognizerHostView.addGestureRecognizer(nativeLookupHitTestGestureRecognizer)
        }
        nativeLookupHitTestGestureRecognizer.clientCoordinateView = webView
        if capturesSegmentTouchesInOverlay {
        } else {
            configureNativeLookupTapFailureRequirements(reason: "attachNativeLookupHitTestOverlay")
            DispatchQueue.main.async { [weak self] in
                self?.configureNativeLookupTapFailureRequirements(reason: "attachNativeLookupHitTestOverlay.async")
            }
        }
        if let snapshotImageView {
            view.insertSubview(nativeLookupHitTestOverlayView, belowSubview: snapshotImageView)
        } else {
            view.addSubview(nativeLookupHitTestOverlayView)
        }
        nativeLookupHitTestOverlayConstraints = [
            nativeLookupHitTestOverlayView.topAnchor.constraint(equalTo: webView.topAnchor),
            nativeLookupHitTestOverlayView.leftAnchor.constraint(equalTo: webView.leftAnchor),
            nativeLookupHitTestOverlayView.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            nativeLookupHitTestOverlayView.rightAnchor.constraint(equalTo: webView.rightAnchor)
        ]
        NSLayoutConstraint.activate(nativeLookupHitTestOverlayConstraints)
    }

    @MainActor
    func setNativeLookupHitTestingEnabled(_ enabled: Bool, reason: String) {
        let wasInstalled = nativeLookupHitTestGestureRecognizer.view != nil
            || nativeLookupHitTestOverlayView.superview != nil
        if enabled {
            if !wasInstalled {
                attachNativeLookupHitTestOverlay()
            }
        } else {
            nativeLookupHitTestGestureRecognizer.view?.removeGestureRecognizer(nativeLookupHitTestGestureRecognizer)
            NSLayoutConstraint.deactivate(nativeLookupHitTestOverlayConstraints)
            nativeLookupHitTestOverlayConstraints.removeAll()
            nativeLookupHitTestOverlayView.removeFromSuperview()
            nativeLookupTapFailureRequirementRecognizerIDs.removeAll()
            earlySuppressedNativeLookupTapRecognizers.removeAll()
        }
    }

    @MainActor
    private func configureNativeLookupTapFailureRequirements(reason: String) {
        var tapRecognizers: [UIGestureRecognizer] = []
        func collectTapRecognizers(in candidate: UIView) {
            if let recognizers = candidate.gestureRecognizers {
                for recognizer in recognizers
                where recognizer !== nativeLookupHitTestGestureRecognizer
                    && recognizer is UITapGestureRecognizer {
                    tapRecognizers.append(recognizer)
                }
            }
            for subview in candidate.subviews {
                collectTapRecognizers(in: subview)
            }
        }
        collectTapRecognizers(in: webView)

        var newlyConfigured: [String] = []
        for recognizer in tapRecognizers {
            let identifier = ObjectIdentifier(recognizer)
            guard !nativeLookupTapFailureRequirementRecognizerIDs.contains(identifier) else { continue }
            recognizer.require(toFail: nativeLookupHitTestGestureRecognizer)
            nativeLookupTapFailureRequirementRecognizerIDs.insert(identifier)
            newlyConfigured.append(String(describing: type(of: recognizer)))
        }
        guard !newlyConfigured.isEmpty else { return }
    }

}
#endif

#if os(iOS)
private func manabiCanUseSampledPageTopColorBackground() -> Bool {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    if version.majorVersion > 26 {
        return true
    }
    return version.majorVersion == 26 && version.minorVersion >= 1
}

private final class WebViewStringKeyPathObserver<Object: NSObject, Value>: NSObject {
    private weak var object: Object?
    private let keyPath: String
    private let changeHandler: (Value?) -> Void
    private var isInvalidated = false

    init(object: Object, keyPath: String, changeHandler: @escaping (Value?) -> Void) {
        self.object = object
        self.keyPath = keyPath
        self.changeHandler = changeHandler
        super.init()
        object.addObserver(self, forKeyPath: keyPath, options: [.new], context: nil)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        object?.removeObserver(self, forKeyPath: keyPath)
    }

    deinit {
        invalidate()
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard self.keyPath == keyPath else { return }
        changeHandler(change?[.newKey] as? Value)
    }
}

extension WKWebView {
    fileprivate func manabiBGColorDescription(_ color: UIColor?) -> String {
        guard let color else { return "nil" }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return String(
                format: "rgba(%.4f,%.4f,%.4f,%.4f)",
                Double(red),
                Double(green),
                Double(blue),
                Double(alpha)
            )
        }
        return String(describing: color)
    }

    var sampledPageTopColor: UIColor? {
        let selector = Selector("_sampl\("edPageTopC")olor")
        guard responds(to: selector), let result = perform(selector) else {
            return nil
        }
        return result.takeUnretainedValue() as? UIColor
    }

    var supportsSampledPageTopColor: Bool {
        responds(to: Selector("_sampl\("edPageTopC")olor"))
    }

    func underPageFallbackBackgroundColor(config: WebViewConfig) -> UIColor {
        UIColor(config.backgroundColor)
    }

    @MainActor
    func applyUnderPageFallbackBackgroundColor(config: WebViewConfig, reason: String) {
        let fallbackColor = underPageFallbackBackgroundColor(config: config)
        if #available(iOS 15.0, *) {
            underPageBackgroundColor = fallbackColor
        }
        scrollView.backgroundColor = fallbackColor
    }

    @available(iOS 15.0, *)
    func applyUnderPageBackgroundColor(config: WebViewConfig, allowSampledPageTopColor: Bool = true) {
        let canUseSampledColor = manabiCanUseSampledPageTopColorBackground()
        let sampledColor = sampledPageTopColor
        let fallbackColor = UIColor(config.backgroundColor)
        let systemColor: UIColor = config.isOpaque ? .systemBackground : .clear
        let shouldWaitForSampledColor = config.usesSampledPageTopColorForUnderPageBackground
            && canUseSampledColor
            && supportsSampledPageTopColor
            && sampledColor == nil
        let resolvedColor: UIColor?
        if config.usesSampledPageTopColorForUnderPageBackground, allowSampledPageTopColor {
            resolvedColor = canUseSampledColor ? sampledColor : systemColor
        } else {
            resolvedColor = fallbackColor
        }
        guard let resolvedColor else { return }
        underPageBackgroundColor = resolvedColor
    }

    func resolvedUnderPageBackgroundColor(config: WebViewConfig, allowSampledPageTopColor: Bool = true) -> UIColor? {
        let fallbackColor = UIColor(config.backgroundColor)
        guard config.usesSampledPageTopColorForUnderPageBackground else {
            return fallbackColor
        }
        guard allowSampledPageTopColor else {
            return fallbackColor
        }
        guard manabiCanUseSampledPageTopColorBackground() else {
            return config.isOpaque ? .systemBackground : .clear
        }
        return sampledPageTopColor
    }

    func applyConfiguredBackgroundForReaderDocumentIfNeeded(config: WebViewConfig, reason: String) {
        guard config.usesConfiguredBackgroundForReaderDocuments else { return }
        let js = """
        (function() {
          const body = document.body;
          return !!(body && (body.classList.contains('readability-mode') || body.dataset.isEbook === 'true'));
        })()
        """
        evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error {
                return
            }
            guard result as? Bool == true else {
                return
            }
            let resolvedColor = UIColor(config.backgroundColor)
            self.underPageBackgroundColor = resolvedColor
            self.scrollView.backgroundColor = resolvedColor
        }
    }

    func logManabiSampledPageTopDOMProbe(reason: String) {
        let escapedReason = reason
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let js = """
        (function() {
          const describe = (selector, element) => {
            if (!element) return null;
            const style = getComputedStyle(element);
            const rect = typeof element.getBoundingClientRect === 'function' ? element.getBoundingClientRect() : null;
            return {
              selector,
              tag: element.tagName || null,
              id: element.id || null,
              className: typeof element.className === 'string' ? element.className : null,
              backgroundColor: style.backgroundColor || null,
              color: style.color || null,
              display: style.display || null,
              visibility: style.visibility || null,
              opacity: style.opacity || null,
              rect: rect ? {
                x: Math.round(rect.x * 100) / 100,
                y: Math.round(rect.y * 100) / 100,
                width: Math.round(rect.width * 100) / 100,
                height: Math.round(rect.height * 100) / 100
              } : null
            };
          };
          const pointElement = (x, y) => describe(`point(${x},${y})`, document.elementFromPoint(x, y));
          const root = document.documentElement;
          const body = document.body;
          const bodyStyle = body ? getComputedStyle(body) : null;
          const rootStyle = root ? getComputedStyle(root) : null;
          return JSON.stringify({
            reason: '\(escapedReason)',
            href: location.href,
            readyState: document.readyState,
            scrollY: window.scrollY,
            innerWidth: window.innerWidth,
            innerHeight: window.innerHeight,
            prefersDark: window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)').matches : null,
            bodyClassName: body?.className ?? null,
            colorSchemeAttr: body?.getAttribute('data-mnb-color-scheme') ?? null,
            lightThemeAttr: body?.getAttribute('data-mnb-light-theme') ?? null,
            darkThemeAttr: body?.getAttribute('data-mnb-dark-theme') ?? null,
            bodyThemeBackgroundVariable: bodyStyle ? bodyStyle.getPropertyValue('--theme-background-color').trim() : null,
            rootBackgroundColor: rootStyle?.backgroundColor ?? null,
            bodyBackgroundColor: bodyStyle?.backgroundColor ?? null,
            readerHeader: describe('#reader-header', document.querySelector('#reader-header')),
            readerContent: describe('#reader-content', document.querySelector('#reader-content')),
            readerPage: describe('#reader-page', document.querySelector('#reader-page')),
            body: describe('body', body),
            html: describe('html', root),
            pointTopCenter: pointElement(Math.floor(window.innerWidth / 2), 1),
            point8Center: pointElement(Math.floor(window.innerWidth / 2), 8),
            point32Center: pointElement(Math.floor(window.innerWidth / 2), 32),
            point80Center: pointElement(Math.floor(window.innerWidth / 2), 80)
          });
        })()
        """
        evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error {
                return
            }
        }
    }
}

extension WKWebViewConfiguration {
    func enableManabiPageTopColorSampling() {
        let selector = Selector("_setSa\("mpledPageTopColorMaxDiff")erence:")
        guard responds(to: selector) else {
            return
        }
        perform(selector, with: 5.0 as Double)
    }
}
#endif

#if os(macOS)
private func manabiCanUseSampledPageTopColorBackground() -> Bool {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    if version.majorVersion > 26 {
        return true
    }
    return version.majorVersion == 26 && version.minorVersion >= 1
}
#endif

public struct WebView {
    private let config: WebViewConfig
    var navigator: WebViewNavigator
    @Binding var state: WebViewState
    var scriptCaller: WebViewScriptCaller?
    let blockedHosts: Set<String>?
    let htmlInState: Bool
    let lifecycleConfig: WebViewLifecycleConfig
    let schemeHandlers: [(WKURLSchemeHandler, String)]
    let onNavigationCommitted: ((WebViewState) -> Void)?
    let onNavigationFinished: ((WebViewState) -> Void)?
    let onNavigationFailed: ((WebViewState) -> Void)?
    let onURLChanged: ((WebViewState) -> Void)?
    let onNavigationAction: ((WKNavigationAction) async -> WKNavigationActionPolicy?)?
    let buildMenu: BuildMenuType?
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    let obscuredInsets: EdgeInsets
    var bounces = true
    let webViewPool: WebViewPool?
    let webViewPrewarmer: WebViewPrewarmer?
    //    let onWarm: (() async -> Void)?
    
    @Environment(\.webViewMessageHandlers) internal var webViewMessageHandlers
    
    //    @State fileprivate var isWarm = false
    @State fileprivate var drawsBackground = false
    @State private var lastInstalledScripts = [WebViewUserScript]()
    
    public init(config: WebViewConfig = .default,
                navigator: WebViewNavigator,
                state: Binding<WebViewState>,
                scriptCaller: WebViewScriptCaller? = nil,
                blockedHosts: Set<String>? = nil,
                htmlInState: Bool = false,
                obscuredInsets: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
                bounces: Bool = true,
                //                onWarm: (() async -> Void)? = nil,
                schemeHandlers: [(WKURLSchemeHandler, String)] = [],
                onNavigationCommitted: ((WebViewState) -> Void)? = nil,
                onNavigationFinished: ((WebViewState) -> Void)? = nil,
                onNavigationFailed: ((WebViewState) -> Void)? = nil,
                onURLChanged: ((WebViewState) -> Void)? = nil,
                onNavigationAction: ((WKNavigationAction) async -> WKNavigationActionPolicy?)? = nil,
                buildMenu: BuildMenuType? = nil,
                hideNavigationDueToScroll: Binding<Bool> = .constant(false),
                textSelection: Binding<String?>? = nil,
                webViewPool: WebViewPool? = nil,
                webViewPrewarmer: WebViewPrewarmer? = nil,
                lifecycleConfig: WebViewLifecycleConfig? = nil
    ) {
        self.config = config
        _state = state
        self.navigator = navigator
        self.scriptCaller = scriptCaller
        self.blockedHosts = blockedHosts
        self.htmlInState = htmlInState
        self.obscuredInsets = obscuredInsets
        self.bounces = bounces
        //        self.onWarm = onWarm
        self.schemeHandlers = schemeHandlers
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onURLChanged = onURLChanged
        self.onNavigationAction = onNavigationAction
        self.buildMenu = buildMenu
        _hideNavigationDueToScroll = hideNavigationDueToScroll
        _textSelection = textSelection ?? .constant(nil)
        self.webViewPool = webViewPool
        self.webViewPrewarmer = webViewPrewarmer
        self.lifecycleConfig = lifecycleConfig ?? .default
    }
    
    @MainActor
    public func makeCoordinator() -> WebViewCoordinator {
        let coordinator = WebViewCoordinator(
            webView: self,
            navigator: navigator,
            scriptCaller: scriptCaller,
            config: config,
            messageHandlers: webViewMessageHandlers,
            onNavigationCommitted: onNavigationCommitted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onURLChanged: onURLChanged,
            onNavigationAction: onNavigationAction,
            hideNavigationDueToScroll: $hideNavigationDueToScroll,
            textSelection: $textSelection
        )
        coordinator.webViewPool = resolvedWebViewPool
        coordinator.lifecycleConfig = lifecycleConfig
        coordinator.navigator.attachFallbackURL = lifecycleConfig.idleLoadURL
        coordinator.navigator.forceClearLoadingIndicatorsHandler = { [weak coordinator] reason, pageURL in
            Task { @MainActor in
                coordinator?.forceClearLoadingIndicators(reason: reason, pageURL: pageURL)
            }
        }
        return coordinator
    }

    @MainActor
    private func resolvedUserScriptDomain(currentURL: URL?) -> URL? {
        if let currentURL {
            return currentURL
        }
        if let pendingRequestURL = navigator.pendingRequest?.url {
            return pendingRequestURL
        }
        if let lastLoadedRequestURL = navigator.lastLoadedRequest?.url {
            return lastLoadedRequestURL
        }
        if let pendingHTMLBaseURL = navigator.pendingHTML?.baseURL {
            return pendingHTMLBaseURL
        }
        if let lastLoadedHTMLBaseURL = navigator.lastLoadedHTML?.baseURL {
            return lastLoadedHTMLBaseURL
        }
        if let pendingDataLoadBaseURL = navigator.pendingDataLoad?.baseURL {
            return pendingDataLoadBaseURL
        }
        if let lastLoadedDataLoadBaseURL = navigator.lastLoadedDataLoad?.baseURL {
            return lastLoadedDataLoadBaseURL
        }
        return state.pageURL.absoluteString == "about:blank" ? nil : state.pageURL
    }
}

#if os(iOS)
extension WebView: UIViewControllerRepresentable {
    @MainActor
    private func makeWebView(
        config: WebViewConfig,
        coordinator: WebViewCoordinator
    ) -> EnhancedWKWebView {
        var web: EnhancedWKWebView?
        var source = "new"
        if web == nil, let resolvedWebViewPool {
            web = resolvedWebViewPool.dequeue {
                makeNewWebView(config: config)
            }
            if web != nil {
                source = "pool"
            }
        }
        if web == nil {
            web = makeNewWebView(config: config)
        }
        guard let web else { fatalError("Couldn't instantiate WKWebView for WebView.") }
        readerLoadLog(
            "webView.instanceSelected",
            [
                "coordinatorID": readerLoadObjectIDString(coordinator),
                "navigatorID": readerLoadObjectIDString(coordinator.navigator),
                "processPoolID": readerLoadObjectIDString(web.configuration.processPool),
                "source": source,
                "webViewID": readerLoadObjectIDString(web)
            ]
        )
        
        web.buildMenu = buildMenu
        
        web.scrollView.delegate = coordinator
        
        return web
    }

    @MainActor
    private func makeNewWebView(config: WebViewConfig) -> EnhancedWKWebView {
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = config.javaScriptEnabled

        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = userAgent
#if os(iOS)
        if config.usesSampledPageTopColorForUnderPageBackground,
           manabiCanUseSampledPageTopColorBackground() {
            configuration.enableManabiPageTopColorSampling()
        }
#endif
        configuration.allowsInlineMediaPlayback = config.allowsInlineMediaPlayback
        if config.dataDetectorsEnabled {
            configuration.dataDetectorTypes = [.all]
        } else {
            configuration.dataDetectorTypes = []
        }
        configuration.defaultWebpagePreferences = preferences
        configuration.processPool = webViewProcessPool
        configuration.websiteDataStore = WKWebsiteDataStore.default()

        for (urlSchemeHandler, urlScheme) in schemeHandlers {
            configuration.setURLSchemeHandler(urlSchemeHandler, forURLScheme: urlScheme)
        }

        let webView = EnhancedWKWebView(frame: .zero, configuration: configuration)
        readerLoadLog(
            "webView.instanceCreated",
            [
                "processPoolID": readerLoadObjectIDString(configuration.processPool),
                "webViewID": readerLoadObjectIDString(webView)
            ]
        )
        webView.isOpaque = config.isOpaque
        if #available(iOS 14.0, *) {
            let resolvedBackgroundColor: UIColor = config.usesSampledPageTopColorForUnderPageBackground
                && !manabiCanUseSampledPageTopColorBackground()
                ? (config.isOpaque ? .systemBackground : .clear)
                : UIColor(config.backgroundColor)
            webView.backgroundColor = resolvedBackgroundColor
            if let resolvedUnderPageColor = webView.resolvedUnderPageBackgroundColor(
                config: config,
                allowSampledPageTopColor: false
            ) {
                webView.scrollView.backgroundColor = resolvedUnderPageColor
            }
        } else {
            webView.backgroundColor = config.isOpaque ? .systemBackground : .clear
            webView.scrollView.backgroundColor = config.isOpaque ? .systemBackground : .clear
        }
        webView.scrollView.isOpaque = config.isOpaque
#if os(iOS)
        webView.hidesTopScrollEdgeEffect = config.hidesTopScrollEdgeEffect
        applyTopScrollEdgeEffectHidden(config.hidesTopScrollEdgeEffect, to: webView, reason: "makeUIView")
#endif
        if #available(iOS 15.0, *) {
            webView.applyUnderPageBackgroundColor(config: config, allowSampledPageTopColor: false)
        }
        return webView
    }

    @MainActor
    private func configureWebView(
        _ webView: EnhancedWKWebView,
        controller: WebViewController,
        context: Context
    ) {
#if os(iOS)
        context.coordinator.hostLayoutController = controller
#endif
        let resolvedContentRules = navigator.peekContentRulesBypass() ? nil : config.contentRules
        let resolvedDomain = resolvedUserScriptDomain(currentURL: webView.url)
        let resolvedUserScriptsState = resolvedUserScriptsState(forDomain: resolvedDomain, config: config)
        readerLoadLog(
            "webView.configure",
            [
                "controllerID": readerLoadObjectIDString(controller),
                "coordinatorID": readerLoadObjectIDString(context.coordinator),
                "navigatorID": readerLoadObjectIDString(context.coordinator.navigator),
                "processPoolID": readerLoadObjectIDString(webView.configuration.processPool),
                "webViewID": readerLoadObjectIDString(webView)
            ]
        )
        if context.coordinator.lastUserScriptsContentController !== webView.configuration.userContentController {
            context.coordinator.lastUserScriptsContentController = webView.configuration.userContentController
            context.coordinator.lastInstalledScriptsSignature = webView.persistedUserScriptsSignature
        }
        if context.coordinator.lastAppliedContentRules != webView.persistedAppliedContentRules {
            context.coordinator.lastAppliedContentRules = webView.persistedAppliedContentRules
        }
        if webView.persistedUserScriptsSignature != nil || webView.persistedAppliedContentRules != nil {
            readerLoadLog(
                "webView.configure.restorePersistedState",
                [
                    "contentRules": webView.persistedAppliedContentRules ?? "nil",
                    "userScriptsSignaturePresent": "\(webView.persistedUserScriptsSignature != nil)",
                    "webViewID": readerLoadObjectIDString(webView)
                ]
            )
        }
        applyCommonConfiguration(
            webView: webView,
            context: context,
            resolvedContentRules: resolvedContentRules
        )
        webView.allowsLinkPreview = true
        webView.uiDelegate = context.coordinator
        webView.scrollView.delegate = context.coordinator
        webView.buildMenu = buildMenu
        navigator.nativeLookupHitTesting.isEnabled = config.nativeLookupHitTestingEnabled
        webView.scrollView.contentInsetAdjustmentBehavior = config.adjustsScrollViewContentInsetsForSafeArea ? .always : .never
        webView.scrollView.isScrollEnabled = config.isScrollEnabled
#if os(iOS)
        webView.hidesTopScrollEdgeEffect = config.hidesTopScrollEdgeEffect
        applyTopScrollEdgeEffectHidden(config.hidesTopScrollEdgeEffect, to: webView, reason: "configureWebView")
#endif
        webView.isOpaque = config.isOpaque
        if #available(iOS 14.0, *) {
            let resolvedBackgroundColor: UIColor = config.usesSampledPageTopColorForUnderPageBackground
                && !manabiCanUseSampledPageTopColorBackground()
                ? (config.isOpaque ? .systemBackground : .clear)
                : UIColor(config.backgroundColor)
            webView.backgroundColor = resolvedBackgroundColor
        } else {
            webView.backgroundColor = .clear
        }
        if #available(iOS 14.0, *) {
            if let resolvedUnderPageColor = webView.resolvedUnderPageBackgroundColor(
                config: config,
                allowSampledPageTopColor: false
            ) {
                webView.scrollView.backgroundColor = resolvedUnderPageColor
            }
        } else {
            webView.scrollView.backgroundColor = .clear
        }
        webView.scrollView.isOpaque = config.isOpaque
        if #available(iOS 15.0, *) {
            webView.applyUnderPageBackgroundColor(config: config, allowSampledPageTopColor: false)
        }
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        updateUserScripts(
            userContentController: webView.configuration.userContentController,
            coordinator: context.coordinator,
            forDomain: resolvedDomain,
            config: config,
            resolvedState: resolvedUserScriptsState
        )
        context.coordinator.lastAppliedConfigurationState = webViewConfigurationState(
            webView: webView,
            resolvedDomain: resolvedDomain,
            resolvedUserScriptsState: resolvedUserScriptsState,
            resolvedContentRules: resolvedContentRules,
            config: config
        )
        context.coordinator.scheduleWebViewBinding(webView, paginationReason: "configure-webview")
        if context.coordinator.scriptCaller == nil, let scriptCaller = scriptCaller {
            context.coordinator.scriptCaller = scriptCaller
        }
        context.coordinator.scriptCaller?.asyncCaller = { @MainActor [weak webView] js, args, frame, world in
            guard let webView else {
                throw ScriptCallerError.evaluationTimedOut
            }
            let resolvedWorld = world ?? .page
            if let args {
                let value = try await webView.callAsyncJavaScript(js, arguments: args, in: frame, contentWorld: resolvedWorld)
                return WebViewScriptCaller.JavaScriptEvaluationResult(value)
            } else {
                let result = try await webView.callAsyncJavaScript(js, in: frame, contentWorld: resolvedWorld)
                return WebViewScriptCaller.JavaScriptEvaluationResult(result)
            }
        }
        context.coordinator.textSelection = $textSelection
        controller.setNativeLookupHitTestStore(navigator.nativeLookupHitTesting)
        controller.setNativeLookupHitTestingEnabled(
            config.nativeLookupHitTestingEnabled,
            reason: "configureWebView"
        )
        refreshDarkModeSetting(webView: webView)
        applyVisualConfiguration(webView: webView, containerView: controller.view)
    }
    
    @MainActor
    public func makeUIViewController(context: Context) -> WebViewController {
        // See: https://stackoverflow.com/questions/25200116/how-to-show-the-inspector-within-your-wkwebview-based-desktop-app
        //        preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        let webView = makeWebView(config: config, coordinator: context.coordinator)
        let controller = WebViewController(webView: webView)
        configureWebView(webView, controller: controller, context: context)
        context.coordinator.markSnapshotRestoreIfNeeded()
        context.coordinator.applyCachedSnapshotIfAvailable(controller: controller)
        controller.onReplaceWebView = { [weak coordinator = context.coordinator] oldWebView, newWebView in
            coordinator?.navigator.logCompetingOperationIfNeeded(
                "replaceWebView",
                metadata: [
                    "newWebViewID": readerLoadObjectIDString(newWebView),
                    "oldWebViewID": readerLoadObjectIDString(oldWebView)
                ]
            )
        }
        controller.onViewDidAppear = { [weak coordinator = context.coordinator, weak controller] in
            guard let coordinator, let controller else { return }
            if coordinator.lifecycleConfig.autoUnloadOnDisappear, controller.isWebViewUnloaded {
                coordinator.prepareForReloadIfNeeded(controller: controller)
                coordinator.navigator.prepareForReloadAfterReattach()
                let newWebView = makeWebView(config: config, coordinator: coordinator)
                controller.replaceWebView(newWebView)
                configureWebView(newWebView, controller: controller, context: context)
            }
        }
        controller.onViewWillDisappear = { [weak coordinator = context.coordinator, weak controller] in
            guard let coordinator, let controller else { return }
            guard !coordinator.lifecycleConfig.unloadOnlyWhenRemovedFromHierarchy else { return }
            coordinator.unloadWebViewIfNeeded(controller: controller)
        }
        controller.onWillMoveToNoParent = { [weak coordinator = context.coordinator, weak controller] in
            guard let coordinator, let controller else { return }
            guard coordinator.lifecycleConfig.unloadOnlyWhenRemovedFromHierarchy else { return }
            coordinator.unloadWebViewIfNeeded(controller: controller)
        }
        controller.onViewDidDisappear = {}
        return controller
    }
    
    @MainActor
    public func updateUIViewController(_ controller: WebViewController, context: Context) {
        navigator.nativeLookupHitTesting.isEnabled = config.nativeLookupHitTestingEnabled
        controller.setNativeLookupHitTestStore(navigator.nativeLookupHitTesting)
        controller.setNativeLookupHitTestingEnabled(
            config.nativeLookupHitTestingEnabled,
            reason: "updateUIViewController"
        )
        if let resolvedWebViewPool {
            resolvedWebViewPool.attachWarmShelfIfNeeded(to: controller.view.window)
        }
        let requestedAt = context.coordinator.navigator.readerLoadRequestedAt
        let provisionalStartedAt = context.coordinator.navigator.readerLoadProvisionalStartedAt
        let committedAt = context.coordinator.navigator.readerLoadCommittedAt
        let requestedBeforeProvisional = requestedAt != nil && provisionalStartedAt == nil
        let requestedAfterProvisionalBeforeCommit = requestedAt != nil && provisionalStartedAt != nil && committedAt == nil
        if readerLoadVerboseUIViewControllerLoggingEnabled && (requestedBeforeProvisional || requestedAfterProvisionalBeforeCommit) {
            readerLoadLog(
                "webView.host.updateUIViewController",
                [
                    "currentURL": controller.webView.url?.absoluteString ?? "nil",
                    "elapsedSinceIssued": readerLoadElapsedString(since: context.coordinator.navigator.readerLoadIssuedAt),
                    "elapsedSinceRequested": readerLoadElapsedString(since: context.coordinator.navigator.readerLoadRequestedAt),
                    "hasSuperview": "\(controller.webView.superview != nil)",
                    "hasWindow": "\(controller.webView.window != nil)",
                    "sceneState": readerLoadSceneStateString(for: controller.webView),
                    "webViewID": readerLoadObjectIDString(controller.webView)
                ]
            )
        }
        if let provisionalStartedAt, requestedAfterProvisionalBeforeCommit {
            let waitElapsed = Date().timeIntervalSince(provisionalStartedAt)
            if waitElapsed >= readerLoadCommitGapWarningThreshold {
                let requestURLString = context.coordinator.navigator.activeReaderLoadRequestURL(
                    for: controller.webView.url
                )?.absoluteString ?? "nil"
                context.coordinator.navigator.updateInternalLoaderCorrelation(
                    for: controller.webView.url,
                    now: Date()
                )
                let internalSchemeResponseGap = context.coordinator.navigator.readerLoadInternalLoaderResponseAt.map {
                    String(format: "%.3fs", Date().timeIntervalSince($0))
                } ?? "nil"
                let internalSchemeDataGap = context.coordinator.navigator.readerLoadInternalLoaderDataAt.map {
                    String(format: "%.3fs", Date().timeIntervalSince($0))
                } ?? "nil"
                let internalSchemeFinishGap = context.coordinator.navigator.readerLoadInternalLoaderFinishedAt.map {
                    String(format: "%.3fs", Date().timeIntervalSince($0))
                } ?? "nil"
                readerLoadLog(
                    "webView.host.loaderPhase.postProvisionalPreCommit",
                    [
                        "currentURL": controller.webView.url?.absoluteString ?? "nil",
                        "elapsedSinceProvisionalStart": String(format: "%.3fs", waitElapsed),
                        "estimatedProgress": String(format: "%.3f", controller.webView.estimatedProgress),
                        "hasSuperview": "\(controller.webView.superview != nil)",
                        "hasWindow": "\(controller.webView.window != nil)",
                        "internalSchemeDataGap": internalSchemeDataGap,
                        "internalSchemeFinishGap": internalSchemeFinishGap,
                        "internalSchemeResponseGap": internalSchemeResponseGap,
                        "isLoading": "\(controller.webView.isLoading)",
                        "requestURL": requestURLString,
                        "sceneState": readerLoadSceneStateString(for: controller.webView),
                        "traceID": context.coordinator.navigator.readerLoadTraceID ?? "nil",
                        "webViewID": readerLoadObjectIDString(controller.webView)
                    ]
                )
            }
        }
        updateCoordinatorBindings(context: context)
        let resolvedContentRules = navigator.peekContentRulesBypass() ? nil : config.contentRules
        let resolvedDomain = resolvedUserScriptDomain(currentURL: controller.webView.url)
        let resolvedUserScriptsState = resolvedUserScriptsState(forDomain: resolvedDomain, config: config)
        let currentConfigurationState = webViewConfigurationState(
            webView: controller.webView,
            resolvedDomain: resolvedDomain,
            resolvedUserScriptsState: resolvedUserScriptsState,
            resolvedContentRules: resolvedContentRules,
            config: config
        )
        let configurationChanged = context.coordinator.lastAppliedConfigurationState != currentConfigurationState

        if requestedBeforeProvisional || requestedAfterProvisionalBeforeCommit {
            context.coordinator.lastHostUpdateContextSignature = nil
        }

        if configurationChanged {
            applyCommonConfiguration(
                webView: controller.webView,
                context: context,
                resolvedContentRules: resolvedContentRules
            )
            refreshDarkModeSetting(webView: controller.webView)
            updateUserScripts(
                userContentController: controller.webView.configuration.userContentController,
                coordinator: context.coordinator,
                forDomain: resolvedDomain,
                config: config,
                resolvedState: resolvedUserScriptsState
            )
            controller.webView.scrollView.bounces = bounces
            controller.webView.scrollView.alwaysBounceVertical = bounces
            controller.webView.scrollView.contentInsetAdjustmentBehavior = config.adjustsScrollViewContentInsetsForSafeArea ? .always : .never
            controller.webView.scrollView.isScrollEnabled = config.isScrollEnabled
#if os(iOS)
            controller.webView.hidesTopScrollEdgeEffect = config.hidesTopScrollEdgeEffect
            applyTopScrollEdgeEffectHidden(config.hidesTopScrollEdgeEffect, to: controller.webView, reason: "updateUIView.configurationChanged")
#endif
            applyVisualConfiguration(webView: controller.webView, containerView: controller.view)
            context.coordinator.lastAppliedConfigurationState = currentConfigurationState
        }
#if os(iOS)
        if controller.webView.hidesTopScrollEdgeEffect != config.hidesTopScrollEdgeEffect {
        }
        controller.webView.hidesTopScrollEdgeEffect = config.hidesTopScrollEdgeEffect
        applyTopScrollEdgeEffectHidden(config.hidesTopScrollEdgeEffect, to: controller.webView, reason: "updateUIView.always")
#endif
        
        //        refreshContentRules(userContentController: controller.webView.configuration.userContentController, coordinator: context.coordinator)
        
        //        controller.webView.setValue(drawsBackground, forKey: "drawsBackground")
        
        
        controller.webView.buildMenu = buildMenu
        context.coordinator.applyCachedSnapshotIfAvailable(controller: controller)
        
        // TODO: Fix for RTL languages, if it matters for _obscuredInsets.
        //        let insets = UIEdgeInsets(top: obscuredInsets.top, left: obscuredInsets.leading, bottom: obscuredInsets.bottom, right: obscuredInsets.trailing)
        let topSafeAreaInset = controller.view.window?.safeAreaInsets.top ?? 0
        let bottomSafeAreaInset = controller.view.window?.safeAreaInsets.bottom ?? 0

        //        let insets = UIEdgeInsets(top: obscuredInsets.top, left: obscuredInsets.leading, bottom: obscuredInsets.bottom, right: obscuredInsets.trailing)
        //        print(obscuredInsets)
        let isBookWebViewUpdate =
            state.pageURL.scheme == "ebook"
            || controller.webView.url?.scheme == "ebook"
            || controller.webView.url?.scheme == "reader-file"
        let proposedTopObscuredInset = max(0, obscuredInsets.top)
        let resolvedTopObscuredInset = isBookWebViewUpdate
            ? max(proposedTopObscuredInset, topSafeAreaInset)
            : proposedTopObscuredInset
        let incomingBottomObscuredInset = max(0, obscuredInsets.bottom)
        let effectiveIncomingBottomObscuredInset = isBookWebViewUpdate
            ? max(incomingBottomObscuredInset, bottomSafeAreaInset)
            : incomingBottomObscuredInset
        let treatsIncomingBottomAsAdditionalClearance =
            bottomSafeAreaInset > 0
            && effectiveIncomingBottomObscuredInset > 0
            && effectiveIncomingBottomObscuredInset < bottomSafeAreaInset
        let resolvedAdditionalBottomSafeAreaInset = treatsIncomingBottomAsAdditionalClearance
            ? effectiveIncomingBottomObscuredInset
            : max(0, effectiveIncomingBottomObscuredInset - bottomSafeAreaInset)
        let proposedObscuredBottomInset = treatsIncomingBottomAsAdditionalClearance
            ? bottomSafeAreaInset + effectiveIncomingBottomObscuredInset
            : effectiveIncomingBottomObscuredInset
        let resolvedObscuredBottomInset = proposedObscuredBottomInset
        let additionalSafeAreaInsets = UIEdgeInsets(
            top: 0,
            left: max(0, obscuredInsets.leading - (controller.view.window?.safeAreaInsets.left ?? 0)),
            bottom: resolvedAdditionalBottomSafeAreaInset,
            right: max(0, obscuredInsets.trailing - (controller.view.window?.safeAreaInsets.right ?? 0))
        )
        //        controller.obscuredInsets = UIEdgeInsets(top: 0, left: 0, bottom: obscuredInsets.bottom, right: 0)

        let resolvedObscuredInsets = UIEdgeInsets(
            top: resolvedTopObscuredInset,
            left: max(0, obscuredInsets.leading),
            bottom: resolvedObscuredBottomInset,
            right: max(0, obscuredInsets.trailing)
        )
        if isBookWebViewUpdate {
            bookLog(
                "swiftUIWebView.updateInsets",
                [
                    "stateURL": state.pageURL.absoluteString,
                    "webViewURL": controller.webView.url?.absoluteString ?? "nil",
                    "incomingTop": "\(obscuredInsets.top)",
                    "incomingLeading": "\(obscuredInsets.leading)",
                    "incomingBottom": "\(obscuredInsets.bottom)",
                    "effectiveIncomingBottom": "\(effectiveIncomingBottomObscuredInset)",
                    "incomingTrailing": "\(obscuredInsets.trailing)",
                    "windowSafeAreaTop": "\(topSafeAreaInset)",
                    "windowSafeAreaBottom": "\(bottomSafeAreaInset)",
                    "bottomPolicy": treatsIncomingBottomAsAdditionalClearance ? "incomingAsAdditionalClearance" : "incomingAsTotalObscured",
                    "topPolicy": isBookWebViewUpdate
                        ? "ebookMaxIncomingWindowSafeArea"
                        : "incomingAsTotalObscured",
                    "proposedTop": "\(proposedTopObscuredInset)",
                    "proposedBottom": "\(proposedObscuredBottomInset)",
                    "resolvedTop": "\(resolvedObscuredInsets.top)",
                    "resolvedBottom": "\(resolvedObscuredInsets.bottom)",
                    "additionalBottom": "\(additionalSafeAreaInsets.bottom)",
                    "scrollContentInsetTopBefore": "\(controller.webView.scrollView.contentInset.top)",
                    "scrollContentInsetBottomBefore": "\(controller.webView.scrollView.contentInset.bottom)",
                    "scrollAdjustedContentInsetTopBefore": "\(controller.webView.scrollView.adjustedContentInset.top)",
                    "scrollAdjustedContentInsetBottomBefore": "\(controller.webView.scrollView.adjustedContentInset.bottom)",
                    "webViewID": readerLoadObjectIDString(controller.webView)
                ]
            )
        }
        safeAreaLog(
            "swiftUIWebView.updateBottom",
            [
                "incomingObscuredTop": "\(obscuredInsets.top)",
                "incomingObscuredLeading": "\(obscuredInsets.leading)",
                "incomingObscuredBottom": "\(obscuredInsets.bottom)",
                "incomingObscuredTrailing": "\(obscuredInsets.trailing)",
                "windowSafeAreaTop": "\(topSafeAreaInset)",
                "windowSafeAreaLeft": "\(controller.view.window?.safeAreaInsets.left ?? 0)",
                "windowSafeAreaBottom": "\(bottomSafeAreaInset)",
                "windowSafeAreaRight": "\(controller.view.window?.safeAreaInsets.right ?? 0)",
                "bottomPolicy": treatsIncomingBottomAsAdditionalClearance ? "incomingAsAdditionalClearance" : "incomingAsTotalObscured",
                "additionalTop": "\(additionalSafeAreaInsets.top)",
                "additionalLeft": "\(additionalSafeAreaInsets.left)",
                "additionalBottom": "\(additionalSafeAreaInsets.bottom)",
                "additionalRight": "\(additionalSafeAreaInsets.right)",
                "topPolicy": isBookWebViewUpdate
                    ? "ebookMaxIncomingWindowSafeArea"
                    : "incomingAsTotalObscured",
                "resolvedObscuredTop": "\(resolvedObscuredInsets.top)",
                "resolvedObscuredLeft": "\(resolvedObscuredInsets.left)",
                "resolvedObscuredBottom": "\(resolvedObscuredInsets.bottom)",
                "resolvedObscuredRight": "\(resolvedObscuredInsets.right)",
                "controllerAdditionalTopBefore": "\(controller.additionalSafeAreaInsets.top)",
                "controllerAdditionalLeftBefore": "\(controller.additionalSafeAreaInsets.left)",
                "controllerAdditionalBottomBefore": "\(controller.additionalSafeAreaInsets.bottom)",
                "controllerAdditionalRightBefore": "\(controller.additionalSafeAreaInsets.right)",
                "controllerObscuredTopBefore": "\(controller.obscuredInsets.top)",
                "controllerObscuredLeftBefore": "\(controller.obscuredInsets.left)",
                "controllerObscuredBottomBefore": "\(controller.obscuredInsets.bottom)",
                "controllerObscuredRightBefore": "\(controller.obscuredInsets.right)",
                "scrollAdjustedContentInsetTopBefore": "\(controller.webView.scrollView.adjustedContentInset.top)",
                "scrollAdjustedContentInsetLeftBefore": "\(controller.webView.scrollView.adjustedContentInset.left)",
                "scrollAdjustedContentInsetBottomBefore": "\(controller.webView.scrollView.adjustedContentInset.bottom)",
                "scrollAdjustedContentInsetRightBefore": "\(controller.webView.scrollView.adjustedContentInset.right)",
                "scrollContentInsetTopBefore": "\(controller.webView.scrollView.contentInset.top)",
                "scrollContentInsetLeftBefore": "\(controller.webView.scrollView.contentInset.left)",
                "scrollContentInsetBottomBefore": "\(controller.webView.scrollView.contentInset.bottom)",
                "scrollContentInsetRightBefore": "\(controller.webView.scrollView.contentInset.right)",
                "webViewID": readerLoadObjectIDString(controller.webView)
            ]
        )
        let hostLayoutChanges = controller.applyHostLayout(
            additionalSafeAreaInsets: additionalSafeAreaInsets,
            obscuredInsets: resolvedObscuredInsets
        )
        if isBookWebViewUpdate {
            let shouldForcePopoverInsetLog =
                hostLayoutChanges.changedAdditionalSafeAreaInsets
                || hostLayoutChanges.changedObscuredInsets
            popoverWebViewInsetLog(
                [
                    "webViewID": readerLoadObjectIDString(controller.webView),
                    "inTop": "\(obscuredInsets.top)",
                    "resolvedTop": "\(resolvedObscuredInsets.top)",
                    "obscuredTop": "\(controller.obscuredInsets.top)",
                    "scrollTop": "\(controller.webView.scrollView.contentInset.top)",
                    "adjustedTop": "\(controller.webView.scrollView.adjustedContentInset.top)",
                    "bottom": "\(controller.obscuredInsets.bottom)",
                    "changed": "\(hostLayoutChanges.changedAdditionalSafeAreaInsets || hostLayoutChanges.changedObscuredInsets)"
                ],
                force: shouldForcePopoverInsetLog
            )
            bookLog(
                "swiftUIWebView.updateInsets.applied",
                [
                    "stateURL": state.pageURL.absoluteString,
                    "webViewURL": controller.webView.url?.absoluteString ?? "nil",
                    "changedAdditional": "\(hostLayoutChanges.changedAdditionalSafeAreaInsets)",
                    "changedObscured": "\(hostLayoutChanges.changedObscuredInsets)",
                    "controllerObscuredTopAfter": "\(controller.obscuredInsets.top)",
                    "controllerObscuredBottomAfter": "\(controller.obscuredInsets.bottom)",
                    "scrollContentInsetTopAfter": "\(controller.webView.scrollView.contentInset.top)",
                    "scrollContentInsetBottomAfter": "\(controller.webView.scrollView.contentInset.bottom)",
                    "scrollAdjustedContentInsetTopAfter": "\(controller.webView.scrollView.adjustedContentInset.top)",
                    "scrollAdjustedContentInsetBottomAfter": "\(controller.webView.scrollView.adjustedContentInset.bottom)",
                    "webViewID": readerLoadObjectIDString(controller.webView)
                ]
            )
        }
        safeAreaLog(
            "swiftUIWebView.updateBottom.applied",
            [
                "changedAdditional": "\(hostLayoutChanges.changedAdditionalSafeAreaInsets)",
                "changedObscured": "\(hostLayoutChanges.changedObscuredInsets)",
                "controllerAdditionalTopAfter": "\(controller.additionalSafeAreaInsets.top)",
                "controllerAdditionalLeftAfter": "\(controller.additionalSafeAreaInsets.left)",
                "controllerAdditionalBottomAfter": "\(controller.additionalSafeAreaInsets.bottom)",
                "controllerAdditionalRightAfter": "\(controller.additionalSafeAreaInsets.right)",
                "controllerObscuredTopAfter": "\(controller.obscuredInsets.top)",
                "controllerObscuredLeftAfter": "\(controller.obscuredInsets.left)",
                "controllerObscuredBottomAfter": "\(controller.obscuredInsets.bottom)",
                "controllerObscuredRightAfter": "\(controller.obscuredInsets.right)",
                "scrollAdjustedContentInsetTopAfter": "\(controller.webView.scrollView.adjustedContentInset.top)",
                "scrollAdjustedContentInsetLeftAfter": "\(controller.webView.scrollView.adjustedContentInset.left)",
                "scrollAdjustedContentInsetBottomAfter": "\(controller.webView.scrollView.adjustedContentInset.bottom)",
                "scrollAdjustedContentInsetRightAfter": "\(controller.webView.scrollView.adjustedContentInset.right)",
                "scrollContentInsetTopAfter": "\(controller.webView.scrollView.contentInset.top)",
                "scrollContentInsetLeftAfter": "\(controller.webView.scrollView.contentInset.left)",
                "scrollContentInsetBottomAfter": "\(controller.webView.scrollView.contentInset.bottom)",
                "scrollContentInsetRightAfter": "\(controller.webView.scrollView.contentInset.right)",
                "webViewID": readerLoadObjectIDString(controller.webView)
            ]
        )
        if (hostLayoutChanges.changedAdditionalSafeAreaInsets || hostLayoutChanges.changedObscuredInsets),
           let requestedAt = context.coordinator.navigator.readerLoadRequestedAt,
           context.coordinator.navigator.readerLoadProvisionalStartedAt == nil {
            let elapsedSinceRequested = Date().timeIntervalSince(requestedAt)
            readerLoadLog(
                "webView.host.layoutUpdate",
                [
                    "changedAdditionalSafeAreaInsets": "\(hostLayoutChanges.changedAdditionalSafeAreaInsets)",
                    "changedObscuredInsets": "\(hostLayoutChanges.changedObscuredInsets)",
                    "elapsedSinceRequested": String(format: "%.3f", elapsedSinceRequested),
                    "pageTopInset": String(format: "%.1f", additionalSafeAreaInsets.top),
                    "pageBottomInset": String(format: "%.1f", additionalSafeAreaInsets.bottom),
                    "obscuredTop": String(format: "%.1f", resolvedObscuredInsets.top),
                    "obscuredBottom": String(format: "%.1f", resolvedObscuredInsets.bottom),
                    "webViewID": readerLoadObjectIDString(controller.webView)
                ]
            )
        }

        // _obscuredInsets ignores sides, probably
        controller.onReplaceWebView = { [weak coordinator = context.coordinator] oldWebView, newWebView in
            coordinator?.navigator.logCompetingOperationIfNeeded(
                "replaceWebView",
                metadata: [
                    "newWebViewID": readerLoadObjectIDString(newWebView),
                    "oldWebViewID": readerLoadObjectIDString(oldWebView)
                ]
            )
        }
        controller.onViewDidAppear = { [weak coordinator = context.coordinator, weak controller] in
            guard let coordinator, let controller else { return }
            if coordinator.lifecycleConfig.autoUnloadOnDisappear, controller.isWebViewUnloaded {
                coordinator.prepareForReloadIfNeeded(controller: controller)
                coordinator.navigator.prepareForReloadAfterReattach()
                let newWebView = makeWebView(config: config, coordinator: coordinator)
                controller.replaceWebView(newWebView)
                configureWebView(newWebView, controller: controller, context: context)
            }
        }
        controller.onViewWillDisappear = { [weak coordinator = context.coordinator, weak controller] in
            guard let coordinator, let controller else { return }
            guard !coordinator.lifecycleConfig.unloadOnlyWhenRemovedFromHierarchy else { return }
            coordinator.unloadWebViewIfNeeded(controller: controller)
        }
        controller.onWillMoveToNoParent = { [weak coordinator = context.coordinator, weak controller] in
            guard let coordinator, let controller else { return }
            guard coordinator.lifecycleConfig.unloadOnlyWhenRemovedFromHierarchy else { return }
            coordinator.unloadWebViewIfNeeded(controller: controller)
        }
        controller.onViewDidDisappear = {}
    }
    
    public static func dismantleUIViewController(_ controller: WebViewController, coordinator: WebViewCoordinator) {
        readerLoadLog(
            "webView.dismantleUIViewController",
            [
                "controllerID": readerLoadObjectIDString(controller),
                "coordinatorID": readerLoadObjectIDString(coordinator),
                "navigatorID": readerLoadObjectIDString(coordinator.navigator),
                "webViewID": readerLoadObjectIDString(controller.webView)
            ]
        )
        controller.clearSnapshotOverlay()
        coordinator.navigator.nativeLookupHitTesting.removeAllTargets()
        coordinator.tearDownBindingsForDetachedWebView(controller.webView)
        if let pool = coordinator.webViewPool {
            if !controller.isWebViewUnloaded {
                controller.detachWebView()
                pool.enqueue(controller.webView, resetURL: coordinator.lifecycleConfig.idleLoadURL)
            }
        } else {
            controller.view.subviews.forEach { $0.removeFromSuperview() }
        }
    }
}
#endif

#if os(macOS)
private func nativeLookupMacPopoverLogValue(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        guard let child = mirror.children.first else { return "nil" }
        return nativeLookupMacPopoverLogValue(child.value)
    }
    switch value {
    case let value as String:
        return value.replacingOccurrences(of: "\n", with: "\\n")
    case let value as Bool:
        return value ? "true" : "false"
    case let value as CGFloat:
        return value.isFinite ? String(format: "%.2f", Double(value)) : "\(value)"
    case let value as Double:
        return value.isFinite ? String(format: "%.2f", value) : "\(value)"
    case let value as CGPoint:
        return "{\(String(format: "%.2f", value.x)),\(String(format: "%.2f", value.y))}"
    case let value as CGSize:
        return "{\(String(format: "%.2f", value.width)),\(String(format: "%.2f", value.height))}"
    case let value as CGRect:
        return "{{\(String(format: "%.2f", value.minX)),\(String(format: "%.2f", value.minY))},{\(String(format: "%.2f", value.width)),\(String(format: "%.2f", value.height))}}"
    case let value as [String: Any]:
        return "{" + value.keys.sorted().map { "\($0):\(nativeLookupMacPopoverLogValue(value[$0] as Any))" }.joined(separator: ",") + "}"
    case let value as [Any]:
        return "[" + value.prefix(5).map { nativeLookupMacPopoverLogValue($0) }.joined(separator: ",") + (value.count > 5 ? ",..." : "") + "]"
    default:
        return String(describing: value).replacingOccurrences(of: "\n", with: "\\n")
    }
}

private func nativeLookupMacPopoverLog(_ stage: String, _ payload: [String: Any] = [:]) {
    let details = payload.keys.sorted()
        .map { "\($0)=\(nativeLookupMacPopoverLogValue(payload[$0] as Any))" }
        .joined(separator: " ")
    if details.isEmpty {
        print("# POPOVER \(stage)")
    } else {
        print("# POPOVER \(stage) \(details)")
    }
}

private final class NativeLookupHitTestOverlayNSView: NSView {
    private enum PressedSegmentStyle {
        static let pressedStrokeAlpha: CGFloat = 0.8
        static let strokeWidth: CGFloat = 1
        static let cornerRadius: CGFloat = 5
        static let inset: CGFloat = 0.5
        static let lookupAttachmentTopExpansion: CGFloat = 0
    }

    weak var store: WebViewNativeLookupHitTestStore?
    private let pressedSegmentLayer = CAShapeLayer()
    private var clearPressedSegmentWorkItem: DispatchWorkItem?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        pressedSegmentLayer.fillColor = NSColor.clear.cgColor
        pressedSegmentLayer.lineWidth = PressedSegmentStyle.strokeWidth
        pressedSegmentLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(PressedSegmentStyle.pressedStrokeAlpha).cgColor
        pressedSegmentLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(pressedSegmentLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        pressedSegmentLayer.frame = bounds
    }

    func showPressedTarget(_ target: WebViewNativeLookupHitTarget) {
        clearPressedSegmentWorkItem?.cancel()
        clearPressedSegmentWorkItem = nil
        let path = CGMutablePath()
        var visualRects: [CGRect] = []
        var strokeRects: [CGRect] = []
        for visualRect in target.projectedRectsForCurrentHitTestOverlay(
            topExpansion: PressedSegmentStyle.lookupAttachmentTopExpansion
        ) {
            let strokeRect = visualRect.insetBy(dx: PressedSegmentStyle.inset, dy: PressedSegmentStyle.inset)
            visualRects.append(visualRect)
            strokeRects.append(strokeRect)
            let radius = min(PressedSegmentStyle.cornerRadius, strokeRect.width / 2, strokeRect.height / 2)
            path.addRoundedRect(in: strokeRect, cornerWidth: radius, cornerHeight: radius)
        }
        let windowFrame = convert(bounds, to: nil)
        let visualWindowRects = visualRects.map { convert($0, to: nil) }
        let strokeWindowRects = strokeRects.map { convert($0, to: nil) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pressedSegmentLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(PressedSegmentStyle.pressedStrokeAlpha).cgColor
        pressedSegmentLayer.path = path
        pressedSegmentLayer.opacity = 1
        CATransaction.commit()
    }
    func clearPressedTarget() {
        clearPressedSegmentWorkItem?.cancel()
        clearPressedSegmentWorkItem = nil
        clearPressedTargetImmediately()
    }

    func clearPressedTarget(after delay: TimeInterval) {
        clearPressedSegmentWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.clearPressedTargetImmediately()
        }
        clearPressedSegmentWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func clearPressedTargetImmediately() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pressedSegmentLayer.path = nil
        pressedSegmentLayer.opacity = 0
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = store?.hitTarget(at: point, in: bounds.size)
        let containsTarget = !isHidden
            && alphaValue > 0
            && target != nil
        guard containsTarget else {
            return nil
        }
        return self
    }
}

private final class NativeLookupHitTestClickGestureRecognizer: NSClickGestureRecognizer {
    private static let segmentClickPressedHandoffDuration: TimeInterval = 0.16

    weak var store: WebViewNativeLookupHitTestStore?
    private weak var pressedOverlay: NativeLookupHitTestOverlayNSView?
    private var mouseDownWasActiveTarget = false

    override func mouseDown(with event: NSEvent) {
        guard let view else {
            nativeLookupMacPopoverLog("mac.click.mouseDown.noView")
            state = .failed
            return
        }
        let point = view.convert(event.locationInWindow, from: nil)
        guard let target = store?.hitTarget(at: point, in: view.bounds.size) else {
            state = .failed
            return
        }
        pressedOverlay = view as? NativeLookupHitTestOverlayNSView
        mouseDownWasActiveTarget = store?.activeElementID == target.elementID
        nativeLookupMacPopoverLog("mac.click.mouseDown.target", [
            "point": point,
            "windowPoint": event.locationInWindow,
            "bounds": view.bounds,
            "targetID": target.elementID,
            "targetRects": WebViewNativeLookupHitTestStore.debugRectStrings(target.rects),
            "hasLookupPayload": target.lookupPayload != nil,
            "frameInfo": target.frameInfo as Any,
            "activeElementID": store?.activeElementID as Any,
            "mouseDownWasActiveTarget": mouseDownWasActiveTarget,
            "targetCount": store?.targetCount as Any,
        ])
        store?.onActiveTargetTouchDown?(target)
        if store?.showsPressedTargetOverlay == true {
            pressedOverlay?.showPressedTarget(target)
        } else {
            pressedOverlay?.clearPressedTarget()
        }
        super.mouseDown(with: event)
        if mouseDownWasActiveTarget {
            pressedOverlay?.clearPressedTarget()
        } else {
            pressedOverlay?.clearPressedTarget(after: Self.segmentClickPressedHandoffDuration)
        }
        mouseDownWasActiveTarget = false
        pressedOverlay = nil
    }

    override func reset() {
        super.reset()
        pressedOverlay?.clearPressedTarget()
        mouseDownWasActiveTarget = false
        pressedOverlay = nil
    }
}

public final class WebViewHostNSView: NSView {
    let webView: EnhancedWKWebView
    private let nativeLookupHitTestOverlayView = NativeLookupHitTestOverlayNSView()
    private var lastSyncedLookupViewportOriginSignature: String?
    private lazy var nativeLookupHitTestGestureRecognizer = NativeLookupHitTestClickGestureRecognizer(
        target: self,
        action: #selector(handleNativeLookupHitTestClick(_:))
    )

    public override var isFlipped: Bool { true }

    init(webView: EnhancedWKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        attachWebView()
        installNativeLookupHitTestGestureRecognizer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func layout() {
        super.layout()
        syncLookupViewportOrigin(reason: "host.layout")
    }

    @MainActor
    func setNativeLookupHitTestStore(_ store: WebViewNativeLookupHitTestStore) {
        nativeLookupHitTestOverlayView.store = store
        nativeLookupHitTestGestureRecognizer.store = store
    }

    private func attachWebView() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: webView.topAnchor),
            leftAnchor.constraint(equalTo: webView.leftAnchor),
            bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            rightAnchor.constraint(equalTo: webView.rightAnchor)
        ])
        nativeLookupHitTestOverlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nativeLookupHitTestOverlayView)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: nativeLookupHitTestOverlayView.topAnchor),
            leftAnchor.constraint(equalTo: nativeLookupHitTestOverlayView.leftAnchor),
            bottomAnchor.constraint(equalTo: nativeLookupHitTestOverlayView.bottomAnchor),
            rightAnchor.constraint(equalTo: nativeLookupHitTestOverlayView.rightAnchor)
        ])
    }

    private func installNativeLookupHitTestGestureRecognizer() {
        nativeLookupHitTestGestureRecognizer.numberOfClicksRequired = 1
        nativeLookupHitTestGestureRecognizer.delaysPrimaryMouseButtonEvents = true
        nativeLookupHitTestOverlayView.addGestureRecognizer(nativeLookupHitTestGestureRecognizer)
    }

    @MainActor
    private func syncLookupViewportOrigin(reason: String) {
        guard let contentView = window?.contentView else { return }
        let webViewWindowRect = webView.convert(webView.bounds, to: nil)
        let contentHeight = contentView.bounds.height
        let originX = webViewWindowRect.minX
        let originY = max(0, contentHeight - webViewWindowRect.maxY)
        let signature = [
            String(format: "%.3f", Double(originX)),
            String(format: "%.3f", Double(originY)),
            String(format: "%.3f", Double(webViewWindowRect.width)),
            String(format: "%.3f", Double(webViewWindowRect.height)),
            reason
        ].joined(separator: "|")
        guard signature != lastSyncedLookupViewportOriginSignature else { return }
        lastSyncedLookupViewportOriginSignature = signature
        nativeLookupMacPopoverLog("webview.lookupViewportOrigin.sync", [
            "reason": reason,
            "originX": originX,
            "originY": originY,
            "webViewWindowRect": webViewWindowRect,
            "contentViewBounds": contentView.bounds,
            "webViewBounds": webView.bounds,
            "url": webView.url?.absoluteString as Any,
        ])
        let escapedReason = reason
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let script = """
        (() => {
          const existing = window.__manabiChromeInsets || {};
          window.__manabiChromeInsets = {
            ...existing,
            viewportOriginX: \(originX),
            viewportOriginY: \(originY),
            viewportOriginSource: 'mac-webview-host:\(escapedReason)',
            viewportOriginRevision: Date.now()
          };
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    @objc private func handleNativeLookupHitTestClick(_ recognizer: NativeLookupHitTestClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: nativeLookupHitTestOverlayView)
        let handled = recognizer.store?.handleTap(at: point, in: nativeLookupHitTestOverlayView.bounds.size) == true
        nativeLookupMacPopoverLog("mac.click.ended.dispatch", [
            "point": point,
            "bounds": nativeLookupHitTestOverlayView.bounds,
            "handled": handled,
            "targetCount": recognizer.store?.targetCount as Any,
            "enabled": recognizer.store?.isEnabled as Any,
            "nearest": recognizer.store?.diagnostics(at: point, limit: 5, in: nativeLookupHitTestOverlayView.bounds.size) as Any,
        ])
    }
}

extension WebView: NSViewRepresentable {
    @MainActor
    public func makeNSView(context: Context) -> WebViewHostNSView {
        if let resolvedWebViewPool {
            resolvedWebViewPool.setCreationClosureIfNeeded {
                makeNewWebView(context: context)
            }
        }

        let webView: EnhancedWKWebView
        if let resolvedWebViewPool {
            webView = resolvedWebViewPool.dequeue {
                makeNewWebView(context: context)
            }
        } else {
            webView = makeNewWebView(context: context)
        }

        let resolvedContentRules = navigator.peekContentRulesBypass() ? nil : config.contentRules
        let resolvedDomain = resolvedUserScriptDomain(currentURL: webView.url)
        let resolvedUserScriptsState = resolvedUserScriptsState(forDomain: resolvedDomain, config: config)
        applyCommonConfiguration(
            webView: webView,
            context: context,
            resolvedContentRules: resolvedContentRules
        )
        updateUserScripts(
            userContentController: webView.configuration.userContentController,
            coordinator: context.coordinator,
            forDomain: resolvedDomain,
            config: config,
            resolvedState: resolvedUserScriptsState
        )
        let resolvedDrawsBackground = config.isOpaque ? drawsBackground : false
        webView.setValue(resolvedDrawsBackground, forKey: "drawsBackground")
        if #available(macOS 11.0, *) {
            let resolvedBackgroundColor: NSColor = config.usesSampledPageTopColorForUnderPageBackground
                && !manabiCanUseSampledPageTopColorBackground()
                ? (config.isOpaque ? .windowBackgroundColor : .clear)
                : NSColor(config.backgroundColor)
            webView.layer?.backgroundColor = resolvedBackgroundColor.cgColor
        } else {
            webView.layer?.backgroundColor = NSColor.clear.cgColor
        }
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        
        context.coordinator.scheduleWebViewBinding(webView, paginationReason: "make-nsview")
        if context.coordinator.scriptCaller == nil, let scriptCaller = scriptCaller {
            context.coordinator.scriptCaller = scriptCaller
        }
        context.coordinator.scriptCaller?.asyncCaller = { @MainActor [weak webView] (js: String, args, frame: WKFrameInfo?, world: WKContentWorld?) async throws -> WebViewScriptCaller.JavaScriptEvaluationResult in
            guard let webView else {
                throw ScriptCallerError.evaluationTimedOut
            }
            let resolvedWorld = world ?? .page
#if DEBUG
            let jsPrefix = js.prefix(120)
            let frameURL = frame?.request.url?.absoluteString ?? "nil"
            let isMainFrame = frame?.isMainFrame ?? true
            let currentURL = webView.url?.absoluteString ?? "nil"
            let startedAt = Date()
            let evalTraceID = "eval-\(Int((startedAt.timeIntervalSince1970 * 1000).rounded()))-\(UUID().uuidString.prefix(6))"
#endif
            do {
                let value: Any?
                if let args {
                    value = try await webView.callAsyncJavaScript(js, arguments: args, in: frame, contentWorld: resolvedWorld)
                } else {
                    value = try await webView.callAsyncJavaScript(js, in: frame, contentWorld: resolvedWorld)
                }
#if DEBUG
                let elapsed = Date().timeIntervalSince(startedAt)
                let typeDescription = value.map { String(describing: type(of: $0)) } ?? "nil"
                let stringLength = (value as? String)?.count
#endif
                return WebViewScriptCaller.JavaScriptEvaluationResult(value)
            } catch {
#if DEBUG
                let elapsed = Date().timeIntervalSince(startedAt)
#endif
                throw error
            }
        }
        
        refreshDarkModeSetting(webView: webView)
        context.coordinator.lastAppliedConfigurationState = webViewConfigurationState(
            webView: webView,
            resolvedDomain: resolvedDomain,
            resolvedUserScriptsState: resolvedUserScriptsState,
            resolvedContentRules: resolvedContentRules,
            config: config
        )
        
        let hostView = WebViewHostNSView(webView: webView)
        navigator.nativeLookupHitTesting.isEnabled = config.nativeLookupHitTestingEnabled
        hostView.setNativeLookupHitTestStore(navigator.nativeLookupHitTesting)
        return hostView
    }

    @MainActor
    private func makeNewWebView(context: Context) -> EnhancedWKWebView {
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = config.javaScriptEnabled

        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = userAgent
#if os(iOS)
        if config.usesSampledPageTopColorForUnderPageBackground,
           manabiCanUseSampledPageTopColorBackground() {
            configuration.enableManabiPageTopColorSampling()
        }
#endif
        configuration.defaultWebpagePreferences = preferences
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.processPool = webViewProcessPool
        let resolvedDrawsBackground = config.isOpaque ? drawsBackground : false
        configuration.setValue(resolvedDrawsBackground, forKey: "drawsBackground")

        for (urlSchemeHandler, urlScheme) in schemeHandlers {
            configuration.setURLSchemeHandler(urlSchemeHandler, forURLScheme: urlScheme)
        }

        return EnhancedWKWebView(frame: CGRect.zero, configuration: configuration)
    }
    
    @MainActor
    public func updateNSView(_ uiView: WebViewHostNSView, context: Context) {
        updateCoordinatorBindings(context: context)
        navigator.nativeLookupHitTesting.isEnabled = config.nativeLookupHitTestingEnabled
        uiView.setNativeLookupHitTestStore(navigator.nativeLookupHitTesting)
        let webView = uiView.webView
        if let scriptCaller {
            context.coordinator.scriptCaller = scriptCaller
        }
        context.coordinator.scriptCaller?.asyncCaller = { @MainActor [weak webView] (js: String, args, frame: WKFrameInfo?, world: WKContentWorld?) async throws -> WebViewScriptCaller.JavaScriptEvaluationResult in
            guard let webView else {
                throw ScriptCallerError.evaluationTimedOut
            }
            let resolvedWorld = world ?? .page
            if let args {
                let value = try await webView.callAsyncJavaScript(js, arguments: args, in: frame, contentWorld: resolvedWorld)
                return WebViewScriptCaller.JavaScriptEvaluationResult(value)
            } else {
                let result = try await webView.callAsyncJavaScript(js, in: frame, contentWorld: resolvedWorld)
                return WebViewScriptCaller.JavaScriptEvaluationResult(result)
            }
        }
        let resolvedContentRules = navigator.peekContentRulesBypass() ? nil : config.contentRules
        let resolvedDomain = resolvedUserScriptDomain(currentURL: webView.url)
        let resolvedUserScriptsState = resolvedUserScriptsState(forDomain: resolvedDomain, config: config)
        let currentConfigurationState = webViewConfigurationState(
            webView: webView,
            resolvedDomain: resolvedDomain,
            resolvedUserScriptsState: resolvedUserScriptsState,
            resolvedContentRules: resolvedContentRules,
            config: config
        )

        if context.coordinator.lastAppliedConfigurationState != currentConfigurationState {
            applyCommonConfiguration(
                webView: webView,
                context: context,
                resolvedContentRules: resolvedContentRules
            )
            updateUserScripts(
                userContentController: webView.configuration.userContentController,
                coordinator: context.coordinator,
                forDomain: resolvedDomain,
                config: config,
                resolvedState: resolvedUserScriptsState
            )
            refreshDarkModeSetting(webView: webView)
            let resolvedDrawsBackground = config.isOpaque ? drawsBackground : false
            webView.setValue(resolvedDrawsBackground, forKey: "drawsBackground")
            if #available(macOS 11.0, *) {
                let resolvedBackgroundColor: NSColor = config.usesSampledPageTopColorForUnderPageBackground
                    && !manabiCanUseSampledPageTopColorBackground()
                    ? (config.isOpaque ? .windowBackgroundColor : .clear)
                    : NSColor(config.backgroundColor)
                webView.layer?.backgroundColor = resolvedBackgroundColor.cgColor
            } else {
                webView.layer?.backgroundColor = NSColor.clear.cgColor
            }
            context.coordinator.lastAppliedConfigurationState = currentConfigurationState
        }
        
        // Can't disable on macOS.
        //        uiView.scrollView.bounces = bounces
        //        uiView.scrollView.alwaysBounceVertical = bounces
        
    }
    
    public static func dismantleNSView(_ nsView: WebViewHostNSView, coordinator: WebViewCoordinator) {
        let webView = nsView.webView
        coordinator.navigator.nativeLookupHitTesting.removeAllTargets()
        coordinator.tearDownBindingsForDetachedWebView(webView)
        if let pool = coordinator.webViewPool {
            webView.removeFromSuperview()
            pool.enqueue(webView)
        }
    }
}
#endif

extension WebView {
    private var resolvedWebViewPool: WebViewPool? {
        webViewPrewarmer?.pool ?? webViewPool
    }

    @MainActor
    private func resolvedUserScriptsState(
        forDomain domain: URL?,
        config: WebViewConfig
    ) -> (scripts: [WebViewUserScript], signature: String) {
        var scripts = config.userScripts
        if let domain = domain?.domainURL.host {
            scripts = scripts.filter { $0.allowedDomains.isEmpty || $0.allowedDomains.contains(domain) }
        } else {
            scripts = scripts.filter { $0.allowedDomains.isEmpty }
        }
        let allScripts = Self.systemScripts + scripts
        let signature = allScripts
            .map { script in
                [
                    "\(script.source.hashValue)",
                    "\(script.injectionTime.rawValue)",
                    "\(script.isForMainFrameOnly)",
                    "\(script.world.map { String(describing: $0) } ?? "nil")"
                ].joined(separator: "|")
            }
            .joined(separator: "||")
        return (allScripts, signature)
    }

    @MainActor
    private func webViewConfigurationState(
        webView: WKWebView,
        resolvedDomain: URL?,
        resolvedUserScriptsState: (scripts: [WebViewUserScript], signature: String),
        resolvedContentRules: String?,
        config: WebViewConfig
    ) -> WebViewConfigurationState {
        WebViewConfigurationState(
            webViewID: ObjectIdentifier(webView),
            userScriptsDomainKey: resolvedDomain?.domainURL.host,
            userScriptsSignature: resolvedUserScriptsState.signature,
            visualSignature: visualConfigurationSignature(config: config),
            scrollBehaviorSignature: scrollBehaviorSignature(),
            contentRulesSignature: resolvedContentRules?.trimmingCharacters(in: .whitespacesAndNewlines),
            messageHandlersSignature: messageHandlersSignature(webViewMessageHandlers),
            paginationSignature: paginationConfigurationSignature(config.paginationConfiguration)
        )
    }

    @MainActor
    private func messageHandlersSignature(_ handlers: WebViewMessageHandlers) -> String {
        handlers.handlers.keys.joined(separator: "|")
    }

    @MainActor
    private func paginationConfigurationSignature(_ paginationConfiguration: WebViewPaginationConfiguration) -> String {
        [
            "\(paginationConfiguration.mode.rawValue)",
            "\(paginationConfiguration.storedPageLength)",
            "\(paginationConfiguration.effectivePageLength)",
            "\(paginationConfiguration.gapBetweenPages)",
            "\(paginationConfiguration.behavesLikeColumns)",
            "\(paginationConfiguration.layoutSize.width)",
            "\(paginationConfiguration.layoutSize.height)"
        ].joined(separator: "|")
    }

    @MainActor
    private func visualConfigurationSignature(config: WebViewConfig) -> String {
        [
            "\(config.javaScriptEnabled)",
            "\(config.allowsBackForwardNavigationGestures)",
            "\(config.allowsInlineMediaPlayback)",
            "\(config.mediaTypesRequiringUserActionForPlayback.rawValue)",
            "\(config.dataDetectorsEnabled)",
            "\(config.isScrollEnabled)",
            String(format: "%.4f", Double(config.pageZoom)),
            "\(config.isOpaque)",
            backgroundColorSignature(config.backgroundColor),
            config.darkModeSetting.rawValue,
            "\(config.adjustsScrollViewContentInsetsForSafeArea)",
            "\(config.nativeLookupHitTestingEnabled)"
        ].joined(separator: "|")
    }

    @MainActor
    private func scrollBehaviorSignature() -> String {
        [
            "\(bounces)",
            "\(drawsBackground)"
        ].joined(separator: "|")
    }

#if os(iOS)
    @MainActor
    private func backgroundColorSignature(_ color: Color) -> String {
        let resolved = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return [
                String(format: "%.4f", red),
                String(format: "%.4f", green),
                String(format: "%.4f", blue),
                String(format: "%.4f", alpha)
            ].joined(separator: "|")
        }
        if let components = resolved.cgColor.components {
            return components.map { String(format: "%.4f", $0) }.joined(separator: "|")
        }
        return String(describing: resolved)
    }
#elseif os(macOS)
    @MainActor
    private func backgroundColorSignature(_ color: Color) -> String {
        let resolved = NSColor(color)
        let rgb = resolved.usingColorSpace(.deviceRGB) ?? resolved
        return [
            String(format: "%.4f", rgb.redComponent),
            String(format: "%.4f", rgb.greenComponent),
            String(format: "%.4f", rgb.blueComponent),
            String(format: "%.4f", rgb.alphaComponent)
        ].joined(separator: "|")
    }
#endif

    var userAgent: String {
        //        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"
        return "Version/18.4 Safari/605.1.15"
    }
    
    @MainActor
    func applyCommonConfiguration(
        webView: WKWebView,
        context: Context,
        resolvedContentRules: String?
    ) {
        refreshMessageHandlers(userContentController: webView.configuration.userContentController, context: context)
        if context.coordinator.lastAppliedContentRules != resolvedContentRules {
            refreshContentRules(
                userContentController: webView.configuration.userContentController,
                coordinator: context.coordinator,
                overrideRules: resolvedContentRules
            )
        } else if let enhancedWebView = webView as? EnhancedWKWebView {
            enhancedWebView.persistedAppliedContentRules = resolvedContentRules
        }
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.pageZoom = config.pageZoom
        webView.allowsBackForwardNavigationGestures = config.allowsBackForwardNavigationGestures
        context.coordinator.schedulePaginationConfigurationApply(reason: "apply-common-configuration", for: webView)
    }

    @MainActor
    func updateCoordinatorBindings(context: Context) {
        context.coordinator.config = config
        context.coordinator.messageHandlers = webViewMessageHandlers
        context.coordinator.onNavigationCommitted = onNavigationCommitted
        context.coordinator.onNavigationFinished = onNavigationFinished
        context.coordinator.onNavigationFailed = onNavigationFailed
        context.coordinator.onURLChanged = onURLChanged
        context.coordinator.onNavigationAction = onNavigationAction
        context.coordinator.webViewPool = resolvedWebViewPool
        context.coordinator.lifecycleConfig = lifecycleConfig
        context.coordinator.navigator.attachFallbackURL = lifecycleConfig.idleLoadURL
        context.coordinator.hideNavigationDueToScroll = $hideNavigationDueToScroll
        context.coordinator.textSelection = $textSelection
    }

    @MainActor
    func refreshDarkModeSetting(webView: WKWebView) {
#if os(iOS)
        switch config.darkModeSetting {
        case .system:
            webView.overrideUserInterfaceStyle = .unspecified
        case .darkModeOverride:
            webView.overrideUserInterfaceStyle = .dark
        case .alwaysLightMode:
            webView.overrideUserInterfaceStyle = .light
        }
#elseif os(macOS)
        switch config.darkModeSetting {
        case .system:
            webView.appearance = nil
        case .darkModeOverride:
            webView.appearance = NSAppearance(named: .darkAqua)
        case .alwaysLightMode:
            webView.appearance = NSAppearance(named: .aqua)
        }
#endif
    }

    #if os(iOS)
    @MainActor
    func applyVisualConfiguration(webView: WKWebView, containerView: UIView?) {
        webView.isOpaque = config.isOpaque
        webView.scrollView.isOpaque = config.isOpaque

        if #available(iOS 14.0, *) {
            let resolvedColor: UIColor = config.usesSampledPageTopColorForUnderPageBackground
                && !manabiCanUseSampledPageTopColorBackground()
                ? (config.isOpaque ? .systemBackground : .clear)
                : UIColor(config.backgroundColor)
            webView.backgroundColor = resolvedColor
            let resolvedUnderPageColor = webView.resolvedUnderPageBackgroundColor(
                config: config,
                allowSampledPageTopColor: false
            )
            if let resolvedUnderPageColor {
                webView.scrollView.backgroundColor = resolvedUnderPageColor
            }
            containerView?.backgroundColor = config.isOpaque ? nil : resolvedColor
            webView.applyConfiguredBackgroundForReaderDocumentIfNeeded(config: config, reason: "visual.apply")
        } else {
            let resolvedColor: UIColor = config.isOpaque ? .systemBackground : .clear
            webView.backgroundColor = resolvedColor
            webView.scrollView.backgroundColor = resolvedColor
            containerView?.backgroundColor = config.isOpaque ? nil : resolvedColor
        }

        if #available(iOS 15.0, *) {
            webView.applyUnderPageBackgroundColor(config: config, allowSampledPageTopColor: false)
        }
    }
    #endif
    
    @MainActor
    func refreshContentRules(
        userContentController: WKUserContentController,
        coordinator: WebViewCoordinator,
        overrideRules: String? = nil
    ) {
        let startedAt = Date()
        let rules = (overrideRules ?? config.contentRules)?.trimmingCharacters(in: .whitespacesAndNewlines)
        readerLoadLog(
            "webView.contentRules.refreshBegin",
            [
                "hasCachedCompiledRule": "\(rules.flatMap { coordinator.compiledContentRules[$0] } != nil)",
                "hasRules": "\(rules?.isEmpty == false)",
                "override": "\(overrideRules != nil)"
            ]
        )
        userContentController.removeAllContentRuleLists()
        guard let contentRules = rules, !contentRules.isEmpty else {
            coordinator.lastAppliedContentRules = nil
            (coordinator.navigator.webView as? EnhancedWKWebView)?.persistedAppliedContentRules = nil
            readerLoadLog(
                "webView.contentRules.refreshCleared",
                [
                    "elapsed": readerLoadElapsedString(since: startedAt)
                ]
            )
            return
        }
        if let ruleList = coordinator.compiledContentRules[contentRules] {
            userContentController.add(ruleList)
            coordinator.lastAppliedContentRules = contentRules
            (coordinator.navigator.webView as? EnhancedWKWebView)?.persistedAppliedContentRules = contentRules
            readerLoadLog(
                "webView.contentRules.refreshAppliedCached",
                [
                    "elapsed": readerLoadElapsedString(since: startedAt)
                ]
            )
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "ContentBlockingRules",
            encodedContentRuleList: contentRules
        ) { ruleList, error in
            guard let ruleList else {
                if let error {
#if DEBUG
                    print("# contentRules.compile error", error)
#endif
                }
                readerLoadLog(
                    "webView.contentRules.refreshCompileFailed",
                    [
                        "elapsed": readerLoadElapsedString(since: startedAt),
                        "error": error?.localizedDescription ?? "nil"
                    ]
                )
                return
            }
            userContentController.add(ruleList)
            coordinator.compiledContentRules[contentRules] = ruleList
            coordinator.lastAppliedContentRules = contentRules
            (coordinator.navigator.webView as? EnhancedWKWebView)?.persistedAppliedContentRules = contentRules
            readerLoadLog(
                "webView.contentRules.refreshCompiled",
                [
                    "elapsed": readerLoadElapsedString(since: startedAt)
                ]
            )
        }
    }
    
    /// Refreshes the WKScriptMessageHandlers for the WebView.
    /// - Note: `systemMessageHandlers` are constant and never change.
    ///         Only the environment's handler names are dynamic.
    /// - Performance: This function avoids unnecessary Set creation or handler updates if nothing changed.
    @MainActor
    func refreshMessageHandlers(userContentController: WKUserContentController, context: Context) {
        if context.coordinator.lastUserContentController !== userContentController {
            context.coordinator.registeredMessageHandlerNames.removeAll()
            context.coordinator.lastEnvHandlerNames = nil
            context.coordinator.lastUserContentController = userContentController
        }
        // systemMessageHandlers never change, so only envHandlerNames matter.
        let envHandlerNames = webViewMessageHandlers.handlers.keys
        // Early exit if environment handler keys haven't changed
        if context.coordinator.lastEnvHandlerNames == envHandlerNames {
            return
        }
        context.coordinator.lastEnvHandlerNames = envHandlerNames
        
        // Only create sets if changes detected.
        let requiredHandlers = Set(Self.systemMessageHandlers).union(envHandlerNames)
        
        // Add any missing handlers.
        for messageHandlerName in requiredHandlers {
            if context.coordinator.registeredMessageHandlerNames.contains(messageHandlerName) { continue }
            // Sometimes we reuse an underlying WKWebView for a new SwiftUI component.
            userContentController.removeScriptMessageHandler(forName: messageHandlerName, contentWorld: .page)
            userContentController.add(context.coordinator, contentWorld: .page, name: messageHandlerName)
            context.coordinator.registeredMessageHandlerNames.insert(messageHandlerName)
        }
        
        // Remove any no-longer-needed handlers.
        for missing in context.coordinator.registeredMessageHandlerNames.subtracting(requiredHandlers) {
            userContentController.removeScriptMessageHandler(forName: missing)
            context.coordinator.registeredMessageHandlerNames.remove(missing)
        }
    }
    
    @MainActor
    func updateUserScripts(
        userContentController: WKUserContentController,
        coordinator: WebViewCoordinator,
        forDomain domain: URL?,
        config: WebViewConfig,
        resolvedState: (scripts: [WebViewUserScript], signature: String)? = nil
    ) {
        let resolvedState = resolvedState ?? resolvedUserScriptsState(forDomain: domain, config: config)
        updateUserScripts(
            userContentController: userContentController,
            coordinator: coordinator,
            forDomain: domain,
            resolvedState: resolvedState
        )
    }

    @MainActor
    func updateUserScripts(
        userContentController: WKUserContentController,
        coordinator: WebViewCoordinator,
        forDomain domain: URL?,
        resolvedState: (scripts: [WebViewUserScript], signature: String)
    ) {
        let startedAt = Date()
        let allScripts = resolvedState.scripts
        let installedScriptsSignature = resolvedState.signature

        if coordinator.lastUserScriptsContentController === userContentController,
           coordinator.lastInstalledScriptsSignature == installedScriptsSignature {
            (coordinator.navigator.webView as? EnhancedWKWebView)?.persistedUserScriptsSignature = installedScriptsSignature
            return
        }

        if allScripts.isEmpty && !userContentController.userScripts.isEmpty {
            userContentController.removeAllUserScripts()
            coordinator.lastUserScriptsContentController = userContentController
            coordinator.lastInstalledScriptsSignature = nil
            (coordinator.navigator.webView as? EnhancedWKWebView)?.persistedUserScriptsSignature = nil
            readerLoadLog(
                "webView.userScripts.refreshCleared",
                [
                    "domain": domain?.absoluteString ?? "nil",
                    "elapsed": readerLoadElapsedString(since: startedAt)
                ]
            )
            return
        }
        
        var matchedExistingScripts = [WKUserScript]()
        if !allScripts.allSatisfy({ newScript in
            return userContentController.userScripts.contains(where: { existingScript in
                if newScript.source == existingScript.source
                    && newScript.injectionTime == existingScript.injectionTime
                    && newScript.isForMainFrameOnly == existingScript.isForMainFrameOnly {
                    //                    && newScript.world == existingScript.world { // TODO: Track associated worlds...
                    matchedExistingScripts.append(existingScript)
                    return true
                }
                return false
            })
        }) || userContentController.userScripts.contains(where: { !matchedExistingScripts.contains($0) }) {
            userContentController.removeAllUserScripts()
            for var script in allScripts {
                userContentController.addUserScript(script.webKitUserScript)
            }
            readerLoadLog(
                "webView.userScripts.refreshApplied",
                [
                    "count": "\(allScripts.count)",
                    "domain": domain?.absoluteString ?? "nil",
                    "elapsed": readerLoadElapsedString(since: startedAt)
                ]
            )
        }
        coordinator.lastUserScriptsContentController = userContentController
        if coordinator.lastInstalledScriptsSignature != installedScriptsSignature {
#if DEBUG
#endif
            coordinator.lastInstalledScriptsSignature = installedScriptsSignature
        }
        (coordinator.navigator.webView as? EnhancedWKWebView)?.persistedUserScriptsSignature = installedScriptsSignature
        if coordinator.lastInstalledScriptsSignature == installedScriptsSignature {
            readerLoadLog(
                "webView.userScripts.refreshComplete",
                [
                    "count": "\(allScripts.count)",
                    "domain": domain?.absoluteString ?? "nil",
                    "elapsed": readerLoadElapsedString(since: startedAt)
                ]
            )
        }
    }
    
    @MainActor fileprivate static let systemScripts = [
        WebViewBackgroundStatusUserScript().userScript,
        LocationChangeUserScript().userScript,
        ImageChangeUserScript().userScript,
        ReaderBootstrapPingUserScript().userScript,
        ReaderDocStateUserScript().userScript,
        UnhandledTapUserScript().userScript,
        PageIconChangeUserScript().userScript,
        TextSelectionUserScript().userScript,
    ]
    
    fileprivate static let systemMessageHandlers: [String] = [
        "swiftUIWebViewBackgroundStatus",
        "swiftUIWebViewLocationChanged",
        "swiftUIWebViewImageUpdated",
        "swiftUIWebViewPageIconUpdated",
        "swiftUIWebViewTextSelection",
        "readerBootstrapPing",
        "readerDocState",
        "swiftUIWebViewUnhandledTap",
    ]
}


//// https://adam.garrett-harris.com/2021-08-21-providing-access-to-directories-in-ios-with-bookmarks/
//fileprivate struct FileBookmarks {
//    static func
//    func startAccessingFileURL() -> URL? {
//        guard let fileURL = url.isFileURL ? url : url.fileURLFromCustomSchemeLoaderURL else { return nil }
//
//        if let fileURLBookmarkData = fileURLBookmarkData {
//            var isStale = false
//            let resolvedURL = try? URL(
//                resolvingBookmarkData: fileURLBookmarkData,
//                bookmarkDataIsStale: &isStale)
//
//            if let resolvedURL = resolvedURL, !isStale {
//                return resolvedURL
//            }
//        }
//
//        // Start accessing a security-scoped resource.
//        guard fileURL.startAccessingSecurityScopedResource() else {
//            // Handle the failure here.
//            return nil
//        }
//
//        // Make sure you release the security-scoped resource when you finish.
//        defer { fileURL.stopAccessingSecurityScopedResource() }
//
//        var err: NSError? = nil
//        var failed = true
//        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &err, byAccessor: { (newURL: URL) -> Void in
//            do {
//                let bookmarkData = try fileURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
//                safeWrite(self) { _, bookmark in
//                    bookmark.fileURLBookmarkData = bookmarkData
//                }
//                failed = false
//            } catch let error {
//                print("\(error)")
//            }
//        })
//        if failed {
//            print("Failed to access file URL \(fileURL)")
//        }
//        return fileURL
//    }
//}

/*
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
 blockedHosts: Set(["apple.com"]),
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
 */
