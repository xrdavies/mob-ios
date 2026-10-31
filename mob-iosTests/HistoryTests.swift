import XCTest
@testable import mob_ios

@MainActor
final class HistoryTests: XCTestCase {
    private func task(_ seq: Int64, _ rev: Int64, _ status: String = Status.succeeded) -> AgentTask {
        AgentTask(id: "t\(seq)", sessionId: "s", prompt: "p\(seq)", status: status, eventId: 1, rev: rev, seq: seq)
    }

    private func turn(_ seq: Int64, _ rev: Int64, size: Int = 10) -> StoredTurn {
        StoredTurn(task: task(seq, rev), messages: [Message(id: "t\(seq):a", taskId: "t\(seq)", role: "assistant",
                                                            content: String(repeating: "x", count: size), createdAt: nil)],
                   activities: [], questions: [])
    }

    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)").appendingPathComponent("history.sqlite")
    }

    private let session = Session(id: "s", title: "s")

    func testMergeKeepsHigherRevAndNeverAppendsAnOlderTurn() {
        let detail = { (tasks: [AgentTask], rev: Int64) in
            ChatDetail(session: Session(id: "s", messages: tasks.map { Message(id: "\($0.id):a", taskId: $0.id, role: "assistant", content: "\($0.id) r\($0.rev ?? 0)", createdAt: nil) }),
                       tasks: tasks, activities: [], questions: [], rev: rev)
        }
        let base = detail([task(3, 3), task(4, 4)], 4)
        let d = ChatDetail.mergedTurns(detail([task(4, 9), task(2, 8), task(5, 9, Status.running)], 9), onto: base, from: 3)
        XCTAssertEqual(d.tasks.map(\.id), ["t3", "t4", "t5"])
        XCTAssertEqual(d.current?.id, "t5")
        XCTAssertEqual(d.session.messages?.map(\.content), ["t3 r3", "t4 r9", "t5 r9"])
        XCTAssertEqual(d.rev, 4)
        let stale = ChatDetail.mergedTurns(detail([task(4, 6)], 6), onto: d, from: 3)
        XCTAssertEqual(stale.session.messages?[1].content, "t4 r9")
        let older = ChatDetail.mergedTurns(detail([task(1, 1), task(2, 8)], 9), onto: d, from: 1)
        XCTAssertEqual(older.tasks.map(\.id), ["t1", "t2", "t3", "t4", "t5"])
    }

    func testStorePagesTurnsAndKeepsNewerTurnsAndCursors() async {
        let store = HistoryStore(url: temp())
        await store.save(machine: "m", session: session, syncRev: 9, turns: (2...5).map { turn($0, $0) }, cursors: ["t2": "c2"], replace: true, keep: [])
        await store.save(machine: "m", session: session, syncRev: 10, turns: [turn(3, 1, size: 99)], replace: false, keep: [])
        let saved = await store.load(machine: "m", id: "s", limit: 2)
        XCTAssertEqual(saved?.syncRev, 10)
        XCTAssertEqual(saved?.oldest, 2)
        XCTAssertEqual(saved?.cursor, "c2")
        XCTAssertEqual(saved?.turns.map(\.task.seq), [4, 5])
        let older = await store.load(machine: "m", id: "s", before: 4, limit: 9)
        XCTAssertEqual(older?.turns.map(\.task.seq), [2, 3])
        XCTAssertEqual(older?.turns[1].messages.first?.content.count, 10, "a lower rev does not replace a turn")
        let missing = await store.load(machine: "m", id: "other", limit: 1)
        XCTAssertNil(missing)
        await store.prune(machine: "m", keeping: [])
        let listed = await store.list(machine: "m")
        XCTAssertTrue(listed.isEmpty)
    }

    func testEvictsLeastRecentlyOpenedAndTrimsTheLast() async {
        // u: the stored size of one turn (its JSON).
        let probe = HistoryStore(url: temp())
        await probe.save(machine: "m", session: session, syncRev: 1, turns: [turn(1, 1, size: 400)], replace: false, keep: [])
        let u = await probe.size()
        let store = HistoryStore(url: temp(), limit: u * 7 / 2, target: u * 32 / 10)
        for id in ["a", "b", "c"] {
            await store.save(machine: "m", session: Session(id: id), syncRev: 1, turns: [turn(1, 1, size: 400)], replace: false, keep: [])
        }
        _ = await store.load(machine: "m", id: "a", limit: 1)
        await store.save(machine: "m", session: Session(id: "c"), syncRev: 2, turns: [turn(2, 2, size: 400)], replace: false, keep: ["c"])
        let a = await store.load(machine: "m", id: "a", before: .max, limit: 9)
        let b = await store.load(machine: "m", id: "b", before: .max, limit: 9)
        let c = await store.load(machine: "m", id: "c", before: .max, limit: 9)
        XCTAssertEqual(a?.turns.count, 1)
        XCTAssertEqual(b?.turns.count, 0, "b was opened least recently")
        XCTAssertEqual(b?.syncRev, 0)
        XCTAssertEqual(c?.turns.count, 2, "the open conversation is kept")

        let one = HistoryStore(url: temp(), limit: u * 5, target: u * 5 / 2)
        await one.save(machine: "m", session: session, syncRev: 7, turns: (1...6).map { turn($0, 1, size: 400) },
                       cursors: ["t1": "c1", "t3": "c3", "t5": "c5"], replace: false, keep: [])
        let trimmed = await one.load(machine: "m", id: "s", limit: 9)
        XCTAssertEqual(trimmed?.turns.map(\.task.seq), [5, 6], "keeps its newest turns, from one with a cursor")
        XCTAssertEqual(trimmed?.cursor, "c5")
    }

    func testRebuildsACorruptFile() async throws {
        let url = temp()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a database, just text long enough to fail".utf8).write(to: url)
        let store = HistoryStore(url: url)
        await store.save(machine: "m", session: session, syncRev: 1, turns: [turn(1, 1)], replace: false, keep: [])
        let saved = await store.load(machine: "m", id: "s", limit: 1)
        XCTAssertEqual(saved?.turns.count, 1)
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    // MARK: - ChatStore against a mobd with sessionHistory

    private func makeChat(_ store: HistoryStore) -> (ChatStore, String) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeOffice.self]
        let client = APIClient(baseURL: "https://history-tests.invalid", token: nil, configuration: config)
        let chat = ChatStore(history: store)
        let machine = "history-\(UUID())"
        UserDefaults.standard.set("s", forKey: "session.\(machine)")
        chat.attach(client, machine: machine, historyKey: "server")
        addTeardownBlock { @MainActor in
            chat.attach(nil, machine: "")
            UserDefaults.standard.removeObject(forKey: "session.\(machine)")
        }
        return (chat, machine)
    }

    private func until(_ what: String, _ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), what)
    }

    func testPagesSavesAndSyncsOnlyChangesAfterRelaunch() async {
        FakeOffice.reset(count: 45)
        let store = HistoryStore(url: temp())
        var (chat, _) = makeChat(store)
        await until("newest page") { chat.detail?.tasks.count == 20 }
        XCTAssertEqual(chat.detail?.tasks.first?.seq, 26)
        XCTAssertTrue(chat.hasOlder)
        XCTAssertEqual(FakeOffice.requests.last, "/sessions/s/history?limit=20")
        chat.loadOlder()
        await until("second page") { chat.detail?.tasks.count == 40 }
        XCTAssertEqual(chat.detail?.current?.seq, 45)
        XCTAssertTrue(FakeOffice.requests.last?.contains("before=c26") == true)
        try? await Task.sleep(for: .milliseconds(200))

        // Relaunch: the saved copy, then only what changed; an old changed turn is not appended.
        FakeOffice.change(2)
        FakeOffice.add()
        (chat, _) = makeChat(store)
        await until("changes merged") { chat.detail?.current?.seq == 46 }
        XCTAssertTrue(FakeOffice.requests.contains("/sessions/s/history?limit=50&since=45") ||
                      FakeOffice.requests.contains("/sessions/s/history?since=45&limit=50"))
        XCTAssertEqual(chat.detail?.tasks.first?.seq, 26, "the newest 20 saved turns, then the new one")
        XCTAssertFalse(chat.detail?.tasks.contains { $0.seq == 2 } ?? true)
        let before = FakeOffice.requests.count
        chat.loadOlder()
        await until("older turns from the local copy") { chat.detail?.tasks.first?.seq == 6 }
        XCTAssertEqual(FakeOffice.requests.filter { $0.contains("before=") }.count,
                       FakeOffice.requests.prefix(before).filter { $0.contains("before=") }.count, "no request for saved turns")
    }

    func testResetLoadsTheNewestPageAndA404RemovesTheCopy() async {
        FakeOffice.reset(count: 25)
        let store = HistoryStore(url: temp())
        var (chat, _) = makeChat(store)
        await until("newest page") { chat.detail?.tasks.count == 20 }
        try? await Task.sleep(for: .milliseconds(200))
        FakeOffice.state.reset = true
        FakeOffice.requests = []
        (chat, _) = makeChat(store)
        await until("reset to the newest page") { FakeOffice.requests.last == "/sessions/s/history?limit=20" && chat.sync == .none }
        XCTAssertTrue(FakeOffice.requests.contains { $0.contains("since=25") })
        XCTAssertEqual(chat.detail?.tasks.first?.seq, 6)
        FakeOffice.state.gone = true
        chat.resync()
        await until("removed") { chat.currentId == nil }
        try? await Task.sleep(for: .milliseconds(200))
        let saved = await store.load(machine: "server", id: "s", limit: 1)
        XCTAssertNil(saved)
    }

    func testOfflineShowsTheSavedCopy() async {
        FakeOffice.reset(count: 25)
        let store = HistoryStore(url: temp())
        var (chat, _) = makeChat(store)
        await until("newest page") { chat.detail?.tasks.count == 20 }
        try? await Task.sleep(for: .milliseconds(200))
        FakeOffice.state.offline = true
        (chat, _) = makeChat(store)
        await until("saved copy, offline") { chat.sync == .offline }
        XCTAssertEqual(chat.detail?.tasks.first?.seq, 6)
        XCTAssertEqual(chat.sessions.map(\.id), ["s"])
        XCTAssertNil(chat.error)
        chat.loadOlder()
        await until("older not available") { chat.olderError != nil }
        XCTAssertEqual(chat.olderError, "Older messages aren't available offline")
    }
}

/// A mobd with sessionHistory and one conversation "s"; cursors are "c<seq>".
private final class FakeOffice: URLProtocol {
    struct State {
        var tasks: [AgentTask] = []
        var rev: Int64 = 0
        var offline = false
        var gone = false
        var reset = false
    }
    nonisolated(unsafe) static var state = State()
    nonisolated(unsafe) static var requests: [String] = []
    private static let lock = NSLock()

    static func reset(count: Int64) {
        lock.withLock {
            state = State(tasks: (1...count).map { AgentTask(id: "t\($0)", sessionId: "s", status: Status.succeeded, eventId: 1, rev: $0, seq: $0) }, rev: count)
            requests = []
        }
    }

    static func change(_ seq: Int) { lock.withLock { state.rev += 1; state.tasks[seq - 1].rev = state.rev } }

    static func add() {
        lock.withLock {
            state.rev += 1
            let seq = Int64(state.tasks.count + 1)
            state.tasks.append(AgentTask(id: "t\(seq)", sessionId: "s", status: Status.succeeded, eventId: 1, rev: state.rev, seq: seq))
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "history-tests.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let (status, body): (Int, Any?) = Self.lock.withLock {
            Self.requests.append(url.path + (url.query.map { "?\($0)" } ?? ""))
            let s = Self.state
            if s.offline { return (0, nil) }
            if url.path == "/health" { return (200, ["ok": true, "apiVersion": 3, "features": ["sessionHistory"]]) }
            let session: [String: Any] = ["id": "s", "title": "s", "status": "succeeded", "updatedAt": "2026-10-01T00:00:00Z"]
            if url.path == "/sessions" { return (200, ["sessions": s.gone ? [] : [session]]) }
            if s.gone { return (404, ["error": "session not found"]) }
            let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            func answer(_ list: [AgentTask], _ extra: [String: Any]) -> [String: Any] {
                var session = session
                session["messages"] = list.map { ["id": "\($0.id):a", "taskId": $0.id, "role": "assistant", "content": "\($0.id) r\($0.rev ?? 0)"] }
                let tasks = list.map { ["id": $0.id, "sessionId": "s", "status": $0.status, "eventId": 1, "rev": $0.rev ?? 0, "seq": $0.seq ?? 0] as [String: Any] }
                return ["session": session, "tasks": tasks, "activities": [], "questions": [], "rev": s.rev].merging(extra) { $1 }
            }
            if let since = q["since"].flatMap(Int64.init) {
                if s.reset || since == 0 || since > s.rev { return (200, answer([], ["reset": true])) }
                return (200, answer(s.tasks.filter { ($0.rev ?? 0) > since }, ["reset": false]))
            }
            let limit = Int(q["limit"] ?? "20") ?? 20
            let before = q["before"].flatMap { Int64($0.dropFirst()) } ?? .max
            let older = s.tasks.filter { ($0.seq ?? 0) < before }
            let list = Array(older.suffix(limit))
            let more = older.count > list.count
            return (200, answer(list, more ? ["hasMore": true, "before": "c\(list[0].seq!)"] : ["hasMore": false]))
        }
        guard let body else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
}
