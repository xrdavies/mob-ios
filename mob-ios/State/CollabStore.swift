import SwiftUI

/// Per-conversation request list and locally dismissed notices, plus the "@" picker's source.
@Observable @MainActor
final class CollabStore {
    private(set) var list: [CollabRequest] = []
    private(set) var waiting: Int = 0
    private(set) var loading = false
    private(set) var error: String?
    /// Requests (by ID) the user saw and dismissed locally; they stay hidden until status changes.
    private var dismissed: Set<String> = []

    var needsUser: [CollabRequest] { list.filter { $0.needsUser && !dismissed.contains($0.id) } }
    var pending: [CollabRequest] { list.filter { r in r.isOpen || needsUser.contains { $0.id == r.id } } }

    func refresh(session: String, client: APIClient) {
        loading = true
        error = nil
        Task { @MainActor in
            do {
                let got = try await client.collab(session: session)
                list = got.requests ?? []
                waiting = got.waiting ?? 0
                // A status change un-dismisses it.
                dismissed = dismissed.filter { id in list.contains { $0.id == id && $0.needsUser } }
                loading = false
            } catch {
                self.error = readable(error)
                loading = false
            }
        }
    }

    func cancel(_ id: String, client: APIClient, stopTurn: Bool = false, done: @escaping (Bool) -> Void = { _ in }) {
        Task { @MainActor in
            do {
                let updated = try await client.cancelCollab(id, stopTurn: stopTurn)
                if let i = list.firstIndex(where: { $0.id == id }) { list[i] = updated }
                done(true)
            } catch {
                self.error = readable(error)
                done(false)
            }
        }
    }

    func dismiss(_ id: String) { dismissed.insert(id) }

    func clear() {
        list = []
        waiting = 0
        error = nil
    }

    func onEvent(_ r: CollabRequest) {
        if let i = list.firstIndex(where: { $0.id == r.id }) { list[i] = r }
        else { list.insert(r, at: 0) }
    }
}
