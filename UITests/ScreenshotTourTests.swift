import XCTest

/// Captures marketing/review screenshots into the repo. Run explicitly:
/// xcodebuild test -only-testing:SplitFreeUITests/ScreenshotTourTests
final class ScreenshotTourTests: XCTestCase {
    let outputDir = "/Users/sank/Documents/Projects/SplitFree/screenshots"

    func snap(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
    }

    func testTour() throws {
        let app = XCUIApplication()
        app.launch()

        // Groups list (populated by the flow test's data).
        XCTAssertTrue(app.staticTexts["Tahoe Trip"].waitForExistence(timeout: 5))
        snap("02-groups")

        app.cells.staticTexts["Tahoe Trip"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Add expense"].waitForExistence(timeout: 5))
        snap("03-group-detail")

        app.buttons["Add expense"].tap()
        XCTAssertTrue(app.textFields["Title (e.g. Dinner at Luigi's)"].waitForExistence(timeout: 5))
        snap("04-add-expense")
        app.buttons["Cancel"].tap()

        app.buttons["Settle up"].firstMatch.tap()
        _ = app.staticTexts["Suggested payments"].waitForExistence(timeout: 5)
        snap("05-settle-up")
        app.buttons["Done"].tap()

        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(app.staticTexts["Spending by month"].waitForExistence(timeout: 5))
        snap("06-insights")

        app.tabBars.buttons["About"].tap()
        _ = app.staticTexts["SplitFree"].waitForExistence(timeout: 5)
        snap("07-about")
    }
}
