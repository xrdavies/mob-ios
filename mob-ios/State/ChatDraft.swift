import Foundation
import Observation
import UIKit

/// A draft belongs to one machine and conversation, including its in-flight uploads.
@MainActor @Observable
final class ChatDraft {
    var text = ""
    var attachments: [DraftAttachment] = []
    private(set) var sending = false

    var attachmentsReady: Bool { attachments.allSatisfy { $0.uploadId != nil && $0.error == nil } }

    func beginSending() { sending = true }

    func finishSending(_ accepted: Bool) {
        sending = false
        if accepted { text = ""; attachments = [] }
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
