#if os(iOS)
import UIKit
import WebKit

/// Samples rendered pixels through public WebKit APIs. No page pixels leave memory.
@MainActor
final class WebViewPageTopColorSampler {
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var takingSnapshot = false
    private var pendingSample: (@MainActor () -> Void)?
    private var resumeSample: (@MainActor () -> Void)?
    private var isSceneActive = true
    private let snapshot: @MainActor (WKWebView, WKSnapshotConfiguration) async throws -> UIImage?

    init(snapshot: @escaping @MainActor (WKWebView, WKSnapshotConfiguration) async throws -> UIImage? = {
        try await $0.takeSnapshot(configuration: $1)
    }) {
        self.snapshot = snapshot
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        pendingSample = nil
        resumeSample = nil
    }

    func setSceneActive(_ active: Bool) {
        guard isSceneActive != active else { return }
        isSceneActive = active
        let resume = resumeSample
        cancel()
        if active { resume?() }
        else { resumeSample = resume }
    }

    func schedule(webView: WKWebView, config: WebViewConfig, isCurrent: @escaping @MainActor () -> Bool) {
        cancel()
        resumeSample = { [weak self, weak webView] in
            guard let self, let webView, isCurrent() else { return }
            self.schedule(webView: webView, config: config, isCurrent: isCurrent)
        }
        guard isSceneActive else { return }
        let request = generation
        task = Task { @MainActor [weak self, weak webView] in
            // Scrolling can issue many requests, but only a settled viewport is sampled.
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard let self, let webView else { return }
            // WebKit snapshots cannot be cancelled. Keep only the latest request and
            // resume it when the current snapshot finishes, without polling WebKit.
            if self.takingSnapshot {
                self.pendingSample = { [weak self, weak webView] in
                    guard let self, let webView, isCurrent() else { return }
                    self.schedule(webView: webView, config: config, isCurrent: isCurrent)
                }
                return
            }
            @MainActor func acceptsResult() -> Bool {
                !Task.isCancelled && self.generation == request && isCurrent()
                    && self.isSceneActive && !webView.isLoading
            }
            guard acceptsResult() else { return }
            let fallback = UIColor(config.backgroundColor)
            @MainActor func apply(_ sampled: UIColor?) {
                (webView as? EnhancedWKWebView)?.sampledUnderPageColor = sampled
                let color = sampled ?? fallback
                if !webView.underPageBackgroundColor.isEqual(color) {
                    webView.underPageBackgroundColor = color
                }
                if webView.scrollView.backgroundColor?.isEqual(color) != true {
                    webView.scrollView.backgroundColor = color
                }
            }
            guard config.usesSampledPageTopColorForUnderPageBackground else {
                apply(nil)
                return
            }
            if config.usesConfiguredBackgroundForReaderDocuments {
                if isReaderOwnedArticleDocument(webView.url) { apply(nil); return }
                // This checks presentation only; content/tracking facts remain native/sidecar-owned.
                let isReader = await self.isReaderDocument(webView)
                guard acceptsResult() else { return }
                // A failed presentation check must not sample a still-transforming Reader shell.
                guard isReader == false else { apply(nil); return }
            }
            guard webView.window != nil,
                  !webView.scrollView.isDragging, !webView.scrollView.isDecelerating,
                  !webView.scrollView.isZooming, !webView.scrollView.isZoomBouncing else { return }
            guard let rect = WebViewPageTopColorPolicy.sampleRect(
                    bounds: webView.bounds, topInset: webView.scrollView.adjustedContentInset.top
                  ) else { apply(nil); return }
            let snapshot = WKSnapshotConfiguration()
            snapshot.rect = rect
            snapshot.snapshotWidth = 128
            snapshot.afterScreenUpdates = true
            let offset = webView.scrollView.contentOffset
            let bounds = webView.bounds
            let style = webView.traitCollection.userInterfaceStyle
            let window = webView.window
            let topInset = webView.scrollView.adjustedContentInset.top
            let pageZoom = webView.pageZoom
            let zoomScale = webView.scrollView.zoomScale
            @MainActor func acceptsViewport() -> Bool {
                acceptsResult() && webView.window === window
                    && webView.bounds == bounds && webView.scrollView.contentOffset == offset
                    && webView.traitCollection.userInterfaceStyle == style
                    && webView.scrollView.adjustedContentInset.top == topInset
                    && webView.pageZoom == pageZoom && webView.scrollView.zoomScale == zoomScale
                    && !webView.scrollView.isDragging && !webView.scrollView.isDecelerating
                    && !webView.scrollView.isZooming && !webView.scrollView.isZoomBouncing
            }
            self.takingSnapshot = true
            defer {
                self.takingSnapshot = false
                let pending = self.pendingSample
                self.pendingSample = nil
                pending?()
            }
            let image = try? await self.snapshot(webView, snapshot)
            guard acceptsViewport() else { return }
            if config.usesConfiguredBackgroundForReaderDocuments {
                // Reader can replace a remote document's presentation while the
                // snapshot is in flight without starting a new WKNavigation.
                let isReader = await self.isReaderDocument(webView)
                guard acceptsViewport() else { return }
                guard isReader == false else { apply(nil); return }
            }
            let color = image?.cgImage.flatMap {
                WebViewPageTopColorPolicy.color(in: $0, maxDifference: config.sampledPageTopColorMaxDifference)
            }
            apply(color)
        }
    }

    private func isReaderDocument(_ webView: WKWebView) async -> Bool? {
        let script = "Boolean(document.body && (document.body.classList.contains('readability-mode') || document.body.dataset.isEbook === 'true'))"
        return try? await webView.evaluateJavaScript(script) as? Bool
    }
}

enum WebViewPageTopColorPolicy {
    /// Read the first content pixels below any native scroll inset, including restored scroll positions.
    static func sampleRect(bounds: CGRect, topInset: CGFloat) -> CGRect? {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, topInset.isFinite,
              bounds.width > 1, bounds.height > 1 else { return nil }
        let top = max(0, topInset)
        guard top < bounds.height - 1 else { return nil }
        return CGRect(x: bounds.minX, y: bounds.minY + top, width: bounds.width,
                      height: min(8, bounds.height - top))
    }

    /// CIE76 ΔE from the mean. Nonuniform or translucent strips use the configured fallback.
    /// Its units and behavior are ours; they do not promise parity with WebKit's private threshold.
    static func color(in image: CGImage, maxDifference: Double) -> UIColor? {
        guard maxDifference.isFinite, maxDifference >= 0 else { return nil }
        let width = 128, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var samples = [(Double, Double, Double)]()
        samples.reserveCapacity(width * height)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[offset + 3] == 255 else { return nil }
            samples.append((Double(pixels[offset]) / 255, Double(pixels[offset + 1]) / 255, Double(pixels[offset + 2]) / 255))
        }
        let count = Double(samples.count)
        let mean = samples.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.0 / count, $0.1 + $1.1 / count, $0.2 + $1.2 / count) }
        let center = lab(mean)
        for sample in samples {
            let value = lab(sample)
            let distance = sqrt(pow(value.0 - center.0, 2) + pow(value.1 - center.1, 2) + pow(value.2 - center.2, 2))
            guard distance <= maxDifference + 1e-9 else { return nil }
        }
        return UIColor(red: mean.0, green: mean.1, blue: mean.2, alpha: 1)
    }

    private static func lab(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func curve(_ value: Double) -> Double {
            value > 216.0 / 24389.0 ? cbrt(value) : (24389.0 / 27.0 * value + 16) / 116
        }
        let r = linear(rgb.0), g = linear(rgb.1), b = linear(rgb.2)
        let x = curve((0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047)
        let y = curve(0.2126729 * r + 0.7151522 * g + 0.0721750 * b)
        let z = curve((0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883)
        return (116 * y - 16, 500 * (x - y), 200 * (y - z))
    }
}
#endif
