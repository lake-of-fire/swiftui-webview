import XCTest
@testable import SwiftUIWebView

final class WebViewTrustedUserActionSemanticEqualityTests: XCTestCase {
    func testObservedTimestampDoesNotChangePublicActionIdentity() {
        let first = WebViewTrustedUserAction(
            action: "markSectionAsRead",
            scope: "section-1",
            source: .isolatedUserActivation,
            observedAtUnixMilliseconds: 100_000
        )
        let second = WebViewTrustedUserAction(
            action: "markSectionAsRead",
            scope: "section-1",
            source: .isolatedUserActivation,
            observedAtUnixMilliseconds: 101_000
        )

        XCTAssertEqual(first, second)
    }

    func testSemanticFieldsStillParticipateInEquality() {
        let baseline = WebViewTrustedUserAction(
            action: "markSectionAsRead",
            scope: "section-1",
            source: .isolatedUserActivation,
            observedAtUnixMilliseconds: 100_000
        )
        XCTAssertNotEqual(
            baseline,
            WebViewTrustedUserAction(
                action: "startOver",
                scope: "section-1",
                observedAtUnixMilliseconds: 100_000
            )
        )
        XCTAssertNotEqual(
            baseline,
            WebViewTrustedUserAction(
                action: "markSectionAsRead",
                scope: "section-2",
                observedAtUnixMilliseconds: 100_000
            )
        )
        XCTAssertNotEqual(
            baseline,
            WebViewTrustedUserAction(
                action: "markSectionAsRead",
                scope: "section-1",
                source: .nativeAuthorizedOperation,
                observedAtUnixMilliseconds: 100_000
            )
        )
    }
}
