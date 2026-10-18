import Foundation
import Observation
import UIKit
import UserNotifications

/// App-wide state: office Macs, the active machine's health, chats, live view and notifications.
@MainActor @Observable
final class AppState: MachineEvents {
    /// For the background refresh handler, which iOS calls outside the view hierarchy.
    static weak var shared: AppState?

    private(set) var machines: [Machine] = []
    private(set) var activeMachineId: String?
    var activeMachine: Machine? { machines.first { $0.id == activeMachineId } }

    private(set) var health: Health?
    private(set) var isConnected = false
    /// Why the last health check failed; nil when connected or not checked yet.
    private(set) var healthError: String?

    var showDesktopDrawer = false
    var showLiveView = false
    /// Bumped to bring the Chat tab to the front (notification taps).
    private(set) var showChat = 0
    /// Chats waiting for an answer, per machine.
    private var waiting: [String: Set<String>] = [:] {
        didSet {
            waitingCount = waiting.values.reduce(0) { $0 + $1.count }
            UNUserNotificationCenter.current().setBadgeCount(waitingCount)
        }
    }
    /// All chats waiting for an answer: tab, chat-list and app icon badges.
    private(set) var waitingCount = 0

    /// Turns waiting for the desktop, per machine (all chats on it).
    private(set) var queued: [String: Int] = [:]

    /// Composer choices, remembered per machine ("<machine>.runner") and per machine and runner
    /// ("<machine>/<runner>.model" / ".effort"), like the desktop app.
    private(set) var turnPrefs: [String: String]

    private(set) var apiClient: APIClient
    let chat = ChatStore()
    /// One live view shared by the thumbnail and the full-screen view.
    let stream = StreamSession()
    let notifier = Notifier()

    /// The app is on screen (notifications for the open chat are skipped then).
    @ObservationIgnored var foreground = true
    @ObservationIgnored private var desktopUsers = 0
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    /// Global event streams, one per machine, so every Mac can notify (not only the active one).
    @ObservationIgnored private var watchers: [String: MachineWatcher] = [:]
    @ObservationIgnored private var liveMachines = Set<String>()

    private let defaults = UserDefaults.standard

    init() {
        let data = UserDefaults.standard.data(forKey: "machines")
        var stored = data.flatMap { try? JSONDecoder().decode([Machine].self, from: $0) } ?? []
        // VNC is gone: older versions kept a Desktop sign-in password, in this JSON or the Keychain.
        // Rewriting the JSON drops it there; the Keychain copies are deleted once.
        var changed = data.map { String(decoding: $0, as: UTF8.self).contains("\"vnc") } ?? false
        if !UserDefaults.standard.bool(forKey: "vncRemoved") {
            for m in stored { Keychain.delete("\(m.id).vncPassword") }
            UserDefaults.standard.set(true, forKey: "vncRemoved")
        }
        // Machines from before pairing, or whose token is gone, need pairing.
        for i in stored.indices where !stored[i].needsPairing && stored[i].token == nil {
            stored[i].needsPairing = true
            changed = true
        }
        let saved = UserDefaults.standard.string(forKey: "activeMachine")
        machines = stored
        activeMachineId = stored.contains { $0.id == saved } ? saved : stored.first?.id
        turnPrefs = (UserDefaults.standard.dictionary(forKey: "turnPrefs") as? [String: String]) ?? [:]
        apiClient = APIClient(baseURL: "", token: nil)
        if changed { saveMachines() }
        chat.onUnauthorized = { [weak self] id in self?.markNeedsPairing(id) }
        stream.onUnauthorized = { [weak self] in if let id = self?.activeMachineId { self?.markNeedsPairing(id) } }
        notifier.onOpen = { [weak self] m, s in self?.openChat(machine: m, session: s) }
        notifier.onAnswer = { [weak self] m, task, question, answer, approved in
            await self?.answerFromNotification(machine: m, task: task, question: question, answer: answer, approved: approved)
        }
        AppState.shared = self
        activate()
        syncWatchers()
    }

    private func saveMachines() {
        defaults.set(try? JSONEncoder().encode(machines), forKey: "machines")
    }

    /// A client for `m` with its device token from the Keychain.
    func client(for m: Machine) -> APIClient { APIClient(baseURL: m.mobdUrl, token: m.token) }

    /// Points the API client, chats, health and live view at the active machine.
    private func activate() {
        let m = activeMachine
        defaults.set(m?.id, forKey: "activeMachine")
        apiClient = m.map(client(for:)) ?? APIClient(baseURL: "", token: nil)
        health = nil
        isConnected = false
        healthError = nil
        // An unpaired machine gets no requests until it is paired again.
        chat.attach(m == nil || m?.needsPairing == true ? nil : apiClient, machine: m?.id ?? "")
        chat.live = m.map { liveMachines.contains($0.id) } ?? false
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkHealthNow()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        if desktopUsers > 0 { connectDesktop() } else { stream.disconnect() }
    }

    func selectMachine(_ id: String) {
        guard id != activeMachineId else { return }
        activeMachineId = id
        activate()
    }

    /// Saves the name from the editor; address and pairing stay as stored.
    func save(_ m: Machine) {
        guard var stored = machines.first(where: { $0.id == m.id }) else { return }
        stored.name = m.name
        store(stored)
    }

    private func store(_ m: Machine) {
        if let i = machines.firstIndex(where: { $0.id == m.id }) { machines[i] = m } else { machines.append(m) }
        saveMachines()
        if activeMachineId == nil || m.id == activeMachineId {
            activeMachineId = m.id
            activate()
        }
        syncWatchers()
    }

    /// Saves a successful pairing (a new machine, or `existing` paired again) and switches to it.
    /// The address and token change together, so the old token never goes to a new address.
    func completePairing(_ link: PairLink, _ result: PairResult, existing: Machine?, name: String) throws {
        var m = existing ?? Machine(id: UUID().uuidString, name: name, mobdUrl: link.origin)
        guard Keychain.set(result.token, for: m.tokenAccount) else {
            throw PairError(message: "Paired, but the credential could not be stored in the Keychain. Run mobd link again and retry.")
        }
        m.mobdUrl = link.origin
        m.serverId = result.serverId
        m.clientId = result.clientId
        m.needsPairing = false
        Log.add("\(m.name): paired with \(link.origin)")
        store(m)
        selectMachine(m.id)
    }

    /// mobd refused the machine's token: stop using it until the device is paired again.
    func markNeedsPairing(_ id: String) {
        guard let i = machines.firstIndex(where: { $0.id == id }), !machines[i].needsPairing else { return }
        Log.error("\(machines[i].name): mobd refused this device, pair again")
        machines[i].needsPairing = true
        saveMachines()
        if id == activeMachineId { activate() }
        syncWatchers()
    }

    /// For views that call the active machine directly (tasks, snapshots, uploads).
    func noteFailure(_ error: Error) {
        if error.isUnauthorized, let id = activeMachineId { markNeedsPairing(id) }
    }

    func delete(_ m: Machine) {
        machines.removeAll { $0.id == m.id }
        saveMachines()
        Keychain.delete(m.tokenAccount)
        waiting[m.id] = nil
        defaults.removeObject(forKey: "session.\(m.id)")
        if m.id == activeMachineId {
            activeMachineId = machines.first?.id
            activate()
        }
        syncWatchers()
    }

    func checkHealth() { Task { await checkHealthNow() } }

    private func checkHealthNow() async {
        guard let m = activeMachine else {
            isConnected = false
            health = nil
            return
        }
        guard !m.needsPairing else {
            isConnected = false
            health = nil
            healthError = "This device needs to be paired again"
            return
        }
        let client = apiClient
        do {
            let h = try await client.health()
            guard client === apiClient else { return }
            if !isConnected { Log.add("\(activeMachine?.name ?? ""): connected, runners \((h.runners ?? []).map(\.name).joined(separator: ", "))") }
            let first = health == nil
            health = h
            isConnected = h.ok
            healthError = nil
            // The live view waits for health to know whether mobd streams.
            if first, desktopUsers > 0, stream.state.status == .idle || stream.state.status == .error { connectDesktop() }
        } catch {
            guard client === apiClient, !(error is CancellationError) else { return }
            if error.isUnauthorized { return markNeedsPairing(m.id) }
            if healthError != readable(error) { Log.error("\(activeMachine?.name ?? ""): health check failed: \(readable(error))") }
            isConnected = false
            health = nil
            healthError = readable(error)
        }
    }

    func setTurnPref(_ key: String, _ value: String?) {
        turnPrefs[key] = value?.isEmpty == false ? value : nil
        defaults.set(turnPrefs, forKey: "turnPrefs")
    }

    // MARK: - Live view

    /// A view that shows the desktop is on screen; the live view stays open while any is.
    func retainDesktop() {
        desktopUsers += 1
        if desktopUsers == 1 { connectDesktop() }
    }

    func releaseDesktop() {
        desktopUsers -= 1
        if desktopUsers == 0 { stream.disconnect() }
    }

    /// `control` takes control once the new picture arrives (a quality change keeps it).
    func connectDesktop(control: Bool = false) {
        guard let m = activeMachine, !m.needsPairing else { return stream.disconnect() }
        guard let health else { return } // connects when health arrives
        if !health.supports("stream") { return stream.unavailable("Update mobd on the office Mac to use the live desktop") }
        let quality = LiveQuality(rawValue: m.liveQuality ?? "") ?? .auto
        let w = Int(UIScreen.main.bounds.width * UIScreen.main.scale)
        let h = Int(UIScreen.main.bounds.height * UIScreen.main.scale)
        // Remember which transport carried the picture, so the next connect races the WebSocket sooner.
        let id = m.id
        stream.onTransport = { [weak self] t in self?.rememberTransport(id, t) }
        stream.connect(client: apiClient, maxWidth: devicePixels(CGFloat(w), scale: 1), maxHeight: devicePixels(CGFloat(h), scale: 1),
                       quality: quality, control: control, preferWebSocket: m.liveWebSocket == true)
    }

    private func rememberTransport(_ id: String, _ t: LiveTransport) {
        guard let i = machines.firstIndex(where: { $0.id == id }) else { return }
        let ws: Bool? = t == .webSocket ? true : nil
        guard machines[i].liveWebSocket != ws else { return }
        machines[i].liveWebSocket = ws
        saveMachines()
    }

    func closeLiveView() {
        stream.setControl(false)
        showLiveView = false
    }

    /// The live view's status, size and control.
    var liveState: LiveState { stream.state }

    func setLiveQuality(_ id: String, _ quality: LiveQuality) {
        guard let i = machines.firstIndex(where: { $0.id == id }) else { return }
        machines[i].liveQuality = quality.rawValue
        saveMachines()
        // mobd fixes the profile per session: reconnect an open view, keeping control if it was on.
        if id == activeMachineId, desktopUsers > 0 { connectDesktop(control: stream.state.control) }
    }

    // MARK: - Events and notifications

    /// Starts a watcher for each paired machine, and stops or restarts one whose URL, token or
    /// pairing changed.
    private func syncWatchers() {
        let byId = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0) })
        for (id, w) in watchers {
            if let m = byId[id], !m.needsPairing, m.mobdUrl == w.machine.mobdUrl, m.token == w.token { continue }
            w.stop()
            watchers[id] = nil
            liveMachines.remove(id)
        }
        for m in machines where watchers[m.id] == nil && !m.needsPairing {
            watchers[m.id] = MachineWatcher(m, client: client(for: m), events: self)
        }
    }

    /// Opens a chat on a machine (from a notification).
    func openChat(machine: String, session: String?) {
        guard machines.contains(where: { $0.id == machine }) else { return }
        selectMachine(machine)
        if let session { chat.open(session) }
        showChat += 1
    }

    private func isOpen(_ m: Machine, _ s: Session) -> Bool {
        foreground && m.id == activeMachineId && chat.currentId == s.id
    }

    func onSeed(_ m: Machine, _ sessions: [Session]) {
        waiting[m.id] = Set(sessions.filter { $0.waiting == true }.map(\.id))
    }

    func onSession(_ m: Machine, _ s: Session, before: Session?) {
        if s.waiting == true { waiting[m.id, default: []].insert(s.id) } else { waiting[m.id]?.remove(s.id) }
        if m.id == activeMachineId { chat.apply(s) }
        notifyChanges(m, s, before: before)
    }

    private func notifyChanges(_ m: Machine, _ s: Session, before: Session?) {
        let waiting = s.waiting == true
        if waiting && before?.waiting != true {
            if !isOpen(m, s) { notifyQuestion(m, s) }
        } else if !waiting && before?.waiting == true {
            notifier.answered(m, s)
        }
        let finished = (s.status == Status.succeeded || s.status == Status.failed) && Status.busy(before?.status)
        if finished && !isOpen(m, s) { notifier.finished(m, s, failed: s.status == Status.failed) }
    }

    /// Fetches the pending question so the notification can show it.
    private func notifyQuestion(_ m: Machine, _ s: Session) {
        Task {
            var q: Question?
            do { q = try await client(for: m).session(s.id).questions?.last { $0.isPending } } catch { if error.isUnauthorized { markNeedsPairing(m.id) } }
            notifier.question(m, s, q)
        }
    }

    /// Answers a question from a notification action; returns an error message on failure.
    private func answerFromNotification(machine: String, task: String, question: String, answer: String?, approved: Bool?) async -> String? {
        guard let m = machines.first(where: { $0.id == machine }) else { return "The machine was removed" }
        guard !m.needsPairing else { return "This device needs to be paired again" }
        do {
            try await client(for: m).answer(task: task, question: question, answer: answer, approved: approved)
            if m.id == activeMachineId { chat.refreshAll() }
            return nil
        } catch {
            if error.isUnauthorized { markNeedsPairing(m.id) }
            return readable(error)
        }
    }

    func onDeleted(_ m: Machine, _ id: String) {
        waiting[m.id]?.remove(id)
        if m.id == activeMachineId { chat.remove(id) }
    }

    func onReset(_ m: Machine) {
        if m.id == activeMachineId { chat.refreshAll() }
    }

    func onQueue(_ m: Machine, _ queued: Int) { self.queued[m.id] = queued }

    func onUnauthorized(_ m: Machine) { markNeedsPairing(m.id) }

    func onLive(_ m: Machine, _ live: Bool) {
        if live { liveMachines.insert(m.id) } else { liveMachines.remove(m.id) }
        guard m.id == activeMachineId else { return }
        let was = chat.live
        chat.live = live
        // Reconnected: catch up on whatever happened while the stream was down.
        if live && !was { chat.refreshAll() }
    }

    /// Background refresh: iOS gives no long-lived connections in the background, so compare
    /// each machine's chats with what was seen last and notify about the differences.
    func backgroundCheck() async {
        var seen = (defaults.dictionary(forKey: "seenSessions") as? [String: String]) ?? [:]
        for m in machines where !m.needsPairing {
            guard let list = await sessions(m) else { continue }
            for s in list {
                let key = "\(m.id)/\(s.id)"
                let state = "\(s.status ?? "")|\(s.waiting == true)"
                if let old = seen[key], old != state {
                    let parts = old.split(separator: "|", omittingEmptySubsequences: false)
                    var before = s
                    before.status = parts.first.map(String.init)
                    before.waiting = parts.count > 1 && parts[1] == "true"
                    notifyChanges(m, s, before: before)
                }
                seen[key] = state
            }
        }
        defaults.set(seen, forKey: "seenSessions")
    }

    /// Remembers the current chat states so the next background check only reports changes.
    func rememberSessions() async {
        var seen: [String: String] = [:]
        for m in machines where !m.needsPairing {
            guard let list = await sessions(m) else { continue }
            for s in list { seen["\(m.id)/\(s.id)"] = "\(s.status ?? "")|\(s.waiting == true)" }
        }
        defaults.set(seen, forKey: "seenSessions")
    }

    /// A machine's chats, or nil when unreachable; a refused token marks it for pairing.
    private func sessions(_ m: Machine) async -> [Session]? {
        do { return try await client(for: m).sessions() } catch {
            if error.isUnauthorized { markNeedsPairing(m.id) }
            return nil
        }
    }
}
