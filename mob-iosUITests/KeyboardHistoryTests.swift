import XCTest

/// Tapping the composer keeps the history visible (mob-ios#8). Opt in with MOBD_TALL_CHAT set to the
/// title of a conversation whose last message is taller than the screen and MOBD_OTHER_CHAT to any
/// other conversation, on the machine paired in the simulator (LayoutTests.testPairMachineFromLink).
/// Turn off the simulator's hardware keyboard (I/O → Keyboard), or no keyboard appears. Sends nothing.
final class KeyboardHistoryTests: XCTestCase {
    func testSwitchingToATallMessageThenTappingTheComposerKeepsTheHistoryVisible() throws {
        let env = ProcessInfo.processInfo.environment
        guard let tall = env["MOBD_TALL_CHAT"], let other = env["MOBD_OTHER_CHAT"], !tall.isEmpty, !other.isEmpty else {
            throw XCTSkip("Set MOBD_TALL_CHAT and MOBD_OTHER_CHAT to conversation titles")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let composer = app.descendants(matching: .any)["composer"].firstMatch
        let timeline = app.scrollViews["chatTimeline"]
        for round in 1...3 {
            open(app, other)
            open(app, tall)
            // Opened at the end: text right above the composer, not space past the last message.
            XCTAssertGreaterThan(texts(app, timeline, above: composer.frame.minY, near: 400), 0, "round \(round): opened past the end")
            composer.tap()
            if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { composer.tap() }
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no software keyboard; turn off the hardware keyboard")
            sleep(1)
            let top = min(composer.frame.minY, app.keyboards.firstMatch.frame.minY)
            XCTAssertGreaterThan(texts(app, timeline, above: top, near: 300), 0, "round \(round): history blank after tapping the composer")
            app.swipeDown(velocity: .slow)
            sleep(1)
        }

        // Reading further up, the keyboard leaves the reading position alone.
        if app.keyboards.firstMatch.exists { timeline.swipeDown(velocity: .slow) }
        timeline.swipeDown(velocity: .slow); timeline.swipeDown(velocity: .slow)
        sleep(2)
        // A line shown once, so it can be found again after the keyboard opens.
        let anchor = timeline.staticTexts.allElementsBoundByIndex.first {
            $0.frame.minY > timeline.frame.minY + 120 && $0.frame.height > 0 && !$0.label.isEmpty
                && app.staticTexts.matching(NSPredicate(format: "label == %@", $0.label)).count == 1
        }
        let label = try XCTUnwrap(anchor?.label)
        let text = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
        let before = text.frame.minY
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        let moved = text.frame.minY - before
        XCTAssertLessThan(abs(moved), 60, "the keyboard moved the text being read by \(Int(moved))pt")
    }

    /// A tap on the history hides the keyboard; the history stays where it was.
    func testTappingTheHistoryHidesTheKeyboard() throws {
        guard let chat = ProcessInfo.processInfo.environment["MOBD_OTHER_CHAT"], !chat.isEmpty else {
            throw XCTSkip("Set MOBD_OTHER_CHAT to a conversation title")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        open(app, chat)
        let composer = app.descendants(matching: .any)["composer"].firstMatch
        let timeline = app.scrollViews["chatTimeline"]
        for round in 1...3 {
            composer.tap()
            if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { composer.tap() }
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no software keyboard; turn off the hardware keyboard")
            sleep(1)
            timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            let gone = NSPredicate(format: "exists == false")
            let hidden = XCTNSPredicateExpectation(predicate: gone, object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed, "round \(round): the keyboard stayed after tapping the history")
            XCTAssertGreaterThan(texts(app, timeline, above: composer.frame.minY, near: 400), 0, "round \(round): history blank after the keyboard hid")
        }
    }

    /// After typing a draft and hiding the keyboard, scrolling up stays up (mob-ios#9).
    func testScrollingUpAfterHidingTheKeyboardIsNotPulledBack() throws {
        guard let chat = ProcessInfo.processInfo.environment["MOBD_OTHER_CHAT"], !chat.isEmpty else {
            throw XCTSkip("Set MOBD_OTHER_CHAT to a conversation title")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        open(app, chat)
        let composer = app.descendants(matching: .any)["composer"].firstMatch
        let timeline = app.scrollViews["chatTimeline"]
        composer.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { composer.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no software keyboard; turn off the hardware keyboard")
        composer.typeText("draft, not sent")
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed, "the keyboard stayed")
        sleep(1)
        // Small slow drags up, as a reader does: each must move the text by the drag and stay there
        // while rows are laid out, not snap back to the end.
        for step in 1...8 {
            guard let anchor = timeline.staticTexts.allElementsBoundByIndex.first(where: {
                $0.frame.minY > timeline.frame.minY + 150 && $0.frame.height > 0 && !$0.label.isEmpty
                    && app.staticTexts.matching(NSPredicate(format: "label == %@", $0.label)).count == 1
            }) else { XCTFail("nothing to follow at step \(step)"); return }
            let text = app.staticTexts.matching(NSPredicate(format: "label == %@", anchor.label)).firstMatch
            let before = text.frame.minY
            let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 250)), withVelocity: .slow, thenHoldForDuration: 0.2)
            usleep(1_200_000)
            XCTAssertTrue(text.exists && text.frame.height > 0, "step \(step): the line left, the timeline went back to the end")
            let moved = text.frame.minY - before
            XCTAssertGreaterThan(moved, 150, "step \(step): the text moved \(Int(moved))pt for a 250pt drag up: pulled back toward the end")
        }
        composer.tap()
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
    }

    private func open(_ app: XCUIApplication, _ title: String) {
        let chats = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Chats'")).firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 15))
        chats.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        // Newer chats can push it under the bottom of the list.
        for _ in 0..<5 where !row.isHittable { app.swipeUp(velocity: .slow) }
        row.tap()
        sleep(3)
    }

    /// Timeline texts within `near` points above `bottom`.
    private func texts(_ app: XCUIApplication, _ timeline: XCUIElement, above bottom: CGFloat, near: CGFloat) -> Int {
        timeline.staticTexts.allElementsBoundByIndex.filter { let f = $0.frame; return f.height > 0 && f.maxY > bottom - near && f.minY < bottom }.count
    }
}
