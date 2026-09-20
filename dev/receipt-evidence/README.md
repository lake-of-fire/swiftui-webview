# Native receipt evidence

Reader's selected baseline is `6628f7244d527959869a54f5f76b88a8aa845ebd`, two commits ahead of this repository's main when this repair began. Preserve those existing Reader-selected commits.

The coordinator now captures named immutable application evidence before either ordinary task scheduling or the optional trusted-action broker's deferred turn. Both delivery paths retain that same snapshot, and the asynchronous handler receives it as task-local transport. The existing WebView/document/cancellation guards remain in place. Application providers are installed once on MainActor before handler installation, capture afresh for each receipt, and must not retain mutable database objects. Final application write validation remains authoritative. The framework has no Common/Realm dependency.

SwiftPM automatically includes the helper; the standalone Xcode framework target also registers it explicitly.

The paired native dispatch tests use actual WebKit messages and the real coordinator. They deterministically advance a test lifetime after receipt capture but before handler entry without replacing the document. Ordinary and optional-broker-deferral routes are covered. The read-only negative control restores only the prior production scheduler while keeping identical test/helper sources; infrastructure, discovery, compilation and WebKit timeout errors do not count as behavioral red.

The portable harness in this directory executes the same production evidence types, including snapshot preservation, nested task-local isolation and missing/wrong-type fail-closed lookup. Initial preparation executed it in Debug and optimized Release on arm64 macOS 15.7.9 / Apple Swift 6.1.2; complete source syntax and Xcode project plist validation also passed. This is not a full package build or a Reader Realm test. The normal native workflow must qualify the final head separately.

The product commit's parent is the exact Reader baseline, not the temporary preparation workflow. No preparation script/workflow is included in product ancestry. No private application source was copied to this public repository.

## Boundary not claimed

Receipt capture closes the native-receipt-to-handler gap. An event generated in JavaScript before a lifetime transition but delivered to native afterward is a different producer-boundary question. An application cannot claim that this generic transport alone proves producer lifetime authority. The coordinated Core change must consume this evidence without late recapture, retain final same-Realm checks, and run its real retained-lifetime regression matrix.
