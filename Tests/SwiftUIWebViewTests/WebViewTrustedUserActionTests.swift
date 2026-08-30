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

    func testAdmissionIsOneShotAndActionBound() {
        let store = WebViewTrustedUserActionAdmissionStore()
        XCTAssertTrue(store.admit(
            action: "markSectionAsRead",
            scope: "section-1",
            document: document,
            frame: frame,
            now: 10
        ))
        XCTAssertNil(store.consume(
            action: "startOver",
            document: document,
            frame: frame,
            now: 10.1
        ))
        XCTAssertEqual(store.consume(
            action: "markSectionAsRead",
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
            document: document,
            frame: frame,
            now: 20
        ))
        XCTAssertNil(store.consume(
            action: "showOriginal",
            document: .init(
                webViewID: document.webViewID,
                generation: document.generation + 1
            ),
            frame: frame,
            now: 20.1
        ))
        XCTAssertNil(store.consume(
            action: "showOriginal",
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
            document: document,
            frame: frame,
            now: 20 + WebViewTrustedUserActionAdmissionStore.lifetime + 0.1
        ))
    }

    func testInvalidationRemovesAllAdmissions() {
        let store = WebViewTrustedUserActionAdmissionStore()
        XCTAssertTrue(store.admit(
            action: "startOver",
            scope: nil,
            document: document,
            frame: frame,
            now: 30
        ))
        store.invalidateAll()
        XCTAssertNil(store.consume(
            action: "startOver",
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
}
