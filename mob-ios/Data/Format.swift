import Foundation

/// "now", "5m", "3h", "2d", then a short date.
func relativeTime(_ iso: String?, now: Date = Date()) -> String {
    guard let t = parseTime(iso) else { return "" }
    let s = now.timeIntervalSince(t)
    switch s {
    case ..<60: return "now"
    case ..<3600: return "\(Int(s / 60))m"
    case ..<86400: return "\(Int(s / 3600))h"
    case ..<(7 * 86400): return "\(Int(s / 86400))d"
    default: return t.formatted(date: .numeric, time: .omitted)
    }
}

/// "1:05" or "12s" for a turn's duration; open-ended turns count to now.
func duration(_ from: String?, _ to: String?) -> String {
    guard let a = parseTime(from) else { return "" }
    let b = parseTime(to) ?? Date()
    let s = max(0, Int(b.timeIntervalSince(a)))
    return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
}

func compactNumber(_ n: Int64) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1e3) }
    return String(n)
}
