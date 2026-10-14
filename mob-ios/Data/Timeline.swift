import Foundation

// Ported from the desktop app (apps/mob/src/lib/timeline.ts), like mob-android.

/// The question card replaces the tool step that asked it.
private let askTools: Set<String> = ["ask_user", "request_approval"]

/// Consecutive steps fold into one expandable group from this many on.
let groupMin = 3

enum TimelineItem: Identifiable, Hashable {
    case user(id: String, message: Message, task: AgentTask?)
    case assistant(id: String, message: Message)
    case steps(id: String, activities: [Activity])
    case group(id: String, activities: [Activity])
    case ask(id: String, question: Question)
    case queued(id: String, task: AgentTask)
    case working(id: String, task: AgentTask, latest: Activity?, waiting: Bool)
    case footer(id: String, task: AgentTask)

    var id: String {
        switch self {
        case .user(let id, _, _), .assistant(let id, _), .steps(let id, _), .group(let id, _),
             .ask(let id, _), .queued(let id, _), .working(let id, _, _, _), .footer(let id, _):
            return id
        }
    }
}

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

func parseTime(_ iso: String?) -> Date? {
    guard let iso else { return nil }
    return isoFormatter.date(from: iso) ?? isoPlain.date(from: iso)
}

private func time(_ iso: String?) -> Double { parseTime(iso)?.timeIntervalSince1970 ?? .greatestFiniteMagnitude }

/// Builds the conversation: per turn, the prompt, then replies, steps and questions by time.
func buildTimeline(tasks: [AgentTask], messages: [Message], activities: [Activity], questions: [Question]) -> [TimelineItem] {
    struct Bucket {
        var messages: [Message] = []
        var activities: [Activity] = []
        var questions: [Question] = []
    }
    var items: [TimelineItem] = []
    let known = Set(tasks.map(\.id))
    var order: [String] = []
    var buckets: [String: Bucket] = [:]
    func add(_ id: String, _ f: (inout Bucket) -> Void) {
        if buckets[id] == nil { buckets[id] = Bucket(); order.append(id) }
        f(&buckets[id]!)
    }
    for m in messages { add(m.taskId) { $0.messages.append(m) } }
    for a in activities where !askTools.contains(a.tool ?? "") { add(a.taskId) { $0.activities.append(a) } }
    for q in questions { add(q.taskId) { $0.questions.append(q) } }
    let orphans = order.filter { !known.contains($0) }

    for turnId in tasks.map(\.id) + orphans {
        let task = tasks.first { $0.id == turnId }
        let b = buckets[turnId] ?? Bucket()
        var user = b.messages.first { $0.role == "user" }
        if user == nil, let prompt = task?.prompt, !prompt.isEmpty {
            user = Message(id: "\(turnId):user", taskId: turnId, role: "user", content: prompt, createdAt: task?.createdAt)
        }
        if let user { items.append(.user(id: user.id, message: user, task: task)) }

        enum Entry { case message(Message), activity(Activity), question(Question) }
        var entries: [(at: Double, order: Int, entry: Entry)] = []
        var n = 0
        for m in b.messages where m.id != user?.id { entries.append((time(m.createdAt), n, .message(m))); n += 1 }
        var seenNotices = Set<String>()
        for a in b.activities {
            if a.kind == "notice" && !seenNotices.insert(a.text ?? a.title).inserted { continue }
            entries.append((time(a.startedAt), n, .activity(a))); n += 1
        }
        for q in b.questions { entries.append((time(q.createdAt), n, .question(q))); n += 1 }
        entries.sort { $0.at != $1.at ? $0.at < $1.at : $0.order < $1.order }

        var run: [Activity] = []
        func flush() {
            if run.count >= groupMin { items.append(.group(id: "\(run[0].id):group", activities: run)) }
            else if !run.isEmpty { items.append(.steps(id: "\(run[0].id):steps", activities: run)) }
            run = []
        }
        for e in entries {
            switch e.entry {
            case .activity(let a): run.append(a)
            case .question(let q):
                flush()
                items.append(.ask(id: "q:\(q.id)", question: q))
            case .message(let m):
                flush()
                items.append(m.role == "user" ? .user(id: m.id, message: m, task: nil) : .assistant(id: m.id, message: m))
            }
        }
        flush()

        guard let task else { continue }
        switch task.status {
        case Status.queued: items.append(.queued(id: "\(task.id):queued", task: task))
        case Status.running:
            items.append(.working(id: "\(task.id):working", task: task,
                                  latest: b.activities.last { $0.kind != "notice" },
                                  waiting: b.questions.contains { $0.isPending }))
        default: items.append(.footer(id: "\(task.id):footer", task: task))
        }
    }
    return items
}

/// Desktop size in points, from the most recent screenshot step's metadata.
struct ScreenGeometry: Equatable {
    let pointWidth: Double
    let pointHeight: Double
}

func screenGeometry(_ activities: [Activity]) -> ScreenGeometry? {
    for a in activities.reversed() where a.tool == "screenshot" {
        guard let data = a.text?.data(using: .utf8),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let w = (meta["point_width"] as? NSNumber)?.doubleValue, let h = (meta["point_height"] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { continue }
        return ScreenGeometry(pointWidth: w, pointHeight: h)
    }
    return nil
}

/// The agent's last completed click, in desktop points.
struct AgentClick: Equatable {
    let id: String
    let x: Double
    let y: Double
}

func latestClick(_ activities: [Activity]) -> AgentClick? {
    func number(_ v: JSONValue?) -> Double? {
        switch v {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    for a in activities.reversed() where a.tool == "click" && a.status == "completed" {
        if let x = number(a.arguments?["x"]), let y = number(a.arguments?["y"]), x.isFinite, y.isFinite {
            return AgentClick(id: a.id, x: x, y: y)
        }
    }
    return nil
}
