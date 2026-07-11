import WebKit
import XCTest
@testable import SwiftUIWebView

final class WebViewUserScriptSignatureTests: XCTestCase {
    func testConfigurationSignatureChangesForInstalledScriptConfiguration() {
        let base = WebViewUserScript(
            source: "window.exampleValue = 1",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )

        XCTAssertNotEqual(
            base.configurationSignatureComponent,
            WebViewUserScript(
                source: "window.exampleValue = 2",
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ).configurationSignatureComponent
        )
        XCTAssertNotEqual(
            base.configurationSignatureComponent,
            WebViewUserScript(
                source: "window.exampleValue = 1",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ).configurationSignatureComponent
        )
        XCTAssertNotEqual(
            base.configurationSignatureComponent,
            WebViewUserScript(
                source: "window.exampleValue = 1",
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            ).configurationSignatureComponent
        )
        XCTAssertNotEqual(
            base.configurationSignatureComponent,
            WebViewUserScript(
                source: "window.exampleValue = 1",
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: .page
            ).configurationSignatureComponent
        )
    }

    func testConfigurationSignatureIncludesDomainFilterMetadata() {
        let unrestricted = WebViewUserScript(
            source: "window.exampleValue = 1",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        let restricted = WebViewUserScript(
            source: "window.exampleValue = 1",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            allowedDomains: ["example.com"]
        )

        XCTAssertNotEqual(
            unrestricted.configurationSignatureComponent,
            restricted.configurationSignatureComponent
        )
    }
}
