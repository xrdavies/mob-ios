import Foundation
import Observation

/// The open conversation: summary, turns, steps and questions.
struct ChatDetail: Equatable {
    var session: Session
    var tasks: [AgentTask]
    var activities: [Activity]
    var questions: [Question]
    /// mobd's revision this state was fetched at; nil from mobd versions without it.
    var rev: Int64? = nil

    var current: AgentTask? { tasks.last }
    var busy: Bool { Status.busy(current?.status) }

    /// `d` applied to `base`: a full answer replaces it; a partial one (`full: false`) replaces only
    /// the turns it carries, with their messages, steps and questions, and keeps the rest.
    static func merged(_ d: SessionDetail, onto base: ChatDetail?) -> ChatDetail {
        let tasks = d.tasks ?? [], activities = d.activities ?? [], questions = d.questions ?? []
        guard d.full == false, let base, base.session.id == d.session.id else {
            return ChatDetail(session: d.session, tasks: tasks, activities: activities, questions: questions, rev: d.rev)
        }
        var all = base.tasks
        for t in tasks { all.upsert(t) }
        let changed = Set(tasks.map(\.id))
        // Kept in turn order, so a changed older turn stays in its place.
        func pick<T>(_ old: [T], _ new: [T], _ turn: (T) -> String) -> [T] {
            let known = Set(all.map(\.id))
            let byTurn = Dictionary(grouping: old.filter { !changed.contains(turn($0)) } + new, by: turn)
            return all.flatMap { byTurn[$0.id] ?? [] } + old.filter { !known.contains(turn($0)) }
        }
        var session = d.session
        session.messages = pick(base.session.messages ?? [], d.session.messages ?? [], \.taskId)
        return ChatDetail(session: session, tasks: all, activities: pick(base.activities, activities, \.taskId),
                          questions: pick(base.questions, questions, \.taskId), rev: d.rev ?? base.rev)
    }
}

// In an extension, so the memberwise initializer stays.
extension ChatDetail {
    /// Saved turns as a conversation, with `session`'s metadata.
    init(session: Session, turns: [StoredTurn], rev: Int64?) {
        var session = session
        session.messages = turns.flatMap(\.messages)
        self.init(session: session, tasks: turns.map(\.task), activities: turns.flatMap(\.activities),
                  questions: turns.flatMap(\.questions), rev: rev)
    }

    /// The turns (all, or those named), in order.
    func turns(_ ids: Set<String>? = nil) -> [StoredTurn] {
        let messages = Dictionary(grouping: session.messages ?? [], by: \.taskId)
        let activities = Dictionary(grouping: self.activities, by: \.taskId)
        let questions = Dictionary(grouping: self.questions, by: \.taskId)
        return tasks.filter { ids?.contains($0.id) ?? true }.map {
            StoredTurn(task: $0, messages: messages[$0.id] ?? [], activities: activities[$0.id] ?? [], questions: questions[$0.id] ?? [])
        }
    }

    var oldestSeq: Int64? { tasks.compactMap(\.seq).min() }

    /// `d`'s turns merged into `base` by task ID, keeping the copy with the higher `rev`. A turn not
    /// held yet joins only when its `seq` is at least `from`, so a changed turn older than the held
    /// range never lands at the end as `current`. Ordered by `seq`; metadata from `d`, revision from `base`.
    static func mergedTurns(_ d: ChatDetail, onto base: ChatDetail?, from: Int64) -> ChatDetail {
        let held = Dictionary((base?.tasks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let fresh = Set(d.tasks.filter { t in
            if let old = held[t.id] { return (old.rev ?? 0) <= (t.rev ?? 0) }
            return (t.seq ?? from) >= from
        }.map(\.id))
        let mine = base?.turns().filter { !fresh.contains($0.task.id) } ?? []
        let turns = (mine + d.turns(fresh)).sorted { ($0.task.seq ?? 0) < ($1.task.seq ?? 0) }
        return ChatDetail(session: d.session, turns: turns, rev: base?.rev)
    }
}

/// Whether the open conversation is in step with mobd (see docs/conversation-history.md).
enum SyncState {
    case none, syncing, offline, failed
}

/// A sync result before it is applied: the conversation to show and the turns to save.
private struct Synced {
    var detail: ChatDetail
    var turns: [StoredTurn]
    var cursors: [String: String]
    var replace: Bool
    var storedFrom: Int64?
    var before: String?
}

/// Chats on the active machine: the list, the open conversation, and every action on them.
/// One instance lives in AppState; `attach` points it at another machine.
@MainActor @Observable
final class ChatStore {
    private(set) var sessions: [Session] = []
    /// Archived chats; nil until the archive is opened.
    private(set) var archived: [Session]?
    private(set) var currentId: String?
    private(set) var detail: ChatDetail? {
        didSet {
            settleOutbox()
            if let detail { remember(detail) }
        }
    }
    /// The message being sent: shown in the chat at once, until mobd's copy arrives.
    private(set) var outbox: Outgoing?
    private(set) var loading = false
    private(set) var sending = false
    /// A stop was requested and the turn has not ended yet.
    private(set) var cancelling = false
    /// Last failure, shown once by the UI and then cleared.
    var error: String?
    private(set) var sync: SyncState = .none
    private(set) var olderLoading = false
    private(set) var olderError: String?
    /// True while the machine's global event stream is connected; polling then only backs it up.
    @ObservationIgnored var live = false
    /// mobd refused the token of this machine; AppState marks it for pairing and detaches.
    @ObservationIgnored var onUnauthorized: ((String) -> Void)?
    /// Another conversation (or a new chat) was opened; the live view follows it on Linux mobd.
    @ObservationIgnored var onOpen: (() -> Void)?

    @ObservationIgnored private var api: APIClient?
    @ObservationIgnored private var machineId = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var selection = 0
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var listPoll: Task<Void, Never>?
    @ObservationIgnored private var stream: Task<Void, Never>?
    @ObservationIgnored private var streamTask: String?
    /// Recently opened conversations on this machine, most recent last: reopening one shows it
    /// at once and fetches only what changed.
    @ObservationIgnored private var cache: [ChatDetail] = []
    /// The local copy, keyed by `historyKey` (the machine's serverId, so every address shares one).
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private var historyKey = ""
    /// mobd serves paged history ("sessionHistory"); nil until /health answers. Only then is the
    /// local copy used.
    @ObservationIgnored private var paged: Bool?
    /// The open conversation's oldest saved turn, and mobd's cursor for the page before it.
    @ObservationIgnored private var storedFrom: Int64?
    @ObservationIgnored private var before: String?
    @ObservationIgnored private var saveTimer: Task<Void, Never>?
    @ObservationIgnored private var writes: Task<Void, Never>?

    /// Turns per history page, from mobd or the local copy.
    static let page = 20

    private var key: String { "session.\(machineId)" }

    init(history: HistoryStore = .shared) {
        self.history = history
    }

    /// Turns before the oldest shown one exist, saved or on mobd.
    var hasOlder: Bool { paged == true && (detail?.tasks.first?.seq ?? 1) > 1 }

    /// `historyKey` names the machine's local copy: its serverId from pairing, else the machine ID.
    func attach(_ client: APIClient?, machine: String, historyKey: String? = nil) {
        if saveTimer != nil { saveCurrent() }
        generation += 1
        selection += 1
        poll?.cancel()
        listPoll?.cancel()
        stopStream()
        live = false
        api = client
        machineId = machine
        sessions = []
        archived = nil
        detail = nil
        currentId = nil
        cache = []
        outbox = nil
        sending = false
        loading = false
        cancelling = false
        error = nil
        sync = .none
        paged = nil
        self.historyKey = historyKey ?? machine
        guard client != nil else { return }
        let gen = generation
        listPoll = Task { [weak self] in
            while let self, !Task.isCancelled, gen == self.generation {
                await self.loadSessions()
                try? await Task.sleep(for: .seconds(self.live ? 60 : 10))
            }
        }
        open(UserDefaults.standard.string(forKey: key))
    }

    /// True (and reported once) when `error` is a refused token for the current machine.
    private func unauthorized(_ error: Error, _ gen: Int) -> Bool {
        guard error.isUnauthorized else { return false }
        if gen == generation { onUnauthorized?(machineId) }
        return true
    }

    /// Runs `block` against the current machine; reports failures unless the machine changed.
    private func run(_ block: @escaping (APIClient) async throws -> Void) {
        guard let client = api else { return }
        let gen = generation
        Task {
            do { try await block(client) } catch {
                if gen == generation, !(error is CancellationError) {
                    self.error = readable(error)
                    _ = unauthorized(error, gen)
                    Log.error(readable(error))
                }
            }
        }
    }

    private func loadSessions() async {
        guard let client = api else { return }
        let gen = generation
        do {
            let list = try await client.sessions()
            if gen == generation {
                sessions = list
                if sync == .offline, currentId == nil { sync = .none }
                // Conversations deleted while this device was away leave the local copy too.
                if paged == true { enqueue { [key = historyKey] in await $0.prune(machine: key, keeping: Set(list.map(\.id))) } }
            }
            if archived != nil {
                let arch = try await client.sessions(archived: "true")
                if gen == generation { archived = arch }
            }
        } catch {
            // The health check reports connection problems; the list keeps its last state.
            _ = unauthorized(error, gen)
            // Unreachable from the start: the conversations saved on this device can still be read.
            guard error.isUnreachable, gen == generation, sessions.isEmpty else { return }
            let saved = await history.list(machine: historyKey)
            guard gen == generation, sessions.isEmpty, !saved.isEmpty else { return }
            sessions = saved.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            if currentId == nil { sync = .offline }
        }
    }

    func refreshSessions() { Task { await loadSessions() } }

    func loadArchived() {
        if archived == nil { archived = [] }
        refreshSessions()
    }

    /// Opens a conversation; nil starts a new chat.
    func open(_ id: String?) {
        let changed = id != currentId
        if changed { selection += 1 }
        if saveTimer != nil { saveCurrent() }
        currentId = id
        defer { if changed { onOpen?() } }
        // With paged history the local copy replaces the memory cache.
        detail = paged == true ? nil : cache.last { $0.session.id == id }
        storedFrom = nil
        before = nil
        olderLoading = false
        olderError = nil
        if sync != .offline { sync = .none }
        cancelling = false
        UserDefaults.standard.set(id, forKey: key)
        poll?.cancel()
        stopStream()
        guard let id else { loading = false; return }
        loading = detail == nil
        follow(id)
    }

    /// Fetches the open conversation now and keeps refreshing it (fast while a turn runs).
    /// `indicate` shows "Syncing…" (returning to the app, reconnecting); routine polls show nothing.
    private func follow(_ id: String, indicate: Bool = false) {
        poll?.cancel()
        guard let client = api else { return }
        let gen = generation
        poll = Task { [weak self] in
            var first = true
            while let self, !Task.isCancelled, gen == self.generation, self.currentId == id {
                do {
                    if self.paged == nil { self.paged = (try? await client.health())?.supports("sessionHistory") }
                    if first, self.paged != false, self.detail == nil {
                        // The saved copy shows at once; then only what changed since it is fetched.
                        let saved = await self.history.load(machine: self.historyKey, id: id, limit: Self.page)
                        guard !Task.isCancelled, gen == self.generation, self.currentId == id else { break }
                        if let saved, !saved.turns.isEmpty, self.detail == nil {
                            self.detail = ChatDetail(session: saved.session, turns: saved.turns, rev: saved.syncRev == 0 ? nil : saved.syncRev)
                            self.storedFrom = saved.oldest
                            self.before = saved.cursor
                            // Saved by a mobd with paged history, so it is one even while /health does not answer.
                            self.paged = self.paged ?? true
                            self.loading = false
                        }
                    }
                    if first, self.paged == true, indicate || self.detail != nil { self.sync = .syncing }
                    let fresh: ChatDetail
                    var synced: Synced?
                    if self.paged == true {
                        synced = try await self.fetchHistory(client, id)
                        fresh = synced!.detail
                    } else {
                        let d = try await client.session(id, since: self.detail?.rev)
                        guard !Task.isCancelled, gen == self.generation, self.currentId == id else { break }
                        fresh = ChatDetail.merged(d, onto: self.detail)
                    }
                    guard !Task.isCancelled, gen == self.generation, self.currentId == id else { break }
                    // A snapshot fetched before newer stream events must not replace them.
                    let shown = self.detail
                    let stale = shown != nil && shown?.current?.id == fresh.current?.id && fresh.busy &&
                        (fresh.current?.eventId ?? 0) < (shown?.current?.eventId ?? 0)
                    if let synced, !stale { self.apply(synced) }
                    else if !stale { self.detail = fresh }
                    if self.sync != .none { self.sync = .none }
                    if self.detail?.busy != true { self.cancelling = false }
                    self.followTurn(client, gen)
                } catch {
                    if Task.isCancelled || error is CancellationError || self.unauthorized(error, gen) { break }
                    if (first || self.paged == true), (error as? APIError)?.status == 404 {
                        // The saved chat was deleted elsewhere.
                        if gen == self.generation { self.remove(id) }
                        break
                    }
                    if self.paged == true, self.detail != nil, gen == self.generation {
                        // The saved copy stays readable; the status says why it may be behind.
                        self.sync = error.isUnreachable ? .offline : .failed
                        Log.error("sync failed: \(readable(error))")
                    } else if first, gen == self.generation { self.error = readable(error) }
                }
                if first { self.loading = false }
                first = false
                let wait: Double = self.stream != nil ? 30 : self.detail?.busy == true ? 2 : self.live ? 60 : 8
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func remember(_ d: ChatDetail) {
        cache.removeAll { $0.session.id == d.session.id }
        cache.append(d)
        if cache.count > 8 { cache.removeFirst() }
    }

    /// Re-reads the open conversation now (after an action) without clearing it.
    private func reload(indicate: Bool = false) { if let id = currentId { follow(id, indicate: indicate) } }

    /// Returning to the app: catches up with what changed meanwhile, showing "Syncing…".
    func resync() {
        guard paged == true, sync != .syncing else { return }
        refreshSessions()
        reload(indicate: true)
    }

    /// What changed since the saved revision, merged into the open conversation; without a saved
    /// copy, or when mobd answers `reset`, the newest page replaces it.
    private func fetchHistory(_ client: APIClient, _ id: String) async throws -> Synced {
        if let rev = detail?.rev, detail?.tasks.isEmpty == false {
            let d = try await client.history(id, ["since": String(rev), "limit": "50"])
            guard currentId == id, let held = detail else { throw CancellationError() }
            if d.reset != true {
                let changes = ChatDetail.merged(d, onto: nil)
                let from = held.tasks.first?.seq ?? 0
                var merged = ChatDetail.mergedTurns(changes, onto: held, from: from)
                merged.rev = d.rev
                // A changed turn inside the saved range is saved even when it is not shown yet.
                let low = storedFrom ?? from
                let ids = Set(changes.tasks.filter { ($0.seq ?? low) >= low }.map(\.id))
                return Synced(detail: merged, turns: changes.turns(ids), cursors: [:], replace: false, storedFrom: storedFrom ?? from, before: before)
            }
            Log.add("history reset by mobd; loading the newest page")
        }
        let page = try await client.history(id, ["limit": String(Self.page)])
        let fresh = ChatDetail.merged(page, onto: nil)
        var cursors: [String: String] = [:]
        if let b = page.before, let first = fresh.tasks.first { cursors[first.id] = b }
        return Synced(detail: fresh, turns: fresh.turns(), cursors: cursors, replace: true, storedFrom: fresh.oldestSeq, before: page.before)
    }

    private func apply(_ s: Synced) {
        detail = s.detail
        storedFrom = s.storedFrom
        before = s.before
        // A running turn is saved every few seconds, not on every poll.
        let running = Set(s.turns.filter { Status.busy($0.task.status) }.map(\.task.id))
        save(s.turns.filter { !running.contains($0.task.id) }, cursors: s.cursors, replace: s.replace)
        if !running.isEmpty { saveSoon() }
    }

    /// Loads the turns before the oldest shown one: from the local copy, else from mobd.
    func loadOlder() {
        guard hasOlder, !olderLoading, let shown = detail, let from = shown.tasks.first?.seq else { return }
        let id = shown.session.id
        let gen = generation
        olderLoading = true
        olderError = nil
        Task {
            defer { if gen == generation, currentId == id { olderLoading = false } }
            var page: ChatDetail?
            if let stored = storedFrom, stored < from,
               let saved = await history.load(machine: historyKey, id: id, before: from, limit: Self.page), !saved.turns.isEmpty {
                page = ChatDetail(session: shown.session, turns: saved.turns, rev: nil)
            }
            do {
                if page == nil {
                    guard let cursor = before, let client = api else { throw APIError(message: "mobd gave no cursor for older messages", status: nil) }
                    let answer = try await client.history(id, ["before": cursor, "limit": String(Self.page)])
                    guard gen == generation, currentId == id else { return }
                    let fresh = ChatDetail.merged(answer, onto: nil)
                    storedFrom = fresh.oldestSeq
                    before = answer.before
                    var cursors: [String: String] = [:]
                    if let b = answer.before, let first = fresh.tasks.first { cursors[first.id] = b }
                    page = fresh
                    save(fresh.turns(), cursors: cursors)
                }
                guard gen == generation, currentId == id, let page, let current = detail else { return }
                // Older pages never move the sync baseline or the session metadata.
                var merged = ChatDetail.mergedTurns(page, onto: current, from: page.oldestSeq ?? from)
                let messages = merged.session.messages
                merged.session = current.session
                merged.session.messages = messages
                detail = merged
            } catch {
                guard gen == generation, currentId == id else { return }
                Log.error("loading older turns failed: \(readable(error))")
                olderError = error.isUnreachable ? "Older messages aren't available offline" : "Couldn't load older messages"
            }
        }
    }

    /// Runs `write` on the local copy after the writes before it.
    private func enqueue(_ write: @escaping @Sendable (HistoryStore) async -> Void) {
        let previous = writes
        let history = history
        writes = Task {
            await previous?.value
            await write(history)
        }
    }

    /// Saves `turns` and the session row of the open conversation.
    private func save(_ turns: [StoredTurn], cursors: [String: String] = [:], replace: Bool = false) {
        guard paged == true, let d = detail, !turns.isEmpty || replace else { return }
        let key = historyKey, session = d.session, rev = d.rev ?? 0
        let keep = [session.id] + sessions.filter { Status.busy($0.status) }.map(\.id)
        enqueue { await $0.save(machine: key, session: session, syncRev: rev, turns: turns, cursors: cursors, replace: replace, keep: keep) }
    }

    /// Saves the current turn now (it finished, or the conversation is left).
    private func saveCurrent() {
        saveTimer?.cancel()
        saveTimer = nil
        guard let d = detail, let t = d.current else { return }
        save(d.turns([t.id]))
    }

    /// While a turn runs, saves it at most every 5 seconds rather than per event.
    private func saveSoon() {
        guard paged == true, saveTimer == nil, let id = currentId else { return }
        saveTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.currentId == id else { return }
            self.saveTimer = nil
            self.saveCurrent()
        }
    }

    private func stopStream() {
        stream?.cancel()
        stream = nil
        streamTask = nil
    }

    /// Streams the open chat's running turn so replies and steps appear as they happen.
    private func followTurn(_ client: APIClient, _ gen: Int) {
        guard let task = detail?.current, Status.busy(task.status) else { return stopStream() }
        if streamTask == task.id, stream != nil { return }
        stopStream()
        streamTask = task.id
        stream = Task { [weak self] in
            var failures = 0
            while let self, !Task.isCancelled, gen == self.generation, self.streamTask == task.id {
                let after = self.detail?.current.flatMap { $0.id == task.id ? $0.eventId : nil } ?? 0
                do {
                    for try await e in client.events(client.url("tasks/\(task.id)/events", ["after": String(after)])) {
                        failures = 0
                        if e.type == sseOpen { Log.add("turn \(task.id.prefix(8)): stream connected") }
                        guard e.type != sseOpen, let data = e.data.data(using: .utf8),
                              let ev = try? APIClient.decoder.decode(TaskEvent.self, from: data) else { continue }
                        Log.add("turn \(task.id.prefix(8)) \(e.type): \(ev.status ?? ev.activity?.title ?? ev.question?.text ?? String((ev.message ?? "").prefix(80)))")
                        if gen == self.generation { self.apply(task.id, e.type, ev) }
                    }
                } catch {
                    failures += 1
                    if !Task.isCancelled { Log.error("turn \(task.id.prefix(8)): stream failed: \(readable(error))") }
                    if self.unauthorized(error, gen) { break }
                }
                // The stream ended or broke: wait, then reconnect while the turn still runs.
                if Task.isCancelled || self.streamTask != task.id { break }
                try? await Task.sleep(for: .seconds(min(30, pow(2, Double(min(failures, 5))))))
                guard let t = self.detail?.current, t.id == task.id, Status.busy(t.status) else { break }
            }
        }
    }

    private func apply(_ taskId: String, _ type: String, _ ev: TaskEvent) {
        guard var d = detail, var t = d.current, t.id == taskId, ev.id > (t.eventId ?? 0) else { return }
        t.eventId = ev.id
        switch type {
        case "resume":
            if let model = ev.model, !model.isEmpty { t.model = model }
        case "activity":
            if let a = ev.activity { d.activities.upsert(a) }
        case "question":
            if let q = ev.question { d.questions.upsert(q) }
        case "usage":
            if let u = ev.usage { t.usage = u }
        case "message":
            if let mid = ev.messageId, let text = ev.message {
                // Messages the user added mid-turn already carry their full ID.
                let user = ev.role == "user"
                var messages = d.session.messages ?? []
                messages.upsert(Message(id: user ? mid : "\(taskId):\(mid)", taskId: taskId, role: user ? "user" : "assistant", content: text, createdAt: ev.timestamp))
                d.session.messages = messages
            }
        case "error":
            if let m = ev.message { error = m }
        default: break
        }
        if let status = ev.status {
            t.status = status
            t.error = status == Status.failed ? ev.message : nil
            if status == Status.running {
                t.startedAt = t.startedAt ?? ev.timestamp
                t.queuePosition = nil
            }
            if Status.terminal(status) { t.finishedAt = t.finishedAt ?? ev.timestamp }
            d.session.status = status
        }
        d.tasks[d.tasks.count - 1] = t
        detail = d
        if Status.terminal(t.status) { saveCurrent() } else { saveSoon() }
        if Status.terminal(ev.status) {
            cancelling = false
            stopStream()
            reload()
            refreshSessions()
        }
    }

    /// A session summary from the machine's global stream.
    func apply(_ s: Session) {
        func byRecent(_ a: Session, _ b: Session) -> Bool {
            if (a.pinned == true) != (b.pinned == true) { return a.pinned == true }
            return (a.updatedAt ?? "") > (b.updatedAt ?? "")
        }
        if s.archived == true {
            sessions.removeAll { $0.id == s.id }
            if archived != nil { archived!.upsert(s); archived!.sort(by: byRecent) }
        } else {
            sessions.upsert(s)
            sessions.sort(by: byRecent)
            archived?.removeAll { $0.id == s.id }
        }
        guard var d = detail, d.session.id == s.id else { return }
        let current = d.current
        d.session.title = s.title
        d.session.status = s.status
        d.session.waiting = s.waiting
        d.session.pinned = s.pinned
        d.session.archived = s.archived
        d.session.activeTaskId = s.activeTaskId
        d.session.updatedAt = s.updatedAt
        d.session.model = s.model
        d.session.effort = s.effort
        detail = d
        // A new turn (from another device) or a status change the turn stream did not deliver.
        let newTurn = s.activeTaskId != nil && s.activeTaskId != current?.id
        if newTurn || (stream == nil && s.status != current?.status) { reload() }
    }

    /// Deletes a machine's local copy (the machine was removed, or mobd no longer accepts this device).
    func forget(historyKey key: String) {
        enqueue { await $0.remove(machine: key) }
    }

    /// The local copy's size, and clearing it (Settings).
    func savedSize() async -> Int64 { await history.size() }

    func clearSaved() async {
        await writes?.value
        await history.clear()
    }

    func remove(_ id: String) {
        enqueue { [key = historyKey] in await $0.remove(machine: key, id: id) }
        cache.removeAll { $0.session.id == id }
        sessions.removeAll { $0.id == id }
        archived?.removeAll { $0.id == id }
        if id == currentId { open(nil) }
    }

    /// After a stream reconnect: refetch everything.
    func refreshAll() {
        refreshSessions()
        reload(indicate: true)
    }

    // MARK: - Actions

    /// Shows the message at once; the composer keeps its draft until `done` confirms acceptance.
    func send(_ prompt: String, runner: String? = nil, model: String? = nil, effort: String? = nil,
              attachments: [String] = [], done: @escaping (Bool) -> Void = { _ in }) {
        guard api != nil, !sending else { return done(false) }
        sending = true
        let sessionId = currentId
        let gen = generation
        let selected = selection
        outbox = Outgoing(text: prompt, sessionId: sessionId)
        run { client in
            var ok = false
            defer {
                if gen == self.generation {
                    self.sending = false
                    if !ok { self.outbox = nil }
                }
                done(ok)
            }
            let task = try await client.createTask(prompt: prompt, sessionId: sessionId, runner: runner, model: model, effort: effort, attachments: attachments)
            ok = true
            guard gen == self.generation else { return }
            self.outbox?.taskId = task.id
            self.outbox?.sessionId = task.sessionId
            if task.sessionId == self.currentId { self.reload() }
            else if sessionId == nil, selected == self.selection { self.open(task.sessionId) }
            self.refreshSessions()
        }
    }

    /// The sent message is in the conversation now: drop the local copy.
    private func settleOutbox() {
        guard let t = outbox?.taskId, detail?.session.messages?.contains(where: { $0.taskId == t }) == true else { return }
        outbox = nil
    }

    func cancel() {
        guard let task = detail?.current, Status.busy(task.status) else { return }
        let gen = generation
        cancelling = true
        run { client in
            do { try await client.cancel(task.id) } catch {
                if gen == self.generation, self.currentId == task.sessionId { self.cancelling = false }
                throw error
            }
            if gen == self.generation, self.currentId == task.sessionId { self.reload() }
        }
    }

    /// Adds a message to the running turn (runners with steer).
    func steer(_ prompt: String, done: @escaping (Bool) -> Void = { _ in }) {
        guard api != nil, !sending, let task = detail?.current else { return done(false) }
        let gen = generation
        sending = true
        run { client in
            var ok = false
            defer {
                if gen == self.generation { self.sending = false }
                done(ok)
            }
            try await client.steer(task.id, prompt: prompt)
            ok = true
            if gen == self.generation, self.currentId == task.sessionId { self.reload() }
        }
    }

    func answer(_ q: Question, answer: String?, approved: Bool?, done: @escaping (Bool) -> Void) {
        guard api != nil else { done(false); return }
        let gen = generation
        let sessionId = currentId
        run { client in
            var ok = false
            defer { done(ok) }
            try await client.answer(q, answer: answer, approved: approved)
            ok = true
            if gen == self.generation, self.currentId == sessionId { self.reload() }
        }
    }

    /// Sets the open conversation's model or effort ("" = machine default), for every device.
    func setTurnSettings(model: String? = nil, effort: String? = nil) {
        guard let id = currentId else { return }
        let gen = generation
        run { client in
            let s = try await client.patchSession(id, model: model, effort: effort)
            if gen == self.generation { self.apply(s) }
        }
    }

    func rename(_ s: Session, _ title: String) { patch(s) { try await $0.patchSession(s.id, title: title) } }
    func setPinned(_ s: Session, _ pinned: Bool) { patch(s) { try await $0.patchSession(s.id, pinned: pinned) } }

    func setArchived(_ s: Session, _ archived: Bool) {
        patch(s) { try await $0.patchSession(s.id, archived: archived) }
        if archived, s.id == currentId { open(nil) }
    }

    private func patch(_ s: Session, _ call: @escaping (APIClient) async throws -> Void) {
        let gen = generation
        run { client in
            try await call(client)
            guard gen == self.generation else { return }
            await self.loadSessions()
            if s.id == self.currentId { self.reload() }
        }
    }

    func delete(_ s: Session) {
        let gen = generation
        run { client in
            try await client.deleteSession(s.id)
            guard gen == self.generation else { return }
            self.remove(s.id)
            await self.loadSessions()
        }
    }
}

extension Array where Element: Identifiable {
    mutating func upsert(_ item: Element) {
        if let i = firstIndex(where: { $0.id == item.id }) { self[i] = item } else { append(item) }
    }
}

/// A message on its way to mobd: its conversation (nil for a new chat until mobd names it) and,
/// once accepted, its turn.
struct Outgoing: Equatable {
    let text: String
    var sessionId: String?
    var taskId: String?
}
