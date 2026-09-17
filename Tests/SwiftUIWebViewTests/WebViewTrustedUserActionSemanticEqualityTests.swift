import XCTest
@testable import SwiftUIWebView

final class WebViewTrustedUserActionSemanticEqualityTests: XCTestCase {
    func testHandlerTransformationsPreserveRequiredTrustedActionPolicy() {
        let initial = WebViewMessageHandlers([
            ("markSectionAsRead", { @Sendable _ in })
        ])
        .requiringTrustedUserAction("markSectionAsRead")

        let transformed = initial
            .updating("markSectionAsRead", handler: { @Sendable _ in })
            .updatingCancellationHandler("markSectionAsRead", handler: { @Sendable _ in })

        XCTAssertTrue(
            transformed.trustedUserActionHandlerNames.contains(
                "markSectionAsRead"
            )
        )
        XCTAssertTrue(
            transformed.requiredTrustedUserActionHandlerNames.contains(
                "markSectionAsRead"
            )
        )
    }

    func testComposedHandlersUnionOptionalAndRequiredTrustedActionPolicy() {
        let optional = WebViewMessageHandlers([
            ("showOriginal", { @Sendable _ in })
        ])
        .acceptingTrustedUserAction("showOriginal")
        let required = WebViewMessageHandlers([
            ("markSectionAsRead", { @Sendable _ in })
        ])
        .requiringTrustedUserAction("markSectionAsRead")

        let composed = optional + required

        XCTAssertEqual(
            composed.trustedUserActionHandlerNames,
            ["showOriginal", "markSectionAsRead"]
        )
        XCTAssertEqual(
            composed.requiredTrustedUserActionHandlerNames,
            ["markSectionAsRead"]
        )
    }

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
