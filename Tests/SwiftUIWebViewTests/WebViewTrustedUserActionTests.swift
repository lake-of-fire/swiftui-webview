import XCTest
import WebKit
@testable import SwiftUIWebView

@MainActor
private final class TrustedUserActionMessageRecorder: NSObject,
    WKScriptMessageHandler {
    private(set) var bodies = [Any]()

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        bodies.append(message.body)
    }
}

@MainActor
final class WebViewTrustedUserActionTests: XCTestCase {
    private enum PageBridgeError: Error {
        case unavailable
    }

    private let document = WebViewTrustedUserActionAdmissionStore.DocumentIdentity(
        webViewID: ObjectIdentifier(NSObject()),
        generation: 7
    )
    private let frame = WebViewTrustedUserActionFrameIdentity(
        isMainFrame: true,
        requestURL: "https://example.com/article",
        mainDocumentURL: "https://example.com/article",
        securityOrigin: "https|example.com|0"
    )
    private let correlationToken = "0123456789abcdef0123456789abcdef"

    func testAdmissionIsOneShotAndActionBound() {
        let store = WebViewTrustedUserActionAdmissionStore()
        XCTAssertTrue(store.admit(
            action: "markSectionAsRead",
            scope: "section-1",
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 10
        ))
        XCTAssertNil(store.consume(
            action: "startOver",
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 10.1
        ))
        XCTAssertEqual(store.consume(
            action: "markSectionAsRead",
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 10.1
        ), WebViewTrustedUserAction(
            action: "markSectionAsRead",
            scope: "section-1"
        ))
        XCTAssertNil(store.consume(
            action: "markSectionAsRead",
            document: document,
            frame: frame,
            now: 10.2
        ))
    }

    func testAdmissionDoesNotCrossDocumentFrameOrExpiry() {
        let store = WebViewTrustedUserActionAdmissionStore()
        XCTAssertTrue(store.admit(
            action: "showOriginal",
            scope: nil,
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 20
        ))
        XCTAssertNil(store.consume(
            action: "showOriginal",
            correlationToken: correlationToken,
            document: .init(
                webViewID: document.webViewID,
                generation: document.generation + 1
            ),
            frame: frame,
            now: 20.1
        ))
        XCTAssertNil(store.consume(
            action: "showOriginal",
            correlationToken: correlationToken,
            document: document,
            frame: .init(
                isMainFrame: false,
                requestURL: frame.requestURL,
                mainDocumentURL: frame.mainDocumentURL,
                securityOrigin: frame.securityOrigin
            ),
            now: 20.1
        ))
        XCTAssertNil(store.consume(
            action: "showOriginal",
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 20 + WebViewTrustedUserActionAdmissionStore.lifetime + 0.1
        ))
    }

    func testMismatchedFrameOrDocumentCannotSpendAnAdmissionForItsSuccessor() {
        let store = WebViewTrustedUserActionAdmissionStore()
        XCTAssertTrue(store.admit(
            action: "markSectionAsRead",
            scope: "section-1",
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 20
        ))

        let replacementFrame = WebViewTrustedUserActionFrameIdentity(
            isMainFrame: true,
            requestURL: "https://example.com/replacement",
            mainDocumentURL: "https://example.com/article",
            securityOrigin: "https|example.com|0"
        )
        XCTAssertNil(store.consume(
            action: "markSectionAsRead",
            correlationToken: correlationToken,
            document: document,
            frame: replacementFrame,
            now: 20.1
        ))
        XCTAssertNil(store.consume(
            action: "markSectionAsRead",
            correlationToken: correlationToken,
            document: .init(
                webViewID: document.webViewID,
                generation: document.generation + 1
            ),
            frame: frame,
            now: 20.1
        ))
        XCTAssertNotNil(store.consume(
            action: "markSectionAsRead",
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 20.1
        ))
        XCTAssertNil(store.consume(
            action: "markSectionAsRead",
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 20.2
        ))
    }

    func testBrokerAdmissionSpendsOriginalClickLifetime() {
        let store = WebViewTrustedUserActionAdmissionStore()
        let observedAt = 100_000.0
        let encodedScope = WebViewTrustedUserActionAdmissionStore
            .brokerScopePrefix + "100000:section-1"
        XCTAssertTrue(store.admit(
            action: "markSectionAsRead",
            scope: encodedScope,
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 50,
            wallClockNowUnixMilliseconds: 101_000
        ))
        let action = store.consume(
            action: "markSectionAsRead",
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 50.49
        )
        XCTAssertEqual(action?.scope, "section-1")
        XCTAssertEqual(action?.observedAtUnixMilliseconds, observedAt)

        let expiringStore = WebViewTrustedUserActionAdmissionStore()
        XCTAssertTrue(expiringStore.admit(
            action: "markSectionAsRead",
            scope: encodedScope,
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 60,
            wallClockNowUnixMilliseconds: 101_000
        ))
        XCTAssertNil(expiringStore.consume(
            action: "markSectionAsRead",
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 60.51
        ))
    }

    func testBrokerAdmissionRejectsAlreadyExpiredInitialDelivery() {
        let store = WebViewTrustedUserActionAdmissionStore()
        let encodedScope = WebViewTrustedUserActionAdmissionStore
            .brokerScopePrefix + "100000:-"
        XCTAssertFalse(store.admit(
            action: "startOver",
            scope: encodedScope,
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 70,
            wallClockNowUnixMilliseconds: 101_501
        ))
        XCTAssertNil(store.consume(
            action: "startOver",
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 70
        ))
    }

    func testBrokerAdmissionRejectsImplausibleFutureTimestampAndMalformedEnvelope() {
        let store = WebViewTrustedUserActionAdmissionStore()
        let future = WebViewTrustedUserActionAdmissionStore
            .brokerScopePrefix + "106000:-"
        XCTAssertFalse(store.admit(
            action: "startOver",
            scope: future,
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 80,
            wallClockNowUnixMilliseconds: 100_000
        ))
        let malformed = WebViewTrustedUserActionAdmissionStore
            .brokerScopePrefix + "not-a-time:section-1"
        XCTAssertFalse(store.admit(
            action: "markSectionAsRead",
            scope: malformed,
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 80,
            wallClockNowUnixMilliseconds: 100_000
        ))
    }

    func testInvalidationRemovesAllAdmissions() {
        let store = WebViewTrustedUserActionAdmissionStore()
        XCTAssertTrue(store.admit(
            action: "startOver",
            scope: nil,
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 30
        ))
        store.invalidateAll()
        XCTAssertNil(store.consume(
            action: "startOver",
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 30.1
        ))
    }

    func testNativeBatchCreatesExactOneShotAdmissionsAndRevokesRemainder() {
        let store = WebViewTrustedUserActionAdmissionStore()
        let ids = store.admitNativeBatch(
            action: "markSectionAsRead",
            count: 2,
            document: document,
            frame: frame,
            now: 40
        )
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(store.consume(
            action: "markSectionAsRead",
            document: document,
            frame: frame,
            now: 40.1
        )?.source, .nativeAuthorizedOperation)
        store.revoke(ids)
        XCTAssertNil(store.consume(
            action: "markSectionAsRead",
            document: document,
            frame: frame,
            now: 40.1
        ))
    }

    func testReversedWorldDeliveryMatchesOnlyItsExactCorrelationToken()
        async {
        let store = WebViewTrustedUserActionAdmissionStore()
        let firstToken = "11111111111111111111111111111111"
        let secondToken = "22222222222222222222222222222222"
        let waitingFirst = Task { @MainActor in
            await store.consumeOrWaitForBrokerAdmission(
                action: "markSectionAsRead",
                correlationToken: firstToken,
                document: document,
                frame: frame,
                now: 50
            )
        }
        await Task.yield()

        XCTAssertTrue(store.admit(
            action: "markSectionAsRead",
            scope: "section-b",
            correlationToken: secondToken,
            document: document,
            frame: frame,
            now: 50,
            wallClockNowUnixMilliseconds: 100_000
        ))
        XCTAssertTrue(store.admit(
            action: "markSectionAsRead",
            scope: "section-a",
            correlationToken: firstToken,
            document: document,
            frame: frame,
            now: 50,
            wallClockNowUnixMilliseconds: 100_000
        ))

        let firstAction = await waitingFirst.value
        XCTAssertEqual(firstAction?.scope, "section-a")
        XCTAssertEqual(store.consume(
            action: "markSectionAsRead",
            correlationToken: secondToken,
            document: document,
            frame: frame,
            now: 50.1
        )?.scope, "section-b")
    }

    func testSameActionDifferentScopesRequireTheirOwnTokens() {
        let store = WebViewTrustedUserActionAdmissionStore()
        let firstToken = "33333333333333333333333333333333"
        let secondToken = "44444444444444444444444444444444"
        XCTAssertTrue(store.admit(
            action: "markSectionAsRead",
            scope: "section-a",
            correlationToken: firstToken,
            document: document,
            frame: frame,
            now: 60
        ))
        XCTAssertTrue(store.admit(
            action: "markSectionAsRead",
            scope: "section-b",
            correlationToken: secondToken,
            document: document,
            frame: frame,
            now: 60
        ))

        XCTAssertEqual(store.consume(
            action: "markSectionAsRead",
            correlationToken: secondToken,
            document: document,
            frame: frame,
            now: 60.1
        )?.scope, "section-b")
        XCTAssertEqual(store.consume(
            action: "markSectionAsRead",
            correlationToken: firstToken,
            document: document,
            frame: frame,
            now: 60.1
        )?.scope, "section-a")
    }

    func testMissingOrDuplicateCorrelationTokenCannotSpendBrokerAdmission()
        async {
        let store = WebViewTrustedUserActionAdmissionStore()
        XCTAssertTrue(store.admit(
            action: "startOver",
            scope: nil,
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 70
        ))
        XCTAssertNil(store.consume(
            action: "startOver",
            correlationToken: nil,
            document: document,
            frame: frame,
            now: 70.1
        ))
        XCTAssertNotNil(store.consume(
            action: "startOver",
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 70.1
        ))
        let duplicateAction = await store.consumeOrWaitForBrokerAdmission(
            action: "startOver",
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 70.1
        )
        XCTAssertNil(duplicateAction)
    }

    func testDuplicateBrokerAdmissionIsRejectedBeforeAndAfterConsumption() {
        let store = WebViewTrustedUserActionAdmissionStore()
        XCTAssertTrue(store.admit(
            action: "startOver",
            scope: nil,
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 75
        ))
        XCTAssertFalse(store.admit(
            action: "startOver",
            scope: nil,
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 75.1
        ))
        XCTAssertNotNil(store.consume(
            action: "startOver",
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 75.2
        ))
        XCTAssertFalse(store.admit(
            action: "startOver",
            scope: nil,
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 75.3
        ))
    }

    func testNavigationReplacementInvalidatesPendingCorrelationWaiter() async {
        let store = WebViewTrustedUserActionAdmissionStore()
        let waiting = Task { @MainActor in
            await store.consumeOrWaitForBrokerAdmission(
                action: "startOver",
                correlationToken: correlationToken,
                document: document,
                frame: frame,
                now: 80
            )
        }
        await Task.yield()
        store.invalidateAll()
        let waitingAction = await waiting.value
        XCTAssertNil(waitingAction)
    }

    func testOptionalHandlerPolicyStillDispatchesWithoutAnAdmission() {
        let handlers = WebViewMessageHandlers([
            ("finishedReading", { @Sendable _ in })
        ])
        .acceptingTrustedUserAction("finishedReading")

        XCTAssertTrue(
            handlers.trustedUserActionHandlerNames.contains("finishedReading")
        )
        XCTAssertFalse(
            handlers.requiredTrustedUserActionHandlerNames.contains(
                "finishedReading"
            )
        )
    }

    func testCrossWorldPageBridgeAddsTheExactBrokerToken()
        async throws {
        let contentController = WKUserContentController()
        var pageBridgeScript =
            WebViewTrustedUserActionBroker.pageCorrelationUserScript
        contentController.addUserScript(
            pageBridgeScript.webKitUserScript
        )
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(
            """
            <!doctype html><html><body>Ready</body></html>
            """,
            baseURL: URL(string: "https://example.com/article")
        )
        try await waitForPageBridge(in: webView)
        let brokerToken = "abcdefabcdefabcdefabcdefabcdefab"
        _ = try await webView.callAsyncJavaScript(
            """
            document.documentElement.setAttribute(
                'data-swiftuiwebview-trusted-action-tokens',
                JSON.stringify({ startOver: brokerToken })
            );
            """,
            arguments: ["brokerToken": brokerToken],
            in: nil,
            contentWorld: WebViewTrustedUserActionBroker.world
        )
        let body = try await webView.callAsyncJavaScript(
            """
            return globalThis.__swiftUIWebViewTrustedUserAction
                .withToken('startOver', {});
            """,
            in: nil,
            contentWorld: .page
        ) as? [String: Any]
        XCTAssertEqual(
            body?[WebViewTrustedUserActionBroker.correlationTokenBodyKey]
                as? String,
            brokerToken
        )
        _ = webView
    }

    func testDynamicallyGeneratedFeedFooterPreservesTokenPayloadAndScope()
        async throws {
        let contentController = WKUserContentController()
        var brokerScript = WebViewTrustedUserActionBroker.userScript
        var pageBridgeScript =
            WebViewTrustedUserActionBroker.pageCorrelationUserScript
        contentController.addUserScript(brokerScript.webKitUserScript)
        contentController.addUserScript(pageBridgeScript.webKitUserScript)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(
            "<!doctype html><html><body>Ready</body></html>",
            baseURL: URL(string: "https://example.com/article")
        )
        try await waitForPageBridge(in: webView)

        let feedID = "feed-dynamic-42"
        _ = try await webView.callAsyncJavaScript(
            """
            const feed = document.createElement('a');
            feed.className = 'mnb-feed-footer-feed';
            feed.dataset.mnbFeedId = feedID;
            document.body.append(feed);
            """,
            arguments: ["feedID": feedID],
            in: nil,
            contentWorld: .page
        )
        try await Task.sleep(for: .milliseconds(50))

        let correlationToken = "1234567890abcdef1234567890abcdef"
        _ = try await webView.callAsyncJavaScript(
            """
            document.documentElement.setAttribute(
                'data-swiftuiwebview-trusted-action-tokens',
                JSON.stringify({ readerFeedFooterAction: correlationToken })
            );
            """,
            arguments: ["correlationToken": correlationToken],
            in: nil,
            contentWorld: WebViewTrustedUserActionBroker.world
        )
        let body = try await webView.callAsyncJavaScript(
            """
            const feed = document.querySelector('.mnb-feed-footer-feed');
            return globalThis.__swiftUIWebViewTrustedUserAction.withToken(
                'readerFeedFooterAction',
                {
                    action: 'openFeed',
                    feedID: feed?.dataset?.mnbFeedId,
                    feedTitle: 'Dynamic Feed',
                }
            );
            """,
            in: nil,
            contentWorld: .page
        ) as? [String: Any]

        XCTAssertEqual(body?["action"] as? String, "openFeed")
        XCTAssertEqual(body?["feedID"] as? String, feedID)
        XCTAssertEqual(
            body?[WebViewTrustedUserActionBroker.correlationTokenBodyKey]
                as? String,
            correlationToken
        )
        let store = WebViewTrustedUserActionAdmissionStore()
        XCTAssertTrue(store.admit(
            action: "readerFeedFooterAction",
            scope: feedID,
            correlationToken: correlationToken,
            document: document,
            frame: frame,
            now: 90
        ))
        let admission = store.consume(
            action: "readerFeedFooterAction",
            correlationToken: body?[WebViewTrustedUserActionBroker
                .correlationTokenBodyKey] as? String,
            document: document,
            frame: frame,
            now: 90.1
        )
        XCTAssertEqual(admission?.scope, body?["feedID"] as? String)
        _ = webView
    }

    func testPageWorldCannotMintAdmissionByAddingAuthorizationAttributes()
        async throws {
        let recorder = TrustedUserActionMessageRecorder()
        let contentController = WKUserContentController()
        var brokerScript = WebViewTrustedUserActionBroker.userScript
        contentController.addUserScript(
            brokerScript.webKitUserScript
        )
        contentController.add(
            recorder,
            contentWorld: WebViewTrustedUserActionBroker.world,
            name: WebViewTrustedUserActionBroker.handlerName
        )
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(
            """
            <!doctype html><html><body>
              <button id="attack"
                data-manabi-trusted-action="startOver">Unrelated</button>
              <button id="synthetic" class="mnb-start-over-button">
                Synthetic
              </button>
              <script>
                document.getElementById('attack').click();
                document.getElementById('synthetic').click();
                try {
                  window.webkit.messageHandlers
                    .swiftUIWebViewTrustedUserAction.postMessage({
                      action: 'startOver'
                    });
                } catch (_error) {}
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://example.com/article")
        )
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(recorder.bodies.isEmpty)
        _ = webView
    }

    private func waitForPageBridge(in webView: WKWebView) async throws {
        for _ in 0..<100 {
            let isInstalled = try? await webView.callAsyncJavaScript(
                """
                return typeof globalThis.__swiftUIWebViewTrustedUserAction
                    ?.withToken === 'function';
                """,
                in: nil,
                contentWorld: .page
            ) as? Bool
            if isInstalled == true {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw PageBridgeError.unavailable
    }
}
