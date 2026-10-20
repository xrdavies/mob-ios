import Foundation
import Observation

/// Desktops on the active machine: GET /desktops, per-session desktop state, memory/disk banners.
/// One instance lives in AppState; `attach` points it at another machine.
@MainActor @Observable
final class DesktopStore {
    /// True when the active machine reports `sessionDesktops` in /health; everything is gated on this.
    private(set) var enabled = false
    /// Desktops by session ID.
    private(set) var desktops: [String: DesktopInfo] = [:]
    private(set) var memory: MemoryInfo?
    private(set) var disk: DiskInfo?
    /// Banner dismissed until the level changes.
    private(set) var dismissedBanner: String?

    @ObservationIgnored private var api: APIClient?
    @ObservationIgnored private var generation = 0

    var banner: ResourceBanner? { ResourceBanner.make(memory: memory, disk: disk) }

    /// The banner unless it was dismissed at its current level.
    var visibleBanner: ResourceBanner? {
        guard enabled, let b = banner, b.dismissKey != dismissedBanner else { return nil }
        return b
    }

    /// Largest memory first.
    var sorted: [DesktopInfo] { desktops.values.sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) } }

    /// A running or asleep mark for a session, or nil when it has no desktop.
    func mark(_ id: String) -> DesktopMark? {
        guard let d = desktops[id] else { return nil }
        switch d.state {
        case "starting", "running", "waking": return .running
        case "asleep": return .asleep
        default: return nil
        }
    }

    func attach(_ client: APIClient?) {
        generation += 1
        api = client
        enabled = false
        desktops = [:]
        memory = nil
        disk = nil
        dismissedBanner = nil
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { refresh() } else { desktops = [:]; memory = nil; disk = nil }
    }

    func refresh() {
        guard enabled, let client = api else { return }
        let gen = generation
        Task {
            do {
                let r = try await client.desktops()
                guard gen == generation else { return }
                desktops = Dictionary((r.desktops ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                memory = r.memory
                disk = r.disk
            } catch {
                // The health check reports connection problems; the desktops keep their last state.
                if gen == generation, !(error is CancellationError) { Log.error("desktops: \(readable(error))") }
            }
        }
    }

    /// Applies a desktop event from the global stream.
    func apply(_ event: DesktopEvent) {
        switch event {
        case .desktop(let info):
            if info.state == "closed" || info.state == "failed" { desktops[info.sessionId] = nil }
            else { desktops[info.sessionId] = info }
            if info.reason == "oomKill" { Log.error("desktop \(info.sessionId.prefix(8)): out of memory, the kernel ended one of its apps") }
            else if info.state == "closed" || info.state == "failed" { Log.add("desktop \(info.sessionId.prefix(8)): \(info.state) (\(info.reason ?? "no reason"))") }
        case .memory(let info): memory = info
        case .disk(let info): disk = info
        }
    }

    func dismissBanner() { dismissedBanner = banner?.dismissKey }

    func close(_ sessionId: String, done: @escaping (String?) -> Void) {
        guard let client = api else { return done("No connection") }
        Task {
            do {
                try await client.closeDesktop(sessionId)
                refresh()
                done(nil)
            } catch {
                done(readable(error))
            }
        }
    }

    func seed(_ sessionId: String, done: @escaping (String?) -> Void) {
        guard let client = api else { return done("No connection") }
        Task {
            do {
                try await client.seedDesktop(sessionId)
                done(nil)
            } catch {
                done(seedErrorText(error))
            }
        }
    }
}
