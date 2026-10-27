import XCTest

/// Repeat with Device Hub's inner and outer screens; pairing requires an explicit invitation.
final class LayoutTests: XCTestCase {
    /// Opt in with a fresh, single-use `mobd link` invitation.
    func testPairMachineFromLink() throws {
        guard let link = ProcessInfo.processInfo.environment["MOBD_PAIR_LINK"], !link.isEmpty else {
            throw XCTSkip("Set MOBD_PAIR_LINK to a fresh pairing link")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        app.buttons["Add machine"].tap()
        let linkField = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        linkField.tap()
        linkField.typeText(link)
        let deviceName = app.textFields["Device name"]
        XCTAssertTrue(deviceName.waitForExistence(timeout: 5))
        deviceName.tap()
        deviceName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        deviceName.typeText("iPhone Duo Simulator Test")
        let pair = app.buttons["Pair"]
        XCTAssertTrue(pair.isEnabled)
        pair.tap()
        let networkAllow = springboard.alerts.buttons["Allow"]
        if networkAllow.waitForExistence(timeout: 3) { networkAllow.tap() }
        XCTAssertTrue(app.staticTexts["Connected to Office Mac"].waitForExistence(timeout: 25))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "paired-settings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSettingsAndPairingAcrossRotation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        defer { XCUIDevice.shared.orientation = .portrait }

        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let addMachine = app.buttons["Add machine"]
        XCTAssertTrue(addMachine.waitForExistence(timeout: 5))
        addMachine.tap()

        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            XCTAssertTrue(cancel.isHittable, "Pairing cannot be closed after rotation")
            XCTAssertTrue(app.buttons["Scan QR code"].isHittable)
            XCTAssertFalse(app.buttons["Pair"].isEnabled)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "pairing-\(orientation.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let link = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        link.tap()
        link.typeText("invalid-pairing-link")
        XCTAssertFalse(app.buttons["Pair"].isEnabled, "An invalid link must not enable pairing")
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.isHittable, "Keyboard covers the close button")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "pairing-keyboard"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Add machine"].waitForExistence(timeout: 5))
    }
}
