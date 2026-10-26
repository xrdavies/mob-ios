import Foundation
import Observation

/// In-memory debug log (Settings → Log), like the desktop app's.
@MainActor @Observable
final class Log {
    static let shared = Log()

    struct Entry: Identifiable {
        let id = UUID()
        let at: Date
        let error: Bool
        let message: String

        /// The formatter belongs to the main actor, like every view of the log.
        @MainActor var line: String { "\(Log.time.string(from: at)) \(error ? "ERROR " : "")\(message)" }
    }

    private(set) var entries: [Entry] = []
    private static let max = 500
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func add(_ message: String, error: Bool = false) {
        Task { @MainActor in
            shared.entries.append(Entry(at: Date(), error: error, message: message))
            if shared.entries.count > max { shared.entries.removeFirst(shared.entries.count - max) }
        }
    }

    static func error(_ message: String) { add(message, error: true) }

    func clear() { entries = [] }

    var text: String { entries.map(\.line).joined(separator: "\n") }
}
