import XCTest

/// Drives the app against a real mobd. Expects a paired machine in the simulator: pair it once in
/// the app's Settings → Add machine with a `mobd link` link. The device token lives in the Keychain,
/// so a machine seeded with `defaults write com.xrdavies.mob-ios machines -data …` needs pairing.
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
        XCTAssertTrue(app.staticTexts["New chat on Office computer"].waitForExistence(timeout: 5), "new chat did not open")
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
        // iPhone opens the chat list as a sheet; on iPad it is always beside the chat.
        let chats = app.buttons["Chats"]
        if chats.waitForExistence(timeout: 5) { chats.tap() }
        XCTAssertTrue(app.staticTexts["Recent"].waitForExistence(timeout: 10))
        shot("chats")
        let search = app.searchFields["Search chats"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("chrome")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS '使用chrome'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Recent"].exists)
        shot("search")
        // iOS 26 closes search with a round button next to the field.
        let close = app.buttons["Close"].firstMatch
        if close.exists { close.tap() }
        else if app.buttons["Cancel"].exists { app.buttons["Cancel"].firstMatch.tap() }
        else { search.buttons["Clear text"].tap() }
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Machines"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Connected to'")).firstMatch.waitForExistence(timeout: 20))
        shot("settings")
        app.swipeUp()
        app.buttons["Log"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'events connected'")).firstMatch.waitForExistence(timeout: 10))
        shot("log")
    }

    func testDesktopThumbnailAndFullScreen() {
        let show = app.buttons["Show desktop"]
        XCTAssertTrue(show.waitForExistence(timeout: 15))
        show.tap()
        let thumb = app.buttons["Office desktop. Opens full screen."]
        XCTAssertTrue(thumb.waitForExistence(timeout: 15))
        sleep(4) // a snapshot or live frame arrives
        shot("thumbnail")
        if UIDevice.current.userInterfaceIdiom == .phone {
            let width = thumb.frame.width
            XCTAssertGreaterThan(width, app.frame.width * 0.85)
            let field = app.textFields.firstMatch
            field.tap()
            field.typeText(String(repeating: "Unsent draft text for keyboard layout. ", count: 8))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(thumb.frame.width, width, accuracy: 2)
            let timeline = app.scrollViews["chatTimeline"]
            if timeline.exists {
                XCTAssertGreaterThan(timeline.frame.height, 0)
                XCTAssertTrue(timeline.staticTexts.allElementsBoundByIndex.contains { $0.isHittable }, "history disappeared after keyboard opened")
            }
            shot("thumbnail-keyboard")
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Landscape iPad has room for the desktop beside the chat.
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(3)
            shot("thumbnail-landscape")
            XCUIDevice.shared.orientation = .portrait
        }
        thumb.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
        sleep(3)
        shot("fullscreen")
        app.buttons["Close"].tap()
    }
}
