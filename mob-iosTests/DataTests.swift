import XCTest
@testable import mob_ios

final class DataTests: XCTestCase {
    func testReportedModelEventDecodesWithOldServerCompatibility() throws {
        let reported = try APIClient.decoder.decode(TaskEvent.self, from: Data(#"{"id":2,"type":"resume","model":"actual-model"}"#.utf8))
        XCTAssertEqual(reported.model, "actual-model")
        let old = try APIClient.decoder.decode(TaskEvent.self, from: Data(#"{"id":2,"type":"resume"}"#.utf8))
        XCTAssertNil(old.model)
    }
    func testModelLabelNeverMistakesTheRunnerForTheModel() {
        var task = AgentTask(id: "t", sessionId: "s", runner: "codex", status: "running")
        XCTAssertEqual(task.modelLabel, "Default model (not reported)")
        task.model = "selected-model"
        XCTAssertEqual(task.modelLabel, "selected-model")
        task.model = "  "
        XCTAssertEqual(task.modelLabel, "Default model (not reported)")
    }

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

    func testOnlyReadsAreRetriedAfterATimeoutOrDroppedConnection() {
        XCTAssertTrue(APIClient.shouldRetry(URLError(.timedOut), method: "GET"))
        XCTAssertTrue(APIClient.shouldRetry(URLError(.networkConnectionLost), method: "GET"))
        XCTAssertFalse(APIClient.shouldRetry(URLError(.timedOut), method: "POST"), "a task or answer must not be sent twice")
        XCTAssertFalse(APIClient.shouldRetry(URLError(.cannotFindHost), method: "GET"))
        XCTAssertFalse(APIClient.shouldRetry(APIError(message: "x", status: 500), method: "GET"))
    }

    func testDefaultChoiceNamesTheAgentsDefault() throws {
        let r = try APIClient.decoder.decode(Runner.self, from: Data(#"{"name":"codex","defaultModel":"gpt-6-astra","defaultEffort":"xhigh"}"#.utf8))
        XCTAssertEqual(defaultLabel("effort", r.defaultEffort), "Default (xhigh)")
        XCTAssertEqual(defaultLabel("model", r.defaultModel), "Default (gpt-6-astra)")
        let old = try APIClient.decoder.decode(Runner.self, from: Data(#"{"name":"claude"}"#.utf8))
        XCTAssertEqual(defaultLabel("effort", old.defaultEffort), "Default effort")
    }

    func testOpenChatShowsItsConversationSettingsAndNewChatItsDraft() throws {
        let session = try APIClient.decoder.decode(Session.self, from: Data(#"{"id":"s","model":"gpt-5.4","effort":"high"}"#.utf8))
        XCTAssertEqual(TurnSettings.shown(session: session, draftModel: "x", draftEffort: nil), TurnChoice(model: "gpt-5.4", effort: "high"))
        XCTAssertEqual(TurnSettings.shown(session: Session(id: "s"), draftModel: "x", draftEffort: nil), TurnChoice(),
                       "a conversation without settings follows the defaults")
        XCTAssertEqual(TurnSettings.shown(session: nil, draftModel: nil, draftEffort: "low"), TurnChoice(effort: "low"))
        XCTAssertEqual(TurnSettings.menuModels(["a"], current: "b"), ["a", "b"])
    }

    func testSettingsFileEditsAndTurningApprovalOffNeedsConfirmation() throws {
        let json = #"""
        {"settings":{"rev":2,"defaultAgent":"codex","agents":{
           "codex":{"models":[],"defaultModel":"","defaultEffort":"","permissions":"approve"},
           "claude":{"models":["opus"],"defaultModel":"","defaultEffort":"","permissions":"bypass"}}},
         "agents":{"codex":{"label":"Codex","efforts":["low","high"],"agentDefaultEffort":"xhigh"},
                   "claude":{"label":"Claude Code","efforts":["low","max"]}}}
        """#
        let info = try APIClient.decoder.decode(MachineSettingsInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.agents["codex"]?.agentDefaultEffort, "xhigh")
        XCTAssertNil(info.installed, "an mobd answer without the list still decodes")
        let withList = try APIClient.decoder.decode(MachineSettingsInfo.self, from: Data(json.replacingOccurrences(of: #""agents":{"codex":{"label""#, with: #""installed":[{"name":"pi","label":"Pi","state":"missing","enabled":false,"install":"npm i -g pi"}],"agents":{"codex":{"label""#).utf8))
        XCTAssertEqual(withList.installed?.first?.stateLabel, "Not installed")
        XCTAssertEqual(withList.installed?.first?.install, "npm i -g pi")
        let next = TurnSettings.with(info.settings, agent: "codex") { $0.models = ["gpt-6-astra"]; $0.defaultEffort = "high" }
        XCTAssertEqual(next.agents["codex"], AgentSettings(models: ["gpt-6-astra"], defaultEffort: "high", permissions: "approve"))
        XCTAssertEqual(try TurnSettings.add(model: " b ", to: ["a"]).get(), ["a", "b"])
        XCTAssertThrowsError(try TurnSettings.add(model: "has space", to: []).get())
        XCTAssertEqual(TurnSettings.newlyUnguarded(info.settings, TurnSettings.with(info.settings, agent: "codex") { $0.permissions = "bypass" }), ["codex"])
        XCTAssertEqual(TurnSettings.newlyUnguarded(info.settings, next), [])
    }

    func testGatewayErrorsFromTheProxyAreExplained() {
        XCTAssertEqual(APIClient.proxyMessage(502), "The office Mac answered, but mobd is not running there. Start it with mobd start.")
        XCTAssertEqual(APIClient.proxyMessage(504), "mobd did not answer in time")
        XCTAssertNil(APIClient.proxyMessage(500))
    }

    /// GET /sessions/{id} as mobd answers it: one message and one step per turn.
    private func detail(_ turns: [(id: String, status: String, text: String)], rev: Int64?, full: Bool?) throws -> SessionDetail {
        let tasks = turns.map { #"{"id":"\#($0.id)","sessionId":"s","status":"\#($0.status)"}"# }
        let messages = turns.map { #"{"id":"\#($0.id):a","taskId":"\#($0.id)","role":"assistant","content":"\#($0.text)"}"# }
        let steps = turns.map { #"{"id":"\#($0.id):1","taskId":"\#($0.id)","kind":"tool","status":"completed","title":"\#($0.text)"}"# }
        var json = #"{"session":{"id":"s","messages":[\#(messages.joined(separator: ","))]},"tasks":[\#(tasks.joined(separator: ","))],"#
            + #""activities":[\#(steps.joined(separator: ","))],"questions":[]"#
        if let rev { json += #","rev":\#(rev)"# }
        if let full { json += #","full":\#(full)"# }
        return try APIClient.decoder.decode(SessionDetail.self, from: Data((json + "}").utf8))
    }

    func testAPartialAnswerReplacesOnlyTheTurnsItCarries() throws {
        let base = ChatDetail.merged(try detail([("t1", "succeeded", "one"), ("t2", "running", "two…")], rev: 5, full: true), onto: nil)
        XCTAssertEqual(base.rev, 5)
        let delta = try detail([("t2", "succeeded", "two"), ("t3", "running", "three")], rev: 9, full: false)
        let d = ChatDetail.merged(delta, onto: base)
        XCTAssertEqual(d.rev, 9)
        XCTAssertEqual(d.tasks.map(\.id), ["t1", "t2", "t3"])
        XCTAssertEqual(d.tasks.map(\.status), ["succeeded", "succeeded", "running"])
        XCTAssertEqual(d.session.messages?.map(\.content), ["one", "two", "three"])
        XCTAssertEqual(d.activities.map(\.title), ["one", "two", "three"])

        // An older turn that changed keeps its place.
        let old = ChatDetail.merged(try detail([("t1", "succeeded", "one, edited")], rev: 10, full: false), onto: d)
        XCTAssertEqual(old.session.messages?.map(\.content), ["one, edited", "two", "three"])
    }

    func testAFullAnswerOrAnOlderMobdReplacesEverything() throws {
        let base = ChatDetail.merged(try detail([("t1", "succeeded", "one"), ("t2", "succeeded", "two")], rev: 5, full: true), onto: nil)
        let full = ChatDetail.merged(try detail([("t2", "succeeded", "two")], rev: 3, full: true), onto: base)
        XCTAssertEqual(full.tasks.map(\.id), ["t2"])
        let legacy = ChatDetail.merged(try detail([("t1", "succeeded", "one")], rev: nil, full: nil), onto: base)
        XCTAssertEqual(legacy.tasks.map(\.id), ["t1"])
        XCTAssertNil(legacy.rev)
    }
}
