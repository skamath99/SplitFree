import XCTest

/// Regression coverage that needs its own setup:
///  - issue #2: group-derived balances/totals must refresh when an existing
///    expense is edited (amount changed, participant added/removed), not just
///    when a new expense is created — plus the per-device "who am I" claim
///    perspective, which is the same staleness family (claims live in
///    UserDefaults, not Core Data).
///  - the receipt-scan flow (needs a clean ledger and the photo library).
/// (Issue #3's settle-up bubble lives in SplitFreeFlowTests.)
final class IssueRegressionTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--reset-data", "--local-store"]
        app.launch()
    }

    // MARK: - Issue #2 + per-device claim perspective

    /// Editing an expense must refresh every group-derived display in place,
    /// and switching the per-device claim must re-render the GroupRow summary.
    func testEditingExpenseRefreshesBalancesEverywhere() throws {
        try app.createTahoeTripWithDinner()

        // Baseline: Sam +$60, Alice/Bob −$30 each.
        XCTAssertTrue(app.staticTexts["$60.00"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "$30.00").count, 2)

        // Edit the amount 90 → 120. The balances section must update in place,
        // without leaving and re-entering the group (the issue #2 repro).
        openDinnerEditor()
        let amountField = app.textFields["0.00"].firstMatch
        app.clearAndType(amountField, "120")
        app.buttons["Save"].tap()

        XCTAssertTrue(app.staticTexts["$80.00"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "$40.00").count, 2)

        // Exclude Bob from the split: Sam and Alice now split $120 → ±$60,
        // Bob settled.
        openDinnerEditor()
        toggleSplitMember("Bob")
        app.buttons["Save"].tap()

        XCTAssertTrue(app.staticTexts["settled"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "$60.00").count, 2) // Sam owed + Alice owes

        // Re-include Bob — the literal issue: "new person added to a
        // transaction" must recompute everyone's balance again.
        openDinnerEditor()
        toggleSplitMember("Bob")
        app.buttons["Save"].tap()

        XCTAssertTrue(app.staticTexts["$80.00"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "$40.00").count, 2)

        // Members pills (same SpendingGroup.balances source) reflect the edit.
        // The Members sheet doesn't cover the group-detail list behind it in the
        // a11y tree, so each amount is counted twice — once per layer: the sheet
        // shows Sam $80 + Alice/Bob $40, and the underlying Balances section
        // repeats them (Sam once, Alice/Bob once) → $80.00 ×2, $40.00 ×4.
        app.openGroupOverflowMenu()
        app.buttons["Members"].tap()
        XCTAssertTrue(app.staticTexts["$80.00"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "$80.00").count, 2)
        XCTAssertEqual(app.staticTexts.matching(identifier: "$40.00").count, 4)
        app.buttons["Done"].tap()

        // Groups-list summary line (GroupRow) was stale pre-fix.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["You are owed $80.00"].waitForExistence(timeout: 5))

        // Insights totals pick up the new amount.
        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(app.staticTexts["$120.00"].waitForExistence(timeout: 5))

        // Per-device claim perspective: switching "who am I" must re-render the
        // GroupRow summary immediately. Balances here are 80/40/40 (not 30!) —
        // as Alice the device owes $40; back as Sam it is owed $80.
        app.tabBars.buttons["Groups"].tap()
        app.cells.staticTexts["Tahoe Trip"].firstMatch.tap()
        claimAsMe("Alice")
        app.navigationBars.buttons.firstMatch.tap() // back to groups list
        XCTAssertTrue(app.staticTexts["You owe $40.00"].waitForExistence(timeout: 5))

        app.cells.staticTexts["Tahoe Trip"].firstMatch.tap()
        claimAsMe("Sam")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["You are owed $80.00"].waitForExistence(timeout: 5))
    }

    // MARK: - Exclusive name claims

    /// A name claimed by one participant can't be claimed by another, and every
    /// participant can see which names are still unclaimed.
    func testClaimExclusivityAndVisibility() throws {
        try app.createTahoeTrip(withDinner: false) // Sam = you/claimed, Alice, Bob

        // As the creator, Sam is claimed; Alice and Bob are not.
        app.openGroupOverflowMenu()
        app.buttons["Members"].tap()
        XCTAssertTrue(app.navigationBars["Members"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Not claimed yet").count, 2)
        app.buttons["Done"].tap()

        // Relaunch as a different person on the same data: the gate must appear.
        app.terminate()
        app.launchArguments = ["--local-store", "--forget-device"]
        app.launch()
        app.cells.staticTexts["Tahoe Trip"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Who are you?"].waitForExistence(timeout: 5))

        // Gate rows are Buttons; the background GroupDetailView's cells leak
        // into the a11y tree under the fullScreenCover, so target buttons only.
        // Sam is taken, so Sam's gate button is disabled.
        let samButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sam'")).firstMatch
        XCTAssertTrue(samButton.waitForExistence(timeout: 5))
        XCTAssertFalse(samButton.isEnabled)

        // Joining as "Sam" is rejected with the "already claimed" error.
        let nameField = app.textFields["Your name"]
        nameField.tap()
        nameField.typeText("Sam")
        app.buttons["Join"].tap()
        XCTAssertTrue(app.staticTexts["That name is already claimed."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Who are you?"].exists)

        // Settle the layout before tapping a member row: keyboard-avoidance
        // shifts the list while the keyboard is up.
        app.keyboards.buttons["Return"].tap()

        // Claiming Alice dismisses the gate.
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Alice'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Who are you?"].waitForNonExistence(timeout: 5))

        // Now only Bob is unclaimed.
        app.openGroupOverflowMenu()
        app.buttons["Members"].tap()
        XCTAssertTrue(app.navigationBars["Members"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Not claimed yet").count, 1)
        app.buttons["Done"].tap()
    }

    // MARK: - Receipt scan
    //
    // Precondition: the runner simulator's photo library contains a receipt
    // image (added via `xcrun simctl addmedia <udid> <receipt.png>`). The
    // reference receipt is a Swiss bill — items 9.00 / 5.00 / 22.00 / 18.50,
    // total CHF 54.50. The scanner returns bare decimals; the group is in USD,
    // so amounts render with a $.
    func testReceiptScanCreatesItemizedExpense() throws {
        // No Dinner: keep the ledger to just the scanned expense for clean math.
        try app.createTahoeTrip(withDinner: false)

        app.buttons["Add expense"].tap()
        XCTAssertTrue(app.buttons["Scan receipt"].waitForExistence(timeout: 5))
        app.buttons["Scan receipt"].tap()
        XCTAssertTrue(app.buttons["Choose receipt photo"].waitForExistence(timeout: 5))
        app.buttons["Choose receipt photo"].tap()

        // Select the receipt from the out-of-process PHPicker. Every grid
        // thumbnail carries the identifier "PXGGridLayout-Info"; the grid sorts
        // newest-first and the just-added receipt is newest (addmedia stamps the
        // *import* date, not EXIF — hence a "Photo, July 05 …" label, not 2007).
        // The onboarding banner's icon also lives in this scroll view, so
        // images.firstMatch / scrollViews.images would grab it — match the
        // thumbnail identifier instead. The sleep is load-bearing: the remote
        // view needs a beat to accept synthesized taps after it settles.
        let grid = app.scrollViews["photosView_content_scroll_view"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10), "PHPicker grid never appeared")
        sleep(2)
        let photo = app.images.matching(
            NSPredicate(format: "identifier == 'PXGGridLayout-Info'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5), "Receipt thumbnail never appeared")
        // PHPicker is a remote view: its elements report isHittable == false to
        // the host, so a plain .tap() is rejected. A coordinate tap on the
        // element's center bypasses the hittability check.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // OCR is async and lands on exactly ONE of two screens (items list OR
        // totals list), so poll their disjunction rather than waiting on both.
        let itemsFound = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'items found'")).firstMatch
        let tapTheTotal = app.staticTexts["Tap the total"]
        let deadline = Date().addingTimeInterval(30)
        while !(itemsFound.exists || tapTheTotal.exists) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(itemsFound.exists || tapTheTotal.exists,
                      "Receipt scan produced neither an items list nor a totals list")

        if itemsFound.exists {
            // Confirm the four real line items were read, then settle on the
            // total rather than itemizing — the total path gives a clean equal
            // three-way split, which is what the exact assertions below expect.
            for amount in ["9.00", "5.00", "22.00", "18.50"] {
                XCTAssertTrue(app.staticTexts.containing(
                    NSPredicate(format: "label CONTAINS %@", amount)).firstMatch.exists,
                    "Expected receipt item \(amount) in the scanned list")
            }
            // The action buttons sit below the fold and SwiftUI's lazy List
            // doesn't materialize offscreen rows into the a11y tree until
            // scrolled into view.
            let useTotal = app.buttons.matching(
                NSPredicate(format: "label CONTAINS 'Just use the total'")).firstMatch
            if !useTotal.exists { app.swipeUp() }
            XCTAssertTrue(useTotal.waitForExistence(timeout: 3),
                          "\"Just use the total\" button never materialized")
            useTotal.tap()
        } else {
            // Totals-only: tap the first (likely-total) candidate.
            app.buttons.matching(NSPredicate(format: "label CONTAINS '54.5'"))
                .firstMatch.tap()
        }

        // Back on the form the amount is prefilled from the receipt total.
        let amountField = app.textFields["0.00"].firstMatch
        XCTAssertTrue(amountField.waitForExistence(timeout: 5))
        let amountValue = amountField.value as? String ?? ""
        XCTAssertTrue(amountValue.contains("54.5"),
                      "Amount field should hold the scanned total, got \(amountValue)")

        app.buttons["Save"].tap()

        // Non-itemized: $54.50 split equally three ways. 5450 / 3 = 1816 each
        // with 2 leftover pennies to the first two members (Sam, Alice), so
        // Sam is owed $36.33 and Alice/Bob owe $18.17 / $18.16.
        XCTAssertTrue(app.staticTexts["Receipt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$54.50"].exists)
        XCTAssertTrue(app.staticTexts["$36.33"].exists)
        XCTAssertTrue(app.staticTexts["$18.17"].exists)
        XCTAssertTrue(app.staticTexts["$18.16"].exists)
    }

    // MARK: - Helpers

    private func openDinnerEditor() {
        app.staticTexts["Dinner"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Edit expense"].waitForExistence(timeout: 5))
    }

    /// Toggles a member's inclusion in the split. The circle button is the only
    /// button in that member's SplitMemberRow, so address it via the row cell.
    private func toggleSplitMember(_ name: String) {
        let row = app.cells.containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.buttons.firstMatch.tap()
    }

    /// Opens Members, long-presses a member, and taps "This is me". Waits for
    /// the sheet to finish animating in before the long-press — pressing while
    /// it slides up opens no context menu.
    private func claimAsMe(_ name: String) {
        app.openGroupOverflowMenu()
        app.buttons["Members"].tap()
        XCTAssertTrue(app.navigationBars["Members"].waitForExistence(timeout: 5))
        let row = app.cells.containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5)) // let the sheet settle
        row.press(forDuration: 1.2)
        if !app.buttons["This is me"].waitForExistence(timeout: 3) {
            row.press(forDuration: 1.2) // retry once if the press raced the animation
        }
        XCTAssertTrue(app.buttons["This is me"].waitForExistence(timeout: 3))
        app.buttons["This is me"].tap()
        app.buttons["Done"].tap()
    }
}
