import XCTest

/// Drives the app against a real mobd. Expects a machine saved in the simulator's defaults
/// (the app's own Settings, or `defaults write com.xrdavies.mob-ios machines -data …`).
final class AppFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // The notification permission prompt belongs to SpringBoard.
        addUIInterruptionMonitor(withDescription: "Notifications") { alert in
            alert.buttons["Allow"].exists ? (alert.buttons["Allow"].tap(), true).1 : false
        }
        app.launch()
        app.tap() // lets the interruption monitor run
    }

    /// Saves a screenshot next to the test run for review.
    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/mob-ios-\(name).png"))
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testSendAndStreamReply() {
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 15))
        newChat.tap()
        // Never send into an existing chat: the empty new-chat screen must be showing.
        XCTAssertTrue(app.staticTexts["New chat on Office Mac"].waitForExistence(timeout: 5), "new chat did not open")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Reply with the word pong. Do not use tools.")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["pong"].waitForExistence(timeout: 120), "no reply")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'tokens'")).firstMatch.waitForExistence(timeout: 20))
        shot("reply")
    }

    func testChatListAndSettings() {
        app.buttons["Chats"].tap()
        XCTAssertTrue(app.staticTexts["Recent"].waitForExistence(timeout: 10))
        shot("chats")
        app.buttons["Done"].tap()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Machines"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Connected to'")).firstMatch.waitForExistence(timeout: 20))
        shot("settings")
    }

    func testDesktopThumbnailAndFullScreen() {
        let show = app.buttons["Show desktop"]
        XCTAssertTrue(show.waitForExistence(timeout: 15))
        show.tap()
        let thumb = app.buttons["Office desktop. Opens full screen."]
        XCTAssertTrue(thumb.waitForExistence(timeout: 15))
        sleep(4) // a snapshot or live frame arrives
        shot("thumbnail")
        thumb.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
        sleep(3)
        shot("fullscreen")
        app.buttons["Close"].tap()
    }
}
