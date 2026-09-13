from pathlib import Path

path = Path("Tests/SwiftUIWebViewTests/WebViewNativeLookupHitTestStoreTests.swift")
text = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label} count={count}")
    text = text.replace(old, new, 1)


# Publication probes and observers are intentionally DEBUG-only production
# seams. Their tests should have exactly the same availability in Release.
replace_once(
    "    func testTargetPublicationProbeDoesNotNotifyForRedundantEmptyClear() {",
    "#if DEBUG\n    func testTargetPublicationProbeDoesNotNotifyForRedundantEmptyClear() {",
    "publication debug guard start",
)
replace_once(
    "    func testLateBarrierRemovesOnlyOlderFramePublications() {",
    "#endif\n\n    func testLateBarrierRemovesOnlyOlderFramePublications() {",
    "publication debug guard end",
)

# Keep the production late-barrier test in Release; only its optional probe
# diagnostics depend on DEBUG-only API.
probe_assertions = """        XCTAssertTrue(store.uiTestTargetProbeText.contains("surfaces=destination"))
        XCTAssertFalse(store.uiTestTargetProbeText.contains("surfaces=source"))
        XCTAssertFalse(store.uiTestTargetProbeText.contains("surfaces=legacy"))
"""
replace_once(
    probe_assertions,
    "#if DEBUG\n" + probe_assertions + "#endif\n",
    "late barrier debug assertions",
)

# Synthetic UI-test taps exist only in DEBUG production code. Preserve the
# methods and assertions in Debug while excluding them from Release compile.
replace_once(
    "    func testUITestTapDispatchesFirstGeometryTargetWithoutRequiringEagerPayload() {",
    "#if DEBUG\n    func testUITestTapDispatchesFirstGeometryTargetWithoutRequiringEagerPayload() {",
    "ui test debug guard start",
)
replace_once(
    "    func testWrappedSegmentDoesNotClaimBlankSpaceBetweenComponentRects() {",
    "#endif\n\n    func testWrappedSegmentDoesNotClaimBlankSpaceBetweenComponentRects() {",
    "ui test debug guard end",
)

path.write_text(text)
