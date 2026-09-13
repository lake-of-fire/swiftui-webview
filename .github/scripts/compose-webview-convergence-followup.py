from pathlib import Path
import re

source_path = Path("Sources/SwiftUIWebView/SwiftUIWebView.swift")
source = source_path.read_text()

# Older document-epoch tests predate current main's mounted-window geometry
# provider. Production callers remain explicit; focused/internal callers may
# omit it, where nil means no mounted-window coordinate origin.
pattern = (
    r"(func installScriptCallerBinding\([\s\S]*?"
    r"snapshotCapture: WebViewScriptCaller\.SnapshotCapture\?,\s*\n\s*)"
    r"coordinateOriginInWindow: @escaping "
    r"WebViewScriptCaller\.CoordinateOriginInWindow"
)
replacement = (
    r"\1coordinateOriginInWindow: @escaping "
    r"WebViewScriptCaller.CoordinateOriginInWindow = { nil }"
)
source, count = re.subn(pattern, replacement, source, count=1)
if count != 1:
    raise SystemExit(f"geometry compatibility seam count={count}")

# Binding/document generation is the cross-await transaction fence. Frame
# registration mutations are validated independently by exact UUID + handle;
# treating every frame-context generation change as transaction cancellation
# incorrectly rejects legitimate retire/replace operations inside fanout.
helper_pattern = (
    r"    private func evaluateBoundJavaScript\(\n"
    r".*?\n"
    r"    \}\n\n"
    r"(?=    private func validateJavaScriptOperation)"
)
helper_replacement = """    private func evaluateBoundJavaScript(
        _ caller: AsyncCaller,
        _ token: JavaScriptBindingToken,
        _ script: String,
        _ arguments: [String: any Sendable]?,
        _ frame: WKFrameInfo?,
        _ world: WKContentWorld?,
        expectedFrameContextGeneration _: UInt64
    ) async throws -> JavaScriptEvaluationResult {
        try validateJavaScriptOperation(token)
        let result: JavaScriptEvaluationResult
        do {
            result = try await caller(script, arguments, frame, world)
        } catch {
            try validateJavaScriptOperation(token)
            let nsError = error as NSError
            if let frame,
               nsError.domain == WKError.errorDomain,
               nsError.code == WKError.javaScriptInvalidFrameTarget.rawValue {
                // One WKFrameInfo may deliberately have several runtime UUID
                // aliases. A rejected exact handle invalidates all of them.
                removeRegisteredFrame(frame)
            }
            throw error
        }
        try validateJavaScriptOperation(token)
        return result
    }

"""
source, count = re.subn(
    helper_pattern,
    helper_replacement,
    source,
    count=1,
    flags=re.S,
)
if count != 1:
    raise SystemExit(f"evaluateBoundJavaScript replacement count={count}")

# Duplicate fanout iterates a frozen snapshot. An earlier invalid-frame error
# may have retired every UUID alias for the handle, so never dispatch a later
# stale alias from that snapshot.
single_old = """            for (uuid, targetFrame) in evaluationContext.childFrames {
                try requireCurrentFrameContext(evaluationContext.frameContextGeneration)
                do {
"""
single_new = """            for (uuid, targetFrame) in evaluationContext.childFrames {
                try requireCurrentFrameContext(evaluationContext.frameContextGeneration)
                guard multiTargetFrames[uuid] === targetFrame else { continue }
                do {
"""
if source.count(single_old) != 1:
    raise SystemExit(f"duplicate fanout loop count={source.count(single_old)}")
source = source.replace(single_old, single_new, 1)

# Aggregate results must keep document/binding continuity while allowing frame
# registration churn. Each child result is admitted only while its exact
# UUID/handle mapping still exists. Optional fanout omits retired results;
# strict fanout converts that loss into cancellation.
aggregate_pattern = (
    r"    public func evaluateJavaScriptInMultiTargetFrames\(\n"
    r".*?\n"
    r"    \}\n\n"
    r"(?=    @MainActor\n"
    r"    public func captureSnapshot\(rect:)"
)
aggregate_replacement = """    public func evaluateJavaScriptInMultiTargetFrames(
        _ js: String,
        arguments: [String: any Sendable]? = nil,
        in world: WKContentWorld? = nil,
        propagatesFrameErrors: Bool = false,
        continueWhile shouldContinue: (@MainActor () -> Bool)? = nil,
        stopAfterResult shouldStopAfterResult: (@MainActor (Any?) -> Bool)? = nil
    ) async throws -> [Any?] {
        guard let evaluationContext = makeJavaScriptEvaluationContext(
            includeChildFrames: true
        ) else {
            reportUnboundEvaluation(
                operation: .evaluateJavaScriptInMultiTargetFrames,
                script: js
            )
            throw ScriptCallerError.evaluationTimedOut
        }
        let asyncCaller = evaluationContext.asyncCaller
        let bindingToken = evaluationContext.bindingToken
        let primitiveArguments: [String: any Sendable]? = arguments?.mapValues {
            if let set = $0 as? Set<AnyHashable> {
                return Array(set) as! any Sendable
            }
            return $0
        }

        func requireContinuation() throws {
            try validateJavaScriptOperation(bindingToken)
            guard shouldContinue?() != false else {
                throw CancellationError()
            }
        }

        try requireContinuation()
        let mainResult = try await evaluateBoundJavaScript(
            asyncCaller,
            bindingToken,
            js,
            primitiveArguments,
            nil,
            world,
            expectedFrameContextGeneration: evaluationContext.frameContextGeneration
        ).value
        try requireContinuation()
        let normalizedMainResult = normalizeJavaScriptResult(mainResult)
        var frameResults: [(uuid: String, frame: WKFrameInfo, value: Any?)] = []

        func finalizedResults() throws -> [Any?] {
            try requireContinuation()
            var finalized = [normalizedMainResult]
            for entry in frameResults {
                guard multiTargetFrames[entry.uuid] === entry.frame else {
                    if propagatesFrameErrors { throw CancellationError() }
                    continue
                }
                finalized.append(entry.value)
            }
            return finalized
        }

        if shouldStopAfterResult?(normalizedMainResult) == true {
            return try finalizedResults()
        }

        for (uuid, targetFrame) in evaluationContext.childFrames {
            try requireContinuation()
            guard multiTargetFrames[uuid] === targetFrame else {
                if propagatesFrameErrors { throw CancellationError() }
                continue
            }
            do {
                let result = try await evaluateBoundJavaScript(
                    asyncCaller,
                    bindingToken,
                    js,
                    primitiveArguments,
                    targetFrame,
                    world,
                    expectedFrameContextGeneration: evaluationContext.frameContextGeneration
                ).value
                try requireContinuation()
                guard multiTargetFrames[uuid] === targetFrame else {
                    if propagatesFrameErrors { throw CancellationError() }
                    continue
                }
                let normalizedResult = normalizeJavaScriptResult(result)
                frameResults.append((uuid, targetFrame, normalizedResult))
                if shouldStopAfterResult?(normalizedResult) == true {
                    return try finalizedResults()
                }
            } catch {
                if error is CancellationError { throw error }
                if propagatesFrameErrors { throw error }
            }
        }

        return try finalizedResults()
    }

"""
source, count = re.subn(
    aggregate_pattern,
    aggregate_replacement,
    source,
    count=1,
    flags=re.S,
)
if count != 1:
    raise SystemExit(f"aggregate evaluator replacement count={count}")

source_path.write_text(source)

# Multiple runtime UUIDs may deliberately alias one WKFrameInfo. Current main's
# two alias-collapsing expectations encode the superseded policy, so align them
# with the composed runtime semantics.
tests_path = Path("Tests/SwiftUIWebViewTests/WebViewScriptCallerTests.swift")
tests = tests_path.read_text()
old_one = """        XCTAssertNil(caller.exactFrame(
            forUUID: "old-runtime-frame",
            documentURL: documentURL
        ))
"""
new_one = """        XCTAssertTrue(caller.exactFrame(
            forUUID: "old-runtime-frame",
            documentURL: documentURL
        ) === frame)
"""
old_two = """        XCTAssertNil(caller.exactFrame(
            forUUID: "replacement-runtime-frame",
            documentURL: documentURL
        ))
"""
new_two = """        XCTAssertTrue(caller.exactFrame(
            forUUID: "replacement-runtime-frame",
            documentURL: documentURL
        ) === replacementFrame)
"""
if tests.count(old_one) != 1 or tests.count(old_two) != 1:
    raise SystemExit(
        "alias assertion preimages "
        f"old={tests.count(old_one)} replacement={tests.count(old_two)}"
    )
tests = tests.replace(old_one, new_one, 1).replace(old_two, new_two, 1)
tests_path.write_text(tests)
