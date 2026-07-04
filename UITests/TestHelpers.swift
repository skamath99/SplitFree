import XCTest

extension XCUIApplication {
    /// Creates the "Tahoe Trip" group (You, Alice, Bob), opens it, and adds a
    /// $90 Dinner paid by You split equally. Assumes a fresh --reset-data run.
    func createTahoeTripWithDinner() throws {
        let createButton = buttons["Create a group"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        createButton.tap()

        let nameField = textFields["Name (e.g. Tahoe Trip)"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Tahoe Trip")

        let memberField = textFields["Member name"]
        memberField.tap()
        memberField.typeText("Alice")
        buttons["Add another member"].tap()
        let memberFields = textFields.matching(identifier: "Member name")
        memberFields.element(boundBy: 1).tap()
        memberFields.element(boundBy: 1).typeText("Bob")
        buttons["Create"].tap()

        let groupCell = cells.staticTexts["Tahoe Trip"]
        XCTAssertTrue(groupCell.waitForExistence(timeout: 5))
        groupCell.tap()

        buttons["Add expense"].tap()
        let titleField = textFields["Title (e.g. Dinner at Luigi's)"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText("Dinner")
        let amountField = textFields["0.00"].firstMatch
        amountField.tap()
        amountField.typeText("90")
        buttons["Save"].tap()
        XCTAssertTrue(staticTexts["Dinner"].waitForExistence(timeout: 5))
    }
}
