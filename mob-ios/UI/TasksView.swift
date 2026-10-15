import SwiftUI

/// Every turn on the active machine (one GET /tasks call); tap opens its chat.
struct TasksView: View {
    @Environment(AppState.self) private var app
    let openChat: (String) -> Void
    @State private var tasks: [AgentTask]?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if app.activeMachine == nil {
                    message("Add your office Mac in Settings")
                } else if app.activeMachine?.needsPairing == true {
                    message("This device needs to be paired again\nSettings → Machines → Pair again")
                } else if let tasks {
                    if tasks.isEmpty {
                        message("No tasks yet\nTasks you create will appear here")
                    } else {
                        List(tasks) { task in
                            Button { openChat(task.sessionId) } label: { row(task) }
                                .buttonStyle(.plain)
                        }
                        .listStyle(.plain)
                    }
                } else if let error {
                    message("Could not load tasks\n\(error)")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Tasks")
            .refreshable { await load() }
        }
        .task(id: app.activeMachineId) {
            tasks = nil
            error = nil
            while !Task.isCancelled {
                await load()
                let busy = tasks?.contains { Status.busy($0.status) } == true
                try? await Task.sleep(for: .seconds(busy ? 3 : 15))
            }
        }
    }

    private func load() async {
        guard let m = app.activeMachine, !m.needsPairing else { return }
        do {
            tasks = try await app.apiClient.tasks().sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            error = nil
        } catch {
            if !(error is CancellationError) { self.error = readable(error) }
            app.noteFailure(error)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(task.prompt ?? "").lineLimit(3)
                Spacer()
                StatusBadge(task: task)
            }
            Text([task.runner, task.model, relativeTime(task.createdAt)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if task.status == Status.failed, let e = task.error, !e.isEmpty {
                Text(e).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
