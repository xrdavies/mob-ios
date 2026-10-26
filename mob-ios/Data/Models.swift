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
    "actuation": "Desktop control",
    "codex": "Codex",
    "claude": "Claude Code",
    "pi": "Pi",
]

struct Health: Codable {
    let ok: Bool
    let features: [String]?
    let runners: [Runner]?
    let runner: String?
    let checks: [String: Check]?

    func supports(_ feature: String) -> Bool { features?.contains(feature) ?? false }

    /// Linux mobd: every conversation has its own desktop, picked by `sessionId` on /stream and /screen.
    var sessionDesktops: Bool { supports("sessionDesktops") }

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
    /// The default settings.json names, else the agent's own; nil when neither is set.
    var defaultModel: String? = nil
    var defaultEffort: String? = nil
    var permissions: String? = nil

    var title: String { label ?? name }

    enum CodingKeys: String, CodingKey {
        case name, label, models, efforts, images, resume, cost, steer, available, detail, defaultModel, defaultEffort, permissions
        case isDefault = "default"
    }
}

/// The menu entry for "no choice": names the agent's default when mobd reports it.
func defaultLabel(_ what: String, _ value: String?) -> String {
    guard let value, !value.isEmpty else { return "Default \(what)" }
    return "Default (\(value))"
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
    /// Why a queued turn still waits: slots, desktops, memory, disk or desktopStarting (Linux mobd).
    var queueReason: String?
    /// True while the turn waits for the user to answer a question.
    var waiting: Bool?

    var modelLabel: String {
        guard let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Default model (not reported)" }
        return model
    }
}

struct Session: Codable, Identifiable, Hashable {
    let id: String
    var title: String?
    var runner: String?
    /// The conversation's model and effort (mobd with "settings"); nil = machine default.
    var model: String?
    var effort: String?
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

/// A conversation's desktop on Linux mobd (GET /desktops and the global "desktop" event).
struct DesktopInfo: Codable, Identifiable, Hashable {
    let sessionId: String
    var title: String?
    var display: String?
    var width: Int?
    var height: Int?
    var scale: Double?
    /// starting, running, asleep, waking, closing, closed or failed.
    var state: String
    /// Why it closed or failed (archived, deleted, user, crashed…), or "oomKill" when the kernel ended one of its apps.
    var reason: String?
    var memoryBytes: Int64?
    var diskBytes: Int64?
    var startedAt: String?
    var lastUsedAt: String?
    var activeTaskId: String?
    var viewers: Int?

    var id: String { sessionId }
}

/// The office computer's memory; `level` is "ok", "low" or "critical".
struct MemoryInfo: Codable, Hashable {
    let level: String
    var availableBytes: Int64?
    var totalBytes: Int64?
    var pressure: Double?
    var warnPercent: Double?
    var floorPercent: Double?
}

struct DiskInfo: Codable, Hashable {
    let level: String
    var freeBytes: Int64?
    var totalBytes: Int64?
    var path: String?
}

/// GET /desktops: largest memory first; only `desktops: []` with one shared desktop.
struct DesktopsResponse: Codable {
    let desktops: [DesktopInfo]?
    let memory: MemoryInfo?
    let disk: DiskInfo?
}

struct SessionsResponse: Codable { let sessions: [Session]? }
struct TasksResponse: Codable { let tasks: [AgentTask]? }

struct SessionDetail: Codable {
    let session: Session
    let tasks: [AgentTask]?
    let activities: [Activity]?
    let questions: [Question]?
    /// The conversation's revision; nil from mobd versions without incremental fetch.
    var rev: Int64? = nil
    /// False when this answers `since` with only the turns changed after it.
    var full: Bool? = nil
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
    var model: String? = nil
    let timestamp: String?
}

/// One way to reach a machine's mobd (its LAN name, a Tailscale or Cloudflare address), paired on
/// its own: each address has its own device token, so a token never goes to an address it was
/// not paired on.
struct MachineAddress: Codable, Identifiable, Hashable {
    var id: String
    var url: String
    var clientId: String?
    /// mobd refused this address's token (or there is none): pair this address again.
    var needsPairing = false
    /// A name the user gave it; nil shows the kind ("LAN" or "Remote").
    var label: String?

    var tokenAccount: String { "\(id).token" }
    var token: String? { Keychain.get(tokenAccount) }
    var kind: AddressKind { AddressKind.of(url) }
}

/// LAN for .local names and private or link-local addresses; Remote for anything else
/// (Tailscale, Cloudflare, a VPN or public name).
enum AddressKind: String {
    case lan = "LAN", remote = "Remote"

    static func of(_ url: String) -> AddressKind {
        guard var host = URL(string: url)?.host?.lowercased() else { return .remote }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".local") { return .lan }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            let (a, b) = (parts[0], parts[1])
            if a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254) { return .lan }
            return .remote
        }
        if host.contains(":") && (host.hasPrefix("fe80") || host.hasPrefix("fc") || host.hasPrefix("fd")) { return .lan }
        return .remote
    }
}

/// An office Mac running mobd: one row, reached over one or more addresses. Stored on the phone
/// only; the device tokens live in the Keychain, not in this JSON.
struct Machine: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var addresses: [MachineAddress]
    /// The address in use, chosen by the user; the first when unset or gone.
    var route: String?
    var liveQuality: String?
    /// The live view last needed mobd's WebSocket here (no UDP path): try it sooner next time.
    var liveWebSocket: Bool?
    /// The office's ID from pairing; nil for machines added before pairing existed.
    var serverId: String?

    /// The first address keeps the machine's ID, so its token account ("<machine>.token") is the
    /// one from before machines had several addresses.
    init(id: String, name: String, mobdUrl: String) {
        self.id = id
        self.name = name
        addresses = [MachineAddress(id: id, url: mobdUrl)]
    }

    private var current: Int? {
        addresses.firstIndex { $0.id == route } ?? (addresses.isEmpty ? nil : 0)
    }

    /// The address in use.
    var address: MachineAddress? { current.map { addresses[$0] } }

    var mobdUrl: String { address?.url ?? "" }
    var clientId: String? { address?.clientId }
    /// The address in use needs pairing (the others may still work).
    var needsPairing: Bool {
        get { address?.needsPairing ?? true }
        set { if let i = current { addresses[i].needsPairing = newValue } }
    }
    var tokenAccount: String { address?.tokenAccount ?? "\(id).token" }
    var token: String? { address?.token }

    /// "LAN", "Remote", or the user's label; a second address of the same kind is numbered.
    func label(_ a: MachineAddress) -> String {
        if let l = a.label?.trimmingCharacters(in: .whitespaces), !l.isEmpty { return l }
        let same = addresses.filter { $0.kind == a.kind && ($0.label ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        guard same.count > 1, let n = same.firstIndex(where: { $0.id == a.id }), n > 0 else { return a.kind.rawValue }
        return "\(a.kind.rawValue) \(n + 1)"
    }

    /// The machine after pairing `origin`: that address paired again when it is saved, else added
    /// next to the others; a machine from before pairing, or of another office, keeps only the new
    /// one. The paired address is the one in use. Returns its index and the token accounts of the
    /// addresses that went.
    func pairing(origin: String, serverId: String, clientId: String) -> (Machine, Int, dropped: [String]) {
        var m = self
        var dropped: [String] = []
        if m.serverId != serverId {
            dropped = m.addresses.map(\.tokenAccount)
            m.addresses = []
        }
        let url = URL(string: origin)
        let n: Int
        if let i = m.addresses.firstIndex(where: { a in url.map { sameOrigin(APIClient.normalize(a.url), $0) } ?? false }) {
            n = i
        } else {
            m.addresses.append(MachineAddress(id: m.addresses.isEmpty ? m.id : UUID().uuidString, url: origin))
            n = m.addresses.count - 1
        }
        m.addresses[n].url = origin
        m.addresses[n].clientId = clientId
        m.addresses[n].needsPairing = false
        m.route = m.addresses[n].id
        m.serverId = serverId
        return (m, n, dropped)
    }

    /// The address's host, for subtitles.
    static func host(_ url: String) -> String { URL(string: url)?.host ?? url }
}

extension Machine {
    private enum Keys: String, CodingKey { case id, name, addresses, route, mobdUrl, liveQuality, liveWebSocket, serverId, clientId, needsPairing }

    /// Saves from before addresses have one address from mobdUrl, clientId and needsPairing;
    /// older ones have no pairing fields: such machines need pairing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        liveQuality = try c.decodeIfPresent(String.self, forKey: .liveQuality)
        liveWebSocket = try c.decodeIfPresent(Bool.self, forKey: .liveWebSocket)
        serverId = try c.decodeIfPresent(String.self, forKey: .serverId)
        route = try c.decodeIfPresent(String.self, forKey: .route)
        if let list = try c.decodeIfPresent([MachineAddress].self, forKey: .addresses), !list.isEmpty {
            addresses = list
        } else {
            var a = MachineAddress(id: id, url: try c.decodeIfPresent(String.self, forKey: .mobdUrl) ?? "")
            a.clientId = try c.decodeIfPresent(String.self, forKey: .clientId)
            a.needsPairing = try c.decodeIfPresent(Bool.self, forKey: .needsPairing) ?? (serverId == nil)
            addresses = [a]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(addresses, forKey: .addresses)
        try c.encodeIfPresent(route, forKey: .route)
        try c.encodeIfPresent(liveQuality, forKey: .liveQuality)
        try c.encodeIfPresent(liveWebSocket, forKey: .liveWebSocket)
        try c.encodeIfPresent(serverId, forKey: .serverId)
    }
}
