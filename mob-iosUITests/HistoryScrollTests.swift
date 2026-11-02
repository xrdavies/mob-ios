import XCTest

/// Scrolling up through a long conversation on a real mobd (mob-ios#6). Opt in with MOBD_LONG_CHAT
/// set to the title of a conversation with more than two pages of turns whose prompts are "Turn 2",
/// "Turn 3", … and whose replies are "Reply <id>." then paragraphs starting "P<id>-<n>", on the
/// machine paired in the simulator (LayoutTests.testPairMachineFromLink).
final class HistoryScrollTests: XCTestCase {
    func testOpensAtTheNewestTurnAndOlderTurnsKeepTheReadingPosition() throws {
        guard let title = ProcessInfo.processInfo.environment["MOBD_LONG_CHAT"], !title.isEmpty else {
            throw XCTSkip("Set MOBD_LONG_CHAT to the title of a long conversation")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let chats = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Chats'")).firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 15))
        chats.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let timeline = app.scrollViews["chatTimeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        sleep(3)

        // Opening shows the end of the conversation, not the top of its newest page.
        let opened = anchors(app).compactMap { turn($0.0) }
        print("SCROLL opened showing turns \(opened)")
        XCTAssertTrue(opened.allSatisfy { $0 >= 40 }, "opened away from the newest turn: \(opened)")

        // MOBD_SETTLE (seconds): wait after each drag, for a mobd behind a proxy that delays older pages.
        let settle = ProcessInfo.processInfo.environment["MOBD_SETTLE"].flatMap(UInt32.init)
        // Small, slow drags without momentum: text on screen must move by the drag, also during
        // the drag in which older turns are added above it.
        var pages = 0
        for _ in 0..<400 where pages < 2 {
            guard let (label, before) = anchors(app).first(where: { $0.1.minY > 150 }) ?? anchors(app).first else {
                XCTFail("nothing to follow on screen"); return
            }
            let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 300)), withVelocity: .slow, thenHoldForDuration: 0.3)
            usleep(500_000)
            let element = app.staticTexts[label]
            // The position is restored in the layout after older turns were added.
            XCTAssertTrue(element.waitForExistence(timeout: 2), "\(label) left the timeline")
            let moved = element.frame.minY - before.minY
            if abs(moved - 300) >= 20 { print("SCROLL \(label) moved \(Int(moved))pt") }
            // A page that lands while the finger is down can be off by about one drag step
            // (docs/conversation-history.md); the old timeline was off by whole pages.
            XCTAssertLessThan(abs(moved - 300), 120, "\(label) jumped by \(Int(moved))pt instead of following the 300pt drag")
            // A page that arrives after the drag (a slow network) must not move what is on screen.
            if let still = settle {
                sleep(still)
                let drift = element.frame.minY - before.minY - moved
                if abs(drift) >= 20 { print("SCROLL \(label) drifted \(Int(drift))pt at rest") }
                XCTAssertLessThan(abs(drift), 20, "\(label) moved \(Int(drift))pt while the timeline was at rest")
            }
            if pages == 0, app.staticTexts["Turn 25"].exists { pages = 1; print("SCROLL second page, \(label) moved \(Int(moved))pt") }
            if pages == 1, app.staticTexts["Turn 5"].exists { pages = 2; print("SCROLL third page, \(label) moved \(Int(moved))pt") }
        }
        XCTAssertEqual(pages, 2, "two older pages were loaded while scrolling up")
    }

    private func turn(_ label: String) -> Int? { label.hasPrefix("Turn ") ? Int(label.dropFirst(5)) : nil }

    /// Texts with unique labels (prompts, replies and their paragraphs) showing between the bars, top
    /// to bottom.
    private func anchors(_ app: XCUIApplication) -> [(String, CGRect)] {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Turn ' OR label BEGINSWITH 'Reply ' OR label BEGINSWITH 'P17'")).allElementsBoundByIndex
            .compactMap { e -> (String, CGRect)? in
                let f = e.frame
                guard f.height > 0, f.maxY > 110, f.minY < 700 else { return nil }
                return (e.label, f)
            }
            .sorted { $0.1.minY < $1.1.minY }
    }
}
