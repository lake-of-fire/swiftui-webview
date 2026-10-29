#if os(iOS)
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
final class WebViewPageTopColorTests: XCTestCase {
    func testUniformStripKeepsItsColorEvenWithZeroTolerance() throws {
        let color = try XCTUnwrap(WebViewPageTopColorPolicy.color(in: image(.red).cgImage!, maxDifference: 0))
        assertColor(color, equals: .red)
    }

    func testThresholdRejectsMixedColorsAndCanBeRelaxed() {
        let strip = image(.red, other: .blue).cgImage!
        XCTAssertNil(WebViewPageTopColorPolicy.color(in: strip, maxDifference: 5))
        XCTAssertNotNil(WebViewPageTopColorPolicy.color(in: strip, maxDifference: 200))
    }

    func testSmallVariationPassesDefaultButNotZeroTolerance() {
        let strip = image(.white, other: UIColor(white: 0.98, alpha: 1)).cgImage!
        XCTAssertNotNil(WebViewPageTopColorPolicy.color(in: strip, maxDifference: 5))
        XCTAssertNil(WebViewPageTopColorPolicy.color(in: strip, maxDifference: 0))
    }

    func testNarrowContrastingBandIsNotLostBetweenSampleRows() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let strip = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 8), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 8))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 3, width: 128, height: 1))
        }
        XCTAssertNil(WebViewPageTopColorPolicy.color(in: strip.cgImage!, maxDifference: 5))
    }

    func testTransparentStripAndInvalidThresholdsAreRejected() {
        XCTAssertNil(WebViewPageTopColorPolicy.color(in: image(.clear).cgImage!, maxDifference: 5))
        for threshold in [-1, Double.nan, .infinity] {
            XCTAssertNil(WebViewPageTopColorPolicy.color(in: image(.white).cgImage!, maxDifference: threshold))
        }
    }

    func testStripStartsBelowNativeInsetsAndRejectsUnusableBounds() {
        XCTAssertEqual(WebViewPageTopColorPolicy.sampleRect(bounds: CGRect(x: 0, y: 0, width: 390, height: 844), topInset: 80),
                       CGRect(x: 0, y: 80, width: 390, height: 8))
        XCTAssertNil(WebViewPageTopColorPolicy.sampleRect(bounds: .zero, topInset: 0))
        XCTAssertNil(WebViewPageTopColorPolicy.sampleRect(bounds: CGRect(x: CGFloat.infinity, y: 0, width: 390, height: 844), topInset: 0))
        XCTAssertNil(WebViewPageTopColorPolicy.sampleRect(bounds: CGRect(x: 0, y: 0, width: 390, height: 80), topInset: 80))
    }

    func testConfigCopiesPreserveThresholdAndNormalizeInvalidInput() {
        let config = WebViewConfig(sampledPageTopColorMaxDifference: 12)
        XCTAssertEqual(config.withUserScripts([]).sampledPageTopColorMaxDifference, 12)
        XCTAssertEqual(config.withHidesTopScrollEdgeEffect(true).sampledPageTopColorMaxDifference, 12)
        XCTAssertEqual(WebViewConfig(sampledPageTopColorMaxDifference: -1).sampledPageTopColorMaxDifference, 0)
        XCTAssertEqual(WebViewConfig(sampledPageTopColorMaxDifference: .nan).sampledPageTopColorMaxDifference, 5)
    }

    func testCancelledSnapshotCannotRecolorNewDocument() async {
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        var finish: CheckedContinuation<UIImage?, Never>?
        let sampler = WebViewPageTopColorSampler { _, _ in
            await withCheckedContinuation { finish = $0 }
        }
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        await waitUntil { finish != nil }
        sampler.cancel()
        webView.underPageBackgroundColor = .green
        finish?.resume(returning: image(.red))
        await settle()
        assertColor(webView.underPageBackgroundColor, equals: .green)
        XCTAssertNil(webView.sampledUnderPageColor)
    }

    func testLostOwnershipAndChangedViewportRejectSnapshot() async {
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        var finish: CheckedContinuation<UIImage?, Never>?
        let ownership = TopColorDocumentOwnership()
        let sampler = WebViewPageTopColorSampler { _, _ in
            await withCheckedContinuation { finish = $0 }
        }
        sampler.schedule(webView: webView, config: config, isCurrent: { ownership.isCurrent })
        await waitUntil { finish != nil }
        ownership.isCurrent = false
        finish?.resume(returning: image(.red))
        await settle()
        XCTAssertNil(webView.sampledUnderPageColor)

        finish = nil
        ownership.isCurrent = true
        sampler.schedule(webView: webView, config: config, isCurrent: { ownership.isCurrent })
        await waitUntil { finish != nil }
        webView.scrollView.contentOffset.y += 10
        finish?.resume(returning: image(.red))
        await settle()
        XCTAssertNil(webView.sampledUnderPageColor)
    }

    func testMixedSnapshotRestoresConfiguredFallback() async {
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        let mixed = image(.red, other: .blue)
        let sampler = WebViewPageTopColorSampler { _, _ in mixed }
        webView.underPageBackgroundColor = .red
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        await waitUntil { self.colorsMatch(webView.underPageBackgroundColor, .green) }
        XCTAssertNil(webView.sampledUnderPageColor)
        assertColor(webView.scrollView.backgroundColor, equals: .green)
    }

    func testReaderReadinessChangeClearsPreviouslySampledColorWithoutNavigation() {
        var state = WebViewState.empty
        let readerConfig = WebViewConfig(backgroundColor: Color(UIColor.green), usesSampledPageTopColorForUnderPageBackground: true,
                                         usesConfiguredBackgroundForReaderDocuments: true)
        let view = WebView(config: readerConfig, navigator: WebViewNavigator(),
                           state: Binding(get: { state }, set: { state = $0 }))
        let coordinator = view.makeCoordinatorForTesting()
        let webView = EnhancedWKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.applyVisualConfiguration(webView: webView, containerView: nil, coordinator: coordinator)
        webView.sampledUnderPageColor = .red
        webView.underPageBackgroundColor = .red
        webView.scrollView.backgroundColor = .red

        state.markReaderRenderReady()
        view.applyVisualConfiguration(webView: webView, containerView: nil, coordinator: coordinator)

        XCTAssertNil(webView.sampledUnderPageColor)
        assertColor(webView.underPageBackgroundColor, equals: .green)
        assertColor(webView.scrollView.backgroundColor, equals: .green)
    }

    func testSnapshotFailureRestoresFallbackAndAllowsNextRequest() async {
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        var calls = 0
        let blue = image(.blue)
        let sampler = WebViewPageTopColorSampler { _, _ in
            calls += 1
            if calls == 1 { throw NSError(domain: "SnapshotTest", code: 1) }
            return blue
        }
        webView.sampledUnderPageColor = .red
        webView.underPageBackgroundColor = .red
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        await waitUntil { webView.sampledUnderPageColor == nil }
        assertColor(webView.underPageBackgroundColor, equals: .green)
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        await waitUntil { self.colorsMatch(webView.sampledUnderPageColor, .blue) }
        XCTAssertEqual(calls, 2)
    }

    func testCancellationDropsQueuedRequestBehindUncancellableSnapshot() async {
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        var calls = 0
        var finish: CheckedContinuation<UIImage?, Never>?
        let sampler = WebViewPageTopColorSampler { _, _ in
            calls += 1
            return await withCheckedContinuation { finish = $0 }
        }
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        await waitUntil { finish != nil }
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        try? await Task.sleep(nanoseconds: 300_000_000)
        sampler.cancel()
        finish?.resume(returning: image(.red))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(webView.sampledUnderPageColor)
    }

    func testInsetChangeRejectsSnapshot() async {
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        var finish: CheckedContinuation<UIImage?, Never>?
        let sampler = WebViewPageTopColorSampler { _, _ in
            await withCheckedContinuation { finish = $0 }
        }
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        await waitUntil { finish != nil }
        webView.scrollView.contentInset.top += 20
        finish?.resume(returning: image(.red))
        await settle()
        XCTAssertNil(webView.sampledUnderPageColor)
    }

    func testPageZoomChangeRejectsInFlightSnapshot() async {
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        var finish: CheckedContinuation<UIImage?, Never>?
        let sampler = WebViewPageTopColorSampler { _, _ in
            await withCheckedContinuation { finish = $0 }
        }
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        await waitUntil { finish != nil }
        let offset = webView.scrollView.contentOffset
        webView.pageZoom = 1.5
        webView.scrollView.contentOffset = offset
        finish?.resume(returning: image(.red))
        await settle()
        XCTAssertNil(webView.sampledUnderPageColor, "Pixels captured at the old zoom must not recolor the new viewport.")
    }

    func testPageZoomConfigurationInvalidatesPreviouslySampledColor() {
        let navigator = WebViewNavigator()
        let view = WebView(config: config, navigator: navigator, state: .constant(.empty))
        let coordinator = view.makeCoordinatorForTesting()
        let webView = EnhancedWKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.applyVisualConfiguration(webView: webView, containerView: nil, coordinator: coordinator)
        webView.sampledUnderPageColor = .red
        webView.underPageBackgroundColor = .red
        let zoomedConfig = WebViewConfig(pageZoom: 1.5, backgroundColor: Color(UIColor.green), usesSampledPageTopColorForUnderPageBackground: true)
        let zoomed = WebView(config: zoomedConfig, navigator: navigator, state: .constant(.empty))
        webView.pageZoom = zoomedConfig.pageZoom
        zoomed.applyVisualConfiguration(webView: webView, containerView: nil, coordinator: coordinator)
        XCTAssertNil(webView.sampledUnderPageColor)
        assertColor(webView.underPageBackgroundColor, equals: .green)
    }

    func testLoadingIdleTransitionResumesSamplingWithoutAnotherNavigation() async throws {
        try await requireForegroundScene()
        let controlled = LoadingPageColorWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let (window, webView) = mountedWebView(controlled)
        defer { window.isHidden = true; webView.navigationDelegate = nil }
        let navigation = FinishedNavigation()
        var state = WebViewState.empty
        let navigator = WebViewNavigator()
        navigator.shouldLoadFallbackOnAttach = false
        let view = WebView(config: config, navigator: navigator,
                           state: Binding(get: { state }, set: { state = $0 }),
                           onNavigationFinished: { _ in navigation.finished = true })
        let coordinator = view.makeCoordinatorForTesting()
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.setWebView(webView)
        webView.navigationDelegate = coordinator
        webView.loadHTMLString("<html><body style='margin:0;background:red;height:1500px'></body></html>", baseURL: nil)
        await waitUntil { navigation.finished }
        let background = try await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
        XCTAssertEqual(background, "rgb(255, 0, 0)", "The idle retry must sample the loaded document, not an attach fallback.")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(webView.isLoading)
        XCTAssertNil(webView.sampledUnderPageColor)

        let loadingState = TopColorLoadingState()
        let idleObservation = webView.observe(\.isLoading, options: [.new]) { _, change in
            guard change.newValue == false else { return }
            Task { @MainActor in loadingState.observedIdle = true }
        }
        defer { idleObservation.invalidate() }
        controlled.finishSimulatedLoading()
        await waitUntil { loadingState.observedIdle }
        await waitUntil { self.colorsMatch(webView.sampledUnderPageColor, .red) }
        assertColor(webView.underPageBackgroundColor, equals: .red)
    }

    func testReaderTransitionDuringSnapshotKeepsConfiguredTheme() async {
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        let delegate = FinishedNavigation()
        webView.navigationDelegate = delegate
        defer { webView.navigationDelegate = nil }
        webView.loadHTMLString("<html><body style='background:red'>Page</body></html>", baseURL: nil)
        await waitUntil { delegate.finished }
        var finish: CheckedContinuation<UIImage?, Never>?
        let sampler = WebViewPageTopColorSampler { _, _ in
            await withCheckedContinuation { finish = $0 }
        }
        let readerConfig = WebViewConfig(backgroundColor: Color(UIColor.green), usesSampledPageTopColorForUnderPageBackground: true,
                                         usesConfiguredBackgroundForReaderDocuments: true)
        webView.underPageBackgroundColor = .blue
        sampler.schedule(webView: webView, config: readerConfig, isCurrent: { true })
        await waitUntil { finish != nil }
        _ = try? await webView.evaluateJavaScript("document.body.classList.add('readability-mode')")
        finish?.resume(returning: image(.red))
        await waitUntil { self.colorsMatch(webView.underPageBackgroundColor, .green) }
        XCTAssertNil(webView.sampledUnderPageColor)
    }

    func testRepeatedRequestsCoalesceAndNeverOverlapSnapshots() async {
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        var calls = 0
        var finishFirst: CheckedContinuation<UIImage?, Never>?
        let blue = image(.blue)
        let sampler = WebViewPageTopColorSampler { _, _ in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { finishFirst = $0 } }
            return blue
        }
        for _ in 0..<10 { sampler.schedule(webView: webView, config: config, isCurrent: { true }) }
        await waitUntil { finishFirst != nil }
        XCTAssertEqual(calls, 1)
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls, 1, "The previous uncancellable WebKit request must finish first")
        finishFirst?.resume(returning: image(.red))
        await waitUntil { webView.sampledUnderPageColor != nil }
        XCTAssertEqual(calls, 2)
        assertColor(webView.sampledUnderPageColor, equals: .blue)
    }

    func testDisablingSamplingClearsColorWithoutTakingSnapshot() async {
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        var calls = 0
        let sampler = WebViewPageTopColorSampler { _, _ in calls += 1; return nil }
        webView.sampledUnderPageColor = .red
        sampler.schedule(webView: webView, config: WebViewConfig(backgroundColor: Color(UIColor.green)), isCurrent: { true })
        await waitUntil { webView.sampledUnderPageColor == nil }
        XCTAssertEqual(calls, 0)
        assertColor(webView.underPageBackgroundColor, equals: .green)
    }

    func testInactiveSceneDefersSamplingUntilActivation() async {
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        var snapshots = 0
        let red = image(.red)
        let sampler = WebViewPageTopColorSampler { _, _ in snapshots += 1; return red }
        sampler.setSceneActive(false)
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(snapshots, 0)
        sampler.setSceneActive(true)
        await waitUntil { webView.sampledUnderPageColor != nil }
        XCTAssertEqual(snapshots, 1)
        assertColor(webView.sampledUnderPageColor, equals: .red)
    }

    func testSceneDeactivationDiscardsInFlightColorAndResamplesOnReturn() async {
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        var firstSnapshot: CheckedContinuation<UIImage?, Never>?
        var snapshots = 0
        let blue = image(.blue)
        let sampler = WebViewPageTopColorSampler { _, _ in
            snapshots += 1
            if snapshots == 1 { return await withCheckedContinuation { firstSnapshot = $0 } }
            return blue
        }
        webView.underPageBackgroundColor = .green
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        await waitUntil { firstSnapshot != nil }
        sampler.setSceneActive(false)
        firstSnapshot?.resume(returning: image(.red))
        await settle()
        XCTAssertNil(webView.sampledUnderPageColor)
        assertColor(webView.underPageBackgroundColor, equals: .green)
        sampler.setSceneActive(true)
        await waitUntil { webView.sampledUnderPageColor != nil }
        XCTAssertEqual(snapshots, 2)
        assertColor(webView.sampledUnderPageColor, equals: .blue)
    }

    func testCancelledOrRetiredRequestDoesNotResumeOnActivation() async {
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        var snapshots = 0
        let sampler = WebViewPageTopColorSampler { _, _ in snapshots += 1; return nil }
        sampler.setSceneActive(false)
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        sampler.cancel()
        sampler.setSceneActive(true)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(snapshots, 0)

        let ownership = TopColorDocumentOwnership()
        sampler.setSceneActive(false)
        sampler.schedule(webView: webView, config: config, isCurrent: { ownership.isCurrent })
        ownership.isCurrent = false
        sampler.setSceneActive(true)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(snapshots, 0)
    }

    func testPublicSnapshotSamplesRenderedPageAndPreservesReaderTheme() async throws {
        try await requireForegroundScene()
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        let delegate = FinishedNavigation()
        webView.navigationDelegate = delegate
        webView.loadHTMLString("<html><body style='margin:0;background:rgb(255,0,0);height:1500px'></body></html>", baseURL: nil)
        await waitUntil { delegate.finished }
        var snapshotDetails = "snapshot not requested"
        let sampler = WebViewPageTopColorSampler { view, configuration in
            do {
                let image = try await view.takeSnapshot(configuration: configuration)
                let accepted = image.cgImage.flatMap { WebViewPageTopColorPolicy.color(in: $0, maxDifference: 5) }
                snapshotDetails = "image=\(image.size), accepted=\(String(describing: accepted)), rect=\(configuration.rect), pixels=\(self.pixelSummary(image.cgImage))"
                return image
            } catch {
                snapshotDetails = "snapshot error: \(error)"
                throw error
            }
        }
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        await waitUntil { webView.sampledUnderPageColor != nil }
        XCTAssertNotNil(webView.sampledUnderPageColor, snapshotDetails)
        if webView.sampledUnderPageColor != nil { assertColor(webView.sampledUnderPageColor, equals: .red) }

        _ = try? await webView.evaluateJavaScript("document.body.classList.add('readability-mode')")
        let readerConfig = WebViewConfig(backgroundColor: Color(UIColor.green), usesSampledPageTopColorForUnderPageBackground: true,
                                         usesConfiguredBackgroundForReaderDocuments: true)
        sampler.schedule(webView: webView, config: readerConfig, isCurrent: { true })
        await waitUntil { webView.sampledUnderPageColor == nil }
        assertColor(webView.underPageBackgroundColor, equals: .green)
        webView.navigationDelegate = nil
    }

    func testPublicSnapshotTracksVisibleContentAfterScrollingAndInsets() async throws {
        try await requireForegroundScene()
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        let delegate = FinishedNavigation()
        webView.navigationDelegate = delegate
        defer { webView.navigationDelegate = nil }
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset.top = 40
        webView.loadHTMLString("""
            <html><meta name='viewport' content='width=device-width,initial-scale=1'>
            <body style='margin:0;background:blue;height:2000px'><div style='height:200px;background:red'></div></body></html>
            """, baseURL: nil)
        await waitUntil { delegate.finished }
        webView.scrollView.setContentOffset(CGPoint(x: 0, y: -40), animated: false)
        let sampler = WebViewPageTopColorSampler()
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        await waitUntil { self.colorsMatch(webView.sampledUnderPageColor, .red) }

        webView.scrollView.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        await waitUntil { self.colorsMatch(webView.sampledUnderPageColor, .blue) }
        assertColor(webView.underPageBackgroundColor, equals: .blue)
    }

    func testPublicSnapshotAppliesColorDifferenceThresholdToRenderedPixels() async throws {
        try await requireForegroundScene()
        let (window, webView) = mountedWebView()
        defer { window.isHidden = true }
        let delegate = FinishedNavigation()
        webView.navigationDelegate = delegate
        defer { webView.navigationDelegate = nil }
        webView.loadHTMLString("""
            <html><body style='margin:0;height:1500px;background:linear-gradient(to right,red 50%,blue 50%)'></body></html>
            """, baseURL: nil)
        await waitUntil { delegate.finished }
        webView.sampledUnderPageColor = .red
        webView.underPageBackgroundColor = .red
        let sampler = WebViewPageTopColorSampler()
        sampler.schedule(webView: webView, config: config, isCurrent: { true })
        await waitUntil { webView.sampledUnderPageColor == nil }
        assertColor(webView.underPageBackgroundColor, equals: .green)

        let relaxed = WebViewConfig(backgroundColor: Color(UIColor.green), usesSampledPageTopColorForUnderPageBackground: true,
                                    sampledPageTopColorMaxDifference: 200)
        sampler.schedule(webView: webView, config: relaxed, isCurrent: { true })
        await waitUntil { webView.sampledUnderPageColor != nil }
        assertColor(webView.sampledUnderPageColor, equals: UIColor(red: 0.5, green: 0, blue: 0.5, alpha: 1))
    }

    private func requireForegroundScene() async throws {
        func isForeground() -> Bool {
            UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene && $0.activationState == .foregroundActive }
        }
#if WEBVIEW_RENDERING_TEST_HOST
        await waitUntil { isForeground() }
        guard isForeground() else {
            throw NSError(domain: "WebViewRenderingTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Rendering test host did not activate a foreground scene"])
        }
#else
        guard isForeground() else {
            throw XCTSkip("Rendered WebKit pixels require the WebViewRenderingTests foreground host")
        }
#endif
    }

    private var config: WebViewConfig {
        WebViewConfig(backgroundColor: Color(UIColor.green), usesSampledPageTopColorForUnderPageBackground: true)
    }

    private func mountedWebView(_ suppliedWebView: EnhancedWKWebView? = nil) -> (UIWindow, EnhancedWKWebView) {
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window: UIWindow
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        let controller = UIViewController()
        window.rootViewController = controller
        let webView = suppliedWebView ?? EnhancedWKWebView(frame: window.bounds)
        webView.frame = window.bounds
        controller.view.addSubview(webView)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        return (window, webView)
    }

    private func colorsMatch(_ actual: UIColor?, _ expected: UIColor) -> Bool {
        guard let actual else { return false }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
        guard actual.getRed(&r, green: &g, blue: &b, alpha: &a),
              expected.getRed(&er, green: &eg, blue: &eb, alpha: &ea) else { return false }
        return zip([r, g, b, a], [er, eg, eb, ea]).allSatisfy { abs($0 - $1) < 0.02 }
    }

    private func pixelSummary(_ image: CGImage?) -> String {
        guard let image else { return "missing CGImage" }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { data in
            let context = CGContext(data: data.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return "\(image.width)x\(image.height) rows=" + (0..<image.height).map { row in
            let offset = (row * image.width + image.width / 2) * 4
            return String(describing: Array(pixels[offset..<(offset + 4)]))
        }.joined(separator: ",")
    }

    private func image(_ color: UIColor, other: UIColor? = nil) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 128, height: 2), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 2))
            if let other {
                other.setFill()
                context.fill(CGRect(x: 64, y: 0, width: 64, height: 2))
            }
        }
    }

    private func assertColor(_ actual: UIColor?, equals expected: UIColor, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { XCTFail("Missing color", file: file, line: line); return }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
        XCTAssertTrue(actual.getRed(&r, green: &g, blue: &b, alpha: &a), file: file, line: line)
        XCTAssertTrue(expected.getRed(&er, green: &eg, blue: &eb, alpha: &ea), file: file, line: line)
        for (value, reference) in zip([r, g, b, a], [er, eg, eb, ea]) {
            XCTAssertEqual(value, reference, accuracy: 0.02, file: file, line: line)
        }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for sampler", file: file, line: line)
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }
}

@MainActor
private final class TopColorDocumentOwnership {
    var isCurrent = true
}

@MainActor
private final class TopColorLoadingState {
    var observedIdle = false
}

@MainActor
private final class LoadingPageColorWebView: EnhancedWKWebView {
    private var simulatesLoading = true
    override var isLoading: Bool { simulatesLoading || super.isLoading }

    func finishSimulatedLoading() {
        willChangeValue(forKey: #keyPath(WKWebView.isLoading))
        simulatesLoading = false
        didChangeValue(forKey: #keyPath(WKWebView.isLoading))
    }
}

@MainActor
private final class FinishedNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}
#endif
