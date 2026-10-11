# MR-UNDO-CLOSEOUT-20260920 — W3

## Scope and exact revisions

This is a receipt-transport implementation/qualification checkpoint, not completion of the application's producer-to-receipt ownership repair.

- Reader product baseline: `6628f7244d527959869a54f5f76b88a8aa845ebd`.
- PR target `main` observed at `6cd5138bf39b71c42dca78e2b1770d7da4319434`. The product baseline already contains trusted-action broker deferral and additional selected commits; this repair retains them.
- Original receipt implementation: `485eb16705c09bfe94ae69c98b54628691d86c29`.
- Receipt ownership tests before the compilation correction: `07e13c499ea680ce7d79f951e738a9bbe65f4515`.
- Exact tested implementation head: `1b9a930acf7a293c9cc6b93d25d949cbc3c038ee`. This note is a documentation-only descendant; its containing commit is the handoff head. The PR records that resulting SHA.
- PR: https://github.com/lake-of-fire/swiftui-webview/pull/11
- Core companion: https://github.com/ManabiIO/ManabiReaderCore/pull/133 at implementation head `805d49de2c0fe33c9d7beae5506134c827c2a36e`.

## Interfaces and implementation

`WebViewMessageReceiptCapture` captures generic application evidence synchronously in the production coordinator, before ordinary scheduling or trusted-action broker deferral. `WebViewMessageReceiptContext.evidence` transports the same immutable value through handler execution. No Realm/Common dependency is introduced. Existing document, binding, owner and cancellation checks are retained.

W3's latest code correction explicitly types suspended test handlers as `@Sendable (WebViewMessage) async -> Void`. The previous native run failed to compile these closures; that was infrastructure/compilation failure, not behavioral RED.

The application must install its provider before registering affected handlers, consume missing evidence as missing (not recapture later), and retain its final same-Realm/account/lifetime admission checks. Captured initial absence is a value, not missing evidence. Receipt transport alone cannot distinguish an A-produced event whose first native delivery occurs after a same-document reset to B.

## Observed native evidence

Read the actual job logs, not just workflow status. Receipt-specific workflow on `1b9a930acf7a293c9cc6b93d25d949cbc3c038ee`:

https://github.com/lake-of-fire/swiftui-webview/actions/runs/35493225141

Job `106031615527`, macOS 15.7.9 arm64, Xcode 26.3 / Swift 6.2.4. GitHub's PR merge ref was checked out; this is vendor-package evidence, not a qualified Reader composition.

Command: `swift test --filter 'WebViewReceiptDispatchTests|WebViewReceiptOwnershipTests'`.

Observed: **8 tests, 0 failures**:

- `testTrustedActionDeferralCarriesTheOriginalReceiptEvidence`
- `testOrdinaryDispatchCapturesBeforeSchedulingAndSurvivesHandlerYield`
- `testCapturedAbsenceIsPreservedInsteadOfRecapturedAfterScheduling`
- `testBrokerDeferredStaleReceiptRejectsWhileFreshLifetimeSucceeds`
- `testConcurrentSameURLWebViewsKeepDistinctEvidenceAcrossSuspension`
- `testDocumentReplacementCancelsOldWorkButDeliversNewDocument`
- `testOrdinaryStaleReceiptRejectsWhileFreshLifetimeSucceeds`
- `testUnregisteredEvidenceRemainsMissingAtRealDelivery`

The same job restored only `Sources/SwiftUIWebView/SwiftUIWebView.swift` from the exact product baseline and ran `WebViewReceiptDispatchTests`. It compiled and discovered all three tests, then produced **8 intended assertion failures in 3 tests**. The workflow rejects compilation/discovery/timeout failures as RED. Artifacts: `receipt-debug-logs` (`10609832971`), `negative-control-logs` (`10609832972`).

Broader CI: https://github.com/lake-of-fire/swiftui-webview/actions/runs/35493225175 . Release, AddressSanitizer and lint jobs report success. Debug reports **92 tests, 1 failure**: `WebViewUIStateTests.testRecoverableWaybackNavigationFailuresPreferLiveURLFallback` expected the live URL but observed the archive URL. All eight receipt tests passed in that run. This note does not classify the Wayback failure as pre-existing without a corresponding baseline run and does not call the whole CI matrix green.

## Outstanding application implementation and qualification

W3's producer-to-first-native-receipt repair is still outstanding in Core. It needs a real producer-held acceptance journey and either proof that the selected generation mechanism already rejects it or a native-issued document/frame/lifetime identity snapshot carried by the producer. Publication must follow successful transitions, preserve rollback recovery and first use, and retain final transaction admission. Merely refreshing a mutable token when a queued event is posted is insufficient.

The Core receipt dispatch/Realm tests are authored but not natively executed or proven discovered. Source-route/manual-command journeys, producer generation/account/binding coverage and receipt-capture cold/warm performance measurement remain unqualified. Vendor test duration is not a target-capture benchmark. No signed CloudKit or assembled Reader result is claimed.

W4 owns shared test/project membership, dependency composition, root gitlinks and final qualification. Do not merge the unrelated Core #130 audio/import bundle for this repair. No target branch has been merged and no release has been deployed.
