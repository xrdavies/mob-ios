import Foundation

// Mirrors the mobd v3 API (mob/docs/mobd-v3.md). Fields mobd may omit are optional.

struct Check: Codable, Hashable {
    let ok: Bool
    let unknown: Bool?
    let detail: String?
}

private let checkLabels = [
    "accessibility": "Accessibility",
    "screenRecording": "Screen Recording",
    "vnc": "Screen Sharing",
    "actuation": "Desktop control",
    "codex": "Codex",
    "claude": "Claude Code",
]

struct Health: Codable {
    let ok: Bool
    let features: [String]?
    let runners: [Runner]?
    let runner: String?
    let models: [String]?
    let efforts: [String]?
    let checks: [String: Check]?

    func supports(_ feature: String) -> Bool { features?.contains(feature) ?? false }

    func runner(_ name: String?) -> Runner? {
        let list = runners ?? []
        return list.first { $0.name == (name ?? runner) } ?? list.first { $0.isDefault == true }
    }

    /// Readiness checks that failed (permissions, Screen Sharing, agent CLIs), as label and detail.
    var problems: [(label: String, detail: String)] {
        (checks ?? [:]).filter { !$0.value.ok && $0.value.unknown != true }
            .sorted { $0.key < $1.key }
            .map { (checkLabels[$0.key] ?? $0.key, $0.value.detail ?? "") }
    }
}

struct Runner: Codable, Hashable {
    let name: String
    let label: String?
    let models: [String]?
    let efforts: [String]?
    let images: Bool?
    let resume: Bool?
    let cost: Bool?
    let steer: Bool?
    let available: Bool?
    let detail: String?
    let isDefault: Bool?

    var title: String { label ?? name }

    enum CodingKeys: String, CodingKey {
        case name, label, models, efforts, images, resume, cost, steer, available, detail
        case isDefault = "default"
    }
}

enum Status {
    static let queued = "queued"
    static let running = "running"
    static let succeeded = "succeeded"
    static let failed = "failed"
    static let cancelled = "cancelled"

    static func terminal(_ s: String?) -> Bool { s == succeeded || s == failed || s == cancelled }
    static func busy(_ s: String?) -> Bool { s == queued || s == running }
}

struct Usage: Codable, Hashable {
    var inputTokens: Int64?
    var cachedInputTokens: Int64?
    var outputTokens: Int64?
    var reasoningOutputTokens: Int64?
    var costUsd: Double?
}

/// One turn. (Named so it does not shadow Swift's Task.)
struct AgentTask: Codable, Identifiable, Hashable {
    let id: String
    let sessionId: String
    var runner: String?
    var prompt: String?
    var model: String?
    var effort: String?
    var status: String
    var eventId: Int64?
    var attachments: [String]?
    var createdAt: String?
    var updatedAt: String?
    var startedAt: String?
    var finishedAt: String?
    var usage: Usage?
    var error: String?
    var queuePosition: Int?
    /// True while the turn waits for the user to answer a question.
    var waiting: Bool?
}

struct Session: Codable, Identifiable, Hashable {
    let id: String
    var title: String?
    var runner: String?
    var resumeId: String?
    var activeTaskId: String?
    var status: String?
    var pinned: Bool?
    var waiting: Bool?
    var archived: Bool?
    var createdAt: String?
    var updatedAt: String?
    /// Only GET /sessions/{id} includes messages; lists and events omit them.
    var messages: [Message]?

    var displayTitle: String {
        if let t = title, !t.trimmingCharacters(in: .whitespaces).isEmpty { return t }
        return "New chat"
    }
}

struct Message: Codable, Identifiable, Hashable {
    let id: String
    let taskId: String
    let role: String
    var content: String
    let createdAt: String?
}

struct Question: Codable, Identifiable, Hashable {
    let id: String
    let taskId: String
    let kind: String
    let text: String
    let details: String?
    let options: [String]?
    let allowText: Bool?
    let status: String
    let answer: String?
    let approved: Bool?
    let createdAt: String?

    var isApproval: Bool { kind == "approval" }
    var isPending: Bool { status == "pending" }
}

struct PlanItem: Codable, Hashable {
    let text: String
    let completed: Bool?
}

struct FileChange: Codable, Hashable {
    let path: String
    let kind: String?
}

/// Any JSON value (tool arguments).
enum JSONValue: Codable, Hashable, CustomStringConvertible {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    var description: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return String(b)
        case .null: return "null"
        default:
            let data = (try? JSONEncoder().encode(self)) ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}

struct Activity: Codable, Identifiable, Hashable {
    let id: String
    let taskId: String
    let kind: String
    let status: String
    let title: String
    let server: String?
    let tool: String?
    let arguments: [String: JSONValue]?
    let command: String?
    let exitCode: Int?
    let text: String?
    let truncated: Bool?
    let error: String?
    let images: [String]?
    let items: [PlanItem]?
    let changes: [FileChange]?
    let startedAt: String?
    let updatedAt: String?
}

/// GET /queue and the global "queue" event.
struct QueueState: Codable {
    let running: [AgentTask]?
    let queued: [AgentTask]?
}

struct SessionsResponse: Codable { let sessions: [Session]? }
struct TasksResponse: Codable { let tasks: [AgentTask]? }

struct SessionDetail: Codable {
    let session: Session
    let tasks: [AgentTask]?
    let activities: [Activity]?
    let questions: [Question]?
}

struct Upload: Codable {
    let id: String
    let name: String?
    let mime: String?
    let size: Int64?
    let url: String?
}

/// An event on GET /tasks/{id}/events.
struct TaskEvent: Codable {
    let id: Int64
    let type: String?
    let message: String?
    let messageId: String?
    let role: String?
    let status: String?
    let activity: Activity?
    let question: Question?
    let usage: Usage?
    let timestamp: String?
}

/// An office Mac running mobd. Stored on the phone only; the device token and desktop password
/// live in the Keychain, not in this JSON.
struct Machine: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var mobdUrl: String
    /// macOS user for Screen Sharing sign-in (ARD), so the live view lands in that user's session.
    var vncUsername: String = ""
    var liveQuality: String?
    /// The office's ID from pairing; nil for machines added before pairing existed.
    var serverId: String?
    var clientId: String?
    /// mobd refused the token (or there is none): run mobd link and pair again.
    var needsPairing = false

    var tokenAccount: String { "\(id).token" }
    var vncPasswordAccount: String { "\(id).vncPassword" }
    var token: String? { Keychain.get(tokenAccount) }
    var vncPassword: String { Keychain.get(vncPasswordAccount) ?? "" }
}

extension Machine {
    private enum Keys: String, CodingKey { case id, name, mobdUrl, vncUsername, liveQuality, serverId, clientId, needsPairing }

    /// Older saves have no pairing fields: such machines need pairing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        mobdUrl = try c.decodeIfPresent(String.self, forKey: .mobdUrl) ?? ""
        vncUsername = try c.decodeIfPresent(String.self, forKey: .vncUsername) ?? ""
        liveQuality = try c.decodeIfPresent(String.self, forKey: .liveQuality)
        serverId = try c.decodeIfPresent(String.self, forKey: .serverId)
        clientId = try c.decodeIfPresent(String.self, forKey: .clientId)
        needsPairing = try c.decodeIfPresent(Bool.self, forKey: .needsPairing) ?? (serverId == nil)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(mobdUrl, forKey: .mobdUrl)
        try c.encode(vncUsername, forKey: .vncUsername)
        try c.encodeIfPresent(liveQuality, forKey: .liveQuality)
        try c.encodeIfPresent(serverId, forKey: .serverId)
        try c.encodeIfPresent(clientId, forKey: .clientId)
        try c.encode(needsPairing, forKey: .needsPairing)
    }

    /// Desktop passwords that older versions saved in the machines JSON, by machine ID.
    static func legacyPasswords(_ data: Data) -> [String: String] {
        struct Old: Decodable { let id: String; let vncPassword: String? }
        let list = (try? JSONDecoder().decode([Old].self, from: data)) ?? []
        return Dictionary(list.compactMap { o in o.vncPassword.flatMap { $0.isEmpty ? nil : (o.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }
}
