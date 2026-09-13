# WebView convergence qualification — 2026-09-13

Candidate `778fcb814ac030a9b5eda642f2869fe95cddf79e` composes current Reader WebView `main@fd2a7a2b44e7bc321d25778a01bc8f64d6e49193` with the qualified document-epoch line `fe302bf8b7385d72778426ee20afad424ac80414`.

The composition preserves current-main native lookup/publication/binding identity, mounted coordinate origin, pooling/trusted-action and script-caller behavior while adding snapshot geometry/provider/document fencing, cancellation/rebinding fencing around JavaScript retries and fanout, exact frame URL/identity retirement, aggregate result fencing, and same-WKWebView document-generation validation.

Multiple UUID aliases for the same `WKFrameInfo` are intentionally preserved. Registry clearing is not itself treated as a document replacement; the composed document-generation token is the cross-document fence. Exact frame replacement/retirement remains UUID + `WKFrameInfo` identity based.

The current-main aggregate replacement test was updated to exercise the real document-generation fence rather than using frame-registry clearing as a proxy. Release-only test availability was aligned with production APIs that are already `#if DEBUG`; no DEBUG-only seam was promoted into release production code.

GitHub Actions run `34752728661` on macOS 15 / Xcode 26.3 / Swift 6.2.4 passed the exact generated composition through:

- full Debug package tests;
- full Release package tests;
- full AddressSanitizer Debug package tests (`ASAN_OPTIONS=detect_leaks=0`).

The run published the candidate only after all three gates passed. Leak checking is not claimed.