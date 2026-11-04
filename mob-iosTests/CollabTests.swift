import XCTest
@testable import mob_ios

/// Agent collaboration (mobd docs/agent-collaboration-design.md): handle rules, the "@" picker,
/// mention resolution and decoding of mobd's JSON.
final class CollabTests: XCTestCase {
    private func session(_ id: String, _ title: String, handle: String? = nil, archived: Bool? = nil) -> Session {
        Session(id: id, title: title, runner: "codex", archived: archived, handle: handle)
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
}
