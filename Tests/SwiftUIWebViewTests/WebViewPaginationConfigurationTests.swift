import XCTest
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
}
