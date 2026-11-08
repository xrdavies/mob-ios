import Foundation

// Agent collaboration (mobd docs/agent-collaboration-design.md): handles name agents, a message
// with @-mentions starts an exchange, and requests between agents are listed per conversation.

/// Who started a turn; nil is the user without mentions.
struct TurnOrigin: Codable, Hashable {
    var kind: String
    var exchangeId: String?
    var requests: [String]?
    /// What a collab turn carried, in order (mobd's inbox items).
    var deliveries: [Delivery]?

    var isCollab: Bool { kind == "collab" }
}

/// One message mobd delivered to an agent: a request, a clarification, its answer, a result or a notice.
struct Delivery: Codable, Hashable {
    let id: String
    let to: String?
    let requestId: String?
    let kind: String
    let text: String
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

// Shared with Desktop's src/lib/collab.ts: the same rules and words on every app.
enum Collab {
    private static let hex = Set("0123456789abcdef")
    private static let handleChars = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    private static let reserved: Set<String> = ["all", "everyone", "here", "user", "me", "mob", "mobd", "system"]

    static func isHex(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { hex.contains($0) } }
    static func shortId(_ id: String) -> String { String(id.prefix(6)) }

    /// Why `h` cannot be a handle, in words for the user; "" when it can.
    static func handleProblem(_ h: String) -> String {
        if h.count < 2 { return "At least 2 characters." }
        if h.count > 32 { return "At most 32 characters." }
        guard let f = h.first, f.isASCII, f.isLetter, f.isLowercase else { return "Start with a letter." }
        if !h.allSatisfy({ handleChars.contains($0) }) { return "Use lowercase letters, digits and -." }
        if isHex(h) { return "Only 0–9 and a–f reads as a conversation ID; add another letter." }
        if reserved.contains(h) { return "@\(h) is reserved." }
        return ""
    }

    /// What the handle field keeps of typed text: lowercase, no leading @, spaces and _ as -.
    static func normalizeHandleInput(_ s: String) -> String {
        var t = s.lowercased()
        while t.hasPrefix("@") { t.removeFirst() }
        var out = ""
        var gap = false
        for c in t {
            if c.isWhitespace || c == "_" { gap = true; continue }
            if gap { out.append("-"); gap = false }
            if handleChars.contains(c) { out.append(c) }
        }
        if gap { out.append("-") }
        return String(out.prefix(32))
    }

    /// An agent's name where space is short: "@handle", else its title cut to `max` characters with a short ID.
    static func shortLabel(_ s: Session, max: Int = 32) -> String {
        if let h = s.handle, !h.isEmpty { return "@\(h)" }
        let t = s.displayTitle
        let cut = t.count > max ? String(t.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" : t
        return "\(cut) (\(shortId(s.id)))"
    }

    /// The conversation an @word names: a handle, or a unique short ID of 6+ hex characters.
    static func resolve(_ word: String, in sessions: [Session]) -> Session? {
        let w = word.lowercased()
        if let s = sessions.first(where: { $0.handle == w }) { return s }
        guard w.count >= 6, isHex(w) else { return nil }
        let byId = sessions.filter { $0.id.hasPrefix(w) }
        return byId.count == 1 ? byId[0] : nil
    }

    struct Segment: Equatable {
        let text: String
        /// The session this mention names; nil for plain text.
        let session: String?
    }

    /// Text split into plain runs and @mentions of other conversations, for chips and highlighting.
    static func mentionSegments(_ text: String, sessions: [Session], current: String?) -> [Segment] {
        var out: [Segment] = []
        var plain = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let before = i == text.startIndex ? nil : text[text.index(before: i)]
            if c == "@", before == nil || before!.isWhitespace {
                let start = text.index(after: i)
                let end = text[start...].firstIndex { !handleChars.contains(Character($0.lowercased())) } ?? text.endIndex
                let word = String(text[start..<end])
                let next = end == text.endIndex ? nil : text[end]
                let boundary = next == nil || next!.isWhitespace || ".,;:!?)".contains(next!)
                if (2...32).contains(word.count), boundary, let s = resolve(word, in: sessions), s.id != current {
                    if !plain.isEmpty { out.append(Segment(text: plain, session: nil)); plain = "" }
                    out.append(Segment(text: "@" + word, session: s.id))
                    i = end
                    continue
                }
            }
            plain.append(c)
            i = text.index(after: i)
        }
        if !plain.isEmpty { out.append(Segment(text: plain, session: nil)) }
        return out
    }

    /// The `@word` being typed at the end of `text` (SwiftUI's field gives no caret), or nil.
    static func mentionQuery(_ text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at != text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        let word = text[text.index(after: at)...]
        guard word.allSatisfy({ handleChars.contains(Character($0.lowercased())) }) else { return nil }
        return word.lowercased()
    }

    /// Who a delivery is from, by session ID: the requester for requests and answers, else the recipient.
    static func sender(_ d: Delivery, _ r: CollabRequest) -> String? {
        if d.kind == "notice" { return nil }
        return d.kind == "request" || d.kind == "answer" ? r.from : r.to
    }

    /// What a delivery says about itself, after the sender's name.
    static func label(_ d: Delivery, _ r: CollabRequest?) -> String {
        switch d.kind {
        case "request": return "asks"
        case "clarification": return "needs clarification"
        case "answer": return "answered your question"
        case "result": return r?.status == "failed" ? "couldn't complete your request" : "replied"
        default: return ""
        }
    }

    /// A delivered message's text without mobd's instructions to the recipient (prompts without deliveries).
    static func deliveryBody(_ body: String) -> String {
        var b = body
        if b.hasPrefix("Request: ") { b.removeFirst("Request: ".count) }
        for marker in ["\n\nWhen done, call complete_request(", "\n\nAnswer with answer_clarification("] {
            if let r = b.range(of: marker) { b = String(b[..<r.lowerBound]) }
        }
        // mobd's result header is one line: "Result of your request "…" to @b (answered):".
        if b.hasPrefix("Result of your request \""), let nl = b.firstIndex(of: "\n") { b = String(b[b.index(after: nl)...]) }
        return b.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a list of tasks shows for one. A collaboration turn's prompt is mobd's instructions to
    /// the agent, not the user's words: it shows what was delivered ("Reply: …") instead.
    static func taskTitle(_ task: AgentTask) -> String {
        if task.origin?.isCollab == true {
            if let d = task.origin?.deliveries?.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                let kind = ["request": "Request: ", "clarification": "Question: ", "answer": "Answer: ", "result": "Reply: "][d.kind] ?? ""
                return kind + d.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let p = parseDelivery(task.prompt ?? "").first { return "\(p.from): \(p.body)" }
        }
        return task.prompt ?? ""
    }

    /// A delivered turn's prompt split into its messages: who sent each and the text.
    static func parseDelivery(_ prompt: String) -> [(from: String, body: String)] {
        prompt.components(separatedBy: "\n\n---\n\n").compactMap { part in
            guard let h = part.range(of: "[Mob collaboration · from "), let end = part.range(of: "]\n", range: h.upperBound..<part.endIndex) else { return nil }
            let header = part[h.upperBound..<end.lowerBound]
            guard let sep = header.range(of: " · request ") else { return nil }
            return (String(header[..<sep.lowerBound]), deliveryBody(String(part[end.upperBound...])))
        }
    }

    /// A readable title for a collaboration tool step, or nil for other steps.
    static func stepTitle(server: String?, tool: String?, arguments: [String: JSONValue]?, sessions: [Session]) -> String? {
        guard server == "mob-mcp" else { return nil }
        func arg(_ k: String) -> String { if case .string(let v)? = arguments?[k] { return v }; return "" }
        var to = arg("to").lowercased()
        while to.hasPrefix("@") { to.removeFirst() }
        let who = resolve(to, in: sessions).map { shortLabel($0) } ?? (to.isEmpty ? "an agent" : isHex(to) ? to : "@\(to)")
        switch tool {
        case "send_request": return "Asked \(who): \(arg("request"))"
        case "ask_clarification": return "Asked for clarification: \(arg("text"))"
        case "answer_clarification": return "Answered the clarification: \(arg("text"))"
        case "complete_request": return arg("outcome") == "failed" ? "Reported it couldn't: \(arg("result"))" : "Replied: \(arg("result"))"
        case "list_collaborators": return "Looked up the mentioned agents"
        default: return nil
        }
    }

    /// A stable hue (0–1) for an agent, so it keeps its colour everywhere.
    static func hue(_ id: String) -> Double {
        var h = 0
        for u in id.unicodeScalars { h = (h * 31 + Int(u.value)) % 360 }
        return Double(h) / 360
    }
}
