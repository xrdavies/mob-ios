import Foundation
import UserNotifications

/// Local notifications for agent questions and finished turns. Tapping one opens the chat;
/// questions can also be answered from the notification (approve/deny, an option, or a typed reply).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    /// Called with (machine ID, session ID) when a notification is tapped.
    var onOpen: ((String, String) -> Void)?
    /// Sends an answer from a notification action; returns an error message on failure.
    var onAnswer: ((_ machine: String, _ task: String, _ question: String, _ answer: String?, _ approved: Bool?) async -> String?)?
    /// One category per pending question, since each has its own option buttons.
    private var categories: [String: UNNotificationCategory] = [:]

    override init() {
        super.init()
        center.delegate = self
        // Delivered notifications keep their buttons only while their category stays registered.
        Task { for c in await center.notificationCategories() where c.identifier.hasPrefix("ask.") { categories[c.identifier] = c } }
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func allowed() async -> Bool {
        let s = await center.notificationSettings()
        return s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
    }

    private func id(_ m: Machine, _ s: Session, _ kind: String) -> String { "\(m.id)/\(s.id)/\(kind)" }

    private func post(_ id: String, title: String, body: String, m: Machine, s: Session, urgent: Bool,
                      category: String? = nil, info: [String: Any] = [:]) {
        Log.add("notification: \(title) — \(body)")
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.subtitle = m.name
        content.sound = .default
        content.threadIdentifier = "\(m.id)/\(s.id)"
        content.interruptionLevel = urgent ? .timeSensitive : .active
        content.userInfo = info.merging(["machine": m.id, "session": s.id]) { a, _ in a }
        if let category { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func question(_ m: Machine, _ s: Session, _ q: Question?) {
        cancel(id(m, s, "done"))
        let approval = q?.isApproval == true
        var category: String?
        var info: [String: Any] = [:]
        if let q {
            category = register(q)
            info = ["task": q.taskId, "question": q.id, "options": Array((q.options ?? []).prefix(3))]
        }
        post(id(m, s, "ask"), title: approval ? "Approval needed" : "The agent asks", body: q?.text ?? s.displayTitle,
             m: m, s: s, urgent: true, category: category, info: info)
    }

    /// Registers the answer buttons for a question and returns its category ID.
    private func register(_ q: Question) -> String {
        let id = "ask.\(q.id)"
        // Answers act on the office Mac, so they need an unlocked phone.
        let auth: UNNotificationActionOptions = [.authenticationRequired]
        var actions: [UNNotificationAction] = []
        if q.isApproval {
            actions = [
                UNNotificationAction(identifier: Action.approve, title: "Approve", options: auth),
                UNNotificationAction(identifier: Action.deny, title: "Deny", options: auth.union(.destructive)),
            ]
        } else {
            let options = q.options ?? []
            // iOS shows a handful of buttons; the rest stay in the chat.
            for (i, o) in options.prefix(3).enumerated() {
                actions.append(UNNotificationAction(identifier: "\(Action.option)\(i)", title: o, options: auth))
            }
            if options.isEmpty || q.allowText != false {
                actions.append(UNTextInputNotificationAction(identifier: Action.reply, title: options.isEmpty ? "Reply" : "Other answer…",
                                                             options: auth, textInputButtonTitle: "Send", textInputPlaceholder: "Your answer"))
            }
        }
        categories[id] = UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
        // Keep the newest few; older questions are long settled.
        if categories.count > 20, let oldest = categories.keys.sorted().first { categories[oldest] = nil }
        center.setNotificationCategories(Set(categories.values))
        return id
    }

    /// Tells the user an answer from a notification did not reach the Mac.
    private func failed(_ info: [AnyHashable: Any], _ message: String) {
        guard let m = info["machine"] as? String, let s = info["session"] as? String else { return }
        Log.add("notification answer failed: \(message)")
        let content = UNMutableNotificationContent()
        content.title = "Your answer was not sent"
        content.body = "\(message). Open the chat to answer."
        content.sound = .default
        content.threadIdentifier = "\(m)/\(s)"
        content.userInfo = ["machine": m, "session": s]
        center.add(UNNotificationRequest(identifier: "\(m)/\(s)/ask", content: content, trigger: nil))
    }

    func finished(_ m: Machine, _ s: Session, failed: Bool) {
        cancel(id(m, s, "ask"))
        post(id(m, s, "done"), title: failed ? "Task failed" : "Task finished", body: s.displayTitle, m: m, s: s, urgent: false)
    }

    /// The question was answered (here or on another device).
    func answered(_ m: Machine, _ s: Session) { cancel(id(m, s, "ask")) }

    private func cancel(_ id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // Show banners while the app is open too (AppState already skips the chat on screen).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let m = info["machine"] as? String, let s = info["session"] as? String else { return }
        let action = response.actionIdentifier
        guard action != UNNotificationDefaultActionIdentifier,
              let task = info["task"] as? String, let question = info["question"] as? String else {
            if action != UNNotificationDismissActionIdentifier { await MainActor.run { onOpen?(m, s) } }
            return
        }
        var answer: String?
        var approved: Bool?
        switch action {
        case Action.approve: approved = true
        case Action.deny: approved = false
        case Action.reply:
            answer = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer?.isEmpty != false { return }
        default:
            // Option buttons carry their index into the question's options.
            let options = info["options"] as? [String] ?? []
            if action.hasPrefix(Action.option), let i = Int(action.dropFirst(Action.option.count)), options.indices.contains(i) {
                answer = options[i]
            }
        }
        guard answer != nil || approved != nil else { return }
        await send(machine: m, session: s, task: task, question: question, answer: answer, approved: approved)
    }

    private func send(machine m: String, session s: String, task: String, question: String, answer: String?, approved: Bool?) async {
        guard let onAnswer else { return }
        if let error = await onAnswer(m, task, question, answer, approved) {
            failed(["machine": m, "session": s], error)
        } else {
            Log.add("answered from notification: \(answer ?? (approved == true ? "approved" : "denied"))")
        }
    }
}

private enum Action {
    static let approve = "approve"
    static let deny = "deny"
    static let reply = "reply"
    static let option = "option."
}
