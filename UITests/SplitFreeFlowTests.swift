import XCTest

final class SplitFreeFlowTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--reset-data", "--local-store"]
        app.launch()
    }

    func testCreateGroupAddExpenseAndSettleUp() throws {
        try app.createTahoeTripWithDinner()

        // Balances: You are owed 60, Alice and Bob owe 30 each.
        XCTAssertTrue(app.staticTexts["Dinner"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$60.00"].exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "$30.00").count, 2)

        // Settle up: two suggested payments of $30 to You.
        app.buttons["Settle up"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Suggested payments"].waitForExistence(timeout: 5))
        let recordButtons = app.buttons.matching(identifier: "Mark as paid")
        XCTAssertEqual(recordButtons.count, 2)
        recordButtons.firstMatch.tap()

        // Record sheet is prefilled; save it.
        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()
        XCTAssertTrue(app.staticTexts["Past payments"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        // One debt left: a single $30 owed.
        XCTAssertTrue(app.staticTexts["Dinner"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "$30.00").count, 2) // owes + is owed

        // Kill and relaunch: everything (including the settlement) must persist.
        // Drop --reset-data so the relaunch doesn't wipe what we just made.
        app.terminate()
        app.launchArguments = ["--local-store"]
        app.launch()
        app.cells.staticTexts["Tahoe Trip"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Dinner"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "$30.00").count, 2)
        app.buttons["Settle up"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Past payments"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.navigationBars.buttons.firstMatch.tap() // back to groups

        // Activity search finds the expense.
        app.tabBars.buttons["Activity"].tap()
        XCTAssertTrue(app.staticTexts["Dinner"].waitForExistence(timeout: 5))

        // Insights renders charts.
        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(app.staticTexts["Spending by month"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Spending by category"].exists)
    }
}
