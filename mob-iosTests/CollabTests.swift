import XCTest
@testable import mob_ios

/// Agent collaboration (mobd docs/agent-collaboration-design.md): handle rules, the "@" picker,
/// mention resolution and decoding of mobd's JSON.
final class CollabTests: XCTestCase {
    private func session(_ id: String, _ title: String, handle: String? = nil, archived: Bool? = nil) -> Session {
        Session(id: id, title: title, runner: "codex", archived: archived, handle: handle)
    }

    /// A collaboration turn is listed by what was delivered, not by mobd's instructions to the agent.
    func testTaskTitles() throws {
        var task = AgentTask(id: "t", sessionId: "s", runner: "codex", status: "succeeded")
        task.prompt = "Fix the tests"
        XCTAssertEqual(Collab.taskTitle(task), "Fix the tests")
        task.prompt = "These messages come from other agents…"
        task.origin = TurnOrigin(kind: "collab", deliveries: [Delivery(id: "d", to: "s", requestId: "r", kind: "result", text: " BLUE ")])
        XCTAssertEqual(Collab.taskTitle(task), "Reply: BLUE")
        task.prompt = "Preamble\n\n[Mob collaboration · from @heron · request r-1 · exchange x-1]\nRequest: What colour?"
        task.origin = TurnOrigin(kind: "collab")
        XCTAssertEqual(Collab.taskTitle(task), "@heron: What colour?")
    }

    func testHandleRulesMatchMobd() {
        for ok in ["api", "order-service", "ui2", "x1", "x234567890123456789012345678901"] {
            XCTAssertTrue(Handle.isValid(ok), ok)
        }
        for bad in ["", "a", "Api", "2api", "my api", "api@m4002", "abc123", "deadbeef", "all", "mobd", "here"] {
            XCTAssertFalse(Handle.isValid(bad), bad)
        }
        XCTAssertFalse(Handle.isValid(String(repeating: "a", count: 33)))
    }

    func testSuggestedHandle() {
        XCTAssertEqual(Handle.suggest(from: "Order service refactor"), "order-service")
        XCTAssertEqual(Handle.suggest(from: "API: fix the login bug!"), "api-fix")
        XCTAssertEqual(Handle.suggest(from: "order service", taken: ["order-service"]), "order-service-2")
        XCTAssertEqual(Handle.suggest(from: "deadbeef"), "agent-deadbeef")
        XCTAssertNil(Handle.suggest(from: "🙂"))
        for title in ["Order service refactor", "Fix the login bug on the checkout page when it fails", "12345 backend"] {
            if let h = Handle.suggest(from: title) { XCTAssertTrue(Handle.isValid(h), h) }
        }
    }

    func testPickerListsHandlesFirstAndExcludesCurrent() {
        let sessions = [
            session("a1111111", "Checkout UI"),
            session("b2222222", "Order service", handle: "api"),
            session("c3333333", "API docs", handle: "apidocs", archived: true),
            session("d4444444", "Billing"),
        ]
        let all = Mentions.candidates(sessions, query: "", excluding: "a1111111").map(\.id)
        XCTAssertEqual(all, ["b2222222", "c3333333", "d4444444"], "handles first, sorted; current excluded")
        XCTAssertEqual(Mentions.candidates(sessions, query: "ap", excluding: nil).map(\.id), ["b2222222", "c3333333"])
        XCTAssertEqual(Mentions.candidates(sessions, query: "bill", excluding: nil).map(\.id), ["d4444444"])
        XCTAssertEqual(MentionCandidate(session: sessions[1]).label, "@api · Order service")
        XCTAssertEqual(MentionCandidate(session: sessions[3]).label, "Billing · d44444")
        XCTAssertTrue(MentionCandidate(session: sessions[2]).archived)
    }

    func testTypedMentionsAreResolved() {
        let sessions = [session("b2222222", "Order service", handle: "api"), session("c3333333", "Old", handle: "old", archived: true)]
        XCTAssertEqual(Mentions.typed("ask @api and @API, email me@example.com, @old"), ["api", "api", "old"])
        XCTAssertEqual(Mentions.resolve(text: "ask @api", picked: [:], sessions: sessions, current: nil), .ok(["b2222222"]))
        XCTAssertEqual(Mentions.resolve(text: "ask @api", picked: [:], sessions: sessions, current: "b2222222"), .ok([]))
        XCTAssertEqual(Mentions.resolve(text: "ask @api", picked: ["api": "b2222222"], sessions: sessions, current: nil), .ok(["b2222222"]))
        if case .blocked(let why) = Mentions.resolve(text: "ask @old", picked: [:], sessions: sessions, current: nil) {
            XCTAssertTrue(why.contains("archived"))
        } else {
            XCTFail("archived mention was not blocked")
        }
        if case .blocked = Mentions.resolve(text: "hi @old", picked: ["old": "c3333333"], sessions: sessions, current: nil) {} else {
            XCTFail("picked archived agent was not blocked")
        }
        XCTAssertEqual(Mentions.resolve(text: "mail me@example.com", picked: [:], sessions: sessions, current: nil), .ok([]))
    }

    func testDecodesCollabJSON() throws {
        let json = #"""
        {"requests":[{"id":"r-1","exchangeId":"x-1","from":"a","to":"b","fromName":"@ui","toName":"@api",
          "text":"Which fields?","status":"needs_clarification","result":null,
          "thread":[{"from":"b","kind":"clarification","text":"US or EU?","at":"2026-11-05T00:00:00Z"}],
          "createdAt":"2026-11-05T00:00:00Z","updatedAt":"2026-11-05T00:01:00Z","expiresAt":"2026-11-06T00:00:00Z"}],
          "waiting":1}
        """#
        let list = try APIClient.decoder.decode(CollabList.self, from: Data(json.utf8))
        let r = try XCTUnwrap(list.requests?.first)
        XCTAssertEqual(r.statusLabel, "needs clarification")
        XCTAssertTrue(r.isOpen)
        XCTAssertFalse(r.needsUser)
        XCTAssertEqual(r.peerName(from: "a"), "@api")
        XCTAssertEqual(r.peerName(from: "b"), "@ui")
        XCTAssertEqual(r.thread?.first?.kind, "clarification")
        XCTAssertEqual(list.waiting, 1)
    }

    func testTurnOriginAndHandleDecode() throws {
        let turn = try APIClient.decoder.decode(AgentTask.self, from: Data(#"""
        {"id":"t1","sessionId":"s","status":"queued","eventId":1,"origin":{"kind":"collab","exchangeId":"x-1","requests":["r-1"]}}
        """#.utf8))
        XCTAssertTrue(turn.origin?.isCollab == true)
        XCTAssertEqual(turn.origin?.requests, ["r-1"])
        let plain = try APIClient.decoder.decode(AgentTask.self, from: Data(#"{"id":"t2","sessionId":"s","status":"succeeded","eventId":1}"#.utf8))
        XCTAssertNil(plain.origin)
        let s = try APIClient.decoder.decode(Session.self, from: Data(#"{"id":"s","title":"x","handle":"api"}"#.utf8))
        XCTAssertEqual(s.handle, "api")
    }

    func testRequestStatesThatNeedTheUser() {
        func r(_ status: String) -> CollabRequest {
            CollabRequest(id: "r", exchangeId: nil, from: "a", to: "b", fromName: nil, toName: nil, text: "q",
                          status: status, result: nil, thread: nil, createdAt: nil, updatedAt: nil, expiresAt: nil)
        }
        for s in ["interrupted", "over_budget", "expired"] { XCTAssertTrue(r(s).needsUser, s) }
        for s in ["open", "in_progress", "needs_clarification"] { XCTAssertTrue(r(s).isOpen, s) }
        for s in ["answered", "failed", "cancelled"] { XCTAssertFalse(r(s).needsUser || r(s).isOpen, s) }
    }

    func testHandleProblemMatchesDesktopAndValidity() {
        XCTAssertEqual(Collab.handleProblem("order-api"), "")
        XCTAssertEqual(Collab.handleProblem("a"), "At least 2 characters.")
        XCTAssertEqual(Collab.handleProblem("1api"), "Start with a letter.")
        XCTAssertEqual(Collab.handleProblem("cafe"), "Only 0–9 and a–f reads as a conversation ID; add another letter.")
        XCTAssertEqual(Collab.handleProblem("here"), "@here is reserved.")
        for h in ["api", "a", "1api", "cafe", "here", String(repeating: "x", count: 33)] {
            XCTAssertEqual(Collab.handleProblem(h).isEmpty, Handle.isValid(h), h)
        }
        XCTAssertEqual(Collab.normalizeHandleInput("@Order Service_v2!"), "order-service-v2")
    }

    func testMentionSegmentsMarkKnownAgentsOnly() {
        let sessions = [session("2ead98c31b", "B", handle: "heron"), session("b9b040ee85", "off road"), session("ea7b1322", "A", handle: "asker")]
        let segs = Collab.mentionSegments("ask @heron and @b9b040, not @nobody or @asker.", sessions: sessions, current: "ea7b1322")
        XCTAssertEqual(segs, [
            .init(text: "ask ", session: nil), .init(text: "@heron", session: "2ead98c31b"), .init(text: " and ", session: nil),
            .init(text: "@b9b040", session: "b9b040ee85"), .init(text: ", not @nobody or @asker.", session: nil),
        ])
        XCTAssertEqual(segs.map(\.text).joined(), "ask @heron and @b9b040, not @nobody or @asker.")
    }

    func testMentionQueryIsTheWordBeingTyped() {
        XCTAssertEqual(Collab.mentionQuery("ask @her"), "her")
        XCTAssertEqual(Collab.mentionQuery("@"), "")
        XCTAssertNil(Collab.mentionQuery("mail me@example"))
        XCTAssertNil(Collab.mentionQuery("ask @heron now"))
    }

    func testDeliveriesReadWithoutMobdsInstructions() throws {
        let r = try JSONDecoder().decode(CollabRequest.self, from: Data(#"{"id":"r-1","from":"A","to":"B","text":"q","status":"failed"}"#.utf8))
        let result = Delivery(id: "d", to: "A", requestId: "r-1", kind: "result", text: "no")
        XCTAssertEqual(Collab.sender(result, r), "B")
        XCTAssertEqual(Collab.sender(Delivery(id: "d", to: "B", requestId: "r-1", kind: "request", text: "q"), r), "A")
        XCTAssertNil(Collab.sender(Delivery(id: "d", to: "A", requestId: "r-1", kind: "notice", text: "x"), r))
        XCTAssertEqual(Collab.label(result, r), "couldn't complete your request")
        XCTAssertEqual(Collab.deliveryBody("Request: Reply okay.\n\nWhen done, call complete_request(\"r-1\", \"answered\" | \"failed\", <result>)."), "Reply okay.")
        XCTAssertEqual(Collab.deliveryBody("Result of your request \"Reply\" to @heron (answered):\nokay"), "okay")
        let parts = Collab.parseDelivery("Preamble.\n\n[Mob collaboration · from @heron · request r-1 · exchange x-1]\nResult of your request \"q\" to @heron (answered):\nokay")
        XCTAssertEqual(parts.first?.from, "@heron")
        XCTAssertEqual(parts.first?.body, "okay")
    }

    func testStepTitlesAndShortLabels() {
        let sessions = [session("2ead98c31b", "B", handle: "heron")]
        XCTAssertEqual(Collab.stepTitle(server: "mob-mcp", tool: "send_request", arguments: ["to": .string("2ead98"), "request": .string("x")], sessions: sessions), "Asked @heron: x")
        XCTAssertEqual(Collab.stepTitle(server: "mob-mcp", tool: "complete_request", arguments: ["outcome": .string("answered"), "result": .string("BLUE")], sessions: []), "Replied: BLUE")
        XCTAssertNil(Collab.stepTitle(server: "mob-mcp", tool: "screenshot", arguments: nil, sessions: []))
        XCTAssertEqual(Collab.shortLabel(session("962ae4ff", String(repeating: "x", count: 40))), String(repeating: "x", count: 31) + "… (962ae4)")
    }
}
