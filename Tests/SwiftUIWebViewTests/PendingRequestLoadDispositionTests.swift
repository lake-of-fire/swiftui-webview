import XCTest
@testable import SwiftUIWebView

final class PendingRequestLoadDispositionTests: XCTestCase {
    func testDefersUntilFullyAttached() {
        let url = URL(string: "ebook://ebook/load/local/test.epub")!

        XCTAssertEqual(
            PendingRequestLoadDisposition.resolve(
                requestURL: url,
                hasWindow: false,
                hasSuperview: false,
                currentURL: nil,
                isLoading: false,
                restartIfSameURL: true
            ),
            .deferUntilAttached
        )

        XCTAssertEqual(
            PendingRequestLoadDisposition.resolve(
                requestURL: url,
                hasWindow: true,
                hasSuperview: false,
                currentURL: nil,
                isLoading: false,
                restartIfSameURL: true
            ),
            .deferUntilAttached
        )
    }

    func testLoadsRequestWhenAttachedAndNotAlreadyLoadingSameURL() {
        let url = URL(string: "ebook://ebook/load/local/test.epub")!

        XCTAssertEqual(
            PendingRequestLoadDisposition.resolve(
                requestURL: url,
                hasWindow: true,
                hasSuperview: true,
                currentURL: nil,
                isLoading: false,
                restartIfSameURL: true
            ),
            .loadRequest
        )
    }

    func testLoadsFileURLWhenAttached() {
        let url = URL(fileURLWithPath: "/tmp/test.epub")

        XCTAssertEqual(
            PendingRequestLoadDisposition.resolve(
                requestURL: url,
                hasWindow: true,
                hasSuperview: true,
                currentURL: nil,
                isLoading: false,
                restartIfSameURL: true
            ),
            .loadFileURL
        )
    }

    func testSkipsAlreadyLoadingSameURLWhenRestartWasRequested() {
        let url = URL(string: "ebook://ebook/load/local/test.epub")!

        XCTAssertEqual(
            PendingRequestLoadDisposition.resolve(
                requestURL: url,
                hasWindow: true,
                hasSuperview: true,
                currentURL: url,
                isLoading: true,
                restartIfSameURL: true
            ),
            .skipAlreadyLoading
        )
    }

    func testDoesNotSkipAlreadyLoadingWhenRestartWasNotRequested() {
        let url = URL(string: "ebook://ebook/load/local/test.epub")!

        XCTAssertEqual(
            PendingRequestLoadDisposition.resolve(
                requestURL: url,
                hasWindow: true,
                hasSuperview: true,
                currentURL: url,
                isLoading: true,
                restartIfSameURL: false
            ),
            .loadRequest
        )
    }
}
