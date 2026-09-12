from pathlib import Path
import re

path = Path("Sources/SwiftUIWebView/SwiftUIWebView.swift")
source = path.read_text()

def replace_once(old: str, new: str, label: str) -> None:
    global source
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one source match, found {count}")
    source = source.replace(old, new, 1)

def replace_all_exact(old: str, new: str, expected: int, label: str) -> None:
    global source
    count = source.count(old)
    if count != expected:
        raise SystemExit(f"{label}: expected {expected} source matches, found {count}")
    source = source.replace(old, new)

def replace_regex(pattern: str, replacement: str, label: str) -> None:
    global source
    source, count = re.subn(pattern, replacement, source, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one regex match, found {count}")

# The coordinator owns the actual mounted WebView/document identity. Fence snapshots
# and expose that same generation to every JavaScript transaction.
replace_once(
'''        guard let scriptCaller else { return }
        scriptCaller.installBinding(
            ownedBy: scriptCallerBindingOwnerID,
            asyncCaller: asyncCaller,
            unsafeCaller: unsafeCaller,
            snapshotCapture: snapshotCapture,
            coordinateOriginInWindow: coordinateOriginInWindow,
            trustedUserActionAdmissionIssuer: {
''',
'''        guard let scriptCaller else { return }
        let fencedSnapshotCapture: WebViewScriptCaller.SnapshotCapture?
        if let snapshotCapture {
            fencedSnapshotCapture = { @MainActor [weak self, weak webView] request in
                try Task.checkCancellation()
                guard let self, let webView,
                      let context = self.captureDocumentCallbackContext(for: webView) else {
                    throw CancellationError()
                }
                let snapshot = try await snapshotCapture(request)
                try Task.checkCancellation()
                guard self.ownsDocumentCallbackContext(context) else {
                    throw CancellationError()
                }
                return snapshot
            }
        } else {
            fencedSnapshotCapture = nil
        }
        scriptCaller.installBinding(
            ownedBy: scriptCallerBindingOwnerID,
            asyncCaller: asyncCaller,
            unsafeCaller: unsafeCaller,
            snapshotCapture: fencedSnapshotCapture,
            coordinateOriginInWindow: coordinateOriginInWindow,
            documentGenerationProvider: { @MainActor [weak self] in
                self?.documentCallbackGeneration
            },
            trustedUserActionAdmissionIssuer: {
''',
"coordinator binding fence",
)

# Snapshot capture uses one frozen geometry snapshot in both directions and rejects
# cancellation/geometry changes across the WebKit await.
snapshot_function = '''@MainActor
func makeWebViewSnapshotCapture(
    for webView: WKWebView
) -> WebViewScriptCaller.SnapshotCapture {
    return { [weak webView] request in
        guard let webView else {
            throw WebViewScriptCallerSnapshotError.unavailable
        }

        try Task.checkCancellation()
        let captureBounds = webView.bounds
        let capturePageZoom = webView.pageZoom
        let requestedRect: CGRect?
        let requestedDOMViewport: CGRect?
        switch request {
        case .viewRect(let rect):
            requestedRect = rect
            requestedDOMViewport = nil
        case .domViewportRect(let rect, let viewportRect):
            requestedRect = try WebViewScriptCaller.resolvedViewRect(
                forDOMViewportRect: rect,
                viewportRect: viewportRect,
                in: captureBounds
            )
            requestedDOMViewport = viewportRect
        }
        let capturedRect = try WebViewScriptCaller.resolvedSnapshotRect(
            requestedRect,
            in: captureBounds
        )
        let configuration = makeWebViewSnapshotConfiguration(capturedRect: capturedRect)

        let image = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<WebViewSnapshotPlatformImage, Error>) in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    continuation.resume(
                        throwing: WebViewScriptCallerSnapshotError.captureFailed(
                            error.localizedDescription
                        )
                    )
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(
                        throwing: WebViewScriptCallerSnapshotError.imageConversionFailed
                    )
                }
            }
        }

        try Task.checkCancellation()
        guard webView.bounds == captureBounds,
              webView.pageZoom == capturePageZoom else {
            throw CancellationError()
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
            capturedRect: capturedRect,
            domViewportRect: requestedDOMViewport.map {
                WebViewScriptCaller.resolvedDOMViewportRect(
                    forViewRect: capturedRect,
                    viewportRect: $0,
                    in: captureBounds
                )
            }
        )
    }
}
'''
replace_regex(
    r'@MainActor\nprivate func makeWebViewSnapshotCapture\(\n.*?\n\}\n\n(?=@MainActor\nfunc makeWebViewSnapshotConfiguration)',
    snapshot_function,
    "snapshot capture function",
)

replace_once(
'''    public struct JavaScriptBindingToken: Equatable, Hashable, Sendable {
        fileprivate let callerID: String
        fileprivate let generation: Int
    }
''',
'''    public struct JavaScriptBindingToken: Equatable, Hashable, Sendable {
        fileprivate let callerID: String
        fileprivate let generation: Int
        fileprivate let documentGeneration: UInt64?
    }
''',
"binding token document generation",
)

replace_once(
'''    private var snapshotCaptureReadinessGeneration = 0
    private var bindingOwnerID: UUID?

    var asyncCaller: AsyncCaller? = nil {
''',
'''    private var snapshotCaptureReadinessGeneration = 0
    private var bindingOwnerID: UUID?
    private var documentGenerationProvider: (@MainActor @Sendable () -> UInt64?)?

    var asyncCaller: AsyncCaller? = nil {
''',
"document generation provider property",
)

replace_once(
'''    public var currentJavaScriptBindingToken: JavaScriptBindingToken? {
        guard asyncCaller != nil else { return nil }
        return JavaScriptBindingToken(
            callerID: id,
            generation: asyncCallerReadinessGeneration
        )
    }

    private func isCurrentJavaScriptBinding(_ token: JavaScriptBindingToken) -> Bool {
        token.callerID == id
            && token.generation == asyncCallerReadinessGeneration
            && asyncCaller != nil
    }
''',
'''    public var currentJavaScriptBindingToken: JavaScriptBindingToken? {
        guard asyncCaller != nil else { return nil }
        let documentGeneration = documentGenerationProvider?()
        guard documentGenerationProvider == nil || documentGeneration != nil else {
            return nil
        }
        return JavaScriptBindingToken(
            callerID: id,
            generation: asyncCallerReadinessGeneration,
            documentGeneration: documentGeneration
        )
    }

    private func isCurrentJavaScriptBinding(_ token: JavaScriptBindingToken) -> Bool {
        token.callerID == id
            && token.generation == asyncCallerReadinessGeneration
            && token.documentGeneration == documentGenerationProvider?()
            && asyncCaller != nil
    }
''',
"binding token validation",
)

replace_once(
'''        snapshotCapture: SnapshotCapture?,
        coordinateOriginInWindow: @escaping CoordinateOriginInWindow,
        trustedUserActionAdmissionIssuer:
''',
'''        snapshotCapture: SnapshotCapture?,
        coordinateOriginInWindow: @escaping CoordinateOriginInWindow,
        documentGenerationProvider: (@MainActor @Sendable () -> UInt64?)? = nil,
        trustedUserActionAdmissionIssuer:
''',
"install binding signature",
)

replace_once(
'''        removeAllMultiTargetFrames()
        bindingOwnerID = ownerID
        self.asyncCaller = asyncCaller
''',
'''        removeAllMultiTargetFrames()
        bindingOwnerID = ownerID
        self.documentGenerationProvider = documentGenerationProvider
        self.asyncCaller = asyncCaller
''',
"install binding body",
)

replace_once(
'''        removeAllMultiTargetFrames()
        bindingOwnerID = nil
        asyncCaller = nil
''',
'''        removeAllMultiTargetFrames()
        bindingOwnerID = nil
        documentGenerationProvider = nil
        asyncCaller = nil
''',
"clear binding body",
)

replace_once(
'''    private struct JavaScriptEvaluationContext {
        let asyncCaller: AsyncCaller
        let frameContextGeneration: UInt64
        let childFrames: [(uuid: String, frame: WKFrameInfo)]
    }

    private var multiTargetFrames = [String: WKFrameInfo]()
    private var framesByCanonicalURL = [String: WKFrameInfo]()
''',
'''    private struct JavaScriptEvaluationContext {
        let asyncCaller: AsyncCaller
        let bindingToken: JavaScriptBindingToken
        let frameContextGeneration: UInt64
        let childFrames: [(uuid: String, frame: WKFrameInfo)]
    }

    private var multiTargetFrames = [String: WKFrameInfo]()
    private var trackedWordTargetFrameUUIDs = Set<String>()
    private var framesByCanonicalURL = [String: WKFrameInfo]()
''',
"evaluation context and tracked-word registry",
)

replace_regex(
    r'''    private func makeJavaScriptEvaluationContext\(
        excluding primaryFrame: WKFrameInfo\? = nil,
        includeChildFrames: Bool
    \) -> JavaScriptEvaluationContext\? \{
.*?
    \}

(?=    private func requireCurrentFrameContext)''',
'''    private func makeJavaScriptEvaluationContext(
        excluding primaryFrame: WKFrameInfo? = nil,
        includeChildFrames: Bool
    ) -> JavaScriptEvaluationContext? {
        guard let asyncCaller,
              let bindingToken = currentJavaScriptBindingToken else {
            return nil
        }
        let childFrames: [(uuid: String, frame: WKFrameInfo)]
        if includeChildFrames {
            childFrames = multiTargetFrames
                .compactMap { uuid, frame -> (uuid: String, frame: WKFrameInfo)? in
                    guard !frame.isMainFrame, frame !== primaryFrame else { return nil }
                    return (uuid, frame)
                }
                .sorted { $0.uuid < $1.uuid }
        } else {
            childFrames = []
        }
        return JavaScriptEvaluationContext(
            asyncCaller: asyncCaller,
            bindingToken: bindingToken,
            frameContextGeneration: frameContextGeneration,
            childFrames: childFrames
        )
    }

''',
"evaluation context factory",
)

# Preserve UUID aliases for the same WKFrameInfo. Distinct runtime UUIDs are distinct
# registrations even when WebKit currently exposes the same wrapper object.
replace_regex(
    r'''    public func addMultiTargetFrame\(_ frame: WKFrameInfo, uuid: String, canonicalURL: URL\? = nil\) -> Bool \{
        for aliasUUID in multiTargetFrames\.compactMap\(\{ candidateUUID, candidateFrame in
            candidateUUID != uuid && candidateFrame === frame \? candidateUUID : nil
        \}\) \{
            removeRegisteredFrame\(uuid: aliasUUID, expectedFrame: frame\)
        \}
''',
'''    public func addMultiTargetFrame(_ frame: WKFrameInfo, uuid: String, canonicalURL: URL? = nil) -> Bool {
''',
"retain same-frame aliases",
)

replace_once(
'''        multiTargetFrames.removeValue(forKey: uuid)
        if let canonicalKey = canonicalFrameKeyByUUID.removeValue(forKey: uuid),
''',
'''        multiTargetFrames.removeValue(forKey: uuid)
        trackedWordTargetFrameUUIDs.remove(uuid)
        if let canonicalKey = canonicalFrameKeyByUUID.removeValue(forKey: uuid),
''',
"tracked-word removal",
)

replace_once(
'''        if registeredFrame === lastKnownMainFrame {
            lastKnownMainFrame = nil
        }
''',
'''        if registeredFrame === lastKnownMainFrame {
            lastKnownMainFrame = multiTargetFrames.values.first(where: {
                $0 === registeredFrame && $0.isMainFrame
            })
        }
''',
"main-frame alias retention",
)

dispatch_helpers = '''    /// Dispatches only while both the installed binding/document token and the
    /// frame-registration transaction remain current. Stale failures are rejected
    /// before they can trigger recovery or retire replacement frame registrations.
    private func evaluateBoundJavaScript(
        _ caller: AsyncCaller,
        _ token: JavaScriptBindingToken,
        _ script: String,
        _ arguments: [String: any Sendable]?,
        _ frame: WKFrameInfo?,
        _ world: WKContentWorld?,
        expectedFrameContextGeneration: UInt64
    ) async throws -> JavaScriptEvaluationResult {
        try validateJavaScriptOperation(token)
        try requireCurrentFrameContext(expectedFrameContextGeneration)
        let result: JavaScriptEvaluationResult
        do {
            result = try await caller(script, arguments, frame, world)
        } catch {
            try validateJavaScriptOperation(token)
            try requireCurrentFrameContext(expectedFrameContextGeneration)
            let nsError = error as NSError
            if let frame,
               nsError.domain == WKError.errorDomain,
               nsError.code == WKError.javaScriptInvalidFrameTarget.rawValue {
                removeRegisteredFrame(
                    frame,
                    expectedContextGeneration: expectedFrameContextGeneration
                )
            }
            throw error
        }
        try validateJavaScriptOperation(token)
        try requireCurrentFrameContext(expectedFrameContextGeneration)
        return result
    }

    private func validateJavaScriptOperation(_ token: JavaScriptBindingToken) throws {
        try Task.checkCancellation()
        guard isCurrentJavaScriptBinding(token) else {
            throw CancellationError()
        }
    }

'''
marker = '''    //    @MainActor
    @discardableResult
    public func evaluateJavaScript(
'''
replace_once(marker, dispatch_helpers + marker, "dispatch fencing helpers")

# Both evaluation entry points now carry the exact binding/document token captured
# alongside the frame-context snapshot.
replace_all_exact(
'''        let asyncCaller = evaluationContext.asyncCaller
        let primitiveArguments: [String: any Sendable]? = arguments?.mapValues {
''',
'''        let asyncCaller = evaluationContext.asyncCaller
        let bindingToken = evaluationContext.bindingToken
        let primitiveArguments: [String: any Sendable]? = arguments?.mapValues {
''',
2,
"evaluation binding token locals",
)

replace_once(
'''            result = try await asyncCaller(js, primitiveArguments, frame, world).value
        } catch {
            primaryError = error
''',
'''            result = try await evaluateBoundJavaScript(
                asyncCaller,
                bindingToken,
                js,
                primitiveArguments,
                frame,
                world,
                expectedFrameContextGeneration: evaluationContext.frameContextGeneration
            ).value
        } catch {
            if error is CancellationError { throw error }
            primaryError = error
''',
"primary JavaScript dispatch",
)

replace_once(
'''                    _ = try await asyncCaller(js, primitiveArguments, targetFrame, world).value
                    try requireCurrentFrameContext(evaluationContext.frameContextGeneration)
                } catch {
                    try requireCurrentFrameContext(evaluationContext.frameContextGeneration)
                    if let error = error as? WKError, error.code == .javaScriptInvalidFrameTarget {
''',
'''                    _ = try await evaluateBoundJavaScript(
                        asyncCaller,
                        bindingToken,
                        js,
                        primitiveArguments,
                        targetFrame,
                        world,
                        expectedFrameContextGeneration: evaluationContext.frameContextGeneration
                    ).value
                    try requireCurrentFrameContext(evaluationContext.frameContextGeneration)
                } catch {
                    try requireCurrentFrameContext(evaluationContext.frameContextGeneration)
                    if error is CancellationError { throw error }
                    if let error = error as? WKError, error.code == .javaScriptInvalidFrameTarget {
''',
"optional child fanout dispatch",
)

replace_once(
'''                        result = try await asyncCaller(
                            "(function () { try { return String(window.location && window.location.href) } catch (_) { return null } })();",
                            primitiveArguments,
                            frame,
                            world
                        ).value
''',
'''                        result = try await evaluateBoundJavaScript(
                            asyncCaller,
                            bindingToken,
                            "(function () { try { return String(window.location && window.location.href) } catch (_) { return null } })();",
                            primitiveArguments,
                            frame,
                            world,
                            expectedFrameContextGeneration: evaluationContext.frameContextGeneration
                        ).value
''',
"coercion retry dispatch",
)

replace_once(
'''                if !handled {
                    // Treat unsupported result types as a benign nil so DOM snapshot can continue.
''',
'''                if !handled,
                   nsError.domain == WKError.errorDomain,
                   nsError.code == WKError.javaScriptResultTypeIsUnsupported.rawValue {
                    // Treat unsupported result types as a benign nil so DOM snapshot can continue.
''',
"coercion failure classification",
)

replace_once(
'''        try requireCurrentFrameContext(evaluationContext.frameContextGeneration)
        return normalizeJavaScriptResult(result)
''',
'''        try requireCurrentFrameContext(evaluationContext.frameContextGeneration)
        try validateJavaScriptOperation(bindingToken)
        return normalizeJavaScriptResult(result)
''',
"primary return fence",
)

replace_once(
'''            mainResult = try await asyncCaller(
                js,
                primitiveArguments,
                nil,
                world
            ).value
''',
'''            mainResult = try await evaluateBoundJavaScript(
                asyncCaller,
                bindingToken,
                js,
                primitiveArguments,
                nil,
                world,
                expectedFrameContextGeneration: evaluationContext.frameContextGeneration
            ).value
''',
"aggregate main dispatch",
)

replace_once(
'''                let result = try await asyncCaller(
                    js,
                    primitiveArguments,
                    targetFrame,
                    world
                ).value
''',
'''                let result = try await evaluateBoundJavaScript(
                    asyncCaller,
                    bindingToken,
                    js,
                    primitiveArguments,
                    targetFrame,
                    world,
                    expectedFrameContextGeneration: evaluationContext.frameContextGeneration
                ).value
''',
"aggregate child dispatch",
)

replace_once(
'''            } catch {
                try requireCurrentFrameContext(evaluationContext.frameContextGeneration)
                if let webKitError = error as? WKError,
''',
'''            } catch {
                try requireCurrentFrameContext(evaluationContext.frameContextGeneration)
                if error is CancellationError { throw error }
                if let webKitError = error as? WKError,
''',
"aggregate cancellation propagation",
)

replace_once(
'''        try requireCurrentFrameContext(evaluationContext.frameContextGeneration)
        return results
''',
'''        try requireCurrentFrameContext(evaluationContext.frameContextGeneration)
        try validateJavaScriptOperation(bindingToken)
        return results
''',
"aggregate return fence",
)

capture_methods = '''    @MainActor
    public func captureSnapshot(rect: CGRect? = nil) async throws -> WebViewSnapshotImage {
        try await captureSnapshot(.viewRect(rect))
    }

    /// Captures a rect expressed in top-frame DOM viewport coordinates.
    ///
    /// `viewportRect` is the top frame's visual viewport in the same CSS-point coordinate space as
    /// `domViewportRect`. This maps page zoom and visual-viewport offsets into WKWebView view points.
    @MainActor
    public func captureSnapshot(
        domViewportRect: CGRect,
        viewportRect: CGRect
    ) async throws -> WebViewSnapshotImage {
        try await captureSnapshot(
            .domViewportRect(domViewportRect, viewportRect: viewportRect)
        )
    }

    @MainActor
    private func captureSnapshot(
        _ request: SnapshotRequest
    ) async throws -> WebViewSnapshotImage {
        try Task.checkCancellation()
        guard let capture = snapshotCapture else {
            throw WebViewScriptCallerSnapshotError.unavailable
        }
        let generation = snapshotCaptureReadinessGeneration
        let image = try await capture(request)
        try Task.checkCancellation()
        guard snapshotCaptureReadinessGeneration == generation,
              snapshotCapture != nil else {
            throw CancellationError()
        }
        return image
    }

'''
replace_regex(
    r'''    @MainActor
    public func captureSnapshot\(rect: CGRect\? = nil\) async throws -> WebViewSnapshotImage \{
.*?
(?=    nonisolated static func resolvedViewRect\()''',
    capture_methods,
    "snapshot public API generation fence",
)

tracked_method = '''    /// Registers a frame that owns a Manabi tracked-word document. General
    /// multi-target frames such as ebook viewer shells are deliberately not
    /// included in tracked-status mutation delivery.
    @MainActor
    @discardableResult
    public func addTrackedWordTargetFrame(
        _ frame: WKFrameInfo,
        uuid: String,
        canonicalURL: URL? = nil
    ) -> Bool {
        let changed = addMultiTargetFrame(
            frame,
            uuid: uuid,
            canonicalURL: canonicalURL
        )
        trackedWordTargetFrameUUIDs.insert(uuid)
        return changed
    }

'''
replace_once(
'''        return registrationChanged
    }
    
    @MainActor
    public func removeAllMultiTargetFrames() {
''',
'''        return registrationChanged
    }

''' + tracked_method + '''    @MainActor
    public func removeAllMultiTargetFrames() {
''',
"tracked-word registration API",
)

replace_once(
'''        multiTargetFrames.removeAll()
        framesByCanonicalURL.removeAll()
''',
'''        multiTargetFrames.removeAll()
        trackedWordTargetFrameUUIDs.removeAll()
        framesByCanonicalURL.removeAll()
''',
"tracked-word clear",
)

tracked_identities = '''    /// Returns every still-registered tracked-word target together with the
    /// runtime UUID that the target document must acknowledge.
    @MainActor
    public func registeredTrackedWordFrameIdentities() -> [
        (uuid: String, frame: WKFrameInfo)
    ] {
        trackedWordTargetFrameUUIDs
            .compactMap { uuid in
                multiTargetFrames[uuid].map { (uuid: uuid, frame: $0) }
            }
            .sorted { $0.uuid < $1.uuid }
    }

'''
replace_once(
'''    @MainActor
    public var mainFrameInfo: WKFrameInfo? {
''',
tracked_identities + '''    @MainActor
    public var mainFrameInfo: WKFrameInfo? {
''',
"tracked-word identity API",
)

# Sanity checks for the composed invariants.
required = [
    "fileprivate let documentGeneration: UInt64?",
    "private var documentGenerationProvider:",
    "let bindingToken: JavaScriptBindingToken",
    "private var trackedWordTargetFrameUUIDs = Set<String>()",
    "private func validateJavaScriptOperation",
    "expectedFrameContextGeneration:",
    "private func captureSnapshot(",
    "public func addTrackedWordTargetFrame(",
    "public func registeredTrackedWordFrameIdentities()",
]
for needle in required:
    if needle not in source:
        raise SystemExit(f"missing composed invariant: {needle}")

if source.count("public func captureSnapshot(\n        domViewportRect: CGRect,") != 1:
    raise SystemExit("DOM snapshot overload must exist exactly once")

path.write_text(source)
