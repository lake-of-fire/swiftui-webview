import XCTest
import WebKit
@testable import SwiftUIWebView

final class WebViewPaginationConfigurationTests: XCTestCase {
    func test_viewLengthMode_usesViewHeightForHorizontalPagination() {
        let configuration = WebViewPaginationConfiguration(
            mode: .leftToRight,
            storedPageLength: 0,
            gapBetweenPages: 24,
            behavesLikeColumns: true,
            layoutSize: .zero
        )

        let resolved = configuration.resolvingEffectivePageLength(using: CGSize(width: 640, height: 960))

        XCTAssertTrue(resolved.usesViewLength)
        XCTAssertEqual(resolved.effectivePageLength, 960)
        XCTAssertEqual(resolved.layoutSize, CGSize(width: 640, height: 960))
    }

    func test_viewLengthMode_usesViewWidthForVerticalPagination() {
        let configuration = WebViewPaginationConfiguration(
            mode: .topToBottom,
            storedPageLength: 0,
            gapBetweenPages: 16,
            behavesLikeColumns: false,
            layoutSize: .zero
        )

        let resolved = configuration.resolvingEffectivePageLength(using: CGSize(width: 720, height: 1024))

        XCTAssertEqual(resolved.effectivePageLength, 720)
    }

    func test_unpaginatedMode_normalizesStructuralIdentity() {
        let configuration = WebViewPaginationConfiguration(
            mode: .unpaginated,
            storedPageLength: 900,
            gapBetweenPages: 44,
            behavesLikeColumns: false,
            layoutSize: CGSize(width: 500, height: 700)
        )

        let identity = configuration.structuralIdentity(using: CGSize(width: 500, height: 700))

        XCTAssertEqual(identity.mode, .unpaginated)
        XCTAssertEqual(identity.storedPageLength, 0)
        XCTAssertEqual(identity.gapBetweenPages, 0)
        XCTAssertTrue(identity.behavesLikeColumns)
    }

    func test_explicitPageLength_preservesStoredAndEffectiveLengths() {
        let configuration = WebViewPaginationConfiguration(
            mode: .leftToRight,
            storedPageLength: 720,
            gapBetweenPages: 18,
            behavesLikeColumns: true,
            layoutSize: .zero
        )

        let resolved = configuration.resolvingEffectivePageLength(using: CGSize(width: 640, height: 960))

        XCTAssertFalse(resolved.usesViewLength)
        XCTAssertEqual(resolved.storedPageLength, 720)
        XCTAssertEqual(resolved.effectivePageLength, 720)
        XCTAssertEqual(resolved.gapBetweenPages, 18)
    }

    func test_zeroLayoutSize_usesFallbackAndClampsNegativeDimensions() {
        let configuration = WebViewPaginationConfiguration(
            mode: .leftToRight,
            storedPageLength: 0,
            gapBetweenPages: 24,
            behavesLikeColumns: true,
            layoutSize: .zero
        )

        let resolved = configuration.resolvingEffectivePageLength(using: CGSize(width: -200, height: 480))

        XCTAssertEqual(resolved.layoutSize, CGSize(width: 0, height: 480))
        XCTAssertEqual(resolved.effectivePageLength, 480)
    }

    func test_dictionaryRepresentation_reportsResolvedShapeFields() {
        let configuration = WebViewPaginationConfiguration(
            mode: .topToBottom,
            storedPageLength: 0,
            gapBetweenPages: 16,
            behavesLikeColumns: false,
            layoutSize: CGSize(width: 700, height: 900)
        ).resolvingEffectivePageLength(using: .zero)

        let dictionary = configuration.dictionaryRepresentation

        XCTAssertEqual(dictionary["mode"], "\(WebViewPaginationMode.topToBottom.rawValue)")
        XCTAssertEqual(dictionary["storedPageLength"], "0.0")
        XCTAssertEqual(dictionary["effectivePageLength"], "700.0")
        XCTAssertEqual(dictionary["layoutWidth"], "700.0")
        XCTAssertEqual(dictionary["layoutHeight"], "900.0")
        XCTAssertEqual(dictionary["usesViewLength"], "true")
    }

    func test_explicitLayoutSizeWinsOverFallbackLayoutSize() {
        let configuration = WebViewPaginationConfiguration(
            mode: .leftToRight,
            storedPageLength: 0,
            gapBetweenPages: 12,
            behavesLikeColumns: true,
            layoutSize: CGSize(width: 500, height: 700)
        )

        let resolved = configuration.resolvingEffectivePageLength(using: CGSize(width: 900, height: 1100))

        XCTAssertEqual(resolved.layoutSize, CGSize(width: 500, height: 700))
        XCTAssertEqual(resolved.effectivePageLength, 700)
    }

    func test_unpaginatedResolutionClearsEffectivePageLengthAndReportsViewLength() {
        let configuration = WebViewPaginationConfiguration(
            mode: .unpaginated,
            storedPageLength: 640,
            effectivePageLength: 640,
            gapBetweenPages: 18,
            behavesLikeColumns: false,
            layoutSize: .zero
        )

        let resolved = configuration.resolvingEffectivePageLength(using: CGSize(width: 600, height: 800))

        XCTAssertEqual(resolved.storedPageLength, 0)
        XCTAssertEqual(resolved.effectivePageLength, 0)
        XCTAssertEqual(resolved.gapBetweenPages, 0)
        XCTAssertTrue(resolved.behavesLikeColumns)
        XCTAssertTrue(resolved.usesViewLength)
    }

    @MainActor
    func test_nativePaginationRemainsDisabledAndPreservesRuntimeSpreadState() throws {
        let controller = WebViewPaginationController()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        _ = controller.attach(webView: webView)
        let sequence = WebViewPaginationSpreadSequence(spreads: [
            .init(index: 0, slots: [.init(kind: .page, pageIndex: 0)]),
            .init(index: 1, slots: [.init(kind: .page, pageIndex: 1)])
        ], currentIndex: 0)
        _ = controller.updateRuntimeSpreadSequence(sequence, reason: "runtime")
        let requested = WebViewPaginationConfiguration(
            mode: .leftToRight, storedPageLength: 800, gapBetweenPages: 20,
            behavesLikeColumns: true, layoutSize: webView.bounds.size
        )

        let applied = try controller.apply(requested, reason: "configuration")
        let readback = try controller.refreshReadback(reason: "readback")
        for state in [applied, readback] {
            XCTAssertEqual(state.desiredConfiguration, .disabled)
            XCTAssertNil(state.appliedConfiguration)
            XCTAssertNil(state.pageCount)
            XCTAssertEqual(state.paginationComplete, false)
            XCTAssertFalse(state.isAppliedToMountedHost)
            XCTAssertEqual(state.spreadSequence, sequence)
            XCTAssertEqual(state.visiblePageIndices, [0])
            XCTAssertEqual(state.canMoveForward, true)
            XCTAssertEqual(state.canMoveBackward, false)
        }
        XCTAssertNil(controller.detach().spreadSequence)
    }

}
