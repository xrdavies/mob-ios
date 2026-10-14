import Foundation
import Observation

/// The open conversation: summary, turns, steps and questions.
struct ChatDetail: Equatable {
    var session: Session
    var tasks: [AgentTask]
    var activities: [Activity]
    var questions: [Question]

    var current: AgentTask? { tasks.last }
    var busy: Bool { Status.busy(current?.status) }
}

/// Chats on the active machine: the list, the open conversation, and every action on them.
/// One instance lives in AppState; `attach` points it at another machine.
@MainActor @Observable
final class ChatStore {
    private(set) var sessions: [Session] = []
    /// Archived chats; nil until the archive is opened.
    private(set) var archived: [Session]?
    private(set) var currentId: String?
    private(set) var detail: ChatDetail?
    private(set) var loading = false
    private(set) var sending = false
    /// A stop was requested and the turn has not ended yet.
    private(set) var cancelling = false
    /// Last failure, shown once by the UI and then cleared.
    var error: String?
    /// True while the machine's global event stream is connected; polling then only backs it up.
    @ObservationIgnored var live = false

    @ObservationIgnored private var api: APIClient?
    @ObservationIgnored private var machineId = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var listPoll: Task<Void, Never>?
    @ObservationIgnored private var stream: Task<Void, Never>?
    @ObservationIgnored private var streamTask: String?

    private var key: String { "session.\(machineId)" }

    func attach(_ client: APIClient?, machine: String) {
        generation += 1
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

    /// Runs `block` against the current machine; reports failures unless the machine changed.
    private func run(_ block: @escaping (APIClient) async throws -> Void) {
        guard let client = api else { return }
        let gen = generation
        Task {
            do { try await block(client) } catch {
                if gen == generation, !(error is CancellationError) { self.error = readable(error) }
            }
        }
    }

    private func loadSessions() async {
        guard let client = api else { return }
        let gen = generation
        do {
            let list = try await client.sessions()
            if gen == generation { sessions = list }
            if archived != nil {
                let arch = try await client.sessions(archived: "true")
                if gen == generation { archived = arch }
            }
        } catch {
            // The health check reports connection problems; the list keeps its last state.
        }
    }

    func refreshSessions() { Task { await loadSessions() } }

    func loadArchived() {
        if archived == nil { archived = [] }
        refreshSessions()
    }

    /// Opens a conversation; nil starts a new chat.
    func open(_ id: String?) {
        currentId = id
        detail = nil
        cancelling = false
        UserDefaults.standard.set(id, forKey: key)
        poll?.cancel()
        stopStream()
        guard let id else { return }
        loading = true
        follow(id)
    }

    /// Fetches the open conversation now and keeps refreshing it (fast while a turn runs).
    private func follow(_ id: String) {
        poll?.cancel()
        guard let client = api else { return }
        let gen = generation
        poll = Task { [weak self] in
            var first = true
            while let self, !Task.isCancelled, gen == self.generation, self.currentId == id {
                do {
                    let d = try await client.session(id)
                    guard gen == self.generation, self.currentId == id else { break }
                    let fresh = ChatDetail(session: d.session, tasks: d.tasks ?? [], activities: d.activities ?? [], questions: d.questions ?? [])
                    // A snapshot fetched before newer stream events must not replace them.
                    let shown = self.detail
                    let stale = shown != nil && shown?.current?.id == fresh.current?.id && fresh.busy &&
                        (fresh.current?.eventId ?? 0) < (shown?.current?.eventId ?? 0)
                    if !stale { self.detail = fresh }
                    if self.detail?.busy != true { self.cancelling = false }
                    self.followTurn(client, gen)
                } catch {
                    if Task.isCancelled { break }
                    if first, (error as? APIError)?.status == 404 {
                        // The saved chat was deleted elsewhere.
                        if gen == self.generation { self.open(nil) }
                        break
                    }
                    if first, gen == self.generation { self.error = readable(error) }
                }
                if first { self.loading = false }
                first = false
                let wait: Double = self.stream != nil ? 30 : self.detail?.busy == true ? 2 : self.live ? 60 : 8
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Re-reads the open conversation now (after an action) without clearing it.
    private func reload() { if let id = currentId { follow(id) } }

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
                        guard e.type != sseOpen, let data = e.data.data(using: .utf8),
                              let ev = try? APIClient.decoder.decode(TaskEvent.self, from: data) else { continue }
                        if gen == self.generation { self.apply(task.id, e.type, ev) }
                    }
                } catch {
                    failures += 1
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
        detail = d
        // A new turn (from another device) or a status change the turn stream did not deliver.
        let newTurn = s.activeTaskId != nil && s.activeTaskId != current?.id
        if newTurn || (stream == nil && s.status != current?.status) { reload() }
    }

    func remove(_ id: String) {
        sessions.removeAll { $0.id == id }
        archived?.removeAll { $0.id == id }
        if id == currentId { open(nil) }
    }

    /// After a stream reconnect: refetch everything.
    func refreshAll() {
        refreshSessions()
        reload()
    }

    // MARK: - Actions

    /// Starts a turn; `done` gets true once mobd accepted it (the composer then clears).
    func send(_ prompt: String, runner: String? = nil, model: String? = nil, effort: String? = nil,
              attachments: [String] = [], done: @escaping (Bool) -> Void = { _ in }) {
        sending = true
        let sessionId = currentId
        let gen = generation
        run { client in
            var ok = false
            defer {
                self.sending = false
                done(ok)
            }
            let task = try await client.createTask(prompt: prompt, sessionId: sessionId, runner: runner, model: model, effort: effort, attachments: attachments)
            ok = true
            guard gen == self.generation else { return }
            if task.sessionId == self.currentId { self.reload() } else { self.open(task.sessionId) }
            await self.loadSessions()
        }
    }

    func cancel() {
        guard let task = detail?.current, Status.busy(task.status) else { return }
        cancelling = true
        run { client in
            do { try await client.cancel(task.id) } catch {
                self.cancelling = false
                throw error
            }
            self.reload()
        }
    }

    /// Adds a message to the running turn (runners with steer).
    func steer(_ prompt: String, done: @escaping (Bool) -> Void = { _ in }) {
        guard let task = detail?.current else { return }
        sending = true
        run { client in
            var ok = false
            defer {
                self.sending = false
                done(ok)
            }
            try await client.steer(task.id, prompt: prompt)
            ok = true
            self.reload()
        }
    }

    func answer(_ q: Question, answer: String?, approved: Bool?) {
        run { client in
            try await client.answer(q, answer: answer, approved: approved)
            self.reload()
        }
    }

    func rename(_ s: Session, _ title: String) { patch(s) { try await $0.patchSession(s.id, title: title) } }
    func setPinned(_ s: Session, _ pinned: Bool) { patch(s) { try await $0.patchSession(s.id, pinned: pinned) } }

    func setArchived(_ s: Session, _ archived: Bool) {
        patch(s) { try await $0.patchSession(s.id, archived: archived) }
        if archived, s.id == currentId { open(nil) }
    }

    private func patch(_ s: Session, _ call: @escaping (APIClient) async throws -> Void) {
        run { client in
            try await call(client)
            await self.loadSessions()
            if s.id == self.currentId { self.reload() }
        }
    }

    func delete(_ s: Session) {
        run { client in
            try await client.deleteSession(s.id)
            if s.id == self.currentId { self.open(nil) }
            await self.loadSessions()
        }
    }
}

extension Array where Element: Identifiable {
    mutating func upsert(_ item: Element) {
        if let i = firstIndex(where: { $0.id == item.id }) { self[i] = item } else { append(item) }
    }
}
