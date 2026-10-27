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

    override func tearDown() {
        if app.staticTexts["Controlling"].exists, app.buttons["View"].exists { app.buttons["View"].tap() }
        super.tearDown()
    }

    func testSendAndStreamReply() throws {
        guard ProcessInfo.processInfo.environment["MOBD_SEND_TEST_MESSAGE"] == "1" else {
            throw XCTSkip("Set MOBD_SEND_TEST_MESSAGE=1 after approving a real model request")
        }
        let newChat = app.buttons["New chat"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 15))
        if newChat.isEnabled { newChat.tap() }
        // Never send into an existing chat: the empty new-chat screen must be showing.
        XCTAssertTrue(app.staticTexts["New chat on Office Mac"].waitForExistence(timeout: 5), "new chat did not open")
        let field = app.descendants(matching: .any)["composer"]
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
        search.typeText("mob-test-no-matching-chat-7c2f")
        XCTAssertTrue(app.staticTexts["No chats match"].waitForExistence(timeout: 5))
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

    func testDraftSurvivesRotationAndBackground() {
        let newChat = app.buttons["New chat"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 15))
        if newChat.isEnabled { newChat.tap() }
        let draft = "Unsent Duo layout regression draft"
        let field = app.descendants(matching: .any)["composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(draft)
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertEqual(field.value as? String, draft)
            XCTAssertTrue(field.isHittable)
            XCTAssertTrue(app.buttons["Send"].isHittable)
            shot("draft-\(orientation.rawValue)")
        }
        XCUIApplication(bundleIdentifier: "com.apple.Preferences").launch()
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "The app did not enter the background")
        app.activate()
        XCTAssertEqual(field.value as? String, draft)
        XCTAssertTrue(app.buttons["Send"].isHittable)
        shot("draft-restored")
    }

    /// The operator folds/unfolds in Device Hub after each printed checkpoint.
    func testDraftAcrossDisplayChanges() throws {
        guard let count = ProcessInfo.processInfo.environment["MOBD_DISPLAY_CHANGES"].flatMap(Int.init), count > 0 else {
            throw XCTSkip("Set MOBD_DISPLAY_CHANGES and change the active display at each checkpoint")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let newChat = app.buttons["New chat"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 15))
        if newChat.isEnabled { newChat.tap() }
        let field = app.descendants(matching: .any)["composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let draft = "Unsent Duo folding regression draft"
        field.tap()
        field.typeText(draft)
        for step in 1...count {
            let before = app.windows.firstMatch.frame.size
            print("display-transition[\(step)]: waiting at \(before)")
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.app.windows.firstMatch.frame.size != before
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 90), .completed)
            XCTAssertEqual(field.value as? String, draft)
            XCTAssertTrue(field.isHittable)
            XCTAssertTrue(app.buttons["Send"].isHittable)
            shot("display-transition-\(step)")
        }
    }

    func testLiveViewResizeAndControlRelease() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let show = app.buttons["Show desktop"]
        XCTAssertTrue(show.waitForExistence(timeout: 15))
        show.tap()
        let thumbnail = app.buttons["Office desktop. Opens full screen."]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 15))
        thumbnail.tap()
        XCTAssertTrue(app.staticTexts["Live"].waitForExistence(timeout: 20), "No decoded live frame")
        let control = app.buttons["Control"]
        XCTAssertTrue(control.isHittable)
        control.tap()
        XCTAssertTrue(app.staticTexts["Controlling"].waitForExistence(timeout: 5))
        XCUIApplication(bundleIdentifier: "com.apple.Preferences").launch()
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "The app did not enter the background")
        app.activate()
        XCTAssertTrue(app.staticTexts["Live"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Controlling"].exists)
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.buttons["Close"].isHittable)
            XCTAssertTrue(app.staticTexts["Live"].exists)
        }
        shot("live-resized")
        app.buttons["Close"].tap()
        app.buttons["Settings"].firstMatch.tap()
        app.swipeUp()
        app.buttons["Log"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'live view: resize to'")).firstMatch.waitForExistence(timeout: 10), "The UI never sent a resize")
        shot("live-resize-log")
    }

    func testDesktopThumbnailAndFullScreen() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let show = app.buttons["Show desktop"]
        XCTAssertTrue(show.waitForExistence(timeout: 15))
        show.tap()
        let thumb = app.buttons["Office desktop. Opens full screen."]
        XCTAssertTrue(thumb.waitForExistence(timeout: 15))
        sleep(4) // a snapshot or live frame arrives
        shot("thumbnail")
        let field = app.descendants(matching: .any)["composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        // Duo can show a sidebar while still reporting the phone idiom.
        if thumb.frame.maxY <= field.frame.minY {
            let width = thumb.frame.width
            XCTAssertGreaterThan(width, field.frame.width * 0.85)
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
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        shot("thumbnail-landscape")
        XCUIDevice.shared.orientation = .portrait
        thumb.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
        sleep(3)
        shot("fullscreen")
        app.buttons["Close"].tap()
    }
}

extension XCTestCase {
    /// Saves a screenshot next to the test run for review.
    func shot(_ name: String) {
        for (index, screen) in XCUIScreen.screens.enumerated() {
            let screenshot = screen.screenshot()
            let label = "\(name)-display-\(index)"
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/mob-ios-\(label).png"))
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = label
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
