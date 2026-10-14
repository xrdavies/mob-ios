import Foundation
import Combine

class APIClient {
    private var baseURL: String
    private let session = URLSession.shared
    
    init(baseURL: String) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    
    func updateBaseURL(_ url: String) {
        self.baseURL = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    
    // MARK: - Health
    
    func getHealth() async throws -> Health {
        let url = URL(string: "\(baseURL)/health")!
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(Health.self, from: data)
    }
    
    // MARK: - Tasks
    
    func createTask(prompt: String, sessionId: String? = nil, runner: String? = nil, model: String? = nil, effort: String? = nil) async throws -> AgentTask {
        let url = URL(string: "\(baseURL)/tasks")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = ["prompt": prompt]
        if let sessionId = sessionId { body["sessionId"] = sessionId }
        if let runner = runner { body["runner"] = runner }
        if let model = model { body["model"] = model }
        if let effort = effort { body["effort"] = effort }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(AgentTask.self, from: data)
    }
    
    func getTask(_ id: String) async throws -> AgentTask {
        let url = URL(string: "\(baseURL)/tasks/\(id)")!
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(AgentTask.self, from: data)
    }
    
    func cancelTask(_ id: String) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)/tasks/\(id)/cancel")!)
        request.httpMethod = "POST"
        _ = try await session.data(for: request)
    }
    
    func steerTask(_ id: String, prompt: String) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)/tasks/\(id)/steer")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": prompt])
        _ = try await session.data(for: request)
    }
    
    // MARK: - Sessions
    
    func getSession(_ id: String) async throws -> SessionDetail {
        let url = URL(string: "\(baseURL)/sessions/\(id)")!
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(SessionDetail.self, from: data)
    }
    
    func listSessions() async throws -> [Session] {
        let url = URL(string: "\(baseURL)/sessions")!
        let (data, _) = try await session.data(from: url)
        let response = try JSONDecoder().decode(SessionsResponse.self, from: data)
        return response.sessions
    }
    
    // MARK: - Questions
    
    func answerQuestion(taskId: String, questionId: String, answer: String? = nil, approved: Bool? = nil) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)/tasks/\(taskId)/questions/\(questionId)/answer")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = [:]
        if let answer = answer { body["answer"] = answer }
        if let approved = approved { body["approved"] = approved }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await session.data(for: request)
    }
    
    // MARK: - SSE Events Stream
    
    func streamEvents(taskId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let url = URL(string: "\(baseURL)/tasks/\(taskId)/events")!
            let task = session.dataTask(with: url) { data, response, error in
                if let error = error {
                    continuation.finish(throwing: error)
                    return
                }
                continuation.finish()
            }
            
            // For SSE streaming we need a custom implementation
            // iOS doesn't have native SSE, so we'd use URLSession or a library
            // For now, mark as TODO and use polling as fallback
            
            continuation.onTermination = { _ in
                task.cancel()
            }
            
            task.resume()
        }
    }
}

// MARK: - Response wrappers

struct SessionsResponse: Codable {
    let sessions: [Session]
}

struct SessionDetail: Codable {
    let session: Session
    let tasks: [AgentTask]
    let activities: [Activity]
    let questions: [Question]
}
