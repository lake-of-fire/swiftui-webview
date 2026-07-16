import CoreGraphics
@testable import SwiftUIWebView
import WebKit
import XCTest

final class WebViewSnapshotTests: XCTestCase {
    @MainActor
    func testWebViewAcceptsAnIsolatedWebsiteDataStore() {
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let webView = WebView(
            navigator: WebViewNavigator(),
            state: .constant(.empty),
            websiteDataStore: websiteDataStore
        )

        XCTAssertTrue(webView.websiteDataStore === websiteDataStore)
    }

    @MainActor
    func testSnapshotConfigurationCapturesSettledCurrentFrameWithoutWaitingForAnimation() {
        let rect = CGRect(x: 10, y: 20, width: 320, height: 480)

        let configuration = makeWebViewSnapshotConfiguration(capturedRect: rect)

        XCTAssertEqual(configuration.rect, rect)
        XCTAssertEqual(configuration.snapshotWidth, 320)
        XCTAssertFalse(configuration.afterScreenUpdates)
    }

    func testResolvedSnapshotRectUsesFullBoundsWhenNoRectIsRequested() throws {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)

        let rect = try WebViewScriptCaller.resolvedSnapshotRect(nil, in: bounds)

        XCTAssertEqual(rect, bounds)
    }

    func testResolvedSnapshotRectClampsToWebViewBounds() throws {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
        let requested = CGRect(x: 300, y: 460, width: 80, height: 80)

        let rect = try WebViewScriptCaller.resolvedSnapshotRect(requested, in: bounds)

        XCTAssertEqual(rect, CGRect(x: 300, y: 460, width: 20, height: 20))
    }

    func testResolvedSnapshotRectRejectsEmptyIntersection() {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
        let requested = CGRect(x: 400, y: 0, width: 20, height: 20)

        XCTAssertThrowsError(try WebViewScriptCaller.resolvedSnapshotRect(requested, in: bounds)) { error in
            XCTAssertEqual(error as? WebViewScriptCallerSnapshotError, .emptyRect)
        }
    }

    func testResolvedSnapshotScaleUsesReturnedPixelWidth() throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: 640,
                height: 960,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let image = context.makeImage()
        else {
            XCTFail("Could not create CGImage test fixture.")
            return
        }

        let scale = WebViewScriptCaller.resolvedSnapshotScale(
            cgImage: image,
            capturedRect: CGRect(x: 0, y: 0, width: 320, height: 480),
            fallbackScale: 1
        )

        XCTAssertEqual(scale, 2)
    }
}
