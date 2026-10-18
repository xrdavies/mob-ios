import XCTest
@testable import mob_ios

final class DataTests: XCTestCase {
    private func task(_ id: String, _ status: String) -> AgentTask {
        AgentTask(id: id, sessionId: "s", runner: "codex", prompt: "prompt \(id)", status: status, createdAt: "2026-10-14T00:00:00Z")
    }

    private func msg(_ id: String, _ role: String, _ at: String) -> Message {
        Message(id: id, taskId: "t1", role: role, content: "text \(id)", createdAt: at)
    }

    private func step(_ id: String, _ at: String, tool: String? = nil) -> Activity {
        Activity(id: id, taskId: "t1", kind: "tool", status: "completed", title: "Step \(id)", server: nil, tool: tool, arguments: nil,
                 command: nil, exitCode: nil, text: nil, truncated: nil, error: nil, images: nil, items: nil, changes: nil,
                 startedAt: at, updatedAt: at)
    }

    private func kind(_ i: TimelineItem) -> String {
        switch i {
        case .user: "user"
        case .assistant: "assistant"
        case .steps: "steps"
        case .group: "group"
        case .ask: "ask"
        case .queued: "queued"
        case .working: "working"
        case .footer: "footer"
        }
    }

    func testTimelineOrdersAndGroups() {
        let items = buildTimeline(
            tasks: [task("t1", Status.succeeded)],
            messages: [msg("t1:user", "user", "2026-10-14T00:00:00Z"), msg("t1:a", "assistant", "2026-10-14T00:00:05Z")],
            activities: [step("1", "2026-10-14T00:00:01Z"), step("2", "2026-10-14T00:00:02Z"), step("3", "2026-10-14T00:00:03Z"),
                         step("ask", "2026-10-14T00:00:04Z", tool: "ask_user"), step("4", "2026-10-14T00:00:06Z")],
            questions: []
        )
        XCTAssertEqual(items.map(kind), ["user", "group", "assistant", "steps", "footer"])
    }

    func testRunningTurnUsesPromptAndWaits() {
        let q = Question(id: "q", taskId: "t1", kind: "approval", text: "Allow?", details: nil, options: nil, allowText: false,
                         status: "pending", answer: nil, approved: nil, createdAt: "2026-10-14T00:00:01Z")
        let items = buildTimeline(tasks: [task("t1", Status.running)], messages: [], activities: [], questions: [q])
        guard case .user(_, let m, _) = items[0], case .ask = items[1], case .working(_, _, _, let waiting) = items[2] else {
            return XCTFail("unexpected \(items.map(kind))")
        }
        XCTAssertEqual(m.content, "prompt t1")
        XCTAssertTrue(waiting)
    }

    func testClickMarker() {
        func act(_ id: String, _ tool: String, status: String = "completed", args: [String: JSONValue]? = nil, text: String? = nil) -> Activity {
            Activity(id: id, taskId: "t", kind: "tool", status: status, title: id, server: nil, tool: tool, arguments: args, command: nil,
                     exitCode: nil, text: text, truncated: nil, error: nil, images: nil, items: nil, changes: nil, startedAt: nil, updatedAt: nil)
        }
        let acts = [
            act("s1", "screenshot", text: #"{"point_width":1512,"point_height":982}"#),
            act("c1", "click", args: ["x": .number(10), "y": .number(20)]),
            act("c2", "click", args: ["x": .number(400), "y": .string("300")]),
            act("c3", "click", status: "failed", args: ["x": .number(1), "y": .number(1)]),
        ]
        XCTAssertEqual(latestClick(acts), AgentClick(id: "c2", x: 400, y: 300))
        XCTAssertEqual(screenGeometry(acts), ScreenGeometry(pointWidth: 1512, pointHeight: 982))
        XCTAssertNil(screenGeometry([act("s", "screenshot", text: "not json")]))
    }

    func testMarkdownBlocks() {
        XCTAssertEqual(parseMarkdown("# Title\n\nSome **bold**\ntext.\n\n- one\n  wrapped\n2. two\n\n```swift\nlet x = 1\n```\n> quoted\n---"), [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold**\ntext."),
            .listItem(ordered: false, marker: "•", depth: 0, text: "one wrapped"),
            .listItem(ordered: true, marker: "2.", depth: 0, text: "two"),
            .code(lang: "swift", text: "let x = 1"),
            .quote("quoted"),
            .rule,
        ])
    }

    func testSSEParser() {
        var p = SSEParser()
        var events: [SSEEvent] = []
        for line in ["id: 7", "event: session", "data: {\"a\":1}", "", ": comment", "data: x", "data: y", ""] {
            if let e = p.line(line) { events.append(e) }
        }
        XCTAssertEqual(events, [SSEEvent(id: "7", type: "session", data: "{\"a\":1}"), SSEEvent(id: "7", type: "message", data: "x\ny")])
    }

    func testNormalizeURL() {
        XCTAssertEqual(APIClient.normalize("192.168.1.5:8080").absoluteString, "http://192.168.1.5:8080/")
        XCTAssertEqual(APIClient.normalize("https://mac.local/ ").absoluteString, "https://mac.local/")
    }
}
