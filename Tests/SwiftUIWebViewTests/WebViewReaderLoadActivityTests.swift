import XCTest
@testable import SwiftUIWebView

@MainActor
final class WebViewReaderLoadActivityTests: XCTestCase {
    private final class Owner {}

    func testPendingLoadEndsByIdentifier() {
        let activity = WebViewReaderLoadActivity()
        let id = UUID()
        let owner = Owner()

        activity.begin(id, owner: owner)
        XCTAssertTrue(activity.hasPendingPreProvisionalLoad)

        activity.end(id)
        XCTAssertFalse(activity.hasPendingPreProvisionalLoad)
    }

    func testReleasedOwnerCannotLeavePendingLoadBehind() {
        let activity = WebViewReaderLoadActivity()
        let id = UUID()
        var owner: Owner? = Owner()

        activity.begin(id, owner: owner!)
        XCTAssertTrue(activity.hasPendingPreProvisionalLoad)

        owner = nil
        XCTAssertFalse(activity.hasPendingPreProvisionalLoad)
    }

    func testEndingOneLoadPreservesOtherPendingLoads() {
        let activity = WebViewReaderLoadActivity()
        let firstID = UUID()
        let secondID = UUID()
        let firstOwner = Owner()
        let secondOwner = Owner()

        activity.begin(firstID, owner: firstOwner)
        activity.begin(secondID, owner: secondOwner)
        activity.end(firstID)

        XCTAssertTrue(activity.hasPendingPreProvisionalLoad)

        activity.end(secondID)
        XCTAssertFalse(activity.hasPendingPreProvisionalLoad)
    }
}
