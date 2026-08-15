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

    func testPhysicalSafariKeyboardStartReachesHost() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Physical keyboard transport requires an iPhone")
#else
        let host = launchAndAllow()
        let start = host.buttons["Start session"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()
        XCTAssertTrue(host.buttons["Turn microphone off"].waitForExistence(timeout: 8), "Host mic did not arm")

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        let address = safari.textFields.firstMatch
        if address.waitForExistence(timeout: 8) { address.tap() }
        else { safari.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Address")).firstMatch.tap() }

        var mic = safari.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Tap to talk")).firstMatch
        for _ in 0..<6 where !mic.exists {
            let next = safari.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "keyboard")).firstMatch
            if next.exists { next.tap() }
            else if safari.buttons["🌐"].exists { safari.buttons["🌐"].tap() }
            sleep(1)
            mic = safari.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Tap to talk")).firstMatch
        }
        XCTAssertTrue(mic.waitForExistence(timeout: 3), "Local Dictation keyboard was not available in Safari")
        mic.tap()
        let listening = safari.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Listening")).firstMatch
        XCTAssertTrue(listening.waitForExistence(timeout: 10), "Keyboard never received /start ACK")

        safari.buttons["Mic off"].tap()
        host.activate()
        XCTAssertTrue(host.buttons["Start session"].waitForExistence(timeout: 8), "Returning to host did not force mic off")
        XCTAssertTrue(host.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "/start received")).firstMatch.waitForExistence(timeout: 5), "Host never logged /start")
#endif
    }

    func testReturningToHostForcesMicOff() {
        let app = launchAndAllow()
        let start = app.buttons["Start session"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(start.waitForExistence(timeout: 8), "Returning to host did not turn microphone off")
    }

    func testSetupCopyIsPresent() {
        let app = launchAndAllow()
        XCTAssertTrue(app.staticTexts["Use it like Wispr Flow"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Start session")).firstMatch.exists
        )
    }
}
