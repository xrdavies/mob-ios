import XCTest

/// The history stays visible while the agent works after a message is sent: steps fold into groups
/// and long replies arrive, and the timeline must neither go blank nor fight a drag. Opt in with
/// MOBD_SLOW_AGENT=1 on a machine paired in the simulator (LayoutTests.testPairMachineFromLink) whose
/// agent takes a while and replies at length, such as a mobd whose claudeBin is a script printing
/// Claude's stream-json slowly (scripts/fake-claude). Sends two messages. Turn off the simulator's
/// hardware keyboard.
final class WorkingTimelineTests: XCTestCase {
    func testHistoryStaysVisibleWhileTheAgentWorks() throws {
        guard ProcessInfo.processInfo.environment["MOBD_SLOW_AGENT"] == "1" else {
            throw XCTSkip("Set MOBD_SLOW_AGENT=1 with a slow agent on the paired machine")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let newChat = app.buttons["New chat"].firstMatch
        if newChat.waitForExistence(timeout: 10), newChat.isEnabled { newChat.tap() }
        // A new chat, then the same chat again: both open the timeline differently.
        for round in 1...2 {
            send(app, "Working test \(round): write a long answer")
            watch(app, seconds: 45, round: round)
        }
    }

    private func send(_ app: XCUIApplication, _ text: String) {
        let composer = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let sendButton = app.buttons["Send"].firstMatch
        XCTAssertTrue(sendButton.waitForExistence(timeout: 60))
        for _ in 0..<60 where !sendButton.isEnabled && app.buttons["Stop"].exists { sleep(1) } // the last turn ends
        composer.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { composer.tap() }
        composer.typeText(text)
        sendButton.tap()
    }

    /// Every second while the agent works the history shows text, and a drag moves it.
    private func watch(_ app: XCUIApplication, seconds: Int, round: Int) {
        let timeline = app.scrollViews["chatTimeline"]
        let composer = app.descendants(matching: .any)["composer"].firstMatch
        for second in 1...seconds {
            sleep(1)
            let bottom = app.keyboards.firstMatch.exists ? min(composer.frame.minY, app.keyboards.firstMatch.frame.minY) : composer.frame.minY
            let shown = visibleTexts(timeline, above: bottom)
            XCTAssertFalse(shown.isEmpty, "round \(round), \(second) s after sending: the history is blank")
            if second % 15 == 0 {
                // A drag down moves the text with it, then the reader goes back to the end.
                // Followed by its label, so only a line shown once (replies can repeat text).
                let once = shown.filter { t in shown.filter { $0.label == t.label }.count == 1 }
                let line = once.isEmpty ? nil : once[once.count / 2]
                timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                    .press(forDuration: 0.05, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
                sleep(1)
                let after = visibleTexts(timeline, above: bottom).filter { $0.label == line?.label }
                if let line, after.count == 1 {
                    XCTAssertGreaterThan(after[0].frame.minY - line.frame.minY, 20, "round \(round): the drag did not move the history")
                }
                timeline.swipeUp(velocity: .fast)
            }
        }
    }

    /// Texts on screen in the timeline, read from one snapshot: rows come and go every second.
    private func visibleTexts(_ timeline: XCUIElement, above bottom: CGFloat) -> [XCUIElementSnapshot] {
        guard let root = try? timeline.snapshot() else { return [] }
        var found: [XCUIElementSnapshot] = [], queue = [root]
        while let s = queue.popLast() {
            queue += s.children
            let f = s.frame
            if s.elementType == .staticText, !s.label.isEmpty, f.height > 0, f.maxY > root.frame.minY, f.minY < bottom { found.append(s) }
        }
        return found.sorted { $0.frame.minY < $1.frame.minY }
    }
}
