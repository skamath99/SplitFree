import XCTest

/// Smoke test for the CKShare flow. Runs cloud-backed (no --local-store), so
/// it needs the simulator signed into iCloud; it creates the group share and
/// checks the system share sheet appears, without inviting anyone.
final class CloudShareSmokeTest: XCTestCase {
    func testShareGroupPresentsCloudSharingSheet() throws {
        let app = XCUIApplication()
        app.launch()

        app.cells.staticTexts["Tahoe Trip"].firstMatch.tap()
        app.navigationBars.buttons["More"].firstMatch.tap()
        let shareButton = app.buttons["Share group"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 5))
        shareButton.tap()

        // UICloudSharingController is system UI; give CloudKit time to
        // create the share, then look for its collaboration sheet.
        let sheetAppeared = app.staticTexts["Tahoe Trip"].firstMatch.waitForExistence(timeout: 20)
        XCTAssertTrue(sheetAppeared)
        sleep(3)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: "/Users/sank/Documents/Projects/SplitFree/screenshots/share-sheet.png"))
    }
}
