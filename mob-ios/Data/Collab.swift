import Foundation

// Agent collaboration (mobd docs/agent-collaboration-design.md): handles name agents, a message
// with @-mentions starts an exchange, and requests between agents are listed per conversation.

/// Who started a turn; nil is the user without mentions.
struct TurnOrigin: Codable, Hashable {
    var kind: String
    var exchangeId: String?
    var requests: [String]?

    var isCollab: Bool { kind == "collab" }
}

struct CollabNote: Codable, Hashable {
    let from: String
    let kind: String
    let text: String
    let at: String?
}

struct CollabRequest: Codable, Identifiable, Hashable {
    let id: String
    let exchangeId: String?
    let from: String
    let to: String
    let fromName: String?
    let toName: String?
    let text: String
    var status: String
    var result: String?
    var thread: [CollabNote]?
    let createdAt: String?
    var updatedAt: String?
    var expiresAt: String?

    /// Still waiting for an outcome.
    var isOpen: Bool { ["open", "in_progress", "needs_clarification"].contains(status) }
    /// Ended in a way the user should look at.
    var needsUser: Bool { ["interrupted", "over_budget", "expired"].contains(status) }

    var statusLabel: String {
        switch status {
        case "open": return "waiting"
        case "in_progress": return "handling"
        case "needs_clarification": return "needs clarification"
        case "answered": return "answered"
        case "failed": return "failed"
        case "cancelled": return "cancelled"
        case "expired": return "expired · needs you"
        case "interrupted": return "interrupted · needs you"
        case "over_budget": return "out of turns · needs you"
        default: return status
        }
    }

    /// The other agent's name, seen from `session`.
    func peerName(from session: String?) -> String {
        session == to ? (fromName ?? "another agent") : (toName ?? "another agent")
    }
}

struct CollabList: Decodable {
    let requests: [CollabRequest]?
    let waiting: Int?
}

enum Handle {
    private static let reserved: Set<String> = ["all", "everyone", "here", "user", "me", "mob", "mobd", "system"]

    /// mobd's rule: 2-32 characters, lowercase letters, digits and -, starts with a letter, not all
    /// hex (so @a1b2c3 always means a short ID), not reserved.
    static func isValid(_ h: String) -> Bool {
        guard (2...32).contains(h.count), let first = h.first, first.isLetter, first.isASCII, first.isLowercase else { return false }
        guard h.allSatisfy({ ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }) else { return false }
        if h.allSatisfy({ "0123456789abcdef".contains($0) }) { return false }
        return !reserved.contains(h)
    }

    /// A handle suggested from a conversation's title, or nil when none fits.
    static func suggest(from title: String, taken: Set<String> = []) -> String? {
        var out = ""
        var dash = false
        for c in title.lowercased() {
            if c.isASCII && (c.isLetter || c.isNumber) {
                if dash && !out.isEmpty { out.append("-") }
                out.append(c); dash = false
            } else {
                dash = true
            }
            if out.count >= 32 { break }
        }
        while let f = out.first, !f.isLetter { out.removeFirst() }
        out = String(out.prefix(32))
        while out.hasSuffix("-") { out.removeLast() }
        if out.count < 2 { return nil }
        let words = out.split(separator: "-")
        // A long title: its first words make a better name.
        if out.count > 20, words.count > 2 { out = words.prefix(2).joined(separator: "-") }
        guard isValid(out) else {
            let agent = "agent-" + out
            return isValid(agent) && !taken.contains(agent) ? String(agent.prefix(32)) : nil
        }
        if !taken.contains(out) { return out }
        for n in 2...99 {
            let c = String(out.prefix(29)) + "-\(n)"
            if isValid(c), !taken.contains(c) { return c }
        }
        return nil
    }
}

/// An agent offered in the `@` picker.
struct MentionCandidate: Identifiable, Hashable {
    let session: Session
    var id: String { session.id }
    var shortId: String { String(session.id.prefix(6)) }
    var archived: Bool { session.archived == true }
    /// "@api · Order service" or "Order service · a1b2c3".
    var label: String {
        if let h = session.handle, !h.isEmpty { return "@\(h) · \(session.displayTitle)" }
        return "\(session.displayTitle) · \(shortId)"
    }
}

enum Mentions {
    /// The picker's list for query `q` (text after "@"): handles first, then titles; the current
    /// conversation is left out. Archived agents stay in the list, marked.
    static func candidates(_ sessions: [Session], query q: String, excluding current: String?) -> [MentionCandidate] {
        let q = q.lowercased()
        let others = sessions.filter { $0.id != current }
        func handle(_ s: Session) -> String { s.handle ?? "" }
        let byHandle = others.filter { !handle($0).isEmpty && (q.isEmpty || handle($0).hasPrefix(q)) }
            .sorted { handle($0) < handle($1) }
        let byTitle = others.filter { s in
            !byHandle.contains(s) && (q.isEmpty || s.displayTitle.lowercased().contains(q) || s.id.hasPrefix(q))
        }
        return (byHandle + byTitle).prefix(20).map(MentionCandidate.init)
    }

    /// `@word` tokens typed in `text` (letters, digits and -).
    static func typed(_ text: String) -> [String] {
        var out: [String] = []
        var scanner = text[...]
        while let at = scanner.firstIndex(of: "@") {
            let before = at == text.startIndex ? nil : text[text.index(before: at)]
            let rest = scanner[scanner.index(after: at)...]
            let word = rest.prefix { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
            if !word.isEmpty, before == nil || before!.isWhitespace || before!.isPunctuation { out.append(String(word).lowercased()) }
            scanner = rest
        }
        return out
    }

    enum Resolution: Equatable {
        case ok([String])
        /// A typed @name that cannot be sent: why.
        case blocked(String)
    }

    /// The session IDs to send: those picked, plus @handles typed without the picker. A typed handle
    /// of an archived agent blocks the send; unknown words are left as text (e.g. an email).
    static func resolve(text: String, picked: [String: String], sessions: [Session], current: String?) -> Resolution {
        var ids: [String] = []
        for word in typed(text) {
            if let id = picked[word] {
                if !ids.contains(id) { ids.append(id) }
                continue
            }
            guard let s = sessions.first(where: { $0.handle == word }) else { continue }
            if s.id == current { continue }
            if s.archived == true { return .blocked("@\(word) is archived. Unarchive it, or give the handle to another conversation.") }
            if !ids.contains(s.id) { ids.append(s.id) }
        }
        for s in sessions where ids.contains(s.id) && s.archived == true {
            return .blocked("@\(s.handle ?? s.displayTitle) is archived. Unarchive it first.")
        }
        return .ok(ids)
    }
}
