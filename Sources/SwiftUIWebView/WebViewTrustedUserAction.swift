import Foundation
import WebKit

/// Receipt-time evidence that an isolated content world observed a genuine user
/// activation for a specific action in the same document and frame.
///
/// No bearer token is exposed to the page world. The evidence is allocated and
/// consumed inside the native message dispatch path.
public struct WebViewTrustedUserAction: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case isolatedUserActivation
        case nativeAuthorizedOperation
    }

    public let action: String
    public let scope: String?
    public let source: Source

    public init(
        action: String,
        scope: String?,
        source: Source = .isolatedUserActivation
    ) {
        self.action = action
        self.scope = scope
        self.source = source
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

    private struct Admission {
        let id: UUID
        let scope: String?
        let source: WebViewTrustedUserAction.Source
        let expiresAt: TimeInterval
    }

    static let maximumActionUTF8Bytes = 128
    static let maximumScopeUTF8Bytes = 4_096
    static let maximumAdmissionCount = 4_096
    static let lifetime: TimeInterval = 1.5

    private var admissions: [Key: [Admission]] = [:]

    func admit(
        action: String,
        scope: String?,
        document: DocumentIdentity,
        frameInfo: WKFrameInfo,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        admit(
            action: action,
            scope: scope,
            document: document,
            frame: WebViewTrustedUserActionFrameIdentity(frameInfo),
            now: now
        )
    }

    func admit(
        action: String,
        scope: String?,
        document: DocumentIdentity,
        frame: WebViewTrustedUserActionFrameIdentity,
        now: TimeInterval
    ) -> Bool {
        guard Self.accepts(action: action, scope: scope) else { return false }
        prune(now: now)
        guard admissionCount < Self.maximumAdmissionCount else { return false }
        let key = Key(
            document: document,
            frame: frame,
            action: action
        )
        admissions[key, default: []].append(
            Admission(
                id: UUID(),
                scope: scope,
                source: .isolatedUserActivation,
                expiresAt: now + Self.lifetime
            )
        )
        return true
    }

    func consume(
        action: String,
        document: DocumentIdentity,
        frameInfo: WKFrameInfo,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> WebViewTrustedUserAction? {
        consume(
            action: action,
            document: document,
            frame: WebViewTrustedUserActionFrameIdentity(frameInfo),
            now: now
        )
    }

    func consume(
        action: String,
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
        let admission = candidates.removeFirst()
        if candidates.isEmpty {
            admissions.removeValue(forKey: key)
        } else {
            admissions[key] = candidates
        }
        return WebViewTrustedUserAction(
            action: action,
            scope: admission.scope,
            source: admission.source
        )
    }

    func invalidateAll() {
        admissions.removeAll(keepingCapacity: true)
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
                scope: nil,
                source: .nativeAuthorizedOperation,
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

    private static func accepts(action: String, scope: String?) -> Bool {
        !action.isEmpty
            && action.utf8.count <= maximumActionUTF8Bytes
            && (scope?.utf8.count ?? 0) <= maximumScopeUTF8Bytes
    }

    private var admissionCount: Int {
        admissions.values.reduce(into: 0) { $0 += $1.count }
    }

    private func prune(now: TimeInterval) {
        admissions = admissions.compactMapValues { candidates in
            let live = candidates.filter { $0.expiresAt >= now }
            return live.isEmpty ? nil : live
        }
    }
}

enum WebViewTrustedUserActionBroker {
    static let handlerName = "swiftUIWebViewTrustedUserAction"
    @MainActor
    static let world = WKContentWorld.world(
        name: "com.manabi.swiftui-webview.trusted-user-action"
    )

    /// This script runs outside the page content world. Page JavaScript cannot
    /// see its message handler or call its closure. `isTrusted` is only one
    /// input here: native also binds the short-lived admission to the exact
    /// WebView document generation, frame, and declared action, and consumes it
    /// once before dispatching the page message.
    ///
    /// Threat-contract boundary: this broker privately registers exact nodes in
    /// the app's reserved control-selector namespace. It ignores page-declared
    /// authorization attributes, but it does not make page-owned layout immune
    /// to selector spoofing, control replacement, or clickjacking. A host that
    /// displays actively adversarial scripts must render these actions as
    /// native UI or as controls created and retained wholly by the isolated
    /// world. Reader-mode output is expected to enforce the reserved namespace
    /// and native handlers still validate document and semantic scope.
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
            const boundedScope = (value) => {
                if (typeof value !== 'string' || value.length === 0
                    || value.length > 4096) {
                    return null;
                }
                return value;
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
                try {
                    for (const action of admission.actions) {
                        globalThis.webkit.messageHandlers
                            .swiftUIWebViewTrustedUserAction.postMessage({
                                action,
                                scope: admission.scope,
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
}
