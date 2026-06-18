import SwiftUI
import WebKit
import UniformTypeIdentifiers
import OrderedCollections
import LRUCache
import Foundation
#if os(iOS)
import UIKit
private typealias WebViewSnapshotPlatformImage = UIImage
#elseif os(macOS)
import AppKit
private typealias WebViewSnapshotPlatformImage = NSImage
#endif

#if os(iOS)
private func applyTopScrollEdgeEffectHidden(_ isHidden: Bool, in view: UIView) {
    if #available(iOS 26.0, *), let scrollView = view as? UIScrollView {
        scrollView.topEdgeEffect.isHidden = isHidden
    }
    view.subviews.forEach { applyTopScrollEdgeEffectHidden(isHidden, in: $0) }
}

private func applyTopScrollEdgeEffectHidden(_ isHidden: Bool, to webView: WKWebView) {
    applyTopScrollEdgeEffectHidden(isHidden, in: webView)
    var ancestor = webView.superview
    while let view = ancestor {
        if #available(iOS 26.0, *), let scrollView = view as? UIScrollView {
            scrollView.topEdgeEffect.isHidden = isHidden
        }
        ancestor = view.superview
    }
}
#endif

@inline(__always)
private func readerLoadElapsedString(since start: Date?, now: Date = Date()) -> String {
    guard let start else { return "nil" }
    return String(format: "%.3fs", now.timeIntervalSince(start))
}

@inline(__always)
private func readerLoadLog(_ stage: String, _ metadata: [String: String] = [:]) {
#if DEBUG
    let payload = metadata
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: " ")
    if payload.isEmpty {
        Swift.debugPrint("# READERLOAD stage=\(stage)")
    } else {
        Swift.debugPrint("# READERLOAD stage=\(stage) \(payload)")
    }
#endif
}

private let readerLoadIssueGapWarningThreshold: TimeInterval = 0.750
private let readerLoadCommitGapWarningThreshold: TimeInterval = 0.750
private let readerLoadStaleLoadingStateThreshold: Double = 0.050
private let internalReaderLoaderStartedAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.startedAt."
private let internalReaderLoaderResponseAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.responseAt."
private let internalReaderLoaderDataAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.dataAt."
private let internalReaderLoaderFinishedAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.finishedAt."
private let activeInternalReaderLoaderTraceIDKey = "SwiftUIWebView.activeInternalReaderLoader.traceID"
private let activeInternalReaderLoaderURLKey = "SwiftUIWebView.activeInternalReaderLoader.url"
private let readerLoadPreProvisionalWarningThreshold: TimeInterval = 2.0
private let readerLoadVerboseUIViewControllerLoggingEnabled =
    ProcessInfo.processInfo.environment["MANABI_READERLOAD_VERBOSE_UIVIEWCONTROLLER"] == "1"
private let readerLoadCorrelationMaxAge: TimeInterval = 30

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
private func shouldResetThroughAboutBlankBeforeInternalReaderLoad(
    currentURL: URL?,
    requestURL: URL?
) -> Bool {
    guard isInternalReaderLoaderURL(requestURL),
          let currentURL else {
        return false
    }
    if currentURL.absoluteString == "about:blank" || isInternalReaderLoaderURL(currentURL) {
        return false
    }
    guard let scheme = currentURL.scheme?.lowercased() else {
        return false
    }
    return !["http", "https", "about"].contains(scheme)
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

public enum WebViewPaginationSpreadSlotKind: String, Codable, Equatable, Sendable {
    case blank
    case page
}

public struct WebViewPaginationSpreadSlot: Codable, Equatable, Sendable {
    public let kind: WebViewPaginationSpreadSlotKind
    public let pageIndex: Int?

    public init(kind: WebViewPaginationSpreadSlotKind, pageIndex: Int? = nil) {
        self.kind = kind
        self.pageIndex = pageIndex
    }
}

public struct WebViewPaginationSpread: Codable, Equatable, Sendable {
    public let index: Int?
    public let slots: [WebViewPaginationSpreadSlot]

    public init(index: Int?, slots: [WebViewPaginationSpreadSlot]) {
        self.index = index
        self.slots = slots
    }

    public var pageIndices: [Int] {
        slots.compactMap(\.pageIndex)
    }

    public var dictionaryRepresentation: [String: String] {
        [
            "spreadIndex": index.map(String.init) ?? "nil",
            "spreadSlots": slots
                .map { slot in
                    "\(slot.kind.rawValue):\(slot.pageIndex.map(String.init) ?? "nil")"
                }
                .joined(separator: ",")
        ]
    }
}

public struct WebViewPaginationSpreadSequence: Codable, Equatable, Sendable {
    public let spreads: [WebViewPaginationSpread]
    public let currentIndex: Int?

    public init(spreads: [WebViewPaginationSpread], currentIndex: Int?) {
        self.spreads = spreads
        self.currentIndex = currentIndex
    }

    public var currentSpread: WebViewPaginationSpread? {
        guard let currentIndex, spreads.indices.contains(currentIndex) else { return nil }
        return spreads[currentIndex]
    }

    public var dictionaryRepresentation: [String: String] {
        [
            "spreadSequenceCount": String(spreads.count),
            "spreadSequenceCurrentIndex": currentIndex.map(String.init) ?? "nil",
        ]
    }
}

fileprivate func webViewPaginationSpreadSlot(from value: Any?) -> WebViewPaginationSpreadSlot? {
    guard let dictionary = value as? [String: Any] else { return nil }
    if let blank = dictionary["blank"] as? Bool, blank {
        return WebViewPaginationSpreadSlot(kind: .blank)
    }
    guard let pageIndex = dictionary["pageIndex"] as? Int else { return nil }
    return WebViewPaginationSpreadSlot(kind: .page, pageIndex: pageIndex)
}

fileprivate func webViewPaginationSpread(from value: Any?) -> WebViewPaginationSpread? {
    guard let dictionary = value as? [String: Any] else { return nil }
    let leadingSlot = webViewPaginationSpreadSlot(from: dictionary["leadingSlot"])
    let trailingSlot = webViewPaginationSpreadSlot(from: dictionary["trailingSlot"])
    let slots: [WebViewPaginationSpreadSlot] = [leadingSlot, trailingSlot].compactMap { $0 }
    guard !slots.isEmpty else { return nil }
    return WebViewPaginationSpread(index: dictionary["index"] as? Int, slots: slots)
}

fileprivate func webViewPaginationSpreadSequence(from value: Any?) -> WebViewPaginationSpreadSequence? {
    guard let dictionary = value as? [String: Any] else { return nil }
    guard let spreadValues = dictionary["spreads"] as? [Any] else { return nil }
    let spreads = spreadValues.compactMap(webViewPaginationSpread(from:))
    guard !spreads.isEmpty else { return nil }
    return WebViewPaginationSpreadSequence(
        spreads: spreads,
        currentIndex: dictionary["currentIndex"] as? Int
    )
}

fileprivate func webViewPaginationDestinationAvailability(
    spread: WebViewPaginationSpread?,
    pageCount: Int?
) -> String? {
    guard let spread else { return nil }
    if spread.slots.count >= 2 {
        let leadingBlank = spread.slots.first?.kind == .blank
        let trailingBlank = spread.slots.last?.kind == .blank
        switch (leadingBlank, trailingBlank) {
        case (true, false):
            return "first"
        case (false, true):
            return "second"
        default:
            break
        }
    }

    let pageIndices = spread.pageIndices
    if pageIndices.count > 1 {
        return "both"
    }
    guard let pageIndex = pageIndices.first else { return "unavailable" }
    if pageIndex == 0 {
        return "first"
    }
    if let pageCount, pageIndex == max(0, pageCount - 1) {
        return "second"
    }
    return "both"
}

fileprivate func webViewPaginationPageOffsetRange(
    visiblePageIndices: [Int]?
) -> WebViewPaginationPageOffsetRange? {
    guard let visiblePageIndices,
          let lowerBound = visiblePageIndices.min(),
          let upperBound = visiblePageIndices.max() else {
        return nil
    }
    return WebViewPaginationPageOffsetRange(lowerBound: lowerBound, upperBound: upperBound)
}

fileprivate func webViewPaginationCurrentContentLocation(
    spread: WebViewPaginationSpread?,
    visiblePageIndices: [Int]?
) -> WebViewPaginationCurrentContentLocation? {
    guard let visiblePageIndices, !visiblePageIndices.isEmpty else { return nil }
    if visiblePageIndices.count > 1 {
        return .center
    }
    if spread?.slots.first?.kind == .blank {
        return .trailing
    }
    return .leading
}

fileprivate func webViewPaginationVisibleUnit(
    spreadSequence: WebViewPaginationSpreadSequence?
) -> WebViewPaginationVisibleUnit? {
    guard let spreadSequence,
          let currentIndex = spreadSequence.currentIndex,
          spreadSequence.spreads.indices.contains(currentIndex) else {
        return nil
    }
    let currentSpread = spreadSequence.spreads[currentIndex]
    let pageIndices = currentSpread.pageIndices
    guard !pageIndices.isEmpty else { return nil }
    let hasLeadingSingleton = currentSpread.slots.first?.kind == .blank
    let hasTrailingSingleton = currentSpread.slots.last?.kind == .blank
    let visiblePageCount = pageIndices.count
    let kind: WebViewPaginationVisibleUnitKind = visiblePageCount > 1 ? .pageSpread : .singlePage
    let spreadPagesAllowedForViewport = spreadSequence.spreads.contains { spread in
        let visiblePageIndices = spread.pageIndices
        if visiblePageIndices.count > 1 {
            return true
        }
        return visiblePageIndices.count == 1 && spread.slots.contains(where: { $0.kind == .blank })
    }
    return WebViewPaginationVisibleUnit(
        kind: kind,
        axis: .horizontal,
        visiblePageCount: visiblePageCount,
        primarySpacing: 0,
        chromeGutterWidth: 0,
        currentUnitIndex: currentIndex,
        leadingPageIndex: pageIndices.first,
        trailingPageIndex: pageIndices.last,
        hasLeadingSingleton: hasLeadingSingleton,
        hasTrailingSingleton: hasTrailingSingleton,
        spreadPagesAllowedForViewport: spreadPagesAllowedForViewport
    )
}

public struct WebViewPaginationVisibleUnit: Codable, Equatable, Sendable {
    public let kind: WebViewPaginationVisibleUnitKind
    public let axis: WebViewPaginationVisibleUnitAxis
    public let visiblePageCount: Int
    public let primarySpacing: CGFloat
    public let chromeGutterWidth: CGFloat
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
        chromeGutterWidth: CGFloat? = nil,
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
        self.chromeGutterWidth = chromeGutterWidth ?? primarySpacing
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
        chromeGutterWidth: 0,
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
            "chromeGutterWidth": "\(chromeGutterWidth)",
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

public enum WebViewPageNavigationStyle: String, Codable, Equatable, Sendable {
    case paged
    case verticalScroll
    case horizontalScroll
}

public enum WebViewPaginationPageNumberMode: String, Codable, Equatable, Sendable {
    case digitalBook
    case printEdition
}

public enum WebViewPaginationPublicationSource: String, Codable, Equatable, Sendable {
    case cache
    case template
    case pagination
}

public enum WebViewPaginationContentHostState: String, Codable, Equatable, Sendable {
    case initial
    case waitingOnContentView
    case preparingContentView
    case placeholderViewAvailable
    case contentViewAvailable
    case preparingForReuse
}

public enum WebViewPaginationPreloadStrategy: String, Codable, Equatable, Sendable {
    case conservative
    case standard
    case aggressive
}

public enum WebViewPaginationCurrentContentLocation: String, Codable, Equatable, Sendable {
    case center
    case leading
    case trailing
}

public enum WebViewPaginationRequestedLocationKind: String, Codable, Equatable, Sendable {
    case anchor
    case cfi
    case progress
    case rect
    case pageNumber
    case href
    case history
}

public struct WebViewPaginationRequestedLocation: Codable, Equatable, Sendable {
    public let kind: WebViewPaginationRequestedLocationKind
    public let value: String
    public let surroundingContext: String?
    public let rectX: Double?
    public let rectY: Double?
    public let rectWidth: Double?
    public let rectHeight: Double?
    public let isRequestedPageChange: Bool

    public init(
        kind: WebViewPaginationRequestedLocationKind,
        value: String,
        surroundingContext: String? = nil,
        rectX: Double? = nil,
        rectY: Double? = nil,
        rectWidth: Double? = nil,
        rectHeight: Double? = nil,
        isRequestedPageChange: Bool = false
    ) {
        self.kind = kind
        self.value = value
        self.surroundingContext = surroundingContext
        self.rectX = rectX
        self.rectY = rectY
        self.rectWidth = rectWidth
        self.rectHeight = rectHeight
        self.isRequestedPageChange = isRequestedPageChange
    }
}

public struct WebViewPaginationPageOffsetRange: Codable, Equatable, Sendable {
    public let lowerBound: Int
    public let upperBound: Int

    public init(lowerBound: Int, upperBound: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

public struct WebViewPaginationPageLabelPolicy: Codable, Equatable, Sendable {
    public let displayMode: WebViewPaginationPageLabelDisplayMode
    public let usesPhysicalPageLabels: Bool
    public let allowsMultipleLabelsInMultiUnitLayout: Bool

    public init(
        displayMode: WebViewPaginationPageLabelDisplayMode,
        usesPhysicalPageLabels: Bool,
        allowsMultipleLabelsInMultiUnitLayout: Bool = false
    ) {
        self.displayMode = displayMode
        self.usesPhysicalPageLabels = usesPhysicalPageLabels
        self.allowsMultipleLabelsInMultiUnitLayout = allowsMultipleLabelsInMultiUnitLayout
    }

    public static let singleLabel = WebViewPaginationPageLabelPolicy(
        displayMode: .singleLabel,
        usesPhysicalPageLabels: false,
        allowsMultipleLabelsInMultiUnitLayout: false
    )

    public var dictionaryRepresentation: [String: String] {
        [
            "pageLabelDisplayMode": displayMode.rawValue,
            "usesPhysicalPageLabels": "\(usesPhysicalPageLabels)",
            "allowsMultipleLabelsInMultiUnitLayout": "\(allowsMultipleLabelsInMultiUnitLayout)"
        ]
    }
}

public struct WebViewPaginationStateEnrichment: Codable, Equatable, Sendable {
    public let visibleUnit: WebViewPaginationVisibleUnit?
    public let pageLabelPolicy: WebViewPaginationPageLabelPolicy?
    public let currentPageDisplayLabel: String?
    public let currentPhysicalPageLabel: String?
    public let pageNavigationStyle: WebViewPageNavigationStyle?
    public let allowsMultipleColumns: Bool?
    public let pageNumberMode: WebViewPaginationPageNumberMode?
    public let paginationComplete: Bool?
    public let configurationKey: String?
    public let publicationSource: WebViewPaginationPublicationSource?
    public let contentHostState: WebViewPaginationContentHostState?
    public let preloadStrategy: WebViewPaginationPreloadStrategy?
    public let currentContentLocation: WebViewPaginationCurrentContentLocation?
    public let requestedLocation: WebViewPaginationRequestedLocation?
    public let pageOffsetsDisplayed: [Int]?
    public let pageOffsetRange: WebViewPaginationPageOffsetRange?
    public let currentPageIndex: Int?
    public let visiblePageIndices: [Int]?
    public let canMoveForward: Bool?
    public let canMoveBackward: Bool?
    public let forwardDestinationAvailability: String?
    public let backwardDestinationAvailability: String?
    public let currentSpread: WebViewPaginationSpread?
    public let destinationSpread: WebViewPaginationSpread?
    public let spreadSequence: WebViewPaginationSpreadSequence?

    public init(
        visibleUnit: WebViewPaginationVisibleUnit? = nil,
        pageLabelPolicy: WebViewPaginationPageLabelPolicy? = nil,
        currentPageDisplayLabel: String? = nil,
        currentPhysicalPageLabel: String? = nil,
        pageNavigationStyle: WebViewPageNavigationStyle? = nil,
        allowsMultipleColumns: Bool? = nil,
        pageNumberMode: WebViewPaginationPageNumberMode? = nil,
        paginationComplete: Bool? = nil,
        configurationKey: String? = nil,
        publicationSource: WebViewPaginationPublicationSource? = nil,
        contentHostState: WebViewPaginationContentHostState? = nil,
        preloadStrategy: WebViewPaginationPreloadStrategy? = nil,
        currentContentLocation: WebViewPaginationCurrentContentLocation? = nil,
        requestedLocation: WebViewPaginationRequestedLocation? = nil,
        pageOffsetsDisplayed: [Int]? = nil,
        pageOffsetRange: WebViewPaginationPageOffsetRange? = nil,
        currentPageIndex: Int? = nil,
        visiblePageIndices: [Int]? = nil,
        canMoveForward: Bool? = nil,
        canMoveBackward: Bool? = nil,
        forwardDestinationAvailability: String? = nil,
        backwardDestinationAvailability: String? = nil,
        currentSpread: WebViewPaginationSpread? = nil,
        destinationSpread: WebViewPaginationSpread? = nil,
        spreadSequence: WebViewPaginationSpreadSequence? = nil
    ) {
        self.visibleUnit = visibleUnit
        self.pageLabelPolicy = pageLabelPolicy
        self.currentPageDisplayLabel = currentPageDisplayLabel
        self.currentPhysicalPageLabel = currentPhysicalPageLabel
        self.pageNavigationStyle = pageNavigationStyle
        self.allowsMultipleColumns = allowsMultipleColumns
        self.pageNumberMode = pageNumberMode
        self.paginationComplete = paginationComplete
        self.configurationKey = configurationKey
        self.publicationSource = publicationSource
        self.contentHostState = contentHostState
        self.preloadStrategy = preloadStrategy
        self.currentContentLocation = currentContentLocation
        self.requestedLocation = requestedLocation
        self.pageOffsetsDisplayed = pageOffsetsDisplayed
        self.pageOffsetRange = pageOffsetRange
        self.currentPageIndex = currentPageIndex
        self.visiblePageIndices = visiblePageIndices
        self.canMoveForward = canMoveForward
        self.canMoveBackward = canMoveBackward
        self.forwardDestinationAvailability = forwardDestinationAvailability
        self.backwardDestinationAvailability = backwardDestinationAvailability
        self.currentSpread = currentSpread
        self.destinationSpread = destinationSpread
        self.spreadSequence = spreadSequence
    }
}

public struct WebViewPaginationState: Equatable, Sendable {
    public let desiredConfiguration: WebViewPaginationConfiguration
    public let appliedConfiguration: WebViewPaginationConfiguration?
    public let pageCount: Int?
    public let visibleUnit: WebViewPaginationVisibleUnit?
    public let pageLabelPolicy: WebViewPaginationPageLabelPolicy?
    public let currentPageDisplayLabel: String?
    public let currentPhysicalPageLabel: String?
    public let pageNavigationStyle: WebViewPageNavigationStyle?
    public let allowsMultipleColumns: Bool?
    public let pageNumberMode: WebViewPaginationPageNumberMode?
    public let paginationComplete: Bool?
    public let configurationKey: String?
    public let publicationSource: WebViewPaginationPublicationSource?
    public let contentHostState: WebViewPaginationContentHostState?
    public let preloadStrategy: WebViewPaginationPreloadStrategy?
    public let currentContentLocation: WebViewPaginationCurrentContentLocation?
    public let requestedLocation: WebViewPaginationRequestedLocation?
    public let pageOffsetsDisplayed: [Int]?
    public let pageOffsetRange: WebViewPaginationPageOffsetRange?
    public let currentPageIndex: Int?
    public let visiblePageIndices: [Int]?
    public let canMoveForward: Bool?
    public let canMoveBackward: Bool?
    public let forwardDestinationAvailability: String?
    public let backwardDestinationAvailability: String?
    public let currentSpread: WebViewPaginationSpread?
    public let destinationSpread: WebViewPaginationSpread?
    public let spreadSequence: WebViewPaginationSpreadSequence?
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
        currentPageDisplayLabel: String? = nil,
        currentPhysicalPageLabel: String? = nil,
        pageNavigationStyle: WebViewPageNavigationStyle? = nil,
        allowsMultipleColumns: Bool? = nil,
        pageNumberMode: WebViewPaginationPageNumberMode? = nil,
        paginationComplete: Bool? = nil,
        configurationKey: String? = nil,
        publicationSource: WebViewPaginationPublicationSource? = nil,
        contentHostState: WebViewPaginationContentHostState? = nil,
        preloadStrategy: WebViewPaginationPreloadStrategy? = nil,
        currentContentLocation: WebViewPaginationCurrentContentLocation? = nil,
        requestedLocation: WebViewPaginationRequestedLocation? = nil,
        pageOffsetsDisplayed: [Int]? = nil,
        pageOffsetRange: WebViewPaginationPageOffsetRange? = nil,
        currentPageIndex: Int? = nil,
        visiblePageIndices: [Int]? = nil,
        canMoveForward: Bool? = nil,
        canMoveBackward: Bool? = nil,
        forwardDestinationAvailability: String? = nil,
        backwardDestinationAvailability: String? = nil,
        currentSpread: WebViewPaginationSpread? = nil,
        destinationSpread: WebViewPaginationSpread? = nil,
        spreadSequence: WebViewPaginationSpreadSequence? = nil,
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
        self.currentPageDisplayLabel = currentPageDisplayLabel
        self.currentPhysicalPageLabel = currentPhysicalPageLabel
        self.pageNavigationStyle = pageNavigationStyle
        self.allowsMultipleColumns = allowsMultipleColumns
        self.pageNumberMode = pageNumberMode
        self.paginationComplete = paginationComplete
        self.configurationKey = configurationKey
        self.publicationSource = publicationSource
        self.contentHostState = contentHostState
        self.preloadStrategy = preloadStrategy
        self.currentContentLocation = currentContentLocation
        self.requestedLocation = requestedLocation
        self.pageOffsetsDisplayed = pageOffsetsDisplayed
        self.pageOffsetRange = pageOffsetRange
        self.currentPageIndex = currentPageIndex
        self.visiblePageIndices = visiblePageIndices
        self.canMoveForward = canMoveForward
        self.canMoveBackward = canMoveBackward
        self.forwardDestinationAvailability = forwardDestinationAvailability
        self.backwardDestinationAvailability = backwardDestinationAvailability
        self.currentSpread = currentSpread
        self.destinationSpread = destinationSpread
        self.spreadSequence = spreadSequence
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
        values["currentPageDisplayLabel"] = currentPageDisplayLabel ?? "nil"
        values["currentPhysicalPageLabel"] = currentPhysicalPageLabel ?? "nil"
        values["pageNavigationStyle"] = pageNavigationStyle?.rawValue ?? "nil"
        values["allowsMultipleColumns"] = allowsMultipleColumns.map(String.init) ?? "nil"
        values["pageNumberMode"] = pageNumberMode?.rawValue ?? "nil"
        values["paginationComplete"] = paginationComplete.map(String.init) ?? "nil"
        values["configurationKey"] = configurationKey ?? "nil"
        values["publicationSource"] = publicationSource?.rawValue ?? "nil"
        values["contentHostState"] = contentHostState?.rawValue ?? "nil"
        values["preloadStrategy"] = preloadStrategy?.rawValue ?? "nil"
        values["currentContentLocation"] = currentContentLocation?.rawValue ?? "nil"
        values["requestedLocationKind"] = requestedLocation?.kind.rawValue ?? "nil"
        values["requestedLocationValue"] = requestedLocation?.value ?? "nil"
        values["pageOffsetsDisplayed"] = pageOffsetsDisplayed?.map(String.init).joined(separator: ",") ?? "nil"
        if let pageOffsetRange {
            values["pageOffsetRange"] = "\(pageOffsetRange.lowerBound)...\(pageOffsetRange.upperBound)"
        } else {
            values["pageOffsetRange"] = "nil"
        }
        values["currentPageIndex"] = currentPageIndex.map(String.init) ?? "nil"
        values["visiblePageIndices"] = visiblePageIndices?.map(String.init).joined(separator: ",") ?? "nil"
        values["canMoveForward"] = canMoveForward.map(String.init) ?? "nil"
        values["canMoveBackward"] = canMoveBackward.map(String.init) ?? "nil"
        values["forwardDestinationAvailability"] = forwardDestinationAvailability ?? "nil"
        values["backwardDestinationAvailability"] = backwardDestinationAvailability ?? "nil"
        values.merge(currentSpread?.dictionaryRepresentation ?? [:], uniquingKeysWith: { _, rhs in rhs })
        if let destinationSpread {
            values["destinationSpreadIndex"] = destinationSpread.index.map(String.init) ?? "nil"
            values["destinationSpreadSlots"] = destinationSpread.slots
                .map { "\($0.kind.rawValue):\($0.pageIndex.map(String.init) ?? "nil")" }
                .joined(separator: ",")
        } else {
            values["destinationSpreadIndex"] = "nil"
            values["destinationSpreadSlots"] = "nil"
        }
        values.merge(spreadSequence?.dictionaryRepresentation ?? [:], uniquingKeysWith: { _, rhs in rhs })
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
        && lhs.currentPageDisplayLabel == rhs.currentPageDisplayLabel
        && lhs.currentPhysicalPageLabel == rhs.currentPhysicalPageLabel
        && lhs.pageNavigationStyle == rhs.pageNavigationStyle
        && lhs.allowsMultipleColumns == rhs.allowsMultipleColumns
        && lhs.pageNumberMode == rhs.pageNumberMode
        && lhs.paginationComplete == rhs.paginationComplete
        && lhs.configurationKey == rhs.configurationKey
        && lhs.publicationSource == rhs.publicationSource
        && lhs.contentHostState == rhs.contentHostState
        && lhs.preloadStrategy == rhs.preloadStrategy
        && lhs.currentContentLocation == rhs.currentContentLocation
        && lhs.requestedLocation == rhs.requestedLocation
        && lhs.pageOffsetsDisplayed == rhs.pageOffsetsDisplayed
        && lhs.pageOffsetRange == rhs.pageOffsetRange
        && lhs.currentPageIndex == rhs.currentPageIndex
        && lhs.visiblePageIndices == rhs.visiblePageIndices
        && lhs.canMoveForward == rhs.canMoveForward
        && lhs.canMoveBackward == rhs.canMoveBackward
        && lhs.forwardDestinationAvailability == rhs.forwardDestinationAvailability
        && lhs.backwardDestinationAvailability == rhs.backwardDestinationAvailability
        && lhs.currentSpread == rhs.currentSpread
        && lhs.destinationSpread == rhs.destinationSpread
        && lhs.spreadSequence == rhs.spreadSequence
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
            currentPageDisplayLabel: enrichment.currentPageDisplayLabel ?? currentPageDisplayLabel,
            currentPhysicalPageLabel: enrichment.currentPhysicalPageLabel ?? currentPhysicalPageLabel,
            pageNavigationStyle: enrichment.pageNavigationStyle ?? pageNavigationStyle,
            allowsMultipleColumns: enrichment.allowsMultipleColumns ?? allowsMultipleColumns,
            pageNumberMode: enrichment.pageNumberMode ?? pageNumberMode,
            paginationComplete: enrichment.paginationComplete ?? paginationComplete,
            configurationKey: enrichment.configurationKey ?? configurationKey,
            publicationSource: enrichment.publicationSource ?? publicationSource,
            contentHostState: enrichment.contentHostState ?? contentHostState,
            preloadStrategy: enrichment.preloadStrategy ?? preloadStrategy,
            currentContentLocation: enrichment.currentContentLocation ?? currentContentLocation,
            requestedLocation: enrichment.requestedLocation ?? requestedLocation,
            pageOffsetsDisplayed: enrichment.pageOffsetsDisplayed ?? pageOffsetsDisplayed,
            pageOffsetRange: enrichment.pageOffsetRange ?? pageOffsetRange,
            currentPageIndex: enrichment.currentPageIndex ?? currentPageIndex,
            visiblePageIndices: enrichment.visiblePageIndices ?? visiblePageIndices,
            canMoveForward: enrichment.canMoveForward ?? canMoveForward,
            canMoveBackward: enrichment.canMoveBackward ?? canMoveBackward,
            forwardDestinationAvailability: enrichment.forwardDestinationAvailability ?? forwardDestinationAvailability,
            backwardDestinationAvailability: enrichment.backwardDestinationAvailability ?? backwardDestinationAvailability,
            currentSpread: enrichment.currentSpread ?? currentSpread,
            destinationSpread: enrichment.destinationSpread ?? destinationSpread,
            spreadSequence: enrichment.spreadSequence ?? spreadSequence,
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
    public var onHit: ((WebViewNativeLookupHit) -> Void)?
    public var onActiveTargetTouchDown: (@MainActor (WebViewNativeLookupHitTarget) -> Void)?
    public var onTouchDownHitCancelled: (@MainActor (WebViewNativeLookupHitTarget) -> Void)?
    public var onActiveLookupBlankTap: (@MainActor () -> Void)?
    public var activeLookupElementID: (@MainActor () -> String?)?
    public var activeElementID: String?
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

    public init(hitSlop: CGFloat = 8) {
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

    private func makeEntries(for targets: [WebViewNativeLookupHitTarget]) -> [Entry] {
        targets.compactMap { target in
            let rects = target.rects
                .filter { !$0.isNull && !$0.isEmpty }
            let hitRects = rects.map { $0.insetBy(dx: -hitSlop, dy: -hitSlop) }
            guard !hitRects.isEmpty else { return nil }
            return Entry(target: target, rects: rects, hitRects: hitRects)
        }
    }

    public func removeAllTargets() {
        entries.removeAll()
        nativeTouchElementID = nil
        suppressUnhandledTapUntil = 0
    }

    @MainActor
    public func closeActiveLookupFromBlankTap() {
        onActiveLookupBlankTap?()
    }

    public func beginNativeTouchStream(on target: WebViewNativeLookupHitTarget) {
        nativeTouchElementID = target.elementID
        suppressUnhandledTapUntil = Date().timeIntervalSinceReferenceDate + 0.5
    }

    public func finishNativeTouchStream(reason _: String) {
        if nativeTouchElementID != nil {
            suppressUnhandledTapUntil = Date().timeIntervalSinceReferenceDate + 0.5
        }
        nativeTouchElementID = nil
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
            return target(for: exactCandidate, usedInflatedHitRect: false)
        }
        return bestCandidate(
            at: point,
            usingInflatedRects: true,
            containerSize: containerSize,
            coordinateViewWindowMinY: coordinateViewWindowMinY,
            coordinateViewWindowOrigin: coordinateViewWindowOrigin
        ).map {
            target(for: $0, usedInflatedHitRect: true)
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
            target(for: $0, usedInflatedHitRect: false)
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
                    distance: distance(from: point, to: hitRect),
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

    private func target(for candidate: Candidate, usedInflatedHitRect: Bool) -> WebViewNativeLookupHitTarget {
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
                    distance: distance(from: rebased.point, to: hitRect),
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
                "contains": hitRect.contains(candidate.hitTestPoint),
                "distance": candidate.distance,
                "centerDistance": candidate.centerDistance,
                "hitTestX": candidate.hitTestPoint.x,
                "hitTestY": candidate.hitTestPoint.y,
                "hitTestRebaseX": candidate.hitTestRebaseX,
                "hitTestRebaseY": candidate.hitTestRebaseY,
                "rect": Self.debugRectStrings([candidate.rect]).first ?? "",
                "hitRect": Self.debugRectStrings([candidate.hitRect]).first ?? "",
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
            debugPrint(
                "POPOVER nativeHitTargets.tapMiss",
                [
                    "point": Self.debugPointString(point),
                    "containerSize": containerSize.map(Self.debugSizeString) as Any,
                    "entryCount": entries.count,
                    "nearest": diagnostics(
                        at: point,
                        limit: 3,
                        in: containerSize,
                        coordinateViewWindowMinY: coordinateViewWindowMinY,
                        coordinateViewWindowOrigin: coordinateViewWindowOrigin
                    ),
                ] as [String : Any]
            )
            return false
        }
        debugPrint(
            "POPOVER nativeHitTargets.tapHit",
            [
                "point": Self.debugPointString(point),
                "containerSize": containerSize.map(Self.debugSizeString) as Any,
                "elementID": candidate.target.elementID,
                "usedInflatedRects": exactCandidate == nil,
                "distance": candidate.distance,
                "centerDistance": candidate.centerDistance,
                "rects": Self.debugRectStrings([candidate.rect]),
                "hitRects": Self.debugRectStrings([candidate.hitRect]),
            ] as [String : Any]
        )
        let target = target(for: candidate, usedInflatedHitRect: exactCandidate == nil)
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
        debugPrint(
            "POPOVER nativeHitTargets.tapHit",
            [
                "point": Self.debugPointString(point),
                "containerSize": containerSize.map(Self.debugSizeString) as Any,
                "elementID": target.elementID,
                "usedInflatedRects": false,
                "source": "capturedStartTarget",
                "rects": Self.debugRectStrings(target.rects.prefix(4)),
                "hitRects": Self.debugRectStrings(target.debugHitRects.prefix(4)),
                "targetUsedInflatedHitRect": target.debugUsedInflatedHitRect as Any,
                "targetDistance": target.debugDistance as Any,
                "targetCenterDistance": target.debugCenterDistance as Any,
            ] as [String : Any]
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
    private(set) public var lastRuntimeSpreadSequence: WebViewPaginationSpreadSequence?
    private(set) public var lastApplyReason: String?
    private(set) public var lastUpdatedAt: Date?

    public init() {}

    public func attach(webView: WKWebView) -> WebViewPaginationState {
        self.webView = webView
        return currentState(reason: "attach")
    }

    public func detach() -> WebViewPaginationState {
        webView = nil
        lastRuntimeSpreadSequence = nil
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
        return currentState(reason: reason)
    }

    public func refreshReadback(reason: String) throws -> WebViewPaginationState {
        lastApplyReason = reason
        lastUpdatedAt = Date()
        if let webView {
            lastPageCount = try queryPageCount(on: webView)
        } else {
            lastPageCount = nil
        }
        return currentState(reason: reason)
    }

    public func currentState(reason: String? = nil) -> WebViewPaginationState {
        let mountedHostIdentifier = webView.map(Self.hostIdentifier(for:))
        let configurationKey = Self.configurationKey(
            desiredConfiguration: desiredConfiguration,
            appliedConfiguration: lastAppliedConfiguration
        )
        let effectiveConfiguration = lastAppliedConfiguration ?? desiredConfiguration
        let runtimeCurrentSpread = lastRuntimeSpreadSequence?.currentSpread
        let runtimeVisibleUnit = webViewPaginationVisibleUnit(
            spreadSequence: lastRuntimeSpreadSequence
        )
        let runtimeVisiblePageIndices = runtimeCurrentSpread?.pageIndices
        let runtimeCurrentPageIndex = runtimeVisiblePageIndices?.first
        let runtimeForwardSpread: WebViewPaginationSpread? = {
            guard let sequence = lastRuntimeSpreadSequence,
                  let currentIndex = sequence.currentIndex else { return nil }
            let nextIndex = currentIndex + 1
            guard sequence.spreads.indices.contains(nextIndex) else { return nil }
            return sequence.spreads[nextIndex]
        }()
        let runtimeBackwardSpread: WebViewPaginationSpread? = {
            guard let sequence = lastRuntimeSpreadSequence,
                  let currentIndex = sequence.currentIndex else { return nil }
            let previousIndex = currentIndex - 1
            guard sequence.spreads.indices.contains(previousIndex) else { return nil }
            return sequence.spreads[previousIndex]
        }()
        let runtimeCanMoveBackward: Bool? = {
            guard let sequence = lastRuntimeSpreadSequence,
                  let currentIndex = sequence.currentIndex else { return nil }
            return currentIndex > 0
        }()
        let runtimeCanMoveForward: Bool? = {
            guard let sequence = lastRuntimeSpreadSequence,
                  let currentIndex = sequence.currentIndex else { return nil }
            return currentIndex + 1 < sequence.spreads.count
        }()
        let runtimePageOffsetRange = webViewPaginationPageOffsetRange(
            visiblePageIndices: runtimeVisiblePageIndices
        )
        let runtimeCurrentContentLocation = webViewPaginationCurrentContentLocation(
            spread: runtimeCurrentSpread,
            visiblePageIndices: runtimeVisiblePageIndices
        )
        let runtimeForwardDestinationAvailability = webViewPaginationDestinationAvailability(
            spread: runtimeForwardSpread,
            pageCount: lastPageCount
        )
        let runtimeBackwardDestinationAvailability = webViewPaginationDestinationAvailability(
            spread: runtimeBackwardSpread,
            pageCount: lastPageCount
        )
        let runtimeDestinationSpread: WebViewPaginationSpread? = {
            switch (runtimeBackwardSpread, runtimeForwardSpread) {
            case (nil, let forward?):
                return forward
            case (let backward?, nil):
                return backward
            default:
                return nil
            }
        }()
        return WebViewPaginationState(
            desiredConfiguration: desiredConfiguration,
            appliedConfiguration: lastAppliedConfiguration,
            pageCount: lastPageCount,
            visibleUnit: runtimeVisibleUnit,
            currentPageDisplayLabel: nil,
            currentPhysicalPageLabel: nil,
            pageNavigationStyle: effectiveConfiguration.mode.isPaginated ? .paged : nil,
            allowsMultipleColumns: effectiveConfiguration.mode.isPaginated ? effectiveConfiguration.behavesLikeColumns : nil,
            pageNumberMode: nil,
            paginationComplete: lastAppliedConfiguration != nil && lastPageCount != nil,
            configurationKey: configurationKey,
            publicationSource: lastAppliedConfiguration == nil ? nil : .pagination,
            contentHostState: nil,
            currentContentLocation: runtimeCurrentContentLocation,
            requestedLocation: nil,
            pageOffsetsDisplayed: runtimeVisiblePageIndices,
            pageOffsetRange: runtimePageOffsetRange,
            currentPageIndex: runtimeCurrentPageIndex,
            visiblePageIndices: runtimeVisiblePageIndices,
            canMoveForward: runtimeCanMoveForward,
            canMoveBackward: runtimeCanMoveBackward,
            forwardDestinationAvailability: runtimeForwardDestinationAvailability,
            backwardDestinationAvailability: runtimeBackwardDestinationAvailability,
            currentSpread: runtimeCurrentSpread,
            destinationSpread: runtimeDestinationSpread,
            spreadSequence: lastRuntimeSpreadSequence,
            mountedHostIdentifier: mountedHostIdentifier,
            appliedHostIdentifier: lastAppliedHostIdentifier,
            isAppliedToMountedHost: mountedHostIdentifier != nil && mountedHostIdentifier == lastAppliedHostIdentifier,
            usedViewLengthInference: (lastAppliedConfiguration ?? desiredConfiguration).usesViewLength,
            lastApplyReason: reason ?? lastApplyReason,
            lastUpdatedAt: lastUpdatedAt
        )
    }

    @discardableResult
    public func updateRuntimeSpreadSequence(
        _ spreadSequence: WebViewPaginationSpreadSequence?,
        reason: String
    ) -> WebViewPaginationState? {
        guard lastRuntimeSpreadSequence != spreadSequence else { return nil }
        lastRuntimeSpreadSequence = spreadSequence
        lastApplyReason = reason
        lastUpdatedAt = Date()
        return currentState(reason: reason)
    }

    private static func configurationKey(
        desiredConfiguration: WebViewPaginationConfiguration,
        appliedConfiguration: WebViewPaginationConfiguration?
    ) -> String {
        let resolved = (appliedConfiguration ?? desiredConfiguration).dictionaryRepresentation
        return resolved
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "|")
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
    private var pendingPaginationApplyTask: Task<Void, Never>?
    private var pendingPaginationStateTask: Task<Void, Never>?
    private var pendingWebViewBindingTask: Task<Void, Never>?
    private let progressUpdateMinimumInterval: CFTimeInterval = 0.12
    private let progressUpdateMinimumDelta: Double = 0.01
#if os(iOS)
    private weak var snapshotHostController: WebViewController?
    private var awaitingSnapshotReload = false
    private var snapshotReloadCommitted = false
    private var snapshotReloadDocumentReady = false
    private var pendingSnapshotRestore = false
    private var activeSnapshotCacheKey: WebViewSnapshotCacheKey?
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
    internal var mirroredHideNavigationDueToScroll: Bool?
    internal var lastNativeHideNavigationSetAt: TimeInterval?
    internal var lastScrollHideNavigationMessageAt: TimeInterval?
    internal var currentHideNavigationDueToScroll: Bool {
        mirroredHideNavigationDueToScroll ?? hideNavigationDueToScroll.wrappedValue
    }
    internal func setHideNavigationDueToScroll(_ value: Bool) {
        mirroredHideNavigationDueToScroll = value
        lastNativeHideNavigationSetAt = Date.timeIntervalSinceReferenceDate
        hideNavigationDueToScroll.wrappedValue = value
    }
    internal func syncHideNavigationDueToScrollFromHost(_ value: Bool) {
        if let mirroredHideNavigationDueToScroll,
           mirroredHideNavigationDueToScroll != value,
           let lastNativeHideNavigationSetAt,
           Date.timeIntervalSinceReferenceDate - lastNativeHideNavigationSetAt < 0.5 {
            return
        }
        mirroredHideNavigationDueToScroll = value
    }
    var textSelection: Binding<String?>

#if os(iOS)
    private func logLookupPerf(_ message: String) {
#if DEBUG
        let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
        print("# LOOKUPPERF", timestamp, message)
#endif
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
        self.mirroredHideNavigationDueToScroll = hideNavigationDueToScroll.wrappedValue
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
        lastEmittedProgress = nil
        lastProgressUpdateTime = 0
    }

    @MainActor
    private func clearScriptCallerBinding() {
        scriptCaller?.asyncCaller = nil
        scriptCaller?.snapshotCapture = nil
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
        if !navigator.shouldLoadFallbackOnAttach {
        }
        removeMessageHandlers(for: webView)
        lastUserScriptsContentController = nil
        lastInstalledScriptsSignature = nil
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
        if !navigator.shouldLoadFallbackOnAttach {
        }
        navigator.webView = webView
        (webView as? EnhancedWKWebView)?.onDidMoveToWindow = { [weak navigator, weak webView] isAttached in
            guard let navigator, let webView else { return }
            Task { @MainActor in
                navigator.handleWindowAttachmentChanged(isAttached: isAttached, webView: webView)
            }
        }
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
                self?.updateLoadingProgress(isLoading: nil, estimatedProgress: progress)
            }
        }

        isLoadingObservation = webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, change in
            guard let self else { return }
            guard let isLoading = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.updateLoadingProgress(isLoading: isLoading, estimatedProgress: nil)
            }
        }

#if os(iOS)
        if config.usesSampledPageTopColorForUnderPageBackground,
           manabiCanUseSampledPageTopColorBackground() {
            sampledPageTopColorObservation = WebViewStringKeyPathObserver(
                object: webView,
                keyPath: "_sampl\("edPageTopC")olor"
            ) { [weak self, weak webView] observedColor in
                Task { @MainActor [weak self, weak webView] in
                    guard let self, let webView else { return }
                    if #available(iOS 15.0, *) {
                        self.applySampledPageTopColorChange(
                            webView: webView,
                            observedColor: observedColor
                        )
                    }
                }
            }
        }
#endif
    }

#if os(iOS)
    @MainActor
    private func beginSampledPageTopColorNavigation(_ webView: WKWebView) {
        webView.applyUnderPageFallbackBackgroundColor(config: config)
    }

    @available(iOS 15.0, *)
    @MainActor
    private func applySampledPageTopColorChange(webView: WKWebView, observedColor: UIColor?) {
        guard observedColor != nil else {
            webView.applyUnderPageFallbackBackgroundColor(config: config)
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
            reason: "sampledPageTopColor.changed"
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
        }
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
        if pageURLChanged {
            newState.mainFrameHTTPStatusCode = nil
        }
        //        debugPrint("# new state:", newState, "old:", webView.state)
        webView.state = newState
        
        if pageURLChanged {
            onURLChanged?(newState)
        }

        updateLoadingProgress(isLoading: isLoading, estimatedProgress: navigator.webView?.estimatedProgress)
            
        return newState
    }

    @MainActor
    private func updateLoadingProgress(isLoading: Bool?, estimatedProgress: Double?) {
        if let isLoading {
            latestIsLoading = isLoading
        }
        if let estimatedProgress {
            latestEstimatedProgress = estimatedProgress
        }

        let clampedProgress = max(0, min(latestEstimatedProgress, 1))
        let progress: Double? = latestIsLoading ? clampedProgress : nil
        let now = CFAbsoluteTimeGetCurrent()

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
            scheduleLoadingProgressUpdate(progress, now: now)
        }
    }

    @MainActor
    private func scheduleLoadingProgressUpdate(_ progress: Double?, now: CFTimeInterval) {
        pendingProgressUpdateTask?.cancel()
        let elapsed = now - lastProgressUpdateTime
        let delay = max(0, progressUpdateMinimumInterval - elapsed)
        guard delay > 0 else {
            emitLoadingProgress(progress, now: CFAbsoluteTimeGetCurrent())
            return
        }

        pendingProgressUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.emitLoadingProgress(progress, now: CFAbsoluteTimeGetCurrent())
        }
    }

    @MainActor
    private func emitLoadingProgress(_ progress: Double?, now: CFTimeInterval) {
        pendingProgressUpdateTask?.cancel()
        pendingProgressUpdateTask = nil

        guard webView.state.loadingProgress != progress else { return }

        lastProgressUpdateTime = now
        lastEmittedProgress = progress

        var newState = webView.state
        newState.loadingProgress = progress
        webView.state = newState
    }

    @MainActor
    fileprivate func forceClearLoadingIndicators(reason: String, pageURL: URL?) {
        let effectivePageURL = pageURL ?? navigator.webView?.url ?? webView.state.pageURL
        let hadLoadingState = webView.state.isLoading || webView.state.loadingProgress != nil || latestIsLoading
        guard hadLoadingState else { return }

        pendingProgressUpdateTask?.cancel()
        pendingProgressUpdateTask = nil
        latestIsLoading = false
        latestEstimatedProgress = 1
        lastEmittedProgress = nil

        var newState = webView.state
        newState.isLoading = false
        newState.isProvisionallyNavigating = false
        newState.loadingProgress = nil
        if newState.pageURL.absoluteString == "about:blank" {
            newState.pageURL = effectivePageURL
        }
        webView.state = newState
    }
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
            let hasActiveLookup = navigator.nativeLookupHitTesting.activeLookupElementID?() != nil
            let requestedHideNavigation = (message.body as? [String: Any])?["hideNavigationDueToScroll"] as? Bool
            let isNavigationStateMessage = requestedHideNavigation != nil
            if isNavigationStateMessage {
                lastScrollHideNavigationMessageAt = Date.timeIntervalSinceReferenceDate
            }
            if let requestedHideNavigation,
               requestedHideNavigation == currentHideNavigationDueToScroll {
                return
            }
            if hasActiveLookup,
               !isNavigationStateMessage,
               navigator.nativeLookupHitTesting.activeNativeTouchElementID == nil {
                navigator.nativeLookupHitTesting.closeActiveLookupFromBlankTap()
                return
            }
            if navigator.nativeLookupHitTesting.shouldSuppressUnhandledTapForNativeLookup, !isNavigationStateMessage {
                return
            }
            if !isNavigationStateMessage,
               let body = message.body as? [String: Any],
               let targetClosestSegment = body["targetClosestSegment"] as? String,
               !targetClosestSegment.isEmpty {
                return
            }
            if hasActiveLookup, !isNavigationStateMessage {
                navigator.nativeLookupHitTesting.closeActiveLookupFromBlankTap()
                return
            }
#if DEBUG
            let body = message.body as? [String: Any]
            let currentHideNavigation = currentHideNavigationDueToScroll
            debugPrint(
                "# TABBAR webUnhandledTapHideNav",
                "current=\(currentHideNavigation)",
                "next=\(!currentHideNavigation)",
                "frame=\(body?["frame"] ?? "nil")",
                "targetTag=\(body?["targetTag"] ?? "nil")",
                "targetClosestSegment=\(body?["targetClosestSegment"] ?? "nil")"
            )
#endif
            if let body = message.body as? [String: Any],
               let requestedHideNavigation = body["hideNavigationDueToScroll"] as? Bool {
                withAnimation(.easeOut(duration: 0.18)) {
                    setHideNavigationDueToScroll(requestedHideNavigation)
                }
            } else {
                if let lastScrollHideNavigationMessageAt,
                   Date.timeIntervalSinceReferenceDate - lastScrollHideNavigationMessageAt < 0.7 {
                    return
                }
                let nextHideNavigation = !currentHideNavigationDueToScroll
                withAnimation(.easeOut(duration: 0.18)) {
                    setHideNavigationDueToScroll(nextHideNavigation)
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
            if let hasReaderRenderReady = body["hasReaderRenderReady"] as? Bool,
               webView.state.hasReaderRenderReady != hasReaderRenderReady {
                var newState = webView.state
                newState.hasReaderRenderReady = hasReaderRenderReady
                webView.state = newState
            }
        } else if message.name == "swiftUIWebViewPaginationReadback" {
            guard let body = message.body as? [String: Any] else { return }
            let refreshedState = try? paginationController.refreshReadback(reason: "runtime-pagination-readback")
            let spreadSequence = webViewPaginationSpreadSequence(from: body["spreadSequence"])
            let paginationState = paginationController.updateRuntimeSpreadSequence(
                spreadSequence,
                reason: "runtime-pagination-readback"
            ) ?? refreshedState
            if let paginationState {
                schedulePaginationStateUpdate(paginationState)
            }
            return
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
        navigator.cancelReaderLoadHeartbeat(reason: "didFinishNavigation")
        if !navigator.shouldLoadFallbackOnAttach {
        }
        debugPrint("# READER webView.nav.finish",
                   "url=\(webView.url?.absoluteString ?? "<nil>")",
                   "isLoading=\(webView.isLoading)")
        let finishNow = Date()
        readerLoadLog(
            "webView.nav.finish",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "elapsedSinceCommit": readerLoadElapsedString(since: navigator.readerLoadCommittedAt, now: finishNow),
                "elapsedSinceDataLoadIssued": readerLoadElapsedString(since: navigator.readerLoadIssuedAt, now: finishNow),
                "elapsedSinceDataLoadReturned": navigator.readerLoadDirectDataReturnedElapsedString(now: finishNow),
                "elapsedSinceNavigatorLoad": readerLoadElapsedString(since: navigator.readerLoadRequestedAt, now: finishNow),
                "requestURL": navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
            ]
        )
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
            webView.applyUnderPageFallbackBackgroundColor(config: config)
        }
        webView.applyConfiguredBackgroundForReaderDocumentIfNeeded(config: config, reason: "navigation.finish")
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
                const bodyText = (body?.innerText || "").trim();
                const bodyHTML = body?.innerHTML || "";
                return {
                    documentURL: document.URL.toString(),
                    readyState: document.readyState,
                    bodyChildElementCount: body?.childElementCount || 0,
                    bodyTextLength: bodyText.length,
                    bodyHTMLLength: bodyHTML.length,
                    hasReaderRenderReady:
                        (html?.dataset?.manabiReaderRenderReady === '1' || body?.dataset?.manabiReaderRenderReady === '1')
                        && !!document.getElementById("reader-content")
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
            if !hasMeaningfulBodyContent || (summary["hasReaderRenderReady"] as? Bool ?? false) {
                readerLoadLog("webView.documentSummary", mapped)
            }
        }
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigator.cancelReaderLoadHeartbeat(reason: "didFailProvisionalNavigation")
        Task {
            scriptCaller?.removeAllMultiTargetFrames()
        }
        if !navigator.shouldLoadFallbackOnAttach {
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
                "requestURL": navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
            ]
        )
#if os(iOS)
        if awaitingSnapshotReload {
            cancelSnapshotReload()
        }
#endif
    }
    
    @MainActor
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        setLoading(false, isProvisionallyNavigating: false)
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigator.cancelReaderLoadHeartbeat(reason: "didFailNavigation")
        Task {
            scriptCaller?.removeAllMultiTargetFrames()
        }
        if !navigator.shouldLoadFallbackOnAttach {
        }
        let newState = setLoading(false, isProvisionallyNavigating: false, error: error)
        let now = Date()
        readerLoadLog(
            "webView.nav.fail",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "elapsedSinceNavigatorLoad": readerLoadElapsedString(since: navigator.readerLoadRequestedAt, now: now),
                "error": error.localizedDescription,
                "requestURL": navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
            ]
        )
        
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
        Task {
            scriptCaller?.removeAllMultiTargetFrames()
        }
        if !navigator.shouldLoadFallbackOnAttach {
        }
        debugPrint("# READER webView.nav.commit",
                   "url=\(webView.url?.absoluteString ?? "<nil>")",
                   "isLoading=\(webView.isLoading)")
        let commitNow = Date()
        navigator.readerLoadCommittedAt = commitNow
        readerLoadLog(
            "webView.nav.commit",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "elapsedSinceDataLoadIssued": readerLoadElapsedString(since: navigator.readerLoadIssuedAt, now: commitNow),
                "elapsedSinceDataLoadReturned": navigator.readerLoadDirectDataReturnedElapsedString(now: commitNow),
                "elapsedSinceNavigatorLoad": readerLoadElapsedString(since: navigator.readerLoadRequestedAt, now: commitNow),
                "elapsedSinceProvisionalStart": readerLoadElapsedString(since: navigator.readerLoadProvisionalStartedAt, now: commitNow),
                "requestURL": navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
            ]
        )
        if let currentURL = webView.url?.absoluteString {
            let correlationBaseline = navigator.readerLoadIssuedAt ?? navigator.readerLoadRequestedAt
            if let finishTimestamp = readerLoadCorrelationTimestamp(
                forKey: internalReaderLoaderFinishedAtKeyPrefix + currentURL,
                baseline: correlationBaseline,
                now: commitNow
            ) {
                readerLoadLog(
                    "webView.nav.commit.afterInternalSchemeFinish",
                    [
                        "currentURL": currentURL,
                        "elapsedSinceInternalSchemeFinish": String(format: "%.3fs", commitNow.timeIntervalSince(finishTimestamp)),
                        "elapsedSinceProvisionalStart": readerLoadElapsedString(since: navigator.readerLoadProvisionalStartedAt, now: commitNow),
                        "requestURL": navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
                    ]
                )
            }
            if let startTimestamp = readerLoadCorrelationTimestamp(
                forKey: internalReaderLoaderStartedAtKeyPrefix + currentURL,
                baseline: correlationBaseline,
                now: commitNow
            ) {
                readerLoadLog(
                    "webView.nav.commit.afterInternalSchemeStart",
                    [
                        "currentURL": currentURL,
                        "elapsedSinceInternalSchemeStart": String(format: "%.3fs", commitNow.timeIntervalSince(startTimestamp)),
                        "requestURL": navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
                    ]
                )
            }
            if let responseTimestamp = readerLoadCorrelationTimestamp(
                forKey: internalReaderLoaderResponseAtKeyPrefix + currentURL,
                baseline: correlationBaseline,
                now: commitNow
            ) {
                readerLoadLog(
                    "webView.nav.commit.afterInternalSchemeResponse",
                    [
                        "currentURL": currentURL,
                        "elapsedSinceInternalSchemeResponse": String(format: "%.3fs", commitNow.timeIntervalSince(responseTimestamp)),
                        "requestURL": navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
                    ]
                )
            }
            if let dataTimestamp = readerLoadCorrelationTimestamp(
                forKey: internalReaderLoaderDataAtKeyPrefix + currentURL,
                baseline: correlationBaseline,
                now: commitNow
            ) {
                readerLoadLog(
                    "webView.nav.commit.afterInternalSchemeData",
                    [
                        "currentURL": currentURL,
                        "elapsedSinceInternalSchemeData": String(format: "%.3fs", commitNow.timeIntervalSince(dataTimestamp)),
                        "requestURL": navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
                    ]
                )
            }
        }
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
        webView.applyUnderPageFallbackBackgroundColor(config: config)
        webView.applyConfiguredBackgroundForReaderDocumentIfNeeded(config: config, reason: "navigation.commit")
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
        if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || !navigator.shouldLoadFallbackOnAttach {
        }
        debugPrint("# READER webView.nav.start",
                   "url=\(webView.url?.absoluteString ?? "<nil>")",
                   "isLoading=\(webView.isLoading)")
        let provisionalNow = Date()
        navigator.readerLoadProvisionalStartedAt = provisionalNow
        navigator.cancelPreProvisionalWarningTask()
        navigator.syncActiveInternalReaderLoaderSignal()
        navigator.cancelReaderLoadHeartbeat(reason: "didStartProvisionalNavigation")
        readerLoadLog(
            "webView.nav.provisionalStart",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "elapsedSinceDataLoadIssued": readerLoadElapsedString(since: navigator.readerLoadIssuedAt, now: provisionalNow),
                "elapsedSinceDataLoadReturned": navigator.readerLoadDirectDataReturnedElapsedString(now: provisionalNow),
                "elapsedSinceIssued": readerLoadElapsedString(since: navigator.readerLoadIssuedAt, now: provisionalNow),
                "elapsedSinceNavigatorLoad": readerLoadElapsedString(since: navigator.readerLoadRequestedAt, now: provisionalNow),
                "requestURL": navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
            ]
        )
        var newState = self.webView.state
        newState.mainFrameHTTPStatusCode = nil
        self.webView.state = newState
        debugPrint(
            "# 404 webView.nav.statusReset",
            "url=\(webView.url?.absoluteString ?? "<nil>")"
        )
        if let currentURL = webView.url?.absoluteString {
            let correlationBaseline = navigator.readerLoadIssuedAt ?? navigator.readerLoadRequestedAt
            if let startTimestamp = readerLoadCorrelationTimestamp(
                forKey: internalReaderLoaderStartedAtKeyPrefix + currentURL,
                baseline: correlationBaseline,
                now: provisionalNow
            ) {
                readerLoadLog(
                    "webView.nav.provisionalStart.afterInternalSchemeStart",
                    [
                        "currentURL": currentURL,
                        "elapsedSinceInternalSchemeStart": String(format: "%.3fs", provisionalNow.timeIntervalSince(startTimestamp)),
                        "requestURL": navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
                    ]
                )
            } else {
                readerLoadLog(
                    "webView.nav.provisionalStart.beforeInternalSchemeStart",
                    [
                        "requestURL": navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
                    ]
                )
            }
            if let responseTimestamp = readerLoadCorrelationTimestamp(
                forKey: internalReaderLoaderResponseAtKeyPrefix + currentURL,
                baseline: correlationBaseline,
                now: provisionalNow
            ) {
                readerLoadLog(
                    "webView.nav.provisionalStart.afterInternalSchemeResponse",
                    [
                        "currentURL": currentURL,
                        "elapsedSinceInternalSchemeResponse": String(format: "%.3fs", provisionalNow.timeIntervalSince(responseTimestamp)),
                        "requestURL": navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
                    ]
                )
            }
            if let dataTimestamp = readerLoadCorrelationTimestamp(
                forKey: internalReaderLoaderDataAtKeyPrefix + currentURL,
                baseline: correlationBaseline,
                now: provisionalNow
            ) {
                readerLoadLog(
                    "webView.nav.provisionalStart.afterInternalSchemeData",
                    [
                        "currentURL": currentURL,
                        "elapsedSinceInternalSchemeData": String(format: "%.3fs", provisionalNow.timeIntervalSince(dataTimestamp)),
                        "requestURL": navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
                    ]
                )
            }
            if let finishTimestamp = readerLoadCorrelationTimestamp(
                forKey: internalReaderLoaderFinishedAtKeyPrefix + currentURL,
                baseline: correlationBaseline,
                now: provisionalNow
            ) {
                readerLoadLog(
                    "webView.nav.provisionalStart.afterInternalSchemeFinish",
                    [
                        "currentURL": currentURL,
                        "elapsedSinceInternalSchemeFinish": String(format: "%.3fs", provisionalNow.timeIntervalSince(finishTimestamp)),
                        "requestURL": navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
                    ]
                )
            }
        }
        if let issuedAt = navigator.readerLoadIssuedAt {
            let issueGap = provisionalNow.timeIntervalSince(issuedAt)
            if issueGap >= readerLoadIssueGapWarningThreshold {
                readerLoadLog(
                    "webView.nav.issueGap",
                    [
                        "currentURL": webView.url?.absoluteString ?? "nil",
                        "elapsedSinceIssued": String(format: "%.3fs", issueGap),
                        "estimatedProgress": String(format: "%.3f", webView.estimatedProgress),
                        "hasSuperview": "\(webView.superview != nil)",
                        "hasWindow": "\(webView.window != nil)",
                        "isLoading": "\(webView.isLoading)",
                        "pendingRequestURL": navigator.pendingRequest?.url?.absoluteString ?? "nil",
                        "requestURL": navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
                    ]
                )
            }
        }
        if navigator.pendingRequest?.url == webView.url {
            if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || !navigator.shouldLoadFallbackOnAttach {
                debugPrint(
                    "# READER navigator.pendingRequest.clearedOnStart",
                    [
                        "navigatorID": navigator.debugIdentifier ?? "nil",
                        "navigatorObjectID": navigator.debugObjectID,
                        "url": webView.url?.absoluteString ?? "nil"
                    ] as [String : Any]
                )
            }
            navigator.pendingRequest = nil
            navigator.cancelPendingRequestLoadTask()
        }
#if os(iOS)
        beginSampledPageTopColorNavigation(webView)
        pendingSnapshotRestore = false
#endif
        _ = setLoading(
            true,
            isProvisionallyNavigating: true,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            backList: webView.backForwardList.backList,
            forwardList: webView.backForwardList.forwardList)
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        debugPrint("# READER webView.nav.decide",
                   "request=\(navigationAction.request.url?.absoluteString ?? "<nil>")",
                   "mainFrame=\(navigationAction.targetFrame?.isMainFrame ?? false)")
        let isMainDocumentNavigation = navigationAction.targetFrame?.isMainFrame == true
        let isInternalReaderLoaderNavigation = isMainDocumentNavigation
            && canonicalContentURLForReaderLoader(navigationAction.request.url) != nil
        if isMainDocumentNavigation,
           let requestedURL = navigationAction.request.url,
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
            return (decision, preferences)
        }
        if let host = navigationAction.request.url?.host, let blockedHosts = self.webView.blockedHosts {
            if blockedHosts.contains(where: { host.contains($0) }) {
                setLoading(false, isProvisionallyNavigating: false)
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
        
        return (.allow, preferences)
    }
    
    @MainActor
    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let response = navigationResponse.response as? HTTPURLResponse {
            debugPrint(
                "# READER webView.nav.response",
                "url=\(response.url?.absoluteString ?? "<nil>")",
                "mimeType=\(response.mimeType ?? "<nil>")",
                "status=\(response.statusCode)",
                "expectedLength=\(response.expectedContentLength)"
            )
            if navigationResponse.isForMainFrame {
                var newState = self.webView.state
                newState.mainFrameHTTPStatusCode = response.statusCode
                self.webView.state = newState
                debugPrint(
                    "# 404 webView.nav.mainFrameResponse",
                    "url=\(response.url?.absoluteString ?? "<nil>")",
                    "status=\(response.statusCode)",
                    "isHTTPError=\(response.statusCode >= 400)"
                )
            }
        }
        return .allow
    }
}

public class WebViewNavigator: NSObject, ObservableObject {
    public struct DebugLoadSnapshot: Sendable {
        public let currentWebViewURL: String
        public let lastRequestURL: String
        public let lastDataLoadBaseURL: String
        public let lastHTMLBaseURL: String
        public let hasAttachedWebView: Bool
        public let isLoading: Bool
    }

    fileprivate var pendingRequest: URLRequest?
    fileprivate var pendingHTML: (html: String, baseURL: URL?)?
    fileprivate var pendingDataLoad: (data: Data, mimeType: String, characterEncodingName: String, baseURL: URL)?
    fileprivate var lastLoadedRequest: URLRequest?
    fileprivate var lastLoadedHTML: (html: String, baseURL: URL?)?
    fileprivate var lastLoadedDataLoad: (data: Data, mimeType: String, characterEncodingName: String, baseURL: URL)?
    @Published public private(set) var hasAttachedWebView = false
    public var debugIdentifier: String?
    public var debugObjectID: String {
        String(describing: ObjectIdentifier(self))
    }
    public let nativeLookupHitTesting = WebViewNativeLookupHitTestStore()
    @MainActor private var bypassContentRulesForNextNavigation = false
    @MainActor private var pendingRequestLoadGeneration: Int = 0
    @MainActor private var pendingRequestLoadTask: Task<Void, Never>?
    @MainActor private var attachFallbackLoadGeneration: Int = 0
    @MainActor private var attachFallbackLoadTask: Task<Void, Never>?
    @MainActor private var readerLoadTraceID: UUID?
    @MainActor private var preProvisionalWarningGeneration: Int = 0
    @MainActor private var preProvisionalWarningTask: Task<Void, Never>?
    @MainActor fileprivate var didLogReaderLoadHeartbeatForCurrentRequest = false
    @MainActor fileprivate var didLogHostPreProvisionalForCurrentRequest = false
    @MainActor private var readerLoadHeartbeatGeneration: Int = 0
    @MainActor private var readerLoadHeartbeatTask: Task<Void, Never>?
    @MainActor private var contentProcessPrewarmGeneration: Int = 0
    @MainActor private var contentProcessPrewarmTask: Task<Void, Never>?
    @MainActor private var contentProcessPrewarmIssuedAt: Date?
    @MainActor private var contentProcessPrewarmCompletedAt: Date?
    @MainActor private var contentProcessPrewarmWebViewID: String?
    @MainActor fileprivate var readerLoadRequestedAt: Date?
    @MainActor fileprivate var readerLoadRequestedURL: URL?
    @MainActor fileprivate var readerLoadIssuedAt: Date?
    @MainActor fileprivate var readerLoadDirectDataReturnedAt: Date?
    @MainActor fileprivate var readerLoadProvisionalStartedAt: Date?
    @MainActor fileprivate var readerLoadCommittedAt: Date?
    public var attachFallbackURL: URL?
    public var attachFallbackDelayNanoseconds: UInt64 = 250_000_000
    public var shouldLoadFallbackOnAttach = true
    public var paginationStateEnrichment: WebViewPaginationStateEnrichment?
    @MainActor fileprivate var forceClearLoadingIndicatorsHandler: ((String, URL?) -> Void)?

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
    private func beginReaderLoadTrace(for request: URLRequest) {
        let now = Date()
        cancelPreProvisionalWarningTask()
        readerLoadTraceID = UUID()
        didLogReaderLoadHeartbeatForCurrentRequest = false
        didLogHostPreProvisionalForCurrentRequest = false
        cancelReaderLoadHeartbeat()
        readerLoadRequestedAt = now
        readerLoadRequestedURL = request.url
        readerLoadIssuedAt = nil
        readerLoadDirectDataReturnedAt = nil
        readerLoadProvisionalStartedAt = nil
        readerLoadCommittedAt = nil
        syncActiveInternalReaderLoaderSignal()
        readerLoadLog(
            "webViewNavigator.loadRequest",
            [
                "attached": "\(webView != nil)",
                "hasSuperview": "\(webView?.superview != nil)",
                "hasWindow": "\(webView?.window != nil)",
                "url": request.url?.absoluteString ?? "nil"
            ]
        )
        if let requestURL = request.url?.absoluteString {
            clearReaderLoaderCorrelationTimestamps(for: requestURL)
        }
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
    private func resetInFlightAboutBlankIfNeeded(
        for request: URLRequest,
        on webView: WKWebView,
        reason: String
    ) -> Bool {
        guard let requestURL = request.url,
              requestURL.absoluteString != "about:blank",
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

        pendingRequest = request
        readerLoadLog(
            "webViewNavigator.inFlightAboutBlankReset",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "estimatedProgress": String(format: "%.3f", estimatedProgress),
                "isLoading": "\(isLoading)",
                "reason": reason,
                "requestURL": requestURL.absoluteString,
                "sceneState": readerLoadSceneStateString(for: webView),
                "webViewID": readerLoadObjectIDString(webView)
            ]
        )
        webView.stopLoading()
        schedulePendingRequestLoadRetry(
            request: request,
            webView: webView,
            attempt: 1,
            generation: pendingRequestLoadGeneration
        )
        return true
    }

    @MainActor
    private func markReaderLoadIssued(for request: URLRequest, reason: String) {
        let now = Date()
        readerLoadIssuedAt = now
        syncActiveInternalReaderLoaderSignal()
        schedulePreProvisionalWarningIfNeeded()
        readerLoadLog(
            "webViewNavigator.requestIssued",
            [
                "currentURL": webView?.url?.absoluteString ?? "nil",
                "elapsedSinceNavigatorLoad": readerLoadElapsedString(since: readerLoadRequestedAt, now: now),
                "estimatedProgress": webView.map { String(format: "%.3f", $0.estimatedProgress) } ?? "nil",
                "hasSuperview": "\(webView?.superview != nil)",
                "hasWindow": "\(webView?.window != nil)",
                "isLoading": "\(webView?.isLoading ?? false)",
                "prewarmCompleted": "\(contentProcessPrewarmCompletedAt != nil)",
                "prewarmElapsed": readerLoadElapsedString(since: contentProcessPrewarmIssuedAt, now: contentProcessPrewarmCompletedAt ?? now),
                "prewarmWebViewID": contentProcessPrewarmWebViewID ?? "nil",
                "reason": reason,
                "requestURL": readerLoadRequestedURL?.absoluteString ?? "nil",
                "url": request.url?.absoluteString ?? "nil"
            ]
        )
        startReaderLoadHeartbeatIfNeeded()
    }

    @MainActor
    fileprivate func syncActiveInternalReaderLoaderSignal() {
        let defaults = UserDefaults.standard
        if let requestURL = readerLoadRequestedURL,
           isInternalReaderLoaderURL(requestURL),
           readerLoadIssuedAt != nil,
           readerLoadProvisionalStartedAt == nil {
            defaults.set(requestURL.absoluteString, forKey: activeInternalReaderLoaderURLKey)
            defaults.set(readerLoadTraceID?.uuidString ?? requestURL.absoluteString, forKey: activeInternalReaderLoaderTraceIDKey)
        } else {
            defaults.removeObject(forKey: activeInternalReaderLoaderTraceIDKey)
            defaults.removeObject(forKey: activeInternalReaderLoaderURLKey)
        }
    }

    @MainActor
    fileprivate func cancelPreProvisionalWarningTask() {
        preProvisionalWarningGeneration &+= 1
        preProvisionalWarningTask?.cancel()
        preProvisionalWarningTask = nil
    }

    @MainActor
    fileprivate func schedulePreProvisionalWarningIfNeeded() {
        cancelPreProvisionalWarningTask()
        guard let requestURL = readerLoadRequestedURL,
              isInternalReaderLoaderURL(requestURL),
              readerLoadIssuedAt != nil,
              readerLoadProvisionalStartedAt == nil else {
            syncActiveInternalReaderLoaderSignal()
            return
        }
        syncActiveInternalReaderLoaderSignal()
        let generation = preProvisionalWarningGeneration
        let traceID = readerLoadTraceID?.uuidString ?? requestURL.absoluteString
        preProvisionalWarningTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(readerLoadPreProvisionalWarningThreshold * 1_000_000_000))
            guard let self,
                  !Task.isCancelled,
                  self.preProvisionalWarningGeneration == generation,
                  self.readerLoadRequestedURL == requestURL,
                  self.readerLoadProvisionalStartedAt == nil,
                  let issuedAt = self.readerLoadIssuedAt else { return }
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
                    "requestURL": requestURL.absoluteString,
                    "sceneState": readerLoadSceneStateString(for: self.webView),
                    "traceID": traceID
                ]
            )
        }
    }

    @MainActor
    fileprivate func logCompetingOperationIfNeeded(_ operation: String, metadata: [String: String] = [:]) {
        guard let requestURL = readerLoadRequestedURL,
              isInternalReaderLoaderURL(requestURL),
              let issuedAt = readerLoadIssuedAt,
              readerLoadProvisionalStartedAt == nil else { return }
        var payload = metadata
        payload["currentURL"] = webView?.url?.absoluteString ?? "nil"
        payload["elapsedSinceIssued"] = String(format: "%.3fs", Date().timeIntervalSince(issuedAt))
        payload["estimatedProgress"] = webView.map { String(format: "%.3f", $0.estimatedProgress) } ?? "nil"
        payload["hasSuperview"] = "\(webView?.superview != nil)"
        payload["hasWindow"] = "\(webView?.window != nil)"
        payload["isLoading"] = "\(webView?.isLoading ?? false)"
        payload["requestURL"] = requestURL.absoluteString
        payload["sceneState"] = readerLoadSceneStateString(for: webView)
        payload["traceID"] = readerLoadTraceID?.uuidString ?? requestURL.absoluteString
        readerLoadLog("webViewNavigator.competingOperation.\(operation)", payload)
    }

    @MainActor
    fileprivate func cancelReaderLoadHeartbeat(reason: String? = nil) {
        readerLoadHeartbeatGeneration &+= 1
        readerLoadHeartbeatTask?.cancel()
        readerLoadHeartbeatTask = nil
        guard let reason else { return }
        readerLoadLog(
            "webViewNavigator.requestHeartbeatCanceled",
            [
                "currentURL": webView?.url?.absoluteString ?? "nil",
                "elapsedSinceIssued": readerLoadElapsedString(since: readerLoadIssuedAt),
                "reason": reason,
                "requestURL": readerLoadRequestedURL?.absoluteString ?? "nil"
            ]
        )
    }

    @MainActor
    fileprivate func readerLoadDirectDataReturnedElapsedString(now: Date = Date()) -> String {
        readerLoadElapsedString(since: readerLoadDirectDataReturnedAt, now: now)
    }

    @MainActor
    private func startReaderLoadHeartbeatIfNeeded() {
        guard isInternalReaderLoaderURL(readerLoadRequestedURL),
              readerLoadIssuedAt != nil,
              readerLoadProvisionalStartedAt == nil else {
            cancelReaderLoadHeartbeat()
            return
        }
        readerLoadHeartbeatGeneration &+= 1
        let generation = readerLoadHeartbeatGeneration
        readerLoadHeartbeatTask?.cancel()
        readerLoadHeartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let strongSelf = self,
                      strongSelf.readerLoadHeartbeatGeneration == generation,
                      strongSelf.readerLoadIssuedAt != nil,
                      strongSelf.readerLoadProvisionalStartedAt == nil else {
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let strongSelf = self,
                      !Task.isCancelled,
                      strongSelf.readerLoadHeartbeatGeneration == generation,
                      strongSelf.readerLoadIssuedAt != nil,
                      strongSelf.readerLoadProvisionalStartedAt == nil else {
                    return
                }
                guard !strongSelf.didLogReaderLoadHeartbeatForCurrentRequest else {
                    continue
                }
                strongSelf.didLogReaderLoadHeartbeatForCurrentRequest = true
                let webView = strongSelf.webView
                readerLoadLog(
                    "webViewNavigator.requestHeartbeat",
                    [
                        "currentURL": webView?.url?.absoluteString ?? "nil",
                        "elapsedSinceIssued": readerLoadElapsedString(since: strongSelf.readerLoadIssuedAt),
                        "estimatedProgress": webView.map { String(format: "%.3f", $0.estimatedProgress) } ?? "nil",
                        "hasSuperview": "\(webView?.superview != nil)",
                        "hasWindow": "\(webView?.window != nil)",
                        "isLoading": "\(webView?.isLoading ?? false)",
                        "requestURL": strongSelf.readerLoadRequestedURL?.absoluteString ?? "nil",
                        "sceneState": readerLoadSceneStateString(for: webView)
                    ]
                )
            }
        }
    }

    @MainActor
    private func cancelContentProcessPrewarm(reason: String? = nil) {
        contentProcessPrewarmGeneration &+= 1
        contentProcessPrewarmTask?.cancel()
        contentProcessPrewarmTask = nil
        guard let reason else { return }
        readerLoadLog(
            "webViewNavigator.prewarmCanceled",
            [
                "currentURL": webView?.url?.absoluteString ?? "nil",
                "elapsed": readerLoadElapsedString(since: contentProcessPrewarmIssuedAt),
                "reason": reason,
                "webViewID": contentProcessPrewarmWebViewID ?? readerLoadObjectIDString(webView)
            ]
        )
    }

    @MainActor
    private func scheduleContentProcessPrewarmIfNeeded(on webView: WKWebView) {
        let webViewID = readerLoadObjectIDString(webView)
        readerLoadLog(
            "webViewNavigator.prewarmSkipped",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "reason": "disabledRealWebViewPrewarm",
                "webViewID": webViewID
            ]
        )
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
                    debugPrint(
                        "# READER navigator.flushPendingRequest.retry.begin",
                        [
                            "navigatorID": self.debugIdentifier ?? "nil",
                            "navigatorObjectID": self.debugObjectID,
                            "url": request.url?.absoluteString ?? "nil",
                            "attempt": currentAttempt
                        ] as [String : Any]
                    )
                }
                guard self.pendingRequest?.url == request.url else { return }
                if webView.window != nil && webView.superview != nil {
                    if self.shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
                        debugPrint(
                            "# READER navigator.flushPendingRequest.retry",
                            [
                                "navigatorID": self.debugIdentifier ?? "nil",
                                "navigatorObjectID": self.debugObjectID,
                                "url": request.url?.absoluteString ?? "nil",
                                "attempt": currentAttempt
                            ] as [String : Any]
                        )
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
                debugPrint(
                    "# READER navigator.flushPendingRequest.retry.exhausted",
                    [
                        "navigatorID": self.debugIdentifier ?? "nil",
                        "navigatorObjectID": self.debugObjectID,
                        "url": request.url?.absoluteString ?? "nil"
                    ] as [String : Any]
                )
            }
            self.pendingRequestLoadTask = nil
        }
    }

    @MainActor
    private func stagePendingRequestThroughAboutBlank(
        _ request: URLRequest,
        on webView: WKWebView,
        diagnosticsReason: String
    ) {
        pendingRequest = request
        readerLoadLog(
            "webViewNavigator.customSchemeTransitionReset",
            [
                "currentURL": webView.url?.absoluteString ?? "nil",
                "reason": diagnosticsReason,
                "requestURL": request.url?.absoluteString ?? "nil"
            ]
        )
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        schedulePendingRequestLoadRetry(
            request: request,
            webView: webView,
            attempt: 1,
            generation: pendingRequestLoadGeneration
        )
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
        if resetInFlightAboutBlankIfNeeded(
            for: request,
            on: webView,
            reason: "issuePendingRequestLoad:\(diagnosticsReason)"
        ) {
            return
        }
        if shouldResetThroughAboutBlankBeforeInternalReaderLoad(
            currentURL: webView.url,
            requestURL: request.url
        ) {
            stagePendingRequestThroughAboutBlank(
                request,
                on: webView,
                diagnosticsReason: diagnosticsReason
            )
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
            debugPrint(
                "# READER navigator.flushPendingRequest.issue",
                [
                    "navigatorID": debugIdentifier ?? "nil",
                    "navigatorObjectID": debugObjectID,
                    "url": request.url?.absoluteString ?? "nil",
                    "webViewURL": webView.url?.absoluteString ?? "nil",
                    "webViewIsLoading": webView.isLoading,
                    "webViewEstimatedProgress": webView.estimatedProgress,
                    "restartIfSameURL": restartIfSameURL,
                    "disposition": String(describing: disposition),
                    "reason": diagnosticsReason
                ] as [String : Any]
            )
        }
        switch disposition {
        case .deferUntilAttached:
            if shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
                debugPrint(
                    "# READER navigator.flushPendingRequest.deferredUntilFullyAttached",
                    [
                        "navigatorID": debugIdentifier ?? "nil",
                        "navigatorObjectID": debugObjectID,
                        "url": request.url?.absoluteString ?? "nil",
                        "reason": diagnosticsReason,
                        "windowAttached": webView.window != nil,
                        "superviewAttached": webView.superview != nil
                ] as [String : Any]
            )
            }
            return
        case .skipAlreadyLoading:
            if shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
                debugPrint(
                    "# READER navigator.flushPendingRequest.skipAlreadyLoading",
                    [
                        "navigatorID": debugIdentifier ?? "nil",
                        "navigatorObjectID": debugObjectID,
                        "url": request.url?.absoluteString ?? "nil",
                        "reason": diagnosticsReason,
                        "webViewURL": webView.url?.absoluteString ?? "nil",
                        "webViewIsLoading": webView.isLoading,
                    "webViewEstimatedProgress": webView.estimatedProgress
                ] as [String : Any]
            )
            }
            let nextGeneration = pendingRequestLoadGeneration
            if shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
                debugPrint(
                    "# READER navigator.flushPendingRequest.restart.fire",
                    [
                        "navigatorID": debugIdentifier ?? "nil",
                        "navigatorObjectID": debugObjectID,
                        "url": request.url?.absoluteString ?? "nil",
                        "reason": diagnosticsReason,
                        "webViewURL": webView.url?.absoluteString ?? "nil",
                        "webViewIsLoading": webView.isLoading,
                        "webViewEstimatedProgress": webView.estimatedProgress
                    ] as [String : Any]
                )
            }
            if webView.url == request.url {
                markReaderLoadIssued(for: request, reason: "reload:\(diagnosticsReason)")
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
            webView.loadFileURL(url, allowingReadAccessTo: url)
        case .loadRequest:
            markReaderLoadIssued(for: request, reason: "loadRequest:\(diagnosticsReason)")
            webView.load(request)
        }
        self.cancelPendingRequestLoadTask()
    }

    @MainActor
    func handleWindowAttachmentChanged(isAttached: Bool, webView: WKWebView) {
        let isReadyForRequest = webView.window != nil && webView.superview != nil
        if shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
            debugPrint(
                "# READER navigator.windowAttachmentChanged",
                [
                    "navigatorID": debugIdentifier ?? "nil",
                    "navigatorObjectID": debugObjectID,
                    "isAttached": isAttached,
                    "isReadyForRequest": isReadyForRequest,
                    "pendingURL": pendingRequest?.url?.absoluteString ?? "nil",
                    "webViewURL": webView.url?.absoluteString ?? "nil"
                ] as [String : Any]
            )
        }
        if isAttached {
            scheduleContentProcessPrewarmIfNeeded(on: webView)
        }
        guard isAttached, let request = pendingRequest else { return }
        if shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
            debugPrint(
                "# READER navigator.flushPendingRequest.attached",
                [
                    "navigatorID": debugIdentifier ?? "nil",
                    "navigatorObjectID": debugObjectID,
                    "url": request.url?.absoluteString ?? "nil"
                ] as [String : Any]
            )
        }
        guard webView.navigationDelegate != nil else {
            if shouldLoadFallbackOnAttach || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" || ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" {
                debugPrint(
                    "# READER navigator.flushPendingRequest.deferredUntilDelegate",
                    [
                        "navigatorID": debugIdentifier ?? "nil",
                        "navigatorObjectID": debugObjectID,
                        "url": request.url?.absoluteString ?? "nil"
                    ] as [String : Any]
                )
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
            if shouldLogDiagnostics || !shouldLoadFallbackOnAttach {
                debugPrint(
                    "# READER navigator.attach",
                    [
                        "navigatorID": debugIdentifier ?? "nil",
                        "navigatorObjectID": debugObjectID,
                        "hasAttachedWebView": webView != nil,
                        "hasPendingHTML": pendingHTML != nil,
                        "hasPendingRequest": pendingRequest != nil,
                        "hasPendingDataLoad": pendingDataLoad != nil
                    ] as [String : Any]
                )
            }
            if oldValue !== webView {
                cancelContentProcessPrewarm(reason: "webViewBindingChanged")
                contentProcessPrewarmIssuedAt = nil
                contentProcessPrewarmCompletedAt = nil
                contentProcessPrewarmWebViewID = nil
            }
            guard let webView else { return }
            if let request = pendingRequest {
                cancelAttachFallbackLoadTask(reason: "pendingRequestFlushedOnAttach")
                if shouldLogDiagnostics || !shouldLoadFallbackOnAttach {
                    debugPrint(
                        "# READER navigator.flushPendingRequest",
                        [
                            "navigatorID": debugIdentifier ?? "nil",
                            "navigatorObjectID": debugObjectID,
                            "url": request.url?.absoluteString ?? "nil"
                        ] as [String : Any]
                    )
                }
                if webView.window == nil || webView.superview == nil {
                    if shouldLogDiagnostics || !shouldLoadFallbackOnAttach {
                        debugPrint(
                            "# READER navigator.flushPendingRequest.deferred",
                            [
                                "navigatorID": debugIdentifier ?? "nil",
                                "navigatorObjectID": debugObjectID,
                                "url": request.url?.absoluteString ?? "nil",
                                "windowAttached": webView.window != nil,
                                "superviewAttached": webView.superview != nil
                            ] as [String : Any]
                        )
                    }
                    return
                }
                issuePendingRequestLoad(request, on: webView, restartIfSameURL: true, diagnosticsReason: "webViewDidSet.attached")
                return
            }
            if let pendingDataLoad {
                cancelAttachFallbackLoadTask(reason: "pendingDataLoadFlushedOnAttach")
                if shouldLogDiagnostics || !shouldLoadFallbackOnAttach {
                    debugPrint(
                        "# READER navigator.flushPendingDataLoad",
                        [
                            "navigatorID": debugIdentifier ?? "nil",
                            "navigatorObjectID": debugObjectID,
                            "bytes": pendingDataLoad.data.count,
                            "mimeType": pendingDataLoad.mimeType,
                            "baseURL": pendingDataLoad.baseURL.absoluteString
                        ] as [String : Any]
                    )
                }
                webView.load(
                    pendingDataLoad.data,
                    mimeType: pendingDataLoad.mimeType,
                    characterEncodingName: pendingDataLoad.characterEncodingName,
                    baseURL: pendingDataLoad.baseURL
                )
                self.pendingDataLoad = nil
                return
            }
            if let pendingHTML {
                cancelAttachFallbackLoadTask(reason: "pendingHTMLFlushedOnAttach")
                if shouldLogDiagnostics || !shouldLoadFallbackOnAttach {
                    debugPrint(
                        "# READER navigator.flushPendingHTML",
                        [
                            "navigatorID": debugIdentifier ?? "nil",
                            "navigatorObjectID": debugObjectID,
                            "htmlLength": pendingHTML.html.count,
                            "baseURL": pendingHTML.baseURL?.absoluteString ?? "nil"
                        ] as [String : Any]
                    )
                }
                webView.loadHTMLString(pendingHTML.html, baseURL: pendingHTML.baseURL)
                self.pendingHTML = nil
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
            if resetInFlightAboutBlankIfNeeded(for: request, on: webView, reason: "navigator.load") {
                return
            }
            if shouldResetThroughAboutBlankBeforeInternalReaderLoad(
                currentURL: webView.url,
                requestURL: request.url
            ) {
                stagePendingRequestThroughAboutBlank(
                    request,
                    on: webView,
                    diagnosticsReason: "navigator.load"
                )
                return
            }
            if let url = request.url, url.isFileURL {
                markReaderLoadIssued(for: request, reason: "navigator.loadFileURL")
                webView.loadFileURL(url, allowingReadAccessTo: url)
            } else {
                markReaderLoadIssued(for: request, reason: "navigator.loadRequest")
                webView.load(request)
            }
        } else {
            pendingRequest = request
        }
    }
    
    @MainActor
    public func load(_ data: Data, mimeType: String, characterEncodingName: String, baseURL: URL) {
        lastLoadedDataLoad = (data: data, mimeType: mimeType, characterEncodingName: characterEncodingName, baseURL: baseURL)
        lastLoadedRequest = nil
        lastLoadedHTML = nil
        cancelAttachFallbackLoadTask(reason: "explicitDataLoad")
        cancelReaderLoadHeartbeat(reason: "explicitDataLoad")
        cancelContentProcessPrewarm(reason: "explicitDataLoad")
        cancelPreProvisionalWarningTask()
        readerLoadTraceID = UUID()
        readerLoadRequestedAt = Date()
        readerLoadRequestedURL = baseURL
        readerLoadIssuedAt = readerLoadRequestedAt
        readerLoadDirectDataReturnedAt = nil
        readerLoadProvisionalStartedAt = nil
        readerLoadCommittedAt = nil
        syncActiveInternalReaderLoaderSignal()
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
            if !shouldLoadFallbackOnAttach {
            }
            pendingDataLoad = (data: data, mimeType: mimeType, characterEncodingName: characterEncodingName, baseURL: baseURL)
            return
        }
        debugPrint(
            "# READER navigator.load.data",
            "bytes=\(data.count)",
            "mimeType=\(mimeType)",
            "baseURL=\(baseURL.absoluteString)"
        )
        readerLoadLog(
            "webViewNavigator.dataLoadDirect",
            [
                "baseURL": baseURL.absoluteString,
                "bytes": "\(data.count)",
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
        readerLoadDirectDataReturnedAt = Date()
        readerLoadLog(
            "webViewNavigator.dataLoadReturned",
            [
                "baseURL": baseURL.absoluteString,
                "elapsedSinceDataLoadIssued": readerLoadElapsedString(since: readerLoadIssuedAt, now: readerLoadDirectDataReturnedAt ?? Date())
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
        cancelReaderLoadHeartbeat(reason: "explicitHTMLLoad")
        cancelContentProcessPrewarm(reason: "explicitHTMLLoad")
        cancelPreProvisionalWarningTask()
        readerLoadTraceID = UUID()
        readerLoadRequestedAt = Date()
        readerLoadRequestedURL = baseURL
        readerLoadIssuedAt = readerLoadRequestedAt
        readerLoadDirectDataReturnedAt = nil
        readerLoadProvisionalStartedAt = nil
        readerLoadCommittedAt = nil
        syncActiveInternalReaderLoaderSignal()
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
            if !shouldLoadFallbackOnAttach {
            }
            pendingHTML = (html: html, baseURL: baseURL)
            return
        }
        if !shouldLoadFallbackOnAttach {
        }
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
    public func forceClearLoadingIndicators(reason: String, pageURL: URL? = nil) {
        forceClearLoadingIndicatorsHandler?(reason, pageURL)
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

    @MainActor
    public func attachedWebViewHasReadyNavigationState() -> Bool {
        guard let webView else { return false }
        return webView.window != nil
            && webView.superview != nil
            && webView.navigationDelegate != nil
            && !webView.isLoading
    }

    public override init() {
        super.init()
    }
}

enum ScriptCallerError: Error {
    case evaluationTimedOut
}

public enum WebViewScriptCallerSnapshotError: Error, Equatable, Sendable {
    case unavailable
    case emptyRect
    case captureFailed(String)
    case imageConversionFailed
}

extension WebViewScriptCallerSnapshotError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "No mounted WKWebView is available for snapshot capture."
        case .emptyRect:
            return "The requested snapshot rect is empty or outside the WKWebView bounds."
        case .captureFailed(let message):
            return "WKWebView snapshot capture failed: \(message)"
        case .imageConversionFailed:
            return "WKWebView snapshot capture did not produce a CGImage."
        }
    }
}

public struct WebViewSnapshotImage: @unchecked Sendable {
    /// Captured bitmap.
    public let cgImage: CGImage
    /// Captured image bounds in pixels. This matches the CGImage pixel dimensions.
    public let bounds: CGRect
    /// Pixel-per-point scale represented by the returned image.
    public let scale: CGFloat
    /// Source rect in WKWebView view-coordinate points.
    public let capturedRect: CGRect

    public init(cgImage: CGImage, bounds: CGRect, scale: CGFloat, capturedRect: CGRect) {
        self.cgImage = cgImage
        self.bounds = bounds
        self.scale = scale
        self.capturedRect = capturedRect
    }
}

@MainActor
private func makeWebViewSnapshotCapture(
    for webView: WKWebView
) -> @MainActor @Sendable (CGRect?) async throws -> WebViewSnapshotImage {
    return { [weak webView] requestedRect in
        guard let webView else {
            throw WebViewScriptCallerSnapshotError.unavailable
        }

        let capturedRect = try WebViewScriptCaller.resolvedSnapshotRect(requestedRect, in: webView.bounds)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = capturedRect
        // WKSnapshotConfiguration.snapshotWidth is in points. Requesting the rect width preserves
        // the native backing scale while keeping the returned bitmap aligned with view coordinates.
        configuration.snapshotWidth = NSNumber(value: Double(capturedRect.width))

        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WebViewSnapshotPlatformImage, Error>) in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: WebViewScriptCallerSnapshotError.captureFailed(error.localizedDescription))
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: WebViewScriptCallerSnapshotError.imageConversionFailed)
                }
            }
        }

        guard let cgImage = webViewSnapshotCGImage(from: image) else {
            throw WebViewScriptCallerSnapshotError.imageConversionFailed
        }

        let fallbackScale = webViewSnapshotNativeScale(for: webView)
        let scale = WebViewScriptCaller.resolvedSnapshotScale(
            cgImage: cgImage,
            capturedRect: capturedRect,
            fallbackScale: fallbackScale
        )
        let bounds = CGRect(
            origin: .zero,
            size: CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        )
        return WebViewSnapshotImage(
            cgImage: cgImage,
            bounds: bounds,
            scale: scale,
            capturedRect: capturedRect
        )
    }
}

private func webViewSnapshotCGImage(from image: WebViewSnapshotPlatformImage) -> CGImage? {
#if os(iOS)
    image.cgImage
#elseif os(macOS)
    var proposedRect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
#endif
}

@MainActor
private func webViewSnapshotNativeScale(for webView: WKWebView) -> CGFloat {
#if os(iOS)
    return webView.window?.screen.scale ?? UIScreen.main.scale
#elseif os(macOS)
    return webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
#endif
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
    /// Indicates whether the backing WKWebView has registered a snapshot capture caller.
    @Published public private(set) var hasSnapshotCapture = false
    private var asyncCallerReadinessGeneration = 0
    private var snapshotCaptureReadinessGeneration = 0

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
    var snapshotCapture: (@MainActor @Sendable (CGRect?) async throws -> WebViewSnapshotImage)? = nil {
        didSet {
            snapshotCaptureReadinessGeneration += 1
            let generation = snapshotCaptureReadinessGeneration
            let isReady = snapshotCapture != nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.snapshotCaptureReadinessGeneration == generation else { return }
                if self.hasSnapshotCapture != isReady {
                    self.hasSnapshotCapture = isReady
                }
            }
        }
    }
    var unsafeCaller: (@MainActor @Sendable (String, WKFrameInfo?, WKContentWorld?) -> Void)? = nil
    
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
                        debugPrint(
                            "# READER scriptCaller.error.resultTypeUnsupported.coerced",
                            "frameURL=\(frame?.request.url?.absoluteString ?? "<nil>")",
                            "note=coerced to string for href"
                        )
                    } catch {
                        primaryError = error
                        nsError = error as NSError
                    }
                }
                if !handled {
                    // Treat unsupported result types as a benign nil so DOM snapshot can continue.
                    result = nil
                    handled = true
                    debugPrint(
                        "# READER scriptCaller.error.resultTypeUnsupported",
                        "frameURL=\(frame?.request.url?.absoluteString ?? "<nil>")",
                        "jsPrefix=\(js.prefix(80))",
                        "note=treated as nil"
                    )
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
                debugPrint(
                    "# READER scriptCaller.error.invalidFrame",
                    "frameURL=\(frame?.request.url?.absoluteString ?? "<nil>")",
                    "jsPrefix=\(js.prefix(80))",
                    "note=cleared stale frame; returning nil"
                )
            }
            if !handled {
                debugPrint(
                    "# READER scriptCaller.error",
                    "code=\(nsError.code)",
                    "domain=\(nsError.domain)",
                    "description=\(nsError.localizedDescription)",
                    "frameURL=\(frame?.request.url?.absoluteString ?? "<nil>")",
                    "jsPrefix=\(js.prefix(80))"
                )
                throw primaryError
            }
        }
        return normalizeJavaScriptResult(result)
    }

    @MainActor
    public func captureSnapshot(rect: CGRect? = nil) async throws -> WebViewSnapshotImage {
        guard let snapshotCapture else {
            throw WebViewScriptCallerSnapshotError.unavailable
        }
        return try await snapshotCapture(rect)
    }

    nonisolated static func resolvedSnapshotRect(_ requestedRect: CGRect?, in bounds: CGRect) throws -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else {
            throw WebViewScriptCallerSnapshotError.emptyRect
        }

        let resolvedRequest: CGRect
        if let requestedRect, !requestedRect.isNull {
            resolvedRequest = requestedRect
        } else {
            resolvedRequest = bounds
        }

        let clamped = resolvedRequest.standardized.intersection(bounds.standardized)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else {
            throw WebViewScriptCallerSnapshotError.emptyRect
        }
        return clamped
    }

    nonisolated static func resolvedSnapshotScale(cgImage: CGImage, capturedRect: CGRect, fallbackScale: CGFloat) -> CGFloat {
        guard capturedRect.width > 0 else {
            return max(fallbackScale, 1)
        }
        let imageScale = CGFloat(cgImage.width) / capturedRect.width
        guard imageScale.isFinite, imageScale > 0 else {
            return max(fallbackScale, 1)
        }
        return imageScale
    }

    @MainActor
    public func evaluateJavaScriptUnsafe(
        _ js: String,
        in frame: WKFrameInfo? = nil,
        duplicateInMultiTargetFrames: Bool = false,
        in world: WKContentWorld? = nil
    ) {
        guard let unsafeCaller else {
            print("No unsafeCaller set for WebViewScriptCaller \(id)")
            return
        }

        unsafeCaller(js, frame, world)

        guard duplicateInMultiTargetFrames else { return }
        for (uuid, targetFrame) in multiTargetFrames.filter({ !$0.value.isMainFrame }) {
            if targetFrame == frame { continue }
            unsafeCaller(js, targetFrame, world)
            if targetFrame.request.url == nil {
                multiTargetFrames.removeValue(forKey: uuid)
            }
        }
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
            debugPrint(
                "# READER scriptCaller.frame.nilURL",
                "uuid=\(uuid)",
                "debug=\(frame.debugDescription)",
                "isMain=\(frame.isMainFrame)"
            )
        }
        debugPrint(
            "# READER scriptCaller.frame.add",
            "uuid=\(uuid)",
            "url=\(frame.request.url?.absoluteString ?? "<nil>")",
            "canonical=\(canonicalFrameKey(for: resolvedCanonicalURL) ?? "<nil>")",
            "isMain=\(frame.isMainFrame)",
            "inserted=\(inserted)"
        )
        return inserted
    }
    
    @MainActor
    public func removeAllMultiTargetFrames() {
        if !multiTargetFrames.isEmpty || !framesByCanonicalURL.isEmpty {
            debugPrint(
                "# READER scriptCaller.frame.clear",
                "byUUID=\(multiTargetFrames.count)",
                "byCanonical=\(framesByCanonicalURL.count)"
            )
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
        const printHandler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.print;
        if (!handler || typeof handler.postMessage !== "function") { return; }
        let stateMachine = { stopped: false, attempts: 0 };
        let rafHandle = { value: 0 };
        let timeoutHandle = { value: 0 };
        let lastTextVisibleSignature = null;
        const isEbookDocument = (() => {
            try {
                const href = String(window.location?.href || "");
                if (href.startsWith("ebook://")) { return true; }
                return document.body?.dataset?.isEbook === "true";
            } catch (_error) {
                return false;
            }
        })();
        let observer = new MutationObserver(() => {
            postState("mutation");
        });
        function hiddenReason(node) {
            if (!node || typeof window.getComputedStyle !== "function") { return null; }
            let current = node;
            while (current) {
                const style = window.getComputedStyle(current);
                const opacity = Number.parseFloat(style.opacity || "1");
                if (style.visibility === "hidden") { return "visibility:hidden"; }
                if (style.display === "none") { return "display:none"; }
                if (current.hidden) { return "hidden-attr"; }
                if (opacity <= 0.01) { return "opacity"; }
                current = current.parentElement ?? null;
            }
            return null;
        }
        function trackingStateForSegment(segment) {
            if (!segment?.classList) { return "unknown"; }
            if (segment.classList.contains("mnb-known")) { return "known"; }
            if (segment.classList.contains("mnb-learning") || segment.classList.contains("mnb-card-created")) {
                return "learning";
            }
            if (segment.classList.contains("mnb-read")) { return "familiar"; }
            if (segment.classList.contains("mnb-suspended")) { return "suspended"; }
            return "unknown";
        }
        function summarizeSegment(segment) {
            if (!segment) { return null; }
            return {
                id: segment.id ?? null,
                state: trackingStateForSegment(segment),
                className: segment.className || null,
                textSample: typeof segment.textContent === "string" ? segment.textContent.trim().slice(0, 48) : null,
                hasSurface: segment.querySelector("mnb-sur") !== null,
                hiddenReason: hiddenReason(segment),
                jlptLevel: segment.dataset?.jlptLevel ?? null,
                lookup: segment.dataset?.jmdictSearchString ?? null
            };
        }
        function summarizeSettings(body, html) {
            return {
                colorScheme: body?.dataset?.manabiColorScheme ?? null,
                lightTheme: body?.dataset?.manabiLightTheme ?? null,
                darkTheme: body?.dataset?.manabiDarkTheme ?? null,
                trackingEnabled: body?.dataset?.manabiTrackingEnabled ?? null,
                trackingHighlightsEnabled: body?.dataset?.manabiTrackingHighlightsEnabled ?? null,
                learningStatusVisibility: body?.dataset?.manabiLearningStatusVisibility ?? null,
                showFamiliar: body?.dataset?.manabiShowFamiliar ?? null,
                showKnown: body?.dataset?.manabiShowKnown ?? null,
                lookupHighlightMode: body?.dataset?.manabiLookupHighlightMode ?? null,
                furiganaEnabled: body?.dataset?.manabiFuriganaEnabled ?? null,
                readerRenderReady: body?.dataset?.manabiReaderRenderReady ?? html?.dataset?.manabiReaderRenderReady ?? null,
                fontPending: html?.dataset?.manabiFontPending ?? null,
                fontReady: html?.dataset?.manabiFontReady ?? null,
                layoutComplete: html?.dataset?.manabiLayoutComplete ?? null,
                subscriptionActive: body?.dataset?.manabiSubscriptionIsActive ?? null
            };
        }
        function summarizeTracking(readerContent) {
            const root = readerContent ?? document;
            const segments = Array.from(root.querySelectorAll("mnb-seg"));
            const surfaces = Array.from(root.querySelectorAll("mnb-sur"));
            const trackedWords = (typeof document.manabi_trackedWords === "object" && document.manabi_trackedWords) ? document.manabi_trackedWords : null;
            const trackedWordKeys = trackedWords ? Object.keys(trackedWords) : [];
            const counts = {
                segments: segments.length,
                surfaces: surfaces.length,
                familiar: 0,
                learning: 0,
                known: 0,
                suspended: 0,
                unknown: 0,
                hiddenSegments: 0,
                visibleSegments: 0,
                segmentsWithoutSurface: 0
            };
            for (const segment of segments) {
                const state = trackingStateForSegment(segment);
                counts[state] = (counts[state] ?? 0) + 1;
                if (hiddenReason(segment)) {
                    counts.hiddenSegments += 1;
                } else {
                    counts.visibleSegments += 1;
                }
                if (!segment.querySelector("mnb-sur")) {
                    counts.segmentsWithoutSurface += 1;
                }
            }
            const samples = segments.slice(0, 8).map(summarizeSegment);
            return {
                counts,
                trackedWords: {
                    count: trackedWordKeys.length,
                    sampleEntryIDs: trackedWordKeys.slice(0, 8)
                },
                samples
            };
        }
        function diagnoseTextVisibleIssue(settings, tracking, state) {
            const counts = tracking.counts;
            const diagnoses = [];
            if (!state?.hasReaderContent) {
                diagnoses.push("reader-content-missing");
                return diagnoses;
            }
            if (settings.fontPending === "1" && settings.fontReady !== "1") {
                diagnoses.push("font-gate-still-pending");
            }
            if (settings.layoutComplete === "false") {
                diagnoses.push("layout-still-building");
            }
            if (counts.segments === 0) {
                diagnoses.push("no-tracked-segments-in-live-dom");
                return diagnoses;
            }
            if (counts.applied === 0) {
                diagnoses.push("tracking-classes-not-applied");
            }
            if ((tracking.trackedWords?.count ?? 0) === 0) {
                diagnoses.push("no-tracked-words-in-js");
            }
            if (counts.surfaces === 0) {
                diagnoses.push("no-mnb-sur-nodes-in-live-dom");
            }
            if (counts.segmentsWithoutSurface === counts.segments && counts.segments > 0) {
                diagnoses.push("all-segments-lost-surface-wrappers");
            }
            if ((tracking.trackedWords?.count ?? 0) > 0 && counts.applied === 0) {
                diagnoses.push("tracked-words-loaded-but-no-segment-status-applied");
            }
            if (counts.hiddenSegments === counts.segments && counts.segments > 0) {
                diagnoses.push("all-tracked-segments-hidden");
            }
            if (counts.learning === 0 && counts.unknown === 0 && counts.familiar > 0 && settings.showFamiliar !== "true") {
                diagnoses.push("only-familiar-segments-present-and-familiar-highlights-disabled");
            }
            if (counts.learning === 0 && counts.unknown === 0 && counts.known > 0 && settings.showKnown !== "true") {
                diagnoses.push("known-segments-present-but-known-highlights-disabled");
            }
            if (diagnoses.length === 0) {
                diagnoses.push("tracked-segments-present-check-css-rendering");
            }
            return diagnoses;
        }
        function postTextVisible(reason, state) {
            try {
                if (!printHandler || typeof printHandler.postMessage !== "function") { return; }
                const body = document.body;
                const html = document.documentElement;
                const readerContent = document.getElementById('reader-content');
                const tracking = summarizeTracking(readerContent);
                const settings = summarizeSettings(body, html);
                const payload = {
                    message: "# TEXTVISIBLE",
                    probeVersion: 2,
                    reason,
                    href: window.location.href,
                    readyState: document.readyState,
                    state: {
                        hasReaderContent: !!readerContent,
                        hasReaderRenderReady: !!state?.hasReaderRenderReady,
                        bodyClassName: body?.className ?? null
                    },
                    settings,
                    tracking,
                    diagnosis: diagnoseTextVisibleIssue(settings, tracking, state)
                };
                const signature = JSON.stringify(payload);
                if (signature === lastTextVisibleSignature) { return; }
                lastTextVisibleSignature = signature;
                printHandler.postMessage(payload);
            } catch (_error) {}
        }
        function currentState(reason) {
            return {
                href: window.location.href,
                readyState: document.readyState,
                hasBody: !!document.body,
                hasReaderContent: !!document.getElementById('reader-content'),
                hasReadabilityGlobal: typeof window.manabi_readability === 'function',
                hasReaderRenderReady:
                    (document.documentElement?.dataset?.manabiReaderRenderReady === '1'
                    || document.body?.dataset?.manabiReaderRenderReady === '1')
                    && !!document.getElementById('reader-content')
                    && (document.documentElement?.dataset?.manabiFontPending ?? null) !== '1'
                    && window.getComputedStyle(document.body).visibility !== 'hidden'
                    && window.getComputedStyle(document.body).display !== 'none'
                    && Number.parseFloat(window.getComputedStyle(document.body).opacity || '1') > 0.01,
                reason
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
            postTextVisible(reason, state);
            if (state.hasReaderRenderReady) {
                stopPolling();
                return true;
            }
            return false;
        }
        window.__manabiPostReaderDocStateEvent = function(reason) {
            return postState(reason || "event");
        };
        if (isEbookDocument) {
            return;
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
                attributeFilter: ["data-manabi-reader-render-ready"]
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

    const interactiveSelectors = '#nav-bar,#progress-wrapper,.nav-relocate-button,.nav-section-progress,a[href],button,input,textarea,select,summary,label,[role="button"],[role="link"],[role="menuitem"],[role="tab"],[contenteditable="true"]';
    const MOVE_THRESHOLD = 8;
    const LONG_PRESS_THRESHOLD_MS = 450;
    const activePointers = new Map();

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
    }

    window.__manabiSuppressCurrentUnhandledTapHideNavigation = function(clientX, clientY) {
        const x = Number(clientX);
        const y = Number(clientY);
        if (!Number.isFinite(x) || !Number.isFinite(y)) {
            return false;
        }
        for (const entry of activePointers.values()) {
            if (Math.hypot(x - entry.startX, y - entry.startY) <= MOVE_THRESHOLD) {
                entry.suppressUnhandledTap = true;
                return true;
            }
        }
        return false;
    };

    window.__manabiSuppressActiveUnhandledTapHideNavigation = function() {
        let markedCount = 0;
        for (const entry of activePointers.values()) {
            entry.suppressUnhandledTap = true;
            markedCount += 1;
        }
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
            return;
        }
        const duration = performance.now() - entry.startTime;
        const finalDX = (event.clientX ?? entry.startX) - entry.startX;
        const finalDY = (event.clientY ?? entry.startY) - entry.startY;
        if (Math.hypot(finalDX, finalDY) > MOVE_THRESHOLD) {
            entry.moved = true;
        }
        const newSelection = selectionText();
        const selectionChanged = newSelection.length > 0 && newSelection !== entry.startSelection;
        if (entry.moved || duration > LONG_PRESS_THRESHOLD_MS || selectionChanged) {
            return;
        }
        if (entry.suppressUnhandledTap === true) {
            return;
        }
        const suppressUntil = Number(window.__manabiSuppressUnhandledTapHideNavigationUntil || 0);
        if (suppressUntil > Date.now()) {
            return;
        }
        const targetClosestSegment = event.target?.closest?.('mnb-seg')?.getAttribute?.('id') ?? null;
        if (targetClosestSegment) {
            return;
        }
        window.webkit.messageHandlers[handlerName].postMessage({
            frame: window === window.top ? 'top' : 'child',
            targetTag: event.target?.tagName?.toLowerCase?.() ?? null,
            targetClosestSegment,
            clientX: event.clientX ?? null,
            clientY: event.clientY ?? null,
            reason: 'pointerUpBlankTap'
        });
    }

    function handlePointerCancel(event) {
        activePointers.delete(event.pointerId);
    }

    let lastScrollPosition = { x: window.scrollX || 0, y: window.scrollY || 0 };
    let accumulatedScroll = { value: 0 };
    let lastPostedScrollHidden = { value: null };
    const SCROLL_THRESHOLD = 24;
    function postHideNavigationForScroll(hidden, reason) {
        if (lastPostedScrollHidden.value === hidden) {
            return;
        }
        lastPostedScrollHidden.value = hidden;
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
        if (Math.abs(dx) > Math.abs(dy)) {
            return;
        }

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
    public static let transparentNonScrollingOverlay = WebViewConfig(
        javaScriptEnabled: true,
        allowsBackForwardNavigationGestures: false,
        dataDetectorsEnabled: false,
        isScrollEnabled: false,
        isOpaque: false,
        backgroundColor: .clear,
        adjustsScrollViewContentInsetsForSafeArea: false,
        nativeLookupHitTestingEnabled: false,
        paginationConfiguration: .disabled
    )
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
    public var onDidMoveToWindow: ((Bool) -> Void)?

    public override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

#if os(macOS)
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onDidMoveToWindow?(window != nil || superview != nil)
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onDidMoveToWindow?(window != nil || superview != nil)
    }
#endif

#if os(iOS)
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        applyTopScrollEdgeEffectHidden(hidesTopScrollEdgeEffect, to: self)
        onDidMoveToWindow?(window != nil || superview != nil)
    }

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        applyTopScrollEdgeEffectHidden(hidesTopScrollEdgeEffect, to: self)
        onDidMoveToWindow?(window != nil || superview != nil)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        applyTopScrollEdgeEffectHidden(hidesTopScrollEdgeEffect, to: self)
    }

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
    private var lastPassThroughLogAt: TimeInterval = 0
    private let pressedSegmentLayer = CAShapeLayer()
    private var clearPressedSegmentWorkItem: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
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
        let path = CGMutablePath()
        var visualRects: [CGRect] = []
        var strokeRects: [CGRect] = []
        for rect in target.projectedRectsForCurrentHitTestOverlay {
            let visualRect = Self.pressVisualRect(for: rect)
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

    private static func pressVisualRect(for rect: CGRect) -> CGRect {
        var visualRect = rect
        visualRect.origin.y -= PressedSegmentStyle.lookupAttachmentTopExpansion
        visualRect.size.height += PressedSegmentStyle.lookupAttachmentTopExpansion
        return visualRect
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

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let target = store?.hitTarget(at: point, in: bounds.size)
        if let target {
        } else {
            let now = Date().timeIntervalSinceReferenceDate
            if now - lastPassThroughLogAt > 0.25 {
                lastPassThroughLogAt = now
            }
        }
        return false
    }
}

private final class NativeLookupHitTestTapGestureRecognizer: UIGestureRecognizer {
    private static let segmentTapMovementTolerance: CGFloat = 14
    private static let segmentLongPressDriftTolerance: CGFloat = 24
    private static let segmentSwipeMovementTolerance: CGFloat = 10
    private static let segmentTapMaximumDuration: TimeInterval = 0.42
    private static let segmentTapPressedHandoffDuration: TimeInterval = 0.16

    weak var store: WebViewNativeLookupHitTestStore?
    weak var coordinateView: NativeLookupHitTestOverlayView?
    private var touchStartPoint: CGPoint?
    private var touchStartTime: TimeInterval?
    private var touchStartTarget: WebViewNativeLookupHitTarget?
    private var touchStartWasActiveTarget = false
    private weak var touchStartOverlay: NativeLookupHitTestOverlayView?
    private var tapExpirationWorkItem: DispatchWorkItem?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
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
        let coordinateViewWindowOrigin = coordinateView.convert(CGPoint.zero, to: nil)
        guard let target = store?.hitTarget(
            at: point,
            in: coordinateView.bounds.size,
            coordinateViewWindowOrigin: coordinateViewWindowOrigin
        ) else {
            logTouchDeliveryVerdict(
                stage: "touchesBegan.noSegmentTarget",
                verdict: "passThrough.allowed",
                reason: "noSegmentTarget",
                point: point,
                coordinateView: coordinateView,
                extra: [
                    "nearest": store?.diagnostics(
                        at: point,
                        limit: 3,
                        in: coordinateView.bounds.size,
                        coordinateViewWindowOrigin: coordinateViewWindowOrigin
                    ) as Any,
                    "segmentTargetTouchesReachWebKit": true,
                ]
            )
            state = .failed
            return
        }
        logTouchDeliveryVerdict(
            stage: "touchesBegan.nativeCandidate",
            verdict: "pending.nativeRecognizerHoldingWebKitTouches",
            reason: "segmentTarget",
            target: target,
            point: point,
            coordinateView: coordinateView,
            extra: [
                "segmentTargetTouchesReachWebKit": "pendingTapDecision",
            ]
        )
        touchStartPoint = point
        touchStartTime = event.timestamp
        touchStartTarget = target
        store?.beginNativeTouchStream(on: target)
        let activeLookupElementID = MainActor.assumeIsolated {
            store?.activeLookupElementID?()
        }
        let activeHighlightElementID = store?.activeElementID
        let hadActiveLookup = activeLookupElementID != nil
        touchStartWasActiveTarget =
            activeLookupElementID == target.elementID
            || activeHighlightElementID == target.elementID
        touchStartOverlay = coordinateView
        touchStartOverlay?.showPressedTarget(target)
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
                    "lookupDispatchedOnTouchDown": false,
                    "completedOnTouchDown": false,
                    "segmentTargetTouchesReachWebKit": "pendingTapDecision",
                ]
            )
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
                    "segmentTargetTouchesReachWebKit": "pendingTapDecision",
                ]
            )
        }
        tapExpirationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.state == .possible else { return }
            self.failGesture(reason: "timeout")
        }
        tapExpirationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.segmentTapMaximumDuration, execute: workItem)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start = touchStartPoint,
              let touch = touches.first,
              let coordinateView else { return }
        let point = touch.location(in: coordinateView)
        let dx = point.x - start.x
        let dy = point.y - start.y
        let movement = hypot(dx, dy)
        let horizontalMovement = abs(dx)
        let verticalMovement = abs(dy)
        let isSwipeLikeMovement =
            horizontalMovement > Self.segmentSwipeMovementTolerance
            && horizontalMovement > verticalMovement * 1.2
        let exceededLongPressDrift = movement > Self.segmentLongPressDriftTolerance
        if isSwipeLikeMovement || exceededLongPressDrift {
            failGesture(reason: "movement", payload: [
                "start": Self.debugPointString(start),
                "point": Self.debugPointString(point),
                "movement": movement,
                "dx": dx,
                "dy": dy,
                "tapTolerance": Self.segmentTapMovementTolerance,
                "longPressDriftTolerance": Self.segmentLongPressDriftTolerance,
                "swipeMovementTolerance": Self.segmentSwipeMovementTolerance,
                "isSwipeLikeMovement": isSwipeLikeMovement,
                "exceededLongPressDrift": exceededLongPressDrift,
            ])
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start = touchStartPoint,
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
        guard duration <= Self.segmentTapMaximumDuration else {
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
        let movement = hypot(point.x - start.x, point.y - start.y)
        guard movement <= Self.segmentTapMovementTolerance else {
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
                    "segmentTargetTouchesReachWebKit": true,
                ]
            )
            resetTrackingState()
            state = .failed
            return
        }
        if touchStartWasActiveTarget {
            MainActor.assumeIsolated {
                store?.onActiveTargetTouchDown?(target)
            }
        } else {
            let coordinateViewWindowOrigin = coordinateView.convert(CGPoint.zero, to: nil)
            guard store?.handleTap(
                on: target,
                at: point,
                in: coordinateView.bounds.size,
                coordinateViewWindowOrigin: coordinateViewWindowOrigin
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
                        "segmentTargetTouchesReachWebKit": true,
                    ]
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
                "lookupDispatchedOnTouchDown": false,
                "segmentTargetTouchesReachWebKit": "touchStreamMayArrive_clickRecognizerBlocked",
                "webkitTapRecognizersRequireNativeLookupFailure": true,
            ]
        )
        if touchStartWasActiveTarget {
            touchStartOverlay?.clearPressedTarget()
        } else {
            touchStartOverlay?.clearPressedTarget(after: Self.segmentTapPressedHandoffDuration)
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

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func reset() {
        if state == .possible {
            dispatchPendingNativeLookupFromResetIfNeeded()
        }
        resetTrackingState()
    }

    private func dispatchPendingNativeLookupFromResetIfNeeded() {
        guard let target = touchStartTarget,
              let point = touchStartPoint,
              let coordinateView else { return }
        guard Self.point(point, isInside: target),
              store?.hasActiveWebTextSelection != true else {
            touchStartOverlay?.clearPressedTarget()
            store?.onTouchDownHitCancelled?(target)
            return
        }
        if touchStartWasActiveTarget {
            store?.onActiveTargetTouchDown?(target)
            touchStartOverlay?.clearPressedTarget()
            return
        }
        let didDispatchLookup = store?.handleTap(
            on: target,
            at: point,
            in: coordinateView.bounds.size
        ) == true
        if didDispatchLookup {
            touchStartOverlay?.clearPressedTarget(after: Self.segmentTapPressedHandoffDuration)
        } else {
            touchStartOverlay?.clearPressedTarget()
            store?.onTouchDownHitCancelled?(target)
        }
    }

    private func resetTrackingState(clearPressedTarget: Bool = true) {
        tapExpirationWorkItem?.cancel()
        tapExpirationWorkItem = nil
        touchStartPoint = nil
        touchStartTime = nil
        touchStartTarget = nil
        touchStartWasActiveTarget = false
        store?.finishNativeTouchStream(reason: "resetTrackingState")
        if clearPressedTarget {
            touchStartOverlay?.clearPressedTarget()
        }
        touchStartOverlay = nil
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
        var payload = extra
        payload["stage"] = stage
        payload["verdict"] = verdict
        payload["reason"] = reason
        payload["recognizerState"] = "\(state.rawValue)"
        payload["recognizerViewType"] = view.map { String(describing: type(of: $0)) } ?? "nil"
        payload["coordinateViewType"] = coordinateView.map { String(describing: type(of: $0)) } ?? "nil"
        payload["recognizerAttachedToCoordinateView"] = (view === coordinateView)
        payload["delaysTouchesBegan"] = delaysTouchesBegan
        payload["delaysTouchesEnded"] = delaysTouchesEnded
        payload["cancelsTouchesInView"] = cancelsTouchesInView
        if let point {
            payload["point"] = Self.debugPointString(point)
        }
        if let coordinateView {
            payload["containerSize"] = Self.debugSizeString(coordinateView.bounds.size)
        }
        if let target {
            payload["elementID"] = target.elementID
            payload["rects"] = WebViewNativeLookupHitTestStore.debugRectStrings(target.rects.prefix(4))
            payload["hitRects"] = WebViewNativeLookupHitTestStore.debugRectStrings(target.debugHitRects.prefix(4))
        }
        debugPrint("POPOVER nativeGesture.touchDelivery", payload)
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
    private var lastKnownWebViewSize: CGSize = .zero
    var isWebViewUnloaded = false
    var onViewDidAppear: (() -> Void)?
    var onViewWillDisappear: (() -> Void)?
    var onViewDidDisappear: (() -> Void)?
    var onWillMoveToNoParent: (() -> Void)?
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
        updateObscuredInsets()
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
        updateObscuredInsets()
    }
    
    private func updateObscuredInsets() {
        guard let webView = view.subviews.compactMap({ $0 as? WKWebView }).first else { return }
        let insets = UIEdgeInsets(
            top: obscuredInsets.top,
            left: obscuredInsets.left,
            bottom: obscuredInsets.bottom,
            right: obscuredInsets.right
        )
        //        let insets = UIEdgeInsets(top: obscuredInsets.top, left: obscuredInsets.left, bottom: 200, right: obscuredInsets.right)
        //        let argument: [Any] = ["_o", "bscu", "red", "Ins", "ets"]
        let argument: [Any] = ["o", "bscu", "red", "Ins", "ets"]
        let key = argument.compactMap({ $0 as? String }).joined()
        webView.setValue(insets, forKey: key)
        
        let windowSafeAreaInsets = view.window?.safeAreaInsets ?? .zero
        let unobscuredInsets = UIEdgeInsets(
            top: max(0, windowSafeAreaInsets.top - insets.top),
            left: 0,
            bottom: max(0, windowSafeAreaInsets.bottom - insets.bottom),
            right: 0
        )
        let unobscuredArgument: [Any] = ["un", "obsc", "uredSa", "feAre", "aInsets"]
        webView.setValue(
            unobscuredInsets,
            forKey: unobscuredArgument.compactMap({ $0 as? String }).joined()
        )
        if #available(iOS 15.5, *) {
            let viewportBounds = webView.bounds
            let hasUsableViewportBounds =
                viewportBounds.width.isFinite
                && viewportBounds.height.isFinite
                && viewportBounds.width > 1
                && viewportBounds.height > 1
            let insetsFitViewport =
                hasUsableViewportBounds
                && insets.left + insets.right < viewportBounds.width
                && insets.top + insets.bottom < viewportBounds.height
            if insetsFitViewport {
                webView.setMinimumViewportInset(insets, maximumViewportInset: insets)
            }
        }
        
        //            webView.setValue(insets, forKey: "unobscuredSafeAreaInsets")
        //            webView.setValue(insets, forKey: "obscuredInsets")
        //        webView.safeAreaInsetsDidChange()
        //            let argument2: [Any] = ["_h", "ave", "Set", "O", "bscu", "red", "Ins", "ets"]
        //            let key2 = argument2.compactMap({ $0 as? String }).joined()
        //            webView.setValue(true, forKey: key2)
        //            webView.setValue(true, forKey: "_haveSetUnobscuredSafeAreaInsets")
        //        }
        // TODO: investigate _isChangingObscuredInsetsInteractively
    }

    @MainActor
    func replaceWebView(_ newWebView: EnhancedWKWebView) {
        detachWebView()
        webView = newWebView
        attachWebView(newWebView)
        isWebViewUnloaded = false
        updateObscuredInsets()
    }

    @MainActor
    func setNativeLookupHitTestStore(_ store: WebViewNativeLookupHitTestStore) {
        nativeLookupHitTestOverlayView.store = store
        nativeLookupHitTestGestureRecognizer.store = store
        nativeLookupHitTestGestureRecognizer.coordinateView = nativeLookupHitTestOverlayView
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
        attachNativeLookupHitTestOverlay()
    }

    @MainActor
    private func attachNativeLookupHitTestOverlay() {
        nativeLookupHitTestOverlayConstraints.removeAll()
        nativeLookupHitTestOverlayView.removeFromSuperview()
        nativeLookupHitTestOverlayView.translatesAutoresizingMaskIntoConstraints = false
        if nativeLookupHitTestGestureRecognizer.view !== webView {
            nativeLookupHitTestGestureRecognizer.view?.removeGestureRecognizer(nativeLookupHitTestGestureRecognizer)
            webView.addGestureRecognizer(nativeLookupHitTestGestureRecognizer)
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
    func applyUnderPageFallbackBackgroundColor(config: WebViewConfig) {
        let fallbackColor = underPageFallbackBackgroundColor(config: config)
        if #available(iOS 15.0, *) {
            underPageBackgroundColor = fallbackColor
        }
        scrollView.backgroundColor = fallbackColor
    }

    @available(iOS 15.0, *)
    func applyUnderPageBackgroundColor(config: WebViewConfig, allowSampledPageTopColor: Bool = true) {
        let canUseSampledColor = manabiCanUseSampledPageTopColorBackground()
        let fallbackColor = UIColor(config.backgroundColor)
        if config.usesSampledPageTopColorForUnderPageBackground, allowSampledPageTopColor {
            if canUseSampledColor {
                if let sampledPageTopColor {
                    underPageBackgroundColor = sampledPageTopColor
                }
            } else {
                underPageBackgroundColor = config.isOpaque ? .systemBackground : .clear
            }
        } else {
            underPageBackgroundColor = fallbackColor
        }
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
        evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, result as? Bool == true else { return }
            let resolvedColor = UIColor(config.backgroundColor)
            self.underPageBackgroundColor = resolvedColor
            self.scrollView.backgroundColor = resolvedColor
        }
    }
}

extension WKWebViewConfiguration {
    func enableManabiPageTopColorSampling() {
        let selector = Selector("_setSa\("mpledPageTopColorMaxDiff")erence:")
        guard responds(to: selector) else { return }
        perform(selector, with: 5.0 as Double)
    }
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
        if web == nil, let resolvedWebViewPool {
            web = resolvedWebViewPool.dequeue {
                makeNewWebView(config: config)
            }
        }
        if web == nil {
            web = makeNewWebView(config: config)
        }
        guard let web else { fatalError("Couldn't instantiate WKWebView for WebView.") }
        
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
        if config.usesSampledPageTopColorForUnderPageBackground,
           manabiCanUseSampledPageTopColorBackground() {
            configuration.enableManabiPageTopColorSampling()
        }
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
        applyTopScrollEdgeEffectHidden(config.hidesTopScrollEdgeEffect, to: webView)
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
        if !navigator.shouldLoadFallbackOnAttach {
        }
        let resolvedContentRules = navigator.peekContentRulesBypass() ? nil : config.contentRules
        if context.coordinator.lastUserScriptsContentController !== webView.configuration.userContentController {
            context.coordinator.lastUserScriptsContentController = webView.configuration.userContentController
            context.coordinator.lastInstalledScriptsSignature = webView.persistedUserScriptsSignature
        }
        if context.coordinator.lastAppliedContentRules != webView.persistedAppliedContentRules {
            context.coordinator.lastAppliedContentRules = webView.persistedAppliedContentRules
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
        let nativeLookupHitTestingEnabled = config.nativeLookupHitTestingEnabled
        navigator.nativeLookupHitTesting.isEnabled = nativeLookupHitTestingEnabled
        webView.scrollView.contentInsetAdjustmentBehavior = config.adjustsScrollViewContentInsetsForSafeArea ? .always : .never
        webView.scrollView.isScrollEnabled = config.isScrollEnabled
#if os(iOS)
        webView.hidesTopScrollEdgeEffect = config.hidesTopScrollEdgeEffect
        applyTopScrollEdgeEffectHidden(config.hidesTopScrollEdgeEffect, to: webView)
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
            forDomain: resolvedUserScriptDomain(currentURL: webView.url),
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
        context.coordinator.scriptCaller?.snapshotCapture = makeWebViewSnapshotCapture(for: webView)
        context.coordinator.textSelection = $textSelection
        controller.setNativeLookupHitTestStore(navigator.nativeLookupHitTesting)
        controller.setNativeLookupHitTestingEnabled(
            nativeLookupHitTestingEnabled,
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
        if !context.coordinator.navigator.shouldLoadFallbackOnAttach {
        }
        configureWebView(webView, controller: controller, context: context)
        context.coordinator.markSnapshotRestoreIfNeeded()
        context.coordinator.applyCachedSnapshotIfAvailable(controller: controller)
        controller.onViewDidAppear = { [weak coordinator = context.coordinator, weak controller] in
            guard let coordinator, let controller else { return }
            #if DEBUG && os(iOS)
            let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
            print("# LOOKUPPERF", timestamp, "webview.viewDidAppear url=\(controller.webView.url?.absoluteString ?? "<nil>")")
            #endif
            if coordinator.lifecycleConfig.autoUnloadOnDisappear, controller.isWebViewUnloaded {
                coordinator.prepareForReloadIfNeeded(controller: controller)
                coordinator.navigator.prepareForReloadAfterReattach()
                let newWebView = makeWebView(config: config, coordinator: coordinator)
                coordinator.navigator.logCompetingOperationIfNeeded(
                    "replaceWebView",
                    metadata: [
                        "newWebViewID": readerLoadObjectIDString(newWebView),
                        "oldWebViewID": readerLoadObjectIDString(controller.webView)
                    ]
                )
                controller.replaceWebView(newWebView)
                configureWebView(newWebView, controller: controller, context: context)
            }
        }
        controller.onViewWillDisappear = { [weak coordinator = context.coordinator, weak controller] in
            guard let coordinator, let controller else { return }
            if !coordinator.navigator.shouldLoadFallbackOnAttach {
            }
            #if DEBUG && os(iOS)
            let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
            print("# LOOKUPPERF", timestamp, "webview.viewWillDisappear url=\(controller.webView.url?.absoluteString ?? "<nil>")")
            #endif
            guard !coordinator.lifecycleConfig.unloadOnlyWhenRemovedFromHierarchy else { return }
            coordinator.unloadWebViewIfNeeded(controller: controller)
        }
        controller.onWillMoveToNoParent = { [weak coordinator = context.coordinator, weak controller] in
            guard let coordinator, let controller else { return }
            if !coordinator.navigator.shouldLoadFallbackOnAttach {
            }
            guard coordinator.lifecycleConfig.unloadOnlyWhenRemovedFromHierarchy else { return }
            coordinator.unloadWebViewIfNeeded(controller: controller)
        }
        controller.onViewDidDisappear = { [weak controller] in
            guard let controller else { return }
            #if DEBUG && os(iOS)
            let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
            print("# LOOKUPPERF", timestamp, "webview.viewDidDisappear url=\(controller.webView.url?.absoluteString ?? "<nil>")")
            #endif
        }
        return controller
    }
    
    @MainActor
    public func updateUIViewController(_ controller: WebViewController, context: Context) {
        let nativeLookupHitTestingEnabled = config.nativeLookupHitTestingEnabled
        navigator.nativeLookupHitTesting.isEnabled = nativeLookupHitTestingEnabled
        controller.setNativeLookupHitTestStore(navigator.nativeLookupHitTesting)
        controller.setNativeLookupHitTestingEnabled(
            nativeLookupHitTestingEnabled,
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
        if let requestedAt, requestedBeforeProvisional {
            let waitElapsed = Date().timeIntervalSince(requestedAt)
            if waitElapsed >= readerLoadIssueGapWarningThreshold,
               !context.coordinator.navigator.didLogHostPreProvisionalForCurrentRequest {
                context.coordinator.navigator.didLogHostPreProvisionalForCurrentRequest = true
                let correlationBaseline = context.coordinator.navigator.readerLoadIssuedAt ?? context.coordinator.navigator.readerLoadRequestedAt
                let requestURLString = context.coordinator.navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
                let internalSchemeStartGap = context.coordinator.navigator.readerLoadRequestedURL.flatMap { requestedURL in
                    readerLoadCorrelationTimestamp(
                        forKey: internalReaderLoaderStartedAtKeyPrefix + requestedURL.absoluteString,
                        baseline: correlationBaseline,
                        now: Date()
                    )
                }.map { String(format: "%.3fs", Date().timeIntervalSince($0)) } ?? "nil"
                readerLoadLog(
                    "webView.host.loaderPhase.preProvisional",
                    [
                        "elapsedSinceRequested": String(format: "%.3fs", waitElapsed),
                        "estimatedProgress": String(format: "%.3f", controller.webView.estimatedProgress),
                        "hasSuperview": "\(controller.webView.superview != nil)",
                        "hasWindow": "\(controller.webView.window != nil)",
                        "internalSchemeStartGap": internalSchemeStartGap,
                        "isLoading": "\(controller.webView.isLoading)",
                        "requestURL": requestURLString,
                        "sceneState": readerLoadSceneStateString(for: controller.webView),
                        "webViewID": readerLoadObjectIDString(controller.webView)
                    ]
                )
            }
        }
        if let provisionalStartedAt, requestedAfterProvisionalBeforeCommit {
            let waitElapsed = Date().timeIntervalSince(provisionalStartedAt)
            if waitElapsed >= readerLoadCommitGapWarningThreshold {
                let correlationBaseline = context.coordinator.navigator.readerLoadIssuedAt ?? context.coordinator.navigator.readerLoadRequestedAt
                let requestURLString = context.coordinator.navigator.readerLoadRequestedURL?.absoluteString ?? "nil"
                let internalSchemeResponseGap = context.coordinator.navigator.readerLoadRequestedURL.flatMap { requestedURL in
                    readerLoadCorrelationTimestamp(
                        forKey: internalReaderLoaderResponseAtKeyPrefix + requestedURL.absoluteString,
                        baseline: correlationBaseline,
                        now: Date()
                    )
                }.map { String(format: "%.3fs", Date().timeIntervalSince($0)) } ?? "nil"
                let internalSchemeDataGap = context.coordinator.navigator.readerLoadRequestedURL.flatMap { requestedURL in
                    readerLoadCorrelationTimestamp(
                        forKey: internalReaderLoaderDataAtKeyPrefix + requestedURL.absoluteString,
                        baseline: correlationBaseline,
                        now: Date()
                    )
                }.map { String(format: "%.3fs", Date().timeIntervalSince($0)) } ?? "nil"
                let internalSchemeFinishGap = context.coordinator.navigator.readerLoadRequestedURL.flatMap { requestedURL in
                    readerLoadCorrelationTimestamp(
                        forKey: internalReaderLoaderFinishedAtKeyPrefix + requestedURL.absoluteString,
                        baseline: correlationBaseline,
                        now: Date()
                    )
                }.map { String(format: "%.3fs", Date().timeIntervalSince($0)) } ?? "nil"
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
                        "webViewID": readerLoadObjectIDString(controller.webView)
                    ]
                )
            }
        }
        if !context.coordinator.navigator.shouldLoadFallbackOnAttach {
        }
        updateCoordinatorBindings(context: context)
        let resolvedContentRules = navigator.peekContentRulesBypass() ? nil : config.contentRules
        applyCommonConfiguration(
            webView: controller.webView,
            context: context,
            resolvedContentRules: resolvedContentRules
        )
        refreshDarkModeSetting(webView: controller.webView)
        updateUserScripts(
            userContentController: controller.webView.configuration.userContentController,
            coordinator: context.coordinator,
            forDomain: resolvedUserScriptDomain(currentURL: controller.webView.url),
            config: config
        )
        
        //        refreshContentRules(userContentController: controller.webView.configuration.userContentController, coordinator: context.coordinator)
        
        //        controller.webView.setValue(drawsBackground, forKey: "drawsBackground")
        
        
        controller.webView.buildMenu = buildMenu
        controller.webView.scrollView.bounces = bounces
        controller.webView.scrollView.alwaysBounceVertical = bounces
        controller.webView.scrollView.contentInsetAdjustmentBehavior = config.adjustsScrollViewContentInsetsForSafeArea ? .always : .never
        controller.webView.scrollView.isScrollEnabled = config.isScrollEnabled
#if os(iOS)
        controller.webView.hidesTopScrollEdgeEffect = config.hidesTopScrollEdgeEffect
        applyTopScrollEdgeEffectHidden(config.hidesTopScrollEdgeEffect, to: controller.webView)
#endif
        applyVisualConfiguration(webView: controller.webView, containerView: controller.view)
        context.coordinator.applyCachedSnapshotIfAvailable(controller: controller)
        
        // TODO: Fix for RTL languages, if it matters for _obscuredInsets.
        //        let insets = UIEdgeInsets(top: obscuredInsets.top, left: obscuredInsets.leading, bottom: obscuredInsets.bottom, right: obscuredInsets.trailing)
        let topSafeAreaInset = controller.view.window?.safeAreaInsets.top ?? 0
        let bottomSafeAreaInset = controller.view.window?.safeAreaInsets.bottom ?? 0

        //        let insets = UIEdgeInsets(top: obscuredInsets.top, left: obscuredInsets.leading, bottom: obscuredInsets.bottom, right: obscuredInsets.trailing)
        //        print(obscuredInsets)
        let incomingBottomObscuredInset = max(0, obscuredInsets.bottom)
        let treatsIncomingBottomAsAdditionalClearance =
            bottomSafeAreaInset > 0
            && incomingBottomObscuredInset > 0
            && incomingBottomObscuredInset < bottomSafeAreaInset
        let resolvedAdditionalBottomSafeAreaInset = treatsIncomingBottomAsAdditionalClearance
            ? incomingBottomObscuredInset
            : max(0, incomingBottomObscuredInset - bottomSafeAreaInset)
        let resolvedObscuredBottomInset = treatsIncomingBottomAsAdditionalClearance
            ? bottomSafeAreaInset + incomingBottomObscuredInset
            : incomingBottomObscuredInset
        controller.additionalSafeAreaInsets = UIEdgeInsets(
            top: max(0, obscuredInsets.top - topSafeAreaInset),
            left: 0,
            bottom: resolvedAdditionalBottomSafeAreaInset,
            right: 0
        )
        //        controller.obscuredInsets = UIEdgeInsets(top: 0, left: 0, bottom: obscuredInsets.bottom, right: 0)
        
        controller.obscuredInsets = UIEdgeInsets(
            top: obscuredInsets.top,
            left: max(0, obscuredInsets.leading),
            bottom: resolvedObscuredBottomInset,
            right: max(0, obscuredInsets.trailing)
        )
        // _obscuredInsets ignores sides, probably
        controller.onViewDidAppear = { [weak coordinator = context.coordinator, weak controller] in
            guard let coordinator, let controller else { return }
            #if DEBUG && os(iOS)
            let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
            print("# LOOKUPPERF", timestamp, "webview.viewDidAppear url=\(controller.webView.url?.absoluteString ?? "<nil>")")
            #endif
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
            #if DEBUG && os(iOS)
            let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
            print("# LOOKUPPERF", timestamp, "webview.viewWillDisappear url=\(controller.webView.url?.absoluteString ?? "<nil>")")
            #endif
            guard !coordinator.lifecycleConfig.unloadOnlyWhenRemovedFromHierarchy else { return }
            coordinator.unloadWebViewIfNeeded(controller: controller)
        }
        controller.onWillMoveToNoParent = { [weak coordinator = context.coordinator, weak controller] in
            guard let coordinator, let controller else { return }
            guard coordinator.lifecycleConfig.unloadOnlyWhenRemovedFromHierarchy else { return }
            coordinator.unloadWebViewIfNeeded(controller: controller)
        }
        controller.onViewDidDisappear = { [weak controller] in
            guard let controller else { return }
            #if DEBUG && os(iOS)
            let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
            print("# LOOKUPPERF", timestamp, "webview.viewDidDisappear url=\(controller.webView.url?.absoluteString ?? "<nil>")")
            #endif
        }
    }
    
    public static func dismantleUIViewController(_ controller: WebViewController, coordinator: WebViewCoordinator) {
        if !coordinator.navigator.shouldLoadFallbackOnAttach {
        }
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
private final class NativeLookupHitTestOverlayNSView: NSView {
    private enum PressedSegmentStyle {
        static let pressedStrokeAlpha: CGFloat = 0.8
        static let strokeWidth: CGFloat = 1
        static let cornerRadius: CGFloat = 5
        static let inset: CGFloat = 0.5
        static let lookupAttachmentTopExpansion: CGFloat = 0
    }

    weak var store: WebViewNativeLookupHitTestStore?
    private var lastPassThroughLogAt: TimeInterval = 0
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
        for rect in target.projectedRectsForCurrentHitTestOverlay {
            let visualRect = Self.pressVisualRect(for: rect)
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

    private static func pressVisualRect(for rect: CGRect) -> CGRect {
        var visualRect = rect
        visualRect.origin.y -= PressedSegmentStyle.lookupAttachmentTopExpansion
        visualRect.size.height += PressedSegmentStyle.lookupAttachmentTopExpansion
        return visualRect
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
        let containsTarget = !isHidden
            && alphaValue > 0
            && store?.containsClaimableTarget(at: point, in: bounds.size) == true
        if containsTarget {
        } else {
            let now = Date().timeIntervalSinceReferenceDate
            if now - lastPassThroughLogAt > 0.25 {
                lastPassThroughLogAt = now
            }
        }
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
        MainActor.assumeIsolated {
            store?.onActiveTargetTouchDown?(target)
        }
        pressedOverlay?.showPressedTarget(target)
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

    @objc private func handleNativeLookupHitTestClick(_ recognizer: NativeLookupHitTestClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        _ = recognizer.store?.handleTap(at: recognizer.location(in: nativeLookupHitTestOverlayView), in: nativeLookupHitTestOverlayView.bounds.size)
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
        applyCommonConfiguration(
            webView: webView,
            context: context,
            resolvedContentRules: resolvedContentRules
        )
        let resolvedDrawsBackground = config.isOpaque ? drawsBackground : false
        webView.setValue(resolvedDrawsBackground, forKey: "drawsBackground")
        if #available(macOS 11.0, *) {
            webView.layer?.backgroundColor = NSColor(config.backgroundColor).cgColor
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
            let jsPrefix = js.prefix(120)
            let frameURL = frame?.request.url?.absoluteString ?? "nil"
            let isMainFrame = frame?.isMainFrame ?? true
            let currentURL = webView.url?.absoluteString ?? "nil"
            let resolvedWorld = world ?? .page
            let startedAt = Date()
            print("# READER scriptCaller.call.start",
                  "url=\(currentURL)",
                  "frameURL=\(frameURL)",
                  "isMainFrame=\(isMainFrame)",
                  "world=\(String(describing: resolvedWorld.name))",
                  "args=\(args?.count ?? 0)",
                  "jsPrefix=\(jsPrefix)")
            do {
                let value: Any?
                if let args {
                    value = try await webView.callAsyncJavaScript(js, arguments: args, in: frame, contentWorld: resolvedWorld)
                } else {
                    value = try await webView.callAsyncJavaScript(js, in: frame, contentWorld: resolvedWorld)
                }
                let elapsed = Date().timeIntervalSince(startedAt)
                let typeDescription = value.map { String(describing: type(of: $0)) } ?? "nil"
                let stringLength = (value as? String)?.count
                print("# READER scriptCaller.call.finish",
                      "url=\(currentURL)",
                      "frameURL=\(frameURL)",
                      "isMainFrame=\(isMainFrame)",
                      "world=\(String(describing: resolvedWorld.name))",
                      "jsPrefix=\(jsPrefix)",
                      "type=\(typeDescription)",
                      "stringLength=\(stringLength.map(String.init) ?? "nil")",
                      String(format: "elapsed=%.3fs", elapsed))
                return WebViewScriptCaller.JavaScriptEvaluationResult(value)
            } catch {
                let elapsed = Date().timeIntervalSince(startedAt)
                print("# READER scriptCaller.call.error",
                      "url=\(currentURL)",
                      "frameURL=\(frameURL)",
                      "isMainFrame=\(isMainFrame)",
                      "world=\(String(describing: resolvedWorld.name))",
                      "jsPrefix=\(jsPrefix)",
                      "error=\(error)",
                      String(format: "elapsed=%.3fs", elapsed))
                throw error
            }
        }
        context.coordinator.scriptCaller?.unsafeCaller = { @MainActor [weak webView] (js: String, frame: WKFrameInfo?, world: WKContentWorld?) in
            guard let webView else { return }
            let resolvedWorld = world ?? .page
            webView.evaluateJavaScript(js, in: frame, in: resolvedWorld, completionHandler: nil)
        }
        context.coordinator.scriptCaller?.snapshotCapture = makeWebViewSnapshotCapture(for: webView)
        
        refreshDarkModeSetting(webView: webView)
        
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
        let resolvedContentRules = navigator.peekContentRulesBypass() ? nil : config.contentRules
        applyCommonConfiguration(
            webView: webView,
            context: context,
            resolvedContentRules: resolvedContentRules
        )
        updateUserScripts(
            userContentController: webView.configuration.userContentController,
            coordinator: context.coordinator,
            forDomain: resolvedUserScriptDomain(currentURL: webView.url),
            config: config
        )
        
        // Can't disable on macOS.
        //        uiView.scrollView.bounces = bounces
        //        uiView.scrollView.alwaysBounceVertical = bounces
        
        refreshDarkModeSetting(webView: webView)
        
        let resolvedDrawsBackground = config.isOpaque ? drawsBackground : false
        webView.setValue(resolvedDrawsBackground, forKey: "drawsBackground")
        if #available(macOS 11.0, *) {
            webView.layer?.backgroundColor = NSColor(config.backgroundColor).cgColor
        } else {
            webView.layer?.backgroundColor = NSColor.clear.cgColor
        }
        
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
        context.coordinator.navigator.forceClearLoadingIndicatorsHandler = { [weak coordinator = context.coordinator] reason, pageURL in
            Task { @MainActor in
                coordinator?.forceClearLoadingIndicators(reason: reason, pageURL: pageURL)
            }
        }
        context.coordinator.hideNavigationDueToScroll = $hideNavigationDueToScroll
        context.coordinator.syncHideNavigationDueToScrollFromHost(hideNavigationDueToScroll)
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
            if let resolvedUnderPageColor = webView.resolvedUnderPageBackgroundColor(
                config: config,
                allowSampledPageTopColor: false
            ) {
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
        userContentController.removeAllContentRuleLists()
        let rules = (overrideRules ?? config.contentRules)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let contentRules = rules, !contentRules.isEmpty else {
            coordinator.lastAppliedContentRules = nil
            (coordinator.navigator.webView as? EnhancedWKWebView)?.persistedAppliedContentRules = nil
            return
        }
        if let ruleList = coordinator.compiledContentRules[contentRules] {
            userContentController.add(ruleList)
            coordinator.lastAppliedContentRules = contentRules
            (coordinator.navigator.webView as? EnhancedWKWebView)?.persistedAppliedContentRules = contentRules
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
                return
            }
            userContentController.add(ruleList)
            coordinator.compiledContentRules[contentRules] = ruleList
            coordinator.lastAppliedContentRules = contentRules
            (coordinator.navigator.webView as? EnhancedWKWebView)?.persistedAppliedContentRules = contentRules
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
    func updateUserScripts(userContentController: WKUserContentController, coordinator: WebViewCoordinator, forDomain domain: URL?, config: WebViewConfig) {
        var scripts = config.userScripts
        if let domain = domain?.domainURL.host {
            scripts = scripts.filter { $0.allowedDomains.isEmpty || $0.allowedDomains.contains(domain) }
        } else {
            scripts = scripts.filter { $0.allowedDomains.isEmpty }
        }
        let allScripts = Self.systemScripts + scripts
        let installedScriptsSignature = allScripts
            .map { script in
                "\(script.source.hashValue)|\(script.injectionTime.rawValue)|\(script.isForMainFrameOnly)"
            }
            .joined(separator: "||")

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
        }
        coordinator.lastUserScriptsContentController = userContentController
        if coordinator.lastInstalledScriptsSignature != installedScriptsSignature {
#if DEBUG
            debugPrint("# READER userScripts.applied", "count=\(allScripts.count)", "pageURL=\(domain?.absoluteString ?? "<nil>")")
#endif
            coordinator.lastInstalledScriptsSignature = installedScriptsSignature
        }
        (coordinator.navigator.webView as? EnhancedWKWebView)?.persistedUserScriptsSignature = installedScriptsSignature
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
        "swiftUIWebViewPaginationReadback",
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
