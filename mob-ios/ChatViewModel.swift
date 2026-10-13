import SwiftUI
import Combine

class ChatViewModel: ObservableObject {
    @Published var currentSession: Session?
    @Published var activeQuestion: Question?
    @Published var isSubmitting = false
    
    var apiClient: APIClient?
    private var cancellables = Set<AnyCancellable>()
    private var pollingTimer: Timer?
    
    func loadSessions() {
        guard let api = apiClient else { return }
        
        Task {
            do {
                let sessions = try await api.listSessions()
                await MainActor.run {
                    self.currentSession = sessions.first
                    if let sessionId = sessions.first?.id {
                        self.startPolling(sessionId: sessionId)
                    }
                }
            } catch {
                print("Failed to load sessions: \(error)")
            }
        }
    }
    
    func submit(prompt: String) {
        guard let api = apiClient else { return }
        
        isSubmitting = true
        
        Task {
            do {
                let task = try await api.createTask(
                    prompt: prompt,
                    sessionId: currentSession?.id
                )
                
                await MainActor.run {
                    self.isSubmitting = false
                    self.startPolling(sessionId: task.sessionId)
                }
            } catch {
                await MainActor.run {
                    self.isSubmitting = false
                }
                print("Failed to create task: \(error)")
            }
        }
    }
    
    func answerQuestion(_ question: Question, answer: String? = nil, approved: Bool? = nil) {
        guard let api = apiClient else { return }
        
        Task {
            do {
                try await api.answerQuestion(taskId: question.taskId, questionId: question.id, answer: answer, approved: approved)
                await MainActor.run {
                    self.activeQuestion = nil
                }
            } catch {
                print("Failed to answer question: \(error)")
            }
        }
    }
    
    private func startPolling(sessionId: String) {
        pollingTimer?.invalidate()
        
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollSession(sessionId: sessionId)
        }
        
        pollSession(sessionId: sessionId)
    }
    
    private func pollSession(sessionId: String) {
        guard let api = apiClient else { return }
        
        Task {
            do {
                let detail = try await api.getSession(sessionId)
                await MainActor.run {
                    self.currentSession = detail.session
                    
                    // Show the first pending question
                    if let pending = detail.questions.first(where: { $0.status == .pending }) {
                        if self.activeQuestion?.id != pending.id {
                            self.activeQuestion = pending
                            self.sendNotification(for: pending)
                        }
                    }
                }
            } catch {
                // Silent fail during polling
            }
        }
    }
    
    private func sendNotification(for question: Question) {
        let content = UNMutableNotificationContent()
        content.title = "Agent needs your input"
        content.body = question.text
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: question.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    deinit {
        pollingTimer?.invalidate()
    }
}
