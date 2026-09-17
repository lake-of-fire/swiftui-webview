import Foundation
import WebKit

/// Evidence that an isolated content world observed a genuine user activation
/// for a specific action in the same document and frame.
///
/// Isolated-world activations carry their original event time so delayed IPC
/// spends the same short lifetime instead of minting a fresh receipt-time
/// lease. Native-authorized operations retain native receipt-time admission.
/// Broker admissions use a page-visible, short-lived correlation token that is
/// still bound to the action, document generation, frame, one-shot store entry,
/// and native semantic validation.
public struct WebViewTrustedUserAction: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case isolatedUserActivation
        case nativeAuthorizedOperation
    }

    public let action: String
    public let scope: String?
    public let source: Source
    public let observedAtUnixMilliseconds: Double?

    public init(
        action: String,
        scope: String?,
        source: Source = .isolatedUserActivation,
        observedAtUnixMilliseconds: Double? = nil
    ) {
        self.action = action
        self.scope = scope
        self.source = source
        self.observedAtUnixMilliseconds = observedAtUnixMilliseconds
    }
}

struct WebViewTrustedUserActionFrameIdentity: Hashable {
    let isMainFrame: Bool
    let requestURL: String?
    let mainDocumentURL: String?
    let securityOrigin: String

    init(
        isMainFrame: Bool,
        requestURL: String?,
        mainDocumentURL: String?,
        securityOrigin: String
    ) {
        self.isMainFrame = isMainFrame
        self.requestURL = requestURL
        self.mainDocumentURL = mainDocumentURL
        self.securityOrigin = securityOrigin
    }

    @MainActor
    init(_ frameInfo: WKFrameInfo) {
        isMainFrame = frameInfo.isMainFrame
        requestURL = frameInfo.request.url?.absoluteString
        mainDocumentURL = frameInfo.request.mainDocumentURL?.absoluteString
        let origin = frameInfo.securityOrigin
        securityOrigin = [origin.protocol, origin.host, String(origin.port)]
            .joined(separator: "|")
    }
}

@MainActor
final class WebViewTrustedUserActionAdmissionStore {
    struct DocumentIdentity: Hashable {
        let webViewID: ObjectIdentifier
        let generation: UInt64
    }

    private struct Key: Hashable {
        let document: DocumentIdentity
        let frame: WebViewTrustedUserActionFrameIdentity
        let action: String
    }

    private struct CorrelationKey: Hashable {
        let key: Key
        let token: String
    }

    private struct Admission {
        let id: UUID
        let correlationToken: String?
        let scope: String?
        let source: WebViewTrustedUserAction.Source
        let observedAtUnixMilliseconds: Double?
        let expiresAt: TimeInterval
    }

    private struct PendingConsumption {
        let id: UUID
        let continuation: CheckedContinuation<WebViewTrustedUserAction?, Never>
        let timeoutTask: Task<Void, Never>
    }

    private struct DecodedBrokerScope {
        let scope: String?
        let observedAtUnixMilliseconds: Double?
    }

    static let maximumActionUTF8Bytes = 128
    static let maximumScopeUTF8Bytes = 4_096
    static let maximumAdmissionCount = 4_096
    static let lifetime: TimeInterval = 1.5
    static let maximumFutureClockSkewMilliseconds: Double = 5_000
    static let correlationTokenUTF8Bytes = 32
    static let brokerScopePrefix = "__swiftUIWebViewTrustedUserActionV1:"
    private static let maximumBrokerEnvelopeUTF8Bytes =
        maximumScopeUTF8Bytes * 3 + 256

    private var admissions: [Key: [Admission]] = [:]
    private var pendingConsumptions: [CorrelationKey: PendingConsumption] = [:]
    private var spentCorrelationTokens: [CorrelationKey: TimeInterval] = [:]

    func admit(
        action: String,
        scope: String?,
        correlationToken: String?,
        document: DocumentIdentity,
        frameInfo: WKFrameInfo,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        admit(
            action: action,
            scope: scope,
            correlationToken: correlationToken,
            document: document,
            frame: WebViewTrustedUserActionFrameIdentity(frameInfo),
            now: now,
            wallClockNowUnixMilliseconds:
                Date().timeIntervalSince1970 * 1_000
        )
    }

    func admit(
        action: String,
        scope: String?,
        correlationToken: String?,
        document: DocumentIdentity,
        frame: WebViewTrustedUserActionFrameIdentity,
        now: TimeInterval,
        wallClockNowUnixMilliseconds: Double? = nil
    ) -> Bool {
        guard let correlationToken,
              Self.acceptsCorrelationToken(correlationToken),
              let decoded = Self.decodeBrokerScope(scope),
              Self.accepts(action: action, scope: decoded.scope) else {
            return false
        }
        prune(now: now)
        guard admissionCount + pendingConsumptions.count
            < Self.maximumAdmissionCount else { return false }

        var expiresAt = now + Self.lifetime
        if let observedAtUnixMilliseconds = decoded.observedAtUnixMilliseconds {
            let wallClockNow = wallClockNowUnixMilliseconds
                ?? Date().timeIntervalSince1970 * 1_000
            guard wallClockNow.isFinite,
                  observedAtUnixMilliseconds.isFinite else { return false }
            let ageMilliseconds = wallClockNow - observedAtUnixMilliseconds
            guard ageMilliseconds >= -Self.maximumFutureClockSkewMilliseconds,
                  ageMilliseconds <= Self.lifetime * 1_000 else {
                return false
            }
            let elapsed = max(0, ageMilliseconds / 1_000)
            expiresAt = now + max(0, Self.lifetime - elapsed)
        }

        let key = Key(
            document: document,
            frame: frame,
            action: action
        )
        let admission = Admission(
            id: UUID(),
            correlationToken: correlationToken,
            scope: decoded.scope,
            source: .isolatedUserActivation,
            observedAtUnixMilliseconds: decoded.observedAtUnixMilliseconds,
            expiresAt: expiresAt
        )
        let correlationKey = CorrelationKey(key: key, token: correlationToken)
        guard spentCorrelationTokens[correlationKey] == nil,
              admissions[key]?.contains(where: {
                  $0.correlationToken == correlationToken
              }) != true else {
            return false
        }
        if let pending = pendingConsumptions.removeValue(forKey: correlationKey) {
            pending.timeoutTask.cancel()
            spentCorrelationTokens[correlationKey] = admission.expiresAt
            pending.continuation.resume(
                returning: Self.makeTrustedUserAction(action, admission: admission)
            )
        } else {
            admissions[key, default: []].append(admission)
        }
        return true
    }

    func consume(
        action: String,
        correlationToken: String? = nil,
        document: DocumentIdentity,
        frameInfo: WKFrameInfo,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> WebViewTrustedUserAction? {
        consume(
            action: action,
            correlationToken: correlationToken,
            document: document,
            frame: WebViewTrustedUserActionFrameIdentity(frameInfo),
            now: now
        )
    }

    func consume(
        action: String,
        correlationToken: String? = nil,
        document: DocumentIdentity,
        frame: WebViewTrustedUserActionFrameIdentity,
        now: TimeInterval
    ) -> WebViewTrustedUserAction? {
        prune(now: now)
        let key = Key(
            document: document,
            frame: frame,
            action: action
        )
        guard var candidates = admissions[key], !candidates.isEmpty else {
            return nil
        }
        let admissionIndex: Int?
        if let correlationToken {
            guard Self.acceptsCorrelationToken(correlationToken) else { return nil }
            admissionIndex = candidates.firstIndex {
                $0.correlationToken == correlationToken
            }
        } else {
            admissionIndex = candidates.firstIndex {
                $0.source == .nativeAuthorizedOperation
            }
        }
        guard let admissionIndex else { return nil }
        let admission = candidates.remove(at: admissionIndex)
        if candidates.isEmpty {
            admissions.removeValue(forKey: key)
        } else {
            admissions[key] = candidates
        }
        if let token = admission.correlationToken {
            spentCorrelationTokens[
                CorrelationKey(key: key, token: token)
            ] = admission.expiresAt
        }
        return Self.makeTrustedUserAction(action, admission: admission)
    }

    /// Waits only for the isolated-world receipt carrying this exact token.
    /// A page command may arrive ahead of that receipt because WebKit delivers
    /// the two content worlds independently. The wait is one-shot, bounded by
    /// the admission lifetime, and is invalidated with the document context.
    func consumeOrWaitForBrokerAdmission(
        action: String,
        correlationToken: String?,
        document: DocumentIdentity,
        frame: WebViewTrustedUserActionFrameIdentity,
        now: TimeInterval
    ) async -> WebViewTrustedUserAction? {
        if let admission = consume(
            action: action,
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: now
        ) {
            return admission
        }
        guard let correlationToken,
              Self.acceptsCorrelationToken(correlationToken) else {
            return nil
        }

        let key = Key(document: document, frame: frame, action: action)
        let correlationKey = CorrelationKey(key: key, token: correlationToken)
        guard pendingConsumptions[correlationKey] == nil,
              spentCorrelationTokens[correlationKey] == nil,
              admissionCount + pendingConsumptions.count
                < Self.maximumAdmissionCount else {
            return nil
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let id = UUID()
                let timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64(Self.lifetime * 1_000_000_000)
                        )
                    } catch {
                        return
                    }
                    self?.timeoutPendingConsumption(
                        id: id,
                        correlationKey: correlationKey
                    )
                }
                pendingConsumptions[correlationKey] = PendingConsumption(
                    id: id,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingConsumption(correlationKey: correlationKey)
            }
        }
    }

    func invalidateAll() {
        admissions.removeAll(keepingCapacity: true)
        spentCorrelationTokens.removeAll(keepingCapacity: true)
        let pending = pendingConsumptions.values
        pendingConsumptions.removeAll(keepingCapacity: true)
        for consumption in pending {
            consumption.timeoutTask.cancel()
            consumption.continuation.resume(returning: nil)
        }
    }

    func admitNativeBatch(
        action: String,
        count: Int,
        document: DocumentIdentity,
        frameInfo: WKFrameInfo,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Set<UUID> {
        admitNativeBatch(
            action: action,
            count: count,
            document: document,
            frame: WebViewTrustedUserActionFrameIdentity(frameInfo),
            now: now
        )
    }

    func admitNativeBatch(
        action: String,
        count: Int,
        document: DocumentIdentity,
        frame: WebViewTrustedUserActionFrameIdentity,
        now: TimeInterval
    ) -> Set<UUID> {
        guard count > 0, count <= Self.maximumAdmissionCount,
              Self.accepts(action: action, scope: nil) else {
            return []
        }
        prune(now: now)
        guard admissionCount + count <= Self.maximumAdmissionCount else {
            return []
        }
        let key = Key(
            document: document,
            frame: frame,
            action: action
        )
        let batch = (0..<count).map { _ in
            Admission(
                id: UUID(),
                correlationToken: nil,
                scope: nil,
                source: .nativeAuthorizedOperation,
                observedAtUnixMilliseconds: nil,
                expiresAt: now + Self.lifetime
            )
        }
        admissions[key, default: []].append(contentsOf: batch)
        return Set(batch.map(\.id))
    }

    func revoke(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        admissions = admissions.compactMapValues { candidates in
            let retained = candidates.filter { !ids.contains($0.id) }
            return retained.isEmpty ? nil : retained
        }
    }

    private static func decodeBrokerScope(
        _ encodedScope: String?
    ) -> DecodedBrokerScope? {
        guard let encodedScope else {
            return DecodedBrokerScope(
                scope: nil,
                observedAtUnixMilliseconds: nil
            )
        }
        guard encodedScope.hasPrefix(brokerScopePrefix) else {
            return DecodedBrokerScope(
                scope: encodedScope,
                observedAtUnixMilliseconds: nil
            )
        }
        guard encodedScope.utf8.count <= maximumBrokerEnvelopeUTF8Bytes else {
            return nil
        }
        let remainder = encodedScope.dropFirst(brokerScopePrefix.count)
        guard let separator = remainder.firstIndex(of: ":"),
              let observedAtUnixMilliseconds = Double(
                remainder[..<separator]
              ), observedAtUnixMilliseconds.isFinite,
              observedAtUnixMilliseconds > 0 else {
            return nil
        }
        let encodedPayload = String(remainder[remainder.index(after: separator)...])
        let scope: String?
        if encodedPayload == "-" {
            scope = nil
        } else {
            guard let decoded = encodedPayload.removingPercentEncoding,
                  !decoded.isEmpty,
                  decoded.utf8.count <= maximumScopeUTF8Bytes else {
                return nil
            }
            scope = decoded
        }
        return DecodedBrokerScope(
            scope: scope,
            observedAtUnixMilliseconds: observedAtUnixMilliseconds
        )
    }

    private static func accepts(action: String, scope: String?) -> Bool {
        !action.isEmpty
            && action.utf8.count <= maximumActionUTF8Bytes
            && (scope?.utf8.count ?? 0) <= maximumScopeUTF8Bytes
    }

    private static func acceptsCorrelationToken(_ token: String) -> Bool {
        token.utf8.count == correlationTokenUTF8Bytes
            && token.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
    }

    private static func makeTrustedUserAction(
        _ action: String,
        admission: Admission
    ) -> WebViewTrustedUserAction {
        WebViewTrustedUserAction(
            action: action,
            scope: admission.scope,
            source: admission.source,
            observedAtUnixMilliseconds: admission.observedAtUnixMilliseconds
        )
    }

    private var admissionCount: Int {
        admissions.values.reduce(into: 0) { $0 += $1.count }
    }

    private func prune(now: TimeInterval) {
        admissions = admissions.compactMapValues { candidates in
            let live = candidates.filter { $0.expiresAt >= now }
            return live.isEmpty ? nil : live
        }
        spentCorrelationTokens = spentCorrelationTokens.filter {
            $0.value >= now
        }
    }

    private func timeoutPendingConsumption(
        id: UUID,
        correlationKey: CorrelationKey
    ) {
        guard let pending = pendingConsumptions[correlationKey],
              pending.id == id else { return }
        pendingConsumptions.removeValue(forKey: correlationKey)
        pending.continuation.resume(returning: nil)
    }

    private func cancelPendingConsumption(correlationKey: CorrelationKey) {
        guard let pending = pendingConsumptions.removeValue(
            forKey: correlationKey
        ) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(returning: nil)
    }
}

enum WebViewTrustedUserActionBroker {
    static let handlerName = "swiftUIWebViewTrustedUserAction"
    static let correlationTokenBodyKey =
        "__swiftUIWebViewTrustedUserActionToken"
    @MainActor
    static let world = WKContentWorld.world(
        name: "com.manabi.swiftui-webview.trusted-user-action"
    )

    /// This script runs outside the page content world. Page JavaScript cannot
    /// see its message handler or call its closure. `isTrusted` is only one
    /// input here: native also binds the short-lived admission to the exact
    /// WebView document generation, frame, declared action, and original event
    /// lifetime, and consumes it once before dispatching the page message.
    ///
    /// Threat-contract boundary: this broker privately registers exact nodes in
    /// the app's reserved control-selector namespace. The page receives a
    /// short-lived correlation token only to pair its synchronous command with
    /// the isolated receipt; it is not an authorization capability independent
    /// of that receipt. It does not make page-owned layout immune to selector
    /// spoofing, control replacement, clickjacking, or hostile scripts that
    /// reuse a token during its narrow lifetime. A host that displays actively
    /// adversarial scripts must render these actions as native UI or as controls
    /// created and retained wholly by the isolated world. Reader-mode output is
    /// expected to enforce the reserved namespace and native handlers still
    /// validate document and semantic scope.
    @MainActor
    static let userScript = WebViewUserScript(
        source: """
        (() => {
            'use strict';
            // Sensitive controls belong to the host reader document. Untrusted
            // EPUB/article child frames may never register controls or mint
            // admissions even if they copy a reserved selector.
            if (window !== window.top) { return; }
            if (globalThis.__swiftUIWebViewTrustedUserActionBrokerInstalled) {
                return;
            }
            Object.defineProperty(
                globalThis,
                '__swiftUIWebViewTrustedUserActionBrokerInstalled',
                { value: true, configurable: false, enumerable: false }
            );
            const registrations = new WeakMap();
            const brokerScopePrefix = '__swiftUIWebViewTrustedUserActionV1:';
            const correlationTokensAttribute =
                'data-swiftuiwebview-trusted-action-tokens';
            const boundedScope = (value) => {
                if (typeof value !== 'string' || value.length === 0
                    || value.length > 4096) {
                    return null;
                }
                return value;
            };
            const trustedEventUnixMilliseconds = (event) => {
                const stamp = Number(event?.timeStamp);
                if (Number.isFinite(stamp) && stamp > 1e12) {
                    return stamp;
                }
                const origin = Number(globalThis.performance?.timeOrigin);
                if (Number.isFinite(origin) && Number.isFinite(stamp)
                    && stamp >= 0) {
                    const candidate = origin + stamp;
                    if (Number.isFinite(candidate) && candidate > 0) {
                        return candidate;
                    }
                }
                const fallback = Date.now();
                return Number.isFinite(fallback) ? fallback : 0;
            };
            const encodedAdmissionScope = (scope, event) => {
                const observedAt = trustedEventUnixMilliseconds(event);
                if (!(observedAt > 0)) { return null; }
                const payload = scope == null ? '-' : encodeURIComponent(scope);
                return brokerScopePrefix
                    + String(Math.round(observedAt)) + ':' + payload;
            };
            const makeCorrelationToken = () => {
                const bytes = new Uint8Array(16);
                if (!globalThis.crypto?.getRandomValues) { return null; }
                globalThis.crypto.getRandomValues(bytes);
                return Array.from(
                    bytes,
                    (byte) => byte.toString(16).padStart(2, '0')
                ).join('');
            };
            const publishPageCorrelation = (action, token) => {
                const root = document.documentElement;
                if (!root) { return; }
                let tokens = {};
                try {
                    const raw = root.getAttribute(correlationTokensAttribute);
                    if (typeof raw === 'string' && raw.length <= 4096) {
                        const decoded = JSON.parse(raw);
                        if (decoded && typeof decoded === 'object'
                            && !Array.isArray(decoded)) {
                            tokens = decoded;
                        }
                    }
                } catch (_error) {}
                tokens[action] = token;
                root.setAttribute(
                    correlationTokensAttribute,
                    JSON.stringify(tokens)
                );
                setTimeout(() => {
                    try {
                        const raw = root.getAttribute(correlationTokensAttribute);
                        const current = typeof raw === 'string'
                            ? JSON.parse(raw) : null;
                        if (!current || current[action] !== token) { return; }
                        delete current[action];
                        if (Object.keys(current).length === 0) {
                            root.removeAttribute(correlationTokensAttribute);
                        } else {
                            root.setAttribute(
                                correlationTokensAttribute,
                                JSON.stringify(current)
                            );
                        }
                    } catch (_error) {}
                }, 0);
            };
            const sectionScope = (control) => {
                const section = control.closest?.(
                    'mnb-section, .mnb-tracking-section,'
                    + ' [data-mnb-tracking-section-id],'
                    + ' [data-mnb-chunk-id]'
                );
                return boundedScope(
                    section?.dataset?.mnbChunkId
                    || section?.dataset?.mnbTrackingSectionId
                    || section?.id
                    || section?.dataset?.sectionIdentifier
                    || section?.getAttribute?.('sid')
                    || null
                );
            };
            const register = (control, actions, scope = null) => {
                if (!(control instanceof Element)
                    || registrations.has(control)
                    || !Array.isArray(actions)
                    || actions.length === 0) {
                    return;
                }
                const acceptedActions = [...new Set(actions)]
                    .filter((action) => typeof action === 'string'
                        && action.length > 0 && action.length <= 128)
                    .slice(0, 4);
                if (acceptedActions.length === 0) { return; }
                registrations.set(control, Object.freeze({
                    actions: Object.freeze(acceptedActions),
                    scope: boundedScope(scope),
                }));
            };
            const registerControl = (control) => {
                if (!(control instanceof Element)
                    || registrations.has(control)) {
                    return;
                }
                if (control.matches('.reader-view-original')) {
                    register(control, ['showOriginal']);
                } else if (control.matches('#mnb-finished-reading-button')) {
                    register(control, ['finishedReading']);
                } else if (control.matches(
                    '.mnb-start-over-button, .mnb-start-over-book-button'
                )) {
                    register(control, ['startOver']);
                } else if (control.matches('#mnb-reader-listen-button')) {
                    register(control, ['readerHeaderMediaButtonTapped']);
                } else if (control.matches('.reader-video-menu-item')) {
                    register(control, ['readerHeaderVideoMakerTapped']);
                } else if (control.matches(
                    '#mnb-reader-due-cards-button, #mnb-reader-new-cards-button'
                )) {
                    register(
                        control,
                        ['readerHeaderReviewButtonTapped'],
                        control.dataset?.mnbReviewKind
                    );
                } else if (control.matches('.mnb-feed-footer-feed')) {
                    register(
                        control,
                        ['readerFeedFooterAction'],
                        control.dataset?.mnbFeedId
                    );
                } else if (control.matches(
                    '.mnb-tracking-unlock-button,'
                    + ' .mnb-tracking-status-unlock-button,'
                    + ' #mnb-tracking-section-subscription-preview-inline-notice-unlock'
                )) {
                    register(control, ['showPurchasing']);
                } else if (control.matches(
                    '#mnb-tracking-section-subscription-preview-inline-notice-disable-highlights'
                )) {
                    register(control, ['disableWordTrackingHighlights']);
                } else if (control.matches(
                    '#nav-primary-text, #nav-hidden-primary-text,'
                    + ' #nav-title-location-label'
                )) {
                    register(control, ['openReaderGoToSheet'], control.id);
                } else if (control.matches(
                    'button.mnb-tracking-button[data-completion-action="finish"]'
                )) {
                    register(control, ['finishedReadingBook']);
                } else if (control.matches(
                    'button.mnb-tracking-button[data-completion-action="restart"]'
                )) {
                    register(control, ['startOver']);
                } else if (control.matches('button.mnb-tracking-button')) {
                    register(
                        control,
                        ['markSectionAsRead'],
                        sectionScope(control)
                            || boundedScope(control.dataset?.pageTrackingId)
                    );
                }
            };
            const registerTree = (root) => {
                if (!(root instanceof Element)) { return; }
                registerControl(root);
                root.querySelectorAll?.(
                    '.reader-view-original, #mnb-finished-reading-button,'
                    + ' .mnb-start-over-button, .mnb-start-over-book-button,'
                    + ' #mnb-reader-listen-button,'
                    + ' .reader-video-menu-item,'
                    + ' #mnb-reader-due-cards-button,'
                    + ' #mnb-reader-new-cards-button,'
                    + ' .mnb-feed-footer-feed,'
                    + ' .mnb-tracking-unlock-button,'
                    + ' .mnb-tracking-status-unlock-button,'
                    + ' #mnb-tracking-section-subscription-preview-inline-notice-unlock,'
                    + ' #mnb-tracking-section-subscription-preview-inline-notice-disable-highlights,'
                    + ' #nav-primary-text, #nav-hidden-primary-text,'
                    + ' #nav-title-location-label, button.mnb-tracking-button'
                )?.forEach(registerControl);
            };
            const installRegistry = () => {
                registerTree(document.documentElement);
                new MutationObserver((mutations) => {
                    for (const mutation of mutations) {
                        for (const node of mutation.addedNodes || []) {
                            registerTree(node);
                        }
                    }
                }).observe(document.documentElement, {
                    childList: true,
                    subtree: true,
                });
            };
            if (document.documentElement) {
                installRegistry();
            } else {
                document.addEventListener(
                    'DOMContentLoaded',
                    installRegistry,
                    { once: true }
                );
            }
            document.addEventListener('click', (event) => {
                if (event?.isTrusted !== true) { return; }
                const path = typeof event.composedPath === 'function'
                    ? event.composedPath()
                    : [event.target];
                let admission = null;
                for (const candidate of path) {
                    const registered = candidate instanceof Element
                        ? registrations.get(candidate)
                        : null;
                    if (registered) {
                        admission = registered;
                        break;
                    }
                }
                if (!admission) { return; }
                const encodedScope = encodedAdmissionScope(
                    admission.scope,
                    event
                );
                if (!encodedScope) { return; }
                try {
                    for (const action of admission.actions) {
                        const correlationToken = makeCorrelationToken();
                        if (!correlationToken) { continue; }
                        publishPageCorrelation(action, correlationToken);
                        globalThis.webkit.messageHandlers
                            .swiftUIWebViewTrustedUserAction.postMessage({
                                action,
                                scope: encodedScope,
                                correlationToken,
                            });
                    }
                } catch (_error) {}
            }, true);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: world
    )

    /// The page-world half of the broker exposes a token during the trusted
    /// click and clears it in the next task. Page producers call
    /// `__swiftUIWebViewTrustedUserAction.withToken(action, body)` as their
    /// `postMessage` body; native then matches the injected token to the
    /// isolated receipt instead of consuming an unrelated action/frame
    /// admission.
    @MainActor
    static let pageCorrelationUserScript = WebViewUserScript(
        source: """
        (() => {
            'use strict';
            if (globalThis.__swiftUIWebViewTrustedUserActionPageBridgeInstalled) {
                return;
            }
            Object.defineProperty(
                globalThis,
                '__swiftUIWebViewTrustedUserActionPageBridgeInstalled',
                { value: true, configurable: false, enumerable: false }
            );
            const tokenBodyKey = '__swiftUIWebViewTrustedUserActionToken';
            const correlationTokensAttribute =
                'data-swiftuiwebview-trusted-action-tokens';
            const accepts = (action, token) =>
                typeof action === 'string' && action.length > 0
                && action.length <= 128
                && typeof token === 'string'
                && /^[0-9a-f]{32}$/.test(token);
            Object.defineProperty(
                globalThis,
                '__swiftUIWebViewTrustedUserAction',
                {
                    configurable: false,
                    enumerable: false,
                    value: Object.freeze({
                        withToken(action, body) {
                            const root = document.documentElement;
                            let tokens = null;
                            try {
                                const raw = root?.getAttribute(
                                    correlationTokensAttribute
                                );
                                if (typeof raw === 'string'
                                    && raw.length <= 4096) {
                                    tokens = JSON.parse(raw);
                                }
                            } catch (_error) {}
                            const token = tokens?.[action];
                            if (!accepts(action, token)
                                || body == null || typeof body !== 'object'
                                || Array.isArray(body)) {
                                return body;
                            }
                            delete tokens[action];
                            if (Object.keys(tokens).length === 0) {
                                root?.removeAttribute(correlationTokensAttribute);
                            } else {
                                root?.setAttribute(
                                    correlationTokensAttribute,
                                    JSON.stringify(tokens)
                                );
                            }
                            return Object.assign({}, body, {
                                [tokenBodyKey]: token,
                            });
                        },
                    }),
                }
            );
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: .page
    )
}
