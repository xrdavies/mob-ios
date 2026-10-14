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
    let vnc = VncSession()
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
        let stored = UserDefaults.standard.data(forKey: "machines").flatMap { try? JSONDecoder().decode([Machine].self, from: $0) } ?? []
        let saved = UserDefaults.standard.string(forKey: "activeMachine")
        machines = stored
        activeMachineId = stored.contains { $0.id == saved } ? saved : stored.first?.id
        turnPrefs = (UserDefaults.standard.dictionary(forKey: "turnPrefs") as? [String: String]) ?? [:]
        apiClient = APIClient(baseURL: "")
        notifier.onOpen = { [weak self] m, s in self?.openChat(machine: m, session: s) }
        AppState.shared = self
        activate()
        syncWatchers()
    }

    private func saveMachines() {
        defaults.set(try? JSONEncoder().encode(machines), forKey: "machines")
    }

    /// Points the API client, chats, health and live view at the active machine.
    private func activate() {
        let m = activeMachine
        defaults.set(m?.id, forKey: "activeMachine")
        apiClient = APIClient(baseURL: m?.mobdUrl ?? "")
        health = nil
        isConnected = false
        healthError = nil
        chat.attach(m == nil ? nil : apiClient, machine: m?.id ?? "")
        chat.live = m.map { liveMachines.contains($0.id) } ?? false
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkHealthNow()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        if desktopUsers > 0 { connectDesktop() } else { vnc.disconnect() }
    }

    func selectMachine(_ id: String) {
        guard id != activeMachineId else { return }
        activeMachineId = id
        activate()
    }

    func newMachine() -> Machine { Machine(id: UUID().uuidString, name: "", mobdUrl: "") }

    func save(_ m: Machine) {
        if let i = machines.firstIndex(where: { $0.id == m.id }) { machines[i] = m } else { machines.append(m) }
        saveMachines()
        if activeMachineId == nil || m.id == activeMachineId {
            activeMachineId = m.id
            activate()
        }
        syncWatchers()
    }

    func delete(_ m: Machine) {
        machines.removeAll { $0.id == m.id }
        saveMachines()
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
        guard activeMachine != nil else {
            isConnected = false
            health = nil
            return
        }
        let client = apiClient
        do {
            let h = try await client.health()
            guard client === apiClient else { return }
            if !isConnected { Log.add("\(activeMachine?.name ?? ""): connected, runners \((h.runners ?? []).map(\.name).joined(separator: ", "))") }
            health = h
            isConnected = h.ok
            healthError = nil
        } catch {
            guard client === apiClient, !(error is CancellationError) else { return }
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
        if desktopUsers == 0 { vnc.disconnect() }
    }

    func connectDesktop() {
        guard let m = activeMachine else { return }
        vnc.connect(url: apiClient.vncURL, username: m.vncUsername, password: m.vncPassword)
    }

    func closeLiveView() {
        vnc.setControl(false)
        showLiveView = false
    }

    // MARK: - Events and notifications

    /// Starts a watcher for each machine, and restarts one whose URL changed.
    private func syncWatchers() {
        let byId = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0) })
        for (id, w) in watchers where byId[id]?.mobdUrl != w.machine.mobdUrl {
            w.stop()
            watchers[id] = nil
            liveMachines.remove(id)
        }
        for m in machines where watchers[m.id] == nil { watchers[m.id] = MachineWatcher(m, events: self) }
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
            let q = try? await APIClient(baseURL: m.mobdUrl).session(s.id).questions?.last { $0.isPending }
            notifier.question(m, s, approval: q?.isApproval == true, text: q?.text)
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
        for m in machines {
            guard let list = try? await APIClient(baseURL: m.mobdUrl).sessions() else { continue }
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
        for m in machines {
            guard let list = try? await APIClient(baseURL: m.mobdUrl).sessions() else { continue }
            for s in list { seen["\(m.id)/\(s.id)"] = "\(s.status ?? "")|\(s.waiting == true)" }
        }
        defaults.set(seen, forKey: "seenSessions")
    }
}
