import Foundation

/// What a machine's global stream reports.
@MainActor
protocol MachineEvents: AnyObject {
    /// `before` is the last known summary, nil for a chat that appeared since.
    func onSession(_ m: Machine, _ s: Session, before: Session?)
    func onDeleted(_ m: Machine, _ id: String)
    func onReset(_ m: Machine)
    func onLive(_ m: Machine, _ live: Bool)
}

/// Follows one machine's GET /events (session summaries) and remembers the last summary of
/// every chat, so callers see transitions: started waiting, finished, failed.
@MainActor
final class MachineWatcher {
    let machine: Machine
    private var known: [String: Session] = [:]
    private var task: Task<Void, Never>?

    init(_ machine: Machine, events: MachineEvents) {
        self.machine = machine
        task = Task { [weak self, weak events] in
            let client = APIClient(baseURL: machine.mobdUrl)
            var lastId: String?
            var failures = 0
            while !Task.isCancelled {
                do {
                    // Seed without notifying, so only changes from now on count.
                    if lastId == nil { try await self?.seed(client) }
                    for try await e in client.events(client.url("events"), lastEventId: lastId) {
                        guard let self, let events else { return }
                        if let id = e.id { lastId = id }
                        switch e.type {
                        case sseOpen:
                            failures = 0
                            events.onLive(machine, true)
                        case "session":
                            if let s = Self.decode(e.data) {
                                let before = self.known.updateValue(s, forKey: s.id)
                                events.onSession(machine, s, before: before)
                            }
                        case "session.deleted":
                            if let s = Self.decode(e.data) {
                                self.known[s.id] = nil
                                events.onDeleted(machine, s.id)
                            }
                        case "reset":
                            try await self.seed(client)
                            events.onReset(machine)
                        default: break
                        }
                    }
                } catch {
                    // Offline or mobd restarted; retry with backoff below.
                }
                if Task.isCancelled { return }
                failures += 1
                events?.onLive(machine, false)
                try? await Task.sleep(for: .seconds(min(60, 2 * pow(2, Double(min(failures, 5))))))
            }
        }
    }

    func stop() { task?.cancel() }

    private static func decode(_ data: String) -> Session? {
        data.data(using: .utf8).flatMap { try? APIClient.decoder.decode(Session.self, from: $0) }
    }

    private func seed(_ client: APIClient) async throws {
        let list = try await client.sessions(archived: "all")
        known = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}
