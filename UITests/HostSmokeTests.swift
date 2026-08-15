import XCTest

final class HostSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchAndAllow() -> XCUIApplication {
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for title in ["Allow", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)
        if app.alerts.buttons["Allow"].waitForExistence(timeout: 3) {
            app.alerts.buttons["Allow"].tap()
        }
        if app.alerts.buttons["Allow"].waitForExistence(timeout: 2) {
            app.alerts.buttons["Allow"].tap()
        }
        app.tap()
        return app
    }

    func testHostLaunchShowsStartSession() {
        let app = launchAndAllow()
        XCTAssertTrue(
            app.buttons["Start session"].waitForExistence(timeout: 8),
            "Start session missing. Hierarchy: \(app.debugDescription)"
        )
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testStartSessionDoesNotCrash() {
        let app = launchAndAllow()
        let start = app.buttons["Start session"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()
        XCTAssertEqual(app.state, .runningForeground, "Start session aborted the process")

        let off = app.buttons["Turn microphone off"]
        let simulatorError = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Simulator cannot start the mic")
        ).firstMatch
        let anyError = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "mic")
        ).firstMatch
        XCTAssertTrue(
            off.waitForExistence(timeout: 6) || simulatorError.waitForExistence(timeout: 2) || anyError.exists,
            "No armed state and no error after Start session. Hierarchy: \(app.debugDescription)"
        )

        if off.exists {
            off.tap()
            XCTAssertTrue(start.waitForExistence(timeout: 6), "Mic off did not restore Start session")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testSetupCopyIsPresent() {
        let app = launchAndAllow()
        XCTAssertTrue(app.staticTexts["Use it like Wispr Flow"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Start session")).firstMatch.exists
        )
    }
}
