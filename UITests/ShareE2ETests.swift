import XCTest

/// Two-simulator CKShare E2E, orchestrated by Scripts/share-e2e.sh: an owner
/// simulator creates a group and copies its invite link; a participant
/// simulator (different iCloud account) accepts it via the app's
/// --accept-share-url hook and adds an expense; the owner sees the expense.
/// Each test is one side of the conversation, so they only run when the
/// script passes the shared context through TEST_RUNNER_ environment
/// variables — otherwise they skip.
///
/// Cloud-backed on purpose: no --local-store, no --reset-data. Repeat runs
/// stay unambiguous because the script generates a unique group name per run.
final class ShareE2ETests: XCTestCase {
    private var groupName: String {
        get throws {
            guard let name = ProcessInfo.processInfo.environment["E2E_GROUP"] else {
                throw XCTSkip("Share E2E runs via Scripts/share-e2e.sh (needs TEST_RUNNER_E2E_GROUP)")
            }
            return name
        }
    }

    // MARK: Owner side (simulator A)

    func testOwnerCreatesGroupAndCopiesInviteLink() throws {
        let group = try groupName
        let app = XCUIApplication()
        app.launch()

        // Empty state has a prominent create button; otherwise the toolbar +.
        let emptyStateCreate = app.buttons["Create a group"]
        if emptyStateCreate.waitForExistence(timeout: 5) {
            emptyStateCreate.tap()
        } else {
            app.navigationBars.buttons["Add"].tap()
        }

        let nameField = app.textFields["Name (e.g. Tahoe Trip)"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(group)
        let yourNameField = app.textFields["Your name"]
        yourNameField.tap()
        yourNameField.typeText("Sam")
        let memberField = app.textFields["Member name"]
        memberField.tap()
        memberField.typeText("Alice")
        app.buttons["Create"].tap()

        let groupCell = app.cells.staticTexts[group]
        XCTAssertTrue(groupCell.waitForExistence(timeout: 5))
        groupCell.tap()

        app.openGroupOverflowMenu()
        let copyButton = app.buttons["Copy invite link"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 5))
        copyButton.tap()

        // Creating + publishing the share is several CloudKit round trips.
        let alert = app.alerts["Invite link copied"]
        XCTAssertTrue(alert.waitForExistence(timeout: 90),
                      "Share was never published — check iCloud sign-in on this simulator")
        alert.buttons["OK"].tap()
    }

    // MARK: Participant side (simulator B)

    func testParticipantJoinsAndAddsExpense() throws {
        let group = try groupName
        guard let url = ProcessInfo.processInfo.environment["E2E_SHARE_URL"] else {
            throw XCTSkip("Needs TEST_RUNNER_E2E_SHARE_URL")
        }

        let app = XCUIApplication()
        app.launchArguments = ["--accept-share-url", url]

        // Acceptance and the shared-store import are both async with no UI
        // signal; relaunching re-runs the (idempotent) accept and forces a
        // fresh import, so poll across relaunches.
        XCTAssertTrue(waitAcrossRelaunches(app, attempts: 8, timeout: 25) {
            $0.cells.staticTexts[group]
        }, "Shared group never appeared — acceptance or import failed")

        app.cells.staticTexts[group].tap()

        // The claim gate can open before the member records finish importing,
        // showing only the "Not in the list?" row — blindly tapping the first
        // enabled cell then focuses the name field instead of claiming. Wait
        // for Alice (the unclaimed member; Sam is the owner's) specifically.
        XCTAssertTrue(app.navigationBars["Who are you?"].waitForExistence(timeout: 10))
        let alice = app.cells.staticTexts["Alice"]
        XCTAssertTrue(alice.waitForExistence(timeout: 60),
                      "Members never imported into the claim sheet")
        alice.tap()
        XCTAssertTrue(app.navigationBars["Who are you?"].waitForNonExistence(timeout: 10),
                      "Claiming Alice didn't dismiss the gate")

        let addExpense = app.buttons["Add expense"]
        XCTAssertTrue(addExpense.waitForExistence(timeout: 10))
        addExpense.tap()
        let titleField = app.textFields["Title (e.g. Dinner at Luigi's)"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText("Kayak rental")
        let amountField = app.textFields["0.00"].firstMatch
        amountField.tap()
        amountField.typeText("40")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Kayak rental"].waitForExistence(timeout: 10))

        // The CloudKit export of the new expense is async; ending the test
        // here kills the app mid-upload and the owner never receives it.
        // Give the mirroring delegate time to finish before teardown.
        sleep(20)
    }

    // MARK: Owner side again (simulator A)

    func testOwnerSeesParticipantExpense() throws {
        let group = try groupName
        let app = XCUIApplication()

        XCTAssertTrue(waitAcrossRelaunches(app, attempts: 8, timeout: 25, navigate: {
            let cell = $0.cells.staticTexts[group]
            if cell.waitForExistence(timeout: 10) { cell.tap() }
            $0.claimFirstMemberIfAsked()
        }) {
            $0.staticTexts["Kayak rental"]
        }, "Participant's expense never synced back to the owner")
    }

    /// Launches the app and waits for `element`; on a miss, terminates and
    /// relaunches (each launch triggers a CloudKit import) up to `attempts`.
    private func waitAcrossRelaunches(_ app: XCUIApplication,
                                      attempts: Int,
                                      timeout: TimeInterval,
                                      navigate: ((XCUIApplication) -> Void)? = nil,
                                      element: (XCUIApplication) -> XCUIElement) -> Bool {
        for attempt in 1...attempts {
            app.launch()
            navigate?(app)
            if element(app).waitForExistence(timeout: timeout) { return true }
            print("ShareE2E: attempt \(attempt)/\(attempts) — not yet, relaunching")
            app.terminate()
        }
        return false
    }
}
