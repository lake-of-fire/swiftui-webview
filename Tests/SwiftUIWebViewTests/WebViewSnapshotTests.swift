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

    func testDOMViewportRectMapsPageZoomAndVisualViewportOffsetIntoViewPoints() throws {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let viewport = CGRect(x: 20, y: 30, width: 400, height: CGFloat(800) / 3)
        let domRect = CGRect(x: 100, y: 80, width: 200, height: 100)

        let rect = try WebViewScriptCaller.resolvedViewRect(
            forDOMViewportRect: domRect,
            viewportRect: viewport,
            in: bounds
        )

        XCTAssertEqual(rect.minX, 120, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 75, accuracy: 0.001)
        XCTAssertEqual(rect.width, 300, accuracy: 0.001)
        XCTAssertEqual(rect.height, 150, accuracy: 0.001)
        let roundTrip = WebViewScriptCaller.resolvedDOMViewportRect(
            forViewRect: rect,
            viewportRect: viewport,
            in: bounds
        )
        XCTAssertEqual(roundTrip.minX, domRect.minX, accuracy: 0.001)
        XCTAssertEqual(roundTrip.minY, domRect.minY, accuracy: 0.001)
        XCTAssertEqual(roundTrip.width, domRect.width, accuracy: 0.001)
        XCTAssertEqual(roundTrip.height, domRect.height, accuracy: 0.001)
    }

    func testDOMViewportRectClampsToViewBoundsAndRejectsInvalidViewport() throws {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let clipped = try WebViewScriptCaller.resolvedViewRect(
            forDOMViewportRect: CGRect(x: 350, y: 240, width: 100, height: 100),
            viewportRect: CGRect(x: 0, y: 0, width: 400, height: CGFloat(800) / 3),
            in: bounds
        )

        XCTAssertEqual(clipped, CGRect(x: 525, y: 360, width: 75, height: 40))
        XCTAssertThrowsError(
            try WebViewScriptCaller.resolvedViewRect(
                forDOMViewportRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                viewportRect: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100),
                in: bounds
            )
        ) { error in
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
