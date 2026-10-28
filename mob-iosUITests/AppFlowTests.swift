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

    func testLiveTouchCoordinatesAndZoom() throws {
        guard let path = ProcessInfo.processInfo.environment["MOBD_INPUT_PROBE_PATH"] else {
            throw XCTSkip("Run the local input probe and set MOBD_INPUT_PROBE_PATH")
        }
        func probe() throws -> [String: Any] {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let p = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(p["name"] as? String, "mob-ios-input-probe")
            XCTAssertEqual(p["ready"] as? Bool, true)
            XCTAssertLessThan(Date().timeIntervalSince1970 - (p["at"] as? Double ?? 0), 2)
            return p
        }
        let initial = try probe()
        let width = try XCTUnwrap(initial["width"] as? Double)
        let height = try XCTUnwrap(initial["height"] as? Double)
        let baseline = (initial["events"] as? [[String: Any]] ?? []).count
        // This input test requires a single machine/address, pointing at this Mac.
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Connected to Office Mac"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Edit '")).count, 1)
        let addresses = Set(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'http'")).allElementsBoundByIndex.compactMap { URL(string: $0.label) }
            .filter { ["http", "https"].contains($0.scheme ?? "") })
        XCTAssertEqual(addresses.count, 1)
        let host = try XCTUnwrap(addresses.first?.host)
        XCTAssertTrue((initial["hosts"] as? [String] ?? []).contains(host), "The app must target the local probe's Mac")
        app.buttons["Chat"].firstMatch.tap()
        func events(_ kind: String) -> [[String: Any]] {
            let p = try? probe()
            return (p?["events"] as? [[String: Any]] ?? []).dropFirst(baseline).filter { $0["kind"] as? String == kind }
        }
        func waitFor(_ kind: String, _ count: Int) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in events(kind).count >= count }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        }
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        let show = app.buttons["Show desktop"]
        XCTAssertTrue(show.waitForExistence(timeout: 15))
        show.tap()
        let thumb = app.buttons["Office desktop. Opens full screen."]
        XCTAssertTrue(thumb.waitForExistence(timeout: 15))
        thumb.tap()
        XCTAssertTrue(app.staticTexts["Live"].waitForExistence(timeout: 20))
        let canvas = app.otherElements["desktopTouchSurface"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), app.debugDescription)
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        }
        func videoSize() -> CGSize {
            let size = canvas.frame.size
            let scale = min(size.width / width, size.height / height)
            return CGSize(width: width * scale, height: height * scale)
        }
        canvas.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(events("down").count, 0, "View mode sent a tap")
        canvas.pinch(withScale: 2, velocity: 1)
        _ = try probe()
        app.buttons["Control"].tap()
        shot("live-touch-control")
        XCTAssertTrue(app.staticTexts["Controlling"].waitForExistence(timeout: 5), app.debugDescription)
        let size = canvas.frame.size
        point(size.width / 2 + videoSize().width / 4, size.height / 2).tap()
        waitFor("down", 1)
        let zoomed = try XCTUnwrap(events("down").last?["x"] as? Double)
        XCTAssertGreaterThan(zoomed, width / 2 + 10)
        XCTAssertLessThan(zoomed, width * 0.75 - 10, "Pinch did not change the mapped coordinate")
        app.buttons["View"].tap()
        point(size.width / 2, size.height / 2).press(forDuration: 0.1, thenDragTo: point(size.width / 2 + 40, size.height / 2))
        app.buttons["Control"].tap()
        canvas.tap()
        waitFor("down", 2)
        XCTAssertLessThan(try XCTUnwrap(events("down").last?["x"] as? Double), width / 2 - 10, "View pan did not move the picture")
        app.buttons["View"].tap()
        canvas.doubleTap()
        app.buttons["Control"].tap()
        let video = videoSize()
        if size.height - video.height > 12 || size.width - video.width > 12 {
            let margin = size.height - video.height > 12 ? CGPoint(x: size.width / 2, y: 4) : CGPoint(x: 4, y: size.height / 2)
            point(margin.x, margin.y).tap()
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(events("down").count, 2, "A letterbox tap reached the Mac")
        }
        point(size.width / 2 + videoSize().width / 4, size.height / 2).tap()
        waitFor("down", 3)
        XCTAssertEqual(try XCTUnwrap(events("down").last?["x"] as? Double), width * 0.75, accuracy: 4)
        XCTAssertEqual(try XCTUnwrap(events("down").last?["y"] as? Double), height / 2, accuracy: 4)
        XCUIDevice.shared.orientation = .portrait
        canvas.tap()
        waitFor("down", 4)
        XCTAssertEqual(try XCTUnwrap(events("down").last?["x"] as? Double), width / 2, accuracy: 4)
        XCTAssertEqual(try XCTUnwrap(events("down").last?["y"] as? Double), height / 2, accuracy: 4)
        canvas.press(forDuration: 0.8)
        waitFor("rightDown", 1)
        let rotated = canvas.frame.size
        let rotatedVideo = videoSize()
        point(rotated.width / 2 - rotatedVideo.width * 0.1, rotated.height / 2)
            .press(forDuration: 0.1, thenDragTo: point(rotated.width / 2 + rotatedVideo.width * 0.1, rotated.height / 2))
        waitFor("drag", 1)
        waitFor("up", 5)
        XCTAssertEqual(try XCTUnwrap(events("up").last?["x"] as? Double), width * 0.6, accuracy: 4)
        app.buttons["Keyboard"].tap()
        app.typeText("duo-ui")
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            events("keyDown").compactMap { $0["text"] as? String }.joined().contains("duo-ui")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 5), .completed)
        app.buttons["Keyboard"].tap()
        app.buttons["View"].tap()
        shot("live-touch-zoom")
        app.buttons["Close"].tap()
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
