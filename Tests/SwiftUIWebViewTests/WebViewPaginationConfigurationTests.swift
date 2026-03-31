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
}
