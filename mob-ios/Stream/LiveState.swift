import Foundation

enum LiveStatus { case idle, connecting, connected, error }

/// The live view's status and picture size, shared by the thumbnail and the full-screen view.
struct LiveState: Equatable {
    var status: LiveStatus = .idle
    var detail = ""
    var width = 0
    var height = 0
    /// Touches and keys reach the office Mac only while true (full-screen Control mode).
    var control = false
}
