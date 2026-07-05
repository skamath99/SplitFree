import XCTest

extension XCUIApplication {
    /// Shared/legacy groups block on the "Who are you?" gate; claim the
    /// first listed member so the test can proceed.
    func claimFirstMemberIfAsked() {
        if navigationBars["Who are you?"].waitForExistence(timeout: 3) {
            // Skip disabled "Claimed" rows — tapping one is inert and hangs.
            cells.matching(NSPredicate(format: "enabled == true")).firstMatch.tap()
        }
    }

    /// Creates the "Tahoe Trip" group (Sam, Alice, Bob), opens it, and adds a
    /// $90 Dinner paid by Sam split equally. Assumes a fresh --reset-data run.
    func createTahoeTripWithDinner() throws {
        try createTahoeTrip(withDinner: true)
    }

    /// Creates "Tahoe Trip" (Sam=you, Alice, Bob) and opens it. With
    /// `withDinner`, also adds a $90 Dinner paid by Sam split equally so tests
    /// that need a clean single-expense ledger can opt out. Fresh --reset-data.
    func createTahoeTrip(withDinner: Bool) throws {
        let createButton = buttons["Create a group"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        createButton.tap()

        let nameField = textFields["Name (e.g. Tahoe Trip)"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Tahoe Trip")

        let yourNameField = textFields["Your name"]
        yourNameField.tap()
        yourNameField.typeText("Sam")

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

        guard withDinner else {
            XCTAssertTrue(buttons["Add expense"].waitForExistence(timeout: 5))
            return
        }

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

    /// Replaces a text field's contents: deletes whatever is there (AmountField
    /// pre-fills the current value when editing), then types. AmountField is
    /// right-aligned and its frame runs the full row width, so a tap short of
    /// the very edge can land mid-digit and drop the caret at position 0, making
    /// backward deletes no-ops — tap dx 0.99 to sit after the last digit. If any
    /// digits survive, double-tap to select the number and delete again.
    func clearAndType(_ field: XCUIElement, _ text: String) {
        let rightEdge = field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5))
        rightEdge.tap()
        func deleteAll() {
            let count = (field.value as? String)?.count ?? 0
            if count > 0 {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count + 2))
            }
        }
        deleteAll()
        if let value = field.value as? String, value.contains(where: \.isNumber) {
            rightEdge.doubleTap()
            deleteAll()
        }
        field.typeText(text)
    }

    /// Opens the group-detail overflow menu (the ellipsis.circle Menu). Its
    /// accessibility label is "More"; fall back to the last nav-bar button.
    func openGroupOverflowMenu() {
        let more = buttons["More"]
        if more.waitForExistence(timeout: 2) {
            more.tap()
            return
        }
        let navButtons = navigationBars.buttons
        navButtons.element(boundBy: navButtons.count - 1).tap()
    }
}
