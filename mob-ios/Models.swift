import Foundation

// MARK: - API Models (matching mobd v3)

struct Health: Codable {
    let ok: Bool
    let features: [String]
    let runners: [Runner]?
    let runner: String?
    let models: [String]?
    let efforts: [String]?
}

struct Runner: Codable, Identifiable {
    let name: String
    let label: String
    let models: [String]
    let efforts: [String]
    let images: Bool
    let resume: Bool
    let cost: Bool
    let steer: Bool?
    let available: Bool
    let detail: String?
    
    var id: String { name }
}

struct AgentTask: Codable, Identifiable {
    let id: String
    let sessionId: String
    let runner: String
    let prompt: String
    let model: String?
    let effort: String?
    let status: TaskStatus
    let createdAt: String
    let updatedAt: String
    let usage: Usage?
}

enum TaskStatus: String, Codable {
    case queued, running, succeeded, failed, cancelled

    var isTerminal: Bool {
        self == .succeeded || self == .failed || self == .cancelled
    }
}

struct Usage: Codable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?
    let costUsd: Double?
    
    enum CodingKeys: String, CodingKey {
        case inputTokens, cachedInputTokens, outputTokens, reasoningOutputTokens
        case costUsd = "costUsd"
    }
}

struct Session: Codable, Identifiable {
    let id: String
    let runner: String
    let resumeId: String?
    let messages: [Message]
    let createdAt: String
    let updatedAt: String
    
    var lastMessage: Message? {
        messages.last
    }
}

struct Message: Codable, Identifiable {
    let id: String
    let taskId: String
    let role: String
    let content: String
    let createdAt: String
}

struct Question: Codable, Identifiable {
    let id: String
    let taskId: String
    let kind: String
    let text: String
    let details: String?
    let options: [String]?
    let allowText: Bool
    let status: QuestionStatus
    let answer: String?
    let approved: Bool?
    let createdAt: String
}

enum QuestionStatus: String, Codable {
    case pending, answered, expired, cancelled
}

struct Activity: Codable, Identifiable {
    let id: String
    let taskId: String
    let kind: String
    let status: String
    let title: String
    let tool: String?
    let command: String?
    let text: String?
    let startedAt: String
    let updatedAt: String
}

struct SSEEvent: Codable {
    let id: Int
    let type: String
    let status: String?
    let message: String?
    let messageId: String?
    let role: String?
    let activity: Activity?
    let question: Question?
    let usage: Usage?
    let timestamp: String
}
