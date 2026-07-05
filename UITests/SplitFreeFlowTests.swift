import XCTest

/// End-to-end happy path: create a group, add an expense, settle up, and
/// confirm everything survives a relaunch. Also covers issue #3 — the
/// settle-up bubble opens the record sheet prefilled with the transfer, and
/// the suggested list refreshes both ways when a payment is saved and deleted.
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

        // Tapping the bubble opens the record sheet prefilled with the transfer;
        // saving it records the payment. One debt is settled, so it lands in
        // history and a single suggestion remains.
        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()
        XCTAssertTrue(app.staticTexts["Past payments"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Mark as paid").count, 1)

        // Deleting the recorded payment brings the suggestion back — the list
        // refreshes both ways. On iOS 26 the section FOOTER is exposed as a cell,
        // and the Suggested-payments footer contains both "paid" and "Apple
        // Cash", so neither can target the history row. "paid Sam" is unique to
        // history rows ("Bob paid Sam"); suggested rows say "pays Sam".
        // Wait for the record sheet to finish dismissing, then settle, so the
        // swipe doesn't land mid-animation and miss the Delete action.
        XCTAssertTrue(app.navigationBars["Record payment"].waitForNonExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let paymentRow = app.cells.containing(
            NSPredicate(format: "label CONTAINS 'paid Sam'")).firstMatch
        paymentRow.swipeLeft()
        if !app.buttons["Delete"].waitForExistence(timeout: 3) {
            paymentRow.swipeLeft() // retry once if the first swipe raced the layout
        }
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3))
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Suggested payments"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Mark as paid").count, 2)

        // Re-record one payment (bubble → Save) so the persistence check below
        // sees exactly one.
        app.buttons.matching(identifier: "Mark as paid").firstMatch.tap()
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
