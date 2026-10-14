import Foundation
import UserNotifications

/// Local notifications for agent questions and finished turns. Tapping one opens the chat.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    /// Called with (machine ID, session ID) when a notification is tapped.
    var onOpen: ((String, String) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func allowed() async -> Bool {
        let s = await center.notificationSettings()
        return s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
    }

    private func id(_ m: Machine, _ s: Session, _ kind: String) -> String { "\(m.id)/\(s.id)/\(kind)" }

    private func post(_ id: String, title: String, body: String, m: Machine, s: Session, urgent: Bool) {
        Log.add("notification: \(title) — \(body)")
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.subtitle = m.name
        content.sound = .default
        content.threadIdentifier = "\(m.id)/\(s.id)"
        content.interruptionLevel = urgent ? .timeSensitive : .active
        content.userInfo = ["machine": m.id, "session": s.id]
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func question(_ m: Machine, _ s: Session, approval: Bool, text: String?) {
        cancel(id(m, s, "done"))
        post(id(m, s, "ask"), title: approval ? "Approval needed" : "The agent asks", body: text ?? s.displayTitle, m: m, s: s, urgent: true)
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
        await MainActor.run { onOpen?(m, s) }
    }
}
