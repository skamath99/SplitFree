import XCTest

/// Smoke test for the CKShare flow. Runs cloud-backed (no --local-store), so
/// it needs the simulator signed into iCloud; it creates the group share and
/// checks the system share sheet appears, without inviting anyone.
final class CloudShareSmokeTest: XCTestCase {
    func testShareGroupPresentsShareSheet() throws {
        let app = XCUIApplication()
        app.launch()

        app.cells.staticTexts["Tahoe Trip"].firstMatch.tap()
        app.claimFirstMemberIfAsked()
        let shareButton = app.navigationBars.buttons["Share group"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 5))
        shareButton.tap()

        // The system collaboration share sheet shows the group name as the
        // preview title once the CKShare is ready.
        let sheetAppeared = app.otherElements[" Collaboration"].firstMatch.waitForExistence(timeout: 20)
        XCTAssertTrue(sheetAppeared)
        sleep(3)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: "/Users/sank/Documents/Projects/SplitFree/screenshots/share-sheet.png"))
    }

    func testCopyInviteLinkConfirms() throws {
        let app = XCUIApplication()
        app.launch()

        app.cells.staticTexts["Tahoe Trip"].firstMatch.tap()
        app.claimFirstMemberIfAsked()
        app.navigationBars.buttons["More"].firstMatch.tap()
        let copyButton = app.buttons["Copy invite link"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 5))
        copyButton.tap()

        let alert = app.alerts["Invite link copied"]
        XCTAssertTrue(alert.waitForExistence(timeout: 30))
        alert.buttons["OK"].tap()
    }
}
