import Foundation
import Observation
import UIKit

/// A draft belongs to one machine and conversation, including its in-flight uploads.
@MainActor @Observable
final class ChatDraft {
    var text = ""
    var attachments: [DraftAttachment] = []
    private(set) var sending = false
    /// Picked mention tokens: word after "@" -> session ID.
    var picked: [String: String] = [:]

    var attachmentsReady: Bool { attachments.allSatisfy { $0.uploadId != nil && $0.error == nil } }

    /// The text being sent: the field stays editable meanwhile, and what was typed since is kept.
    private var sent: String?

    func beginSending() { sending = true; sent = text }

    func finishSending(_ accepted: Bool) {
        sending = false
        defer { sent = nil }
        guard accepted else { return }
        let typed = sent.map { text.hasPrefix($0) ? String(text.dropFirst($0.count)) : text } ?? ""
        text = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : typed
        attachments = []; picked = [:]
    }
}

@MainActor @Observable
final class DraftAttachment: Identifiable {
    let id = UUID()
    var preview: UIImage?
    var uploadId: String?
    var error: String?
}

@MainActor
final class ChatDrafts {
    private var drafts: [String: [String: ChatDraft]] = [:]

    func draft(machine: String, session: String?) -> ChatDraft {
        let key = session ?? ""
        if let draft = drafts[machine]?[key] { return draft }
        let draft = ChatDraft()
        drafts[machine, default: [:]][key] = draft
        return draft
    }
}
