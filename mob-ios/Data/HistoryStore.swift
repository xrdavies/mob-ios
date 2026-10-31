import Foundation
import SQLite3

/// One saved turn: the task with its messages, steps and questions.
struct StoredTurn: Codable, Equatable {
    var task: AgentTask
    var messages: [Message]
    var activities: [Activity]
    var questions: [Question]
}

/// A saved conversation: its session row, sync revision and the newest turns asked for.
struct SavedConversation {
    var session: Session
    var syncRev: Int64
    /// The oldest saved turn and mobd's cursor for the page before it.
    var oldest: Int64?
    var cursor: String?
    /// Oldest first.
    var turns: [StoredTurn]
}

/// The local copy of conversations (docs/conversation-history.md): SQLite in Application Support,
/// excluded from backup, readable after the first unlock. mobd stays the source of truth, so a
/// corrupt file or another schema version is deleted and rebuilt. An actor, so every write goes
/// through one queue. Failures are logged; the app then works as without a copy.
actor HistoryStore {
    static let shared = HistoryStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("history.sqlite"))

    /// SQLite's user_version of the current schema.
    private static let schema: Int32 = 1
    private let url: URL
    /// The storage limit and the size eviction brings it back under.
    private let limit: Int64
    private let target: Int64
    private var db: OpaquePointer?

    init(url: URL, limit: Int64 = 500 * 1024 * 1024, target: Int64 = 450 * 1024 * 1024) {
        self.url = url
        self.limit = limit
        self.target = target
    }

    /// The newest `limit` saved turns older than `before` (nil: the newest); nil when not saved.
    /// Opening a conversation (no `before`) makes it the most recently opened.
    func load(machine: String, id: String, before: Int64? = nil, limit: Int) -> SavedConversation? {
        guard let row = query("SELECT session, sync_rev FROM conversations WHERE machine = ? AND id = ?", [.text(machine), .text(id)],
                              { ($0.text(0), $0.int(1)) }).first,
              let session = decode(Session.self, row.0) else { return nil }
        if before == nil {
            run("UPDATE conversations SET opened_at = (SELECT COALESCE(MAX(opened_at), 0) + 1 FROM conversations) WHERE machine = ? AND id = ?",
                [.text(machine), .text(id)])
        }
        let oldest = query("SELECT seq, cursor FROM turns WHERE machine = ? AND conversation = ? ORDER BY seq LIMIT 1",
                           [.text(machine), .text(id)], { ($0.int(0), $0.optionalText(1)) }).first
        let turns = query("SELECT data FROM turns WHERE machine = ? AND conversation = ? AND seq < ? ORDER BY seq DESC LIMIT ?",
                          [.text(machine), .text(id), .int(before ?? .max), .int(Int64(limit))], { $0.text(0) })
            .compactMap { decode(StoredTurn.self, $0) }
        return SavedConversation(session: session, syncRev: row.1, oldest: oldest?.0, cursor: oldest?.1, turns: turns.reversed())
    }

    /// The saved conversations' session rows, for the chat list while mobd is unreachable.
    func list(machine: String) -> [Session] {
        query("SELECT session FROM conversations WHERE machine = ?", [.text(machine)], { $0.text(0) })
            .compactMap { decode(Session.self, $0) }
    }

    /// Saves the session row and turns (`replace` drops the conversation's other turns first). A
    /// turn is only replaced by one with at least its `rev`; `cursors` name turns that were the
    /// oldest of a page. Then evicts down to the limit, never touching the `keep` conversations.
    func save(machine: String, session: Session, syncRev: Int64, turns: [StoredTurn], cursors: [String: String] = [:],
              replace: Bool, keep: [String]) {
        var row = session
        row.messages = nil
        guard let sessionJSON = encode(row) else { return }
        guard exec("BEGIN") else { return }
        var ok = run("""
            INSERT INTO conversations (machine, id, session, sync_rev, opened_at, size)
            VALUES (?, ?, ?, ?, (SELECT COALESCE(MAX(opened_at), 0) + 1 FROM conversations), 0)
            ON CONFLICT (machine, id) DO UPDATE SET session = excluded.session, sync_rev = excluded.sync_rev
            """, [.text(machine), .text(session.id), .text(sessionJSON), .int(syncRev)])
        if ok, replace {
            ok = run("DELETE FROM turns WHERE machine = ? AND conversation = ?", [.text(machine), .text(session.id)])
        }
        for t in turns where ok {
            guard let data = encode(t) else { continue }
            ok = run("""
                INSERT INTO turns (machine, conversation, id, seq, rev, size, cursor, data) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (machine, conversation, id) DO UPDATE SET seq = excluded.seq, rev = excluded.rev,
                  size = excluded.size, cursor = COALESCE(excluded.cursor, turns.cursor), data = excluded.data
                WHERE excluded.rev >= turns.rev
                """, [.text(machine), .text(session.id), .text(t.task.id), .int(t.task.seq ?? 0), .int(t.task.rev ?? 0),
                      .int(Int64(data.utf8.count)), cursors[t.task.id].map { .text($0) } ?? .null, .text(data)])
        }
        if ok { ok = resize(machine, session.id) }
        guard ok, exec("COMMIT") else {
            exec("ROLLBACK")
            return
        }
        evict(machine: machine, keep: Set(keep))
    }

    private func evict(machine: String, keep: Set<String>) {
        var total = size()
        guard total > limit else { return }
        let candidates = query("""
            SELECT c.machine, c.id, SUM(t.size) FROM conversations c
            JOIN turns t ON t.machine = c.machine AND t.conversation = c.id
            GROUP BY c.machine, c.id ORDER BY c.opened_at
            """, [], { ($0.text(0), $0.text(1), $0.int(2)) })
            .filter { !($0.0 == machine && keep.contains($0.1)) }
        guard exec("BEGIN") else { return }
        for (i, (m, id, size)) in candidates.enumerated() where total > target {
            if i + 1 < candidates.count {
                run("DELETE FROM turns WHERE machine = ? AND conversation = ?", [.text(m), .text(id)])
                total -= size
            } else {
                // The last one keeps its newest turns. The oldest kept turn needs a cursor, or the
                // turns before it could never be fetched again.
                let rows = query("SELECT id, size, cursor IS NOT NULL FROM turns WHERE machine = ? AND conversation = ? ORDER BY seq",
                                 [.text(m), .text(id)], { ($0.text(0), $0.int(1), $0.int(2) != 0) })
                var drop = 0
                while drop < rows.count && (total > target || !rows[drop].2) {
                    total -= rows[drop].1
                    drop += 1
                }
                for r in rows.prefix(drop) {
                    run("DELETE FROM turns WHERE machine = ? AND conversation = ? AND id = ?", [.text(m), .text(id), .text(r.0)])
                }
            }
            // Without turns, the next open loads the newest page instead of changes since a revision.
            run("""
                UPDATE conversations SET sync_rev = 0 WHERE machine = ?1 AND id = ?2
                AND NOT EXISTS (SELECT 1 FROM turns WHERE machine = ?1 AND conversation = ?2)
                """, [.text(m), .text(id)])
            resize(m, id)
        }
        exec("COMMIT")
    }

    /// Deletes one conversation, or the machine's whole copy.
    func remove(machine: String, id: String? = nil) {
        if let id {
            run("DELETE FROM turns WHERE machine = ? AND conversation = ?", [.text(machine), .text(id)])
            run("DELETE FROM conversations WHERE machine = ? AND id = ?", [.text(machine), .text(id)])
        } else {
            run("DELETE FROM turns WHERE machine = ?", [.text(machine)])
            run("DELETE FROM conversations WHERE machine = ?", [.text(machine)])
        }
    }

    /// Deletes the machine's conversations that are not in `ids` (mobd's current list).
    func prune(machine: String, keeping ids: Set<String>) {
        for id in query("SELECT id FROM conversations WHERE machine = ?", [.text(machine)], { $0.text(0) }) where !ids.contains(id) {
            remove(machine: machine, id: id)
        }
    }

    func clear() {
        exec("DELETE FROM turns; DELETE FROM conversations;")
        exec("VACUUM")
    }

    /// The bytes of saved conversations, as counted against the limit.
    func size() -> Int64 {
        query("SELECT COALESCE(SUM(size), 0) FROM conversations", [], { $0.int(0) }).first ?? 0
    }

    @discardableResult
    private func resize(_ machine: String, _ id: String) -> Bool {
        run("""
            UPDATE conversations SET size = length(CAST(session AS BLOB))
              + (SELECT COALESCE(SUM(size), 0) FROM turns WHERE machine = ?1 AND conversation = ?2)
            WHERE machine = ?1 AND id = ?2
            """, [.text(machine), .text(id)])
    }

    // MARK: - SQLite

    enum Value {
        case text(String), int(Int64), null
    }

    struct Row {
        let stmt: OpaquePointer
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        func optionalText(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// The open database, opening (and if needed rebuilding) it first.
    private func connection() -> OpaquePointer? {
        if let db { return db }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let db = open() { return adopt(db) }
        discard()
        if let db = open() { return adopt(db) }
        report("The local copy of conversations could not be opened")
        return nil
    }

    private func adopt(_ db: OpaquePointer) -> OpaquePointer {
        self.db = db
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        return db
    }

    private func open() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        func value(_ sql: String) -> String? {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
        }
        let version = Int32(value("PRAGMA user_version") ?? "") ?? -1
        let ok = (version == 0 || version == Self.schema) && value("PRAGMA quick_check") == "ok" && sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS conversations (
              machine TEXT NOT NULL, id TEXT NOT NULL, session TEXT NOT NULL, sync_rev INTEGER NOT NULL,
              opened_at INTEGER NOT NULL, size INTEGER NOT NULL, PRIMARY KEY (machine, id));
            CREATE TABLE IF NOT EXISTS turns (
              machine TEXT NOT NULL, conversation TEXT NOT NULL, id TEXT NOT NULL, seq INTEGER NOT NULL,
              rev INTEGER NOT NULL, size INTEGER NOT NULL, cursor TEXT, data TEXT NOT NULL,
              PRIMARY KEY (machine, conversation, id));
            CREATE INDEX IF NOT EXISTS turns_seq ON turns (machine, conversation, seq);
            PRAGMA user_version = \(Self.schema);
            """, nil, nil, nil) == SQLITE_OK
        if !ok {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private func discard() {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// A corrupt file found while working is dropped; the next call starts a new one.
    private func check(_ code: Int32) -> Bool {
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
            report("The local copy of conversations is damaged; starting a new one")
            sqlite3_close(db)
            db = nil
            discard()
        }
        return code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db = connection() else { return false }
        return check(sqlite3_exec(db, sql, nil, nil, nil))
    }

    private func prepare(_ sql: String, _ values: [Value]) -> OpaquePointer? {
        guard let db = connection() else { return nil }
        var stmt: OpaquePointer?
        guard check(sqlite3_prepare_v2(db, sql, -1, &stmt, nil)) else { return nil }
        for (i, v) in values.enumerated() {
            let n = Int32(i + 1)
            switch v {
            case .text(let s): sqlite3_bind_text(stmt, n, s, -1, Self.transient)
            case .int(let x): sqlite3_bind_int64(stmt, n, x)
            case .null: sqlite3_bind_null(stmt, n)
            }
        }
        return stmt
    }

    @discardableResult
    private func run(_ sql: String, _ values: [Value]) -> Bool {
        guard let stmt = prepare(sql, values) else { return false }
        defer { sqlite3_finalize(stmt) }
        return check(sqlite3_step(stmt))
    }

    private func query<T>(_ sql: String, _ values: [Value], _ row: (Row) -> T) -> [T] {
        guard let stmt = prepare(sql, values) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let code = sqlite3_step(stmt)
            guard code == SQLITE_ROW else { _ = check(code); break }
            out.append(row(Row(stmt: stmt)))
        }
        return out
    }

    private nonisolated func report(_ message: String) {
        Task { @MainActor in Log.error(message) }
    }

    private func encode<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        try? APIClient.decoder.decode(type, from: Data(text.utf8))
    }
}
