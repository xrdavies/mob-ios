import Foundation

// Conversation desktops on Linux mobd (feature `sessionDesktops`): state, events, the resource banner.

/// "No desktop yet — it starts with the conversation's first turn."
let noDesktopText = "No desktop yet — it starts with the conversation's first turn"

/// What the live view says when POST /stream fails; nil keeps the generic handling.
func streamErrorText(_ error: Error) -> String? {
    guard let e = error as? APIError, let code = e.code else { return nil }
    switch code {
    case "no_desktop": return noDesktopText
    case "session_not_found", "session_required", "desktop_unavailable": return e.message
    default: return nil
    }
}

/// Display text for a queued task's reason (only set on Linux mobd).
func queueReasonText(_ reason: String?) -> String? {
    guard let r = reason else { return nil }
    switch r {
    case "slots": return "Waiting for a free slot"
    case "desktops": return "Waiting: the desktop limit is reached"
    case "memory": return "Waiting: the office computer is low on memory"
    case "disk": return "Waiting: the office computer is low on disk space"
    case "desktopStarting": return "Starting the desktop"
    default: return nil
    }
}

/// "Queued #2 · <reason>", with no position shown when missing and a fallback reason.
func queuedLabel(_ task: AgentTask) -> String {
    let pos = task.queuePosition.map { " #\($0)" } ?? ""
    let reason = queueReasonText(task.queueReason) ?? "waits for the desktop"
    return "Queued\(pos) · \(reason)"
}

/// The low-memory or low-disk banner (nil when everything is ok).
struct ResourceBanner: Equatable {
    let level: String // "low" or "critical"
    let text: String
    let dismissKey: String

    static func make(memory: MemoryInfo?, disk: DiskInfo?) -> ResourceBanner? {
        let m = memory?.level ?? "ok", d = disk?.level ?? "ok"
        guard m != "ok" || d != "ok" else { return nil }
        let critical = m == "critical" || d == "critical"
        let level = critical ? "critical" : "low"
        var parts: [String] = []
        if m != "ok" { parts.append("low on memory") }
        if d != "ok" { parts.append("low on disk space") }
        var text = "The office computer is \(parts.joined(separator: " and ")). Close desktops or delete conversations you no longer need."
        if m == "critical" { text += " New conversations wait until memory is freed." }
        else if d == "critical" { text += " New conversations wait until disk space is freed." }
        return ResourceBanner(level: level, text: text, dismissKey: "\(m)|\(d)")
    }
}

/// An event from the global stream: desktop state changed, or memory/disk level changed.
enum DesktopEvent: Equatable {
    case desktop(DesktopInfo)
    case memory(MemoryInfo)
    case disk(DiskInfo)

    static func parse(type: String, data: String) -> DesktopEvent? {
        guard let d = data.data(using: .utf8) else { return nil }
        switch type {
        case "desktop":
            if let info = try? APIClient.decoder.decode(DesktopInfo.self, from: d) { return .desktop(info) }
        case "memory":
            if let info = try? APIClient.decoder.decode(MemoryInfo.self, from: d) { return .memory(info) }
        case "disk":
            if let info = try? APIClient.decoder.decode(DiskInfo.self, from: d) { return .disk(info) }
        default: break
        }
        return nil
    }
}

/// What "Use this browser profile for new conversations" says when mobd refuses.
func seedErrorText(_ error: Error) -> String {
    if (error as? APIError)?.code == "browser_running" { return "Close the browser in this conversation first" }
    return readable(error)
}

/// Which mark a conversation shows in the chat list: running desktop or asleep.
enum DesktopMark: String { case running, asleep }
