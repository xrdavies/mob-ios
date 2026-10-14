import SwiftUI

struct TasksView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = TasksViewModel()
    
    var body: some View {
        NavigationView {
            Group {
                if viewModel.tasks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                        Text("No tasks yet")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Tasks you create will appear here")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    List(viewModel.tasks) { task in
                        TaskRow(task: task)
                    }
                    .refreshable {
                        await viewModel.refresh()
                    }
                }
            }
            .navigationTitle("Tasks")
        }
        .onAppear {
            viewModel.apiClient = appState.apiClient
            viewModel.loadTasks()
        }
    }
}

struct TaskRow: View {
    let task: AgentTask
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.prompt)
                    .font(.body)
                    .lineLimit(2)
                
                Spacer()
                
                StatusBadge(status: task.status)
            }
            
            HStack {
                Text(task.runner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if let model = task.model {
                    Text("· \(model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Text(formatTime(task.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func formatTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return "" }
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .short
        timeFormatter.timeStyle = .short
        return timeFormatter.string(from: date)
    }
}

struct StatusBadge: View {
    let status: TaskStatus
    
    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor)
            .foregroundStyle(.white)
            .cornerRadius(6)
    }
    
    private var backgroundColor: Color {
        switch status {
        case .queued: return .gray
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}

class TasksViewModel: ObservableObject {
    @Published var tasks: [AgentTask] = []
    var apiClient: APIClient?
    
    func loadTasks() {
        Task {
            await refresh()
        }
    }
    
    @MainActor
    func refresh() async {
        guard let api = apiClient else { return }
        
        do {
            let sessions = try await api.listSessions()
            var allTasks: [AgentTask] = []
            
            for session in sessions {
                let detail = try await api.getSession(session.id)
                allTasks.append(contentsOf: detail.tasks)
            }
            
            self.tasks = allTasks.sorted { $0.createdAt > $1.createdAt }
        } catch {
            print("Failed to load tasks: \(error)")
        }
    }
}
