#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import SwiftUIWebView

@MainActor
private final class UploadOpenPanel: NSOpenPanel {
    var selection: [URL] = []
    var response: NSApplication.ModalResponse = .OK

    override var url: URL? { selection.first }
    override var urls: [URL] { selection }

    override func begin(completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
        handler(response)
    }
}

@MainActor
final class WebViewOpenPanelTests: XCTestCase {
    func testSingleFileInputDisablesMultipleSelection() {
        let panel = makePanel()
        panel.selection = [URL(fileURLWithPath: "/tmp/upload.txt")]

        let result = runPanel(panel)

        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertEqual(result, panel.selection)
    }

    func testMultipleFileInputReturnsEverySelectedURL() {
        let panel = makePanel()
        panel.selection = [
            URL(fileURLWithPath: "/tmp/first.txt"),
            URL(fileURLWithPath: "/tmp/二番目.txt")
        ]

        let result = runPanel(panel, allowsMultipleSelection: true)

        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertEqual(result, panel.selection)
    }

    func testDirectoryInputPermitsDirectorySelection() {
        let panel = makePanel()
        panel.selection = [URL(fileURLWithPath: "/tmp/upload-folder", isDirectory: true)]

        let result = runPanel(panel, allowsDirectories: true)

        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertEqual(result, panel.selection)
    }

    func testCancelDiscardsPanelSelection() {
        let panel = makePanel()
        panel.selection = [URL(fileURLWithPath: "/tmp/upload.txt")]
        panel.response = .cancel

        XCTAssertNil(runPanel(panel))
    }

    func testAbortedPanelCompletesWithNoSelection() {
        let panel = makePanel()
        panel.response = .abort

        XCTAssertNil(runPanel(panel))
    }

    private func makePanel() -> UploadOpenPanel {
        _ = NSApplication.shared
        return UploadOpenPanel()
    }

    private func runPanel(
        _ panel: UploadOpenPanel,
        allowsMultipleSelection: Bool = false,
        allowsDirectories: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [URL]? {
        let navigator = WebViewNavigator()
        let view = WebView(navigator: navigator, state: .constant(.empty))
        let coordinator = view.makeCoordinatorForTesting()
        let webView = WKWebView(frame: .zero)
        navigator.webView = webView
        defer { navigator.webView = nil }
        coordinator.makeOpenPanel = { panel }
        var result: [URL]?
        var completionCount = 0

        // WKFrameInfo and WKOpenPanelParameters are WebKit-owned objects;
        // constructing them directly leaves invalid native backing storage.
        coordinator.runOpenPanel(
            webView: webView,
            allowsMultipleSelection: allowsMultipleSelection,
            allowsDirectories: allowsDirectories
        ) { urls in
            completionCount += 1
            result = urls
        }

        XCTAssertEqual(completionCount, 1, file: file, line: line)
        return result
    }
}
#endif
