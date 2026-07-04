import XCTest

final class SplitFreeFlowTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testCreateGroupAddExpenseAndSettleUp() throws {
        // Create a group with two extra members.
        if app.buttons["Create a group"].waitForExistence(timeout: 5) {
            app.buttons["Create a group"].tap()
        } else {
            app.navigationBars.buttons["Add"].tap()
        }
        let nameField = app.textFields["Name (e.g. Tahoe Trip)"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Tahoe Trip")

        let memberField = app.textFields["Member name"]
        memberField.tap()
        memberField.typeText("Alice")
        app.buttons["Add another member"].tap()
        let memberFields = app.textFields.matching(identifier: "Member name")
        memberFields.element(boundBy: 1).tap()
        memberFields.element(boundBy: 1).typeText("Bob")
        app.buttons["Create"].tap()

        // Open the group.
        let groupCell = app.cells.staticTexts["Tahoe Trip"]
        XCTAssertTrue(groupCell.waitForExistence(timeout: 5))
        groupCell.tap()

        // Add a $90 dinner paid by You, split equally 3 ways.
        app.buttons["Add expense"].tap()
        let titleField = app.textFields["Title (e.g. Dinner at Luigi's)"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText("Dinner")
        let amountField = app.textFields["0.00"].firstMatch
        amountField.tap()
        amountField.typeText("90")
        app.buttons["Save"].tap()

        // Balances: You are owed 60, Alice and Bob owe 30 each.
        XCTAssertTrue(app.staticTexts["Dinner"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$60.00"].exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "$30.00").count, 2)

        // Settle up: two suggested payments of $30 to You.
        app.buttons["Settle up"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Suggested payments"].waitForExistence(timeout: 5))
        let recordButtons = app.buttons.matching(identifier: "Record payment")
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
        app.terminate()
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
