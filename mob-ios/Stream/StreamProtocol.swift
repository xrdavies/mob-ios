import CoreGraphics
import Foundation

// The live desktop protocol (mobd docs/desktop-streaming.md), kept free of WebRTC and UIKit so it
// can be unit tested: quality profiles, control messages, input messages, points normalized to the
// display, and the readout from WebRTC statistics. Mirrors the desktop app's stream.ts/liveInput.ts.

/// mobd's quality profiles (internal/stream/stream.go).
enum LiveQuality: String, Codable, CaseIterable, Identifiable {
    case auto, high, low
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .high: "High"
        case .low: "Low"
        }
    }

    var hint: String {
        switch self {
        case .auto: "Starts at 720p and follows the connection, up to 1080p at 30 fps and 6 Mbps"
        case .high: "Starts sharp at 3 Mbps, then follows the connection, up to 1080p at 30 fps and 6 Mbps"
        case .low: "For slow or metered links: up to 720p at 15 fps and 1 Mbps"
        }
    }
}

/// Pixels to ask mobd for: points × screen scale, rounded up to 64 so small changes reuse the size.
func devicePixels(_ points: CGFloat, scale: CGFloat) -> Int {
    let px = Int((points * max(scale, 1) / 64).rounded(.up)) * 64
    return min(max(px, 64), 8192)
}

// MARK: - Control channel (from mobd)

enum ControlMessage: Equatable {
    case stats(kbps: Int, width: Int, height: Int, fps: Int, loss: Double, rttMs: Int)
    case ended(String)
    case error(about: String, message: String)
    case cursor(x: Double, y: Double)

    /// A message from mobd's `control` channel; nil for anything unknown or malformed.
    static func parse(_ data: Data) -> ControlMessage? {
        guard let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func num(_ k: String) -> Double { (m[k] as? NSNumber)?.doubleValue ?? 0 }
        func str(_ k: String) -> String { m[k] as? String ?? "" }
        switch m["t"] as? String {
        case "stats":
            return .stats(kbps: Int(num("kbps")), width: Int(num("width")), height: Int(num("height")), fps: Int(num("fps")),
                          loss: num("loss"), rttMs: Int(num("rttMs")))
        case "ended": return .ended(str("message").isEmpty ? "The office Mac ended the live view" : str("message"))
        case "error": return .error(about: str("about"), message: str("message"))
        case "cursor": return .cursor(x: num("x"), y: num("y"))
        default: return nil
        }
    }
}

// MARK: - Input (to mobd)

enum MouseButton: String { case left, middle, right }

/// Messages on the `input` (reliable) and `pointer` (unreliable) channels.
enum InputMessage: Equatable {
    case move(x: Double, y: Double)
    case button(x: Double, y: Double, button: MouseButton, down: Bool)
    case key(code: String, down: Bool)
    case text(String)
    case scroll(x: Double, y: Double, dx: Double, dy: Double)
    case keyframe
    case resize(maxWidth: Int, maxHeight: Int)

    /// Moves go on `pointer` (latest wins); everything else on `input`, resize on `control`.
    var channel: String {
        switch self {
        case .move: "pointer"
        case .keyframe, .resize: "control"
        default: "input"
        }
    }

    var json: Data {
        let r = { (v: Double) in (v * 10000).rounded() / 10000 }
        let o: [String: Any] = switch self {
        case .move(let x, let y): ["t": "move", "x": r(x), "y": r(y)]
        case .button(let x, let y, let b, let down): ["t": "button", "x": r(x), "y": r(y), "button": b.rawValue, "down": down]
        case .key(let code, let down): ["t": "key", "code": code, "down": down]
        case .text(let s): ["t": "text", "text": s]
        case .scroll(let x, let y, let dx, let dy): ["t": "scroll", "x": r(x), "y": r(y), "dx": dx.rounded(), "dy": dy.rounded()]
        case .keyframe: ["t": "keyframe"]
        case .resize(let w, let h): ["t": "resize", "maxWidth": w, "maxHeight": h]
        }
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }
}

/// A point in an aspect-fit picture of `video` inside `box`, normalized and clamped to the picture;
/// `inside` is false over the letterbox bars.
func normalizePoint(_ p: CGPoint, in box: CGSize, video: CGSize) -> (x: Double, y: Double, inside: Bool)? {
    guard video.width > 0, video.height > 0, box.width > 0, box.height > 0 else { return nil }
    let s = min(box.width / video.width, box.height / video.height)
    let w = video.width * s, h = video.height * s
    let x = Double((p.x - (box.width - w) / 2) / w)
    let y = Double((p.y - (box.height - h) / 2) / h)
    return (min(max(x, 0), 1), min(max(y, 0), 1), (0...1).contains(x) && (0...1).contains(y))
}

/// Web `KeyboardEvent.code` for a character from the phone keyboard when sent with a held modifier
/// (⌘C as KeyC); nil when it has no single key.
func webKeyCode(for c: Character) -> String? {
    let s = String(c).lowercased()
    guard s.count == 1, let u = s.unicodeScalars.first else { return nil }
    if ("a"..."z").contains(s) { return "Key" + s.uppercased() }
    if ("0"..."9").contains(s) { return "Digit" + s }
    let punct: [Character: String] = [
        " ": "Space", "-": "Minus", "=": "Equal", "[": "BracketLeft", "]": "BracketRight", "\\": "Backslash",
        ";": "Semicolon", "'": "Quote", ",": "Comma", ".": "Period", "/": "Slash", "`": "Backquote",
    ]
    return punct[Character(u)]
}

private let modifierCodes: Set<String> = ["ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight", "AltLeft", "AltRight", "MetaLeft", "MetaRight", "CapsLock", "Fn"]

/// Keys and buttons held on the office Mac, so they can all be released when control ends or the
/// app goes to the background (a dropped touch never sends its button-up).
struct HeldInput {
    private(set) var keys: [String] = []
    private(set) var buttons: [MouseButton] = []
    private var last = (x: 0.5, y: 0.5)

    mutating func point(_ x: Double, _ y: Double) { last = (x, y) }

    mutating func keyDown(_ code: String) -> [InputMessage] {
        if !keys.contains(code) { keys.append(code) }
        return [.key(code: code, down: true)]
    }

    mutating func keyUp(_ code: String) -> [InputMessage] {
        guard let i = keys.firstIndex(of: code) else { return [] }
        keys.remove(at: i)
        return [.key(code: code, down: false)]
    }

    mutating func buttonDown(_ b: MouseButton, _ x: Double, _ y: Double) -> [InputMessage] {
        point(x, y)
        if !buttons.contains(b) { buttons.append(b) }
        return [.button(x: x, y: y, button: b, down: true)]
    }

    mutating func buttonUp(_ b: MouseButton, _ x: Double, _ y: Double) -> [InputMessage] {
        point(x, y)
        guard let i = buttons.firstIndex(of: b) else { return [] }
        buttons.remove(at: i)
        return [.button(x: x, y: y, button: b, down: false)]
    }

    /// Other keys first, then modifiers, then buttons at the last position.
    mutating func releaseAll() -> [InputMessage] {
        let order = keys.filter { !modifierCodes.contains($0) } + keys.filter { modifierCodes.contains($0) }
        var out = order.map { InputMessage.key(code: $0, down: false) }
        out += buttons.map { .button(x: last.x, y: last.y, button: $0, down: false) }
        keys = []
        buttons = []
        return out
    }
}

// MARK: - Readout

enum Network: String { case lan = "LAN", tailscale = "Tailscale", internet = "Internet", relay = "relay" }

/// Where the peer's address lives: Tailscale (100.64.0.0/10, fd7a:115c:a1e0::/48), a private LAN, or beyond.
func networkOf(_ address: String, candidateType: String? = nil) -> Network {
    if candidateType == "relay" { return .relay }
    let a = address.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let parts = a.split(separator: ".").compactMap { Int($0) }
    if parts.count == 4 {
        let (x, y) = (parts[0], parts[1])
        if x == 100, (64..<128).contains(y) { return .tailscale }
        if x == 10 || x == 127 || (x == 172 && (16..<32).contains(y)) || (x == 192 && y == 168) || (x == 169 && y == 254) { return .lan }
        return .internet
    }
    if a.hasPrefix("fd7a:115c:a1e0:") { return .tailscale }
    if ["fe8", "fe9", "fea", "feb", "fc", "fd"].contains(where: a.hasPrefix) || a == "::1" { return .lan }
    return .internet
}

/// Candidate addresses in an SDP keyed "protocol:port", for stats that leave the address out.
func candidateAddresses(_ sdp: String) -> [String: String] {
    var out: [String: String] = [:]
    for line in sdp.split(whereSeparator: \.isNewline) where line.hasPrefix("a=candidate:") {
        let f = line.split(separator: " ")
        guard f.count >= 8, f[6] == "typ" else { continue }
        out["\(f[2].lowercased()):\(f[5])"] = String(f[4])
    }
    return out
}

struct StatsSample: Equatable {
    var at: TimeInterval
    var bytes: Double
    var frames: Double
}

struct Readout: Equatable {
    var transport = "WebRTC"
    /// Video received, kilobytes per second.
    var kBps = 0
    /// Frames decoded per second.
    var fps = 0
    var network: Network?
    var rttMs: Int?
}

/// One statistics report (id → type and values) against the previous sample.
func readStats(_ report: [String: (type: String, values: [String: Any])], prev: StatsSample?, now: TimeInterval,
               remoteAddresses: [String: String] = [:]) -> (sample: StatsSample, readout: Readout) {
    func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
    let video = report.values.first { $0.type == "inbound-rtp" && (($0.values["kind"] ?? $0.values["mediaType"]) as? String) == "video" }
    let sample = StatsSample(at: now, bytes: num(video?.values["bytesReceived"]) ?? 0, frames: num(video?.values["framesDecoded"]) ?? 0)
    var r = Readout()
    if let prev, now > prev.at {
        let s = now - prev.at
        r.kBps = max(0, Int(((sample.bytes - prev.bytes) / 1000 / s).rounded()))
        r.fps = max(0, Int(((sample.frames - prev.frames) / s).rounded()))
    }
    let transport = report.values.first { $0.type == "transport" && $0.values["selectedCandidatePairId"] != nil }
    let pair = (transport?.values["selectedCandidatePairId"] as? String).flatMap { report[$0] }
        ?? report.values.first { $0.type == "candidate-pair" && (($0.values["selected"] as? NSNumber)?.boolValue == true
            || (($0.values["nominated"] as? NSNumber)?.boolValue == true && ($0.values["state"] as? String) == "succeeded")) }
    if let pair {
        let remote = (pair.values["remoteCandidateId"] as? String).flatMap { report[$0] }
        let local = (pair.values["localCandidateId"] as? String).flatMap { report[$0] }
        let key = "\(((remote?.values["protocol"] as? String) ?? "udp").lowercased()):\(num(remote?.values["port"]).map { String(Int($0)) } ?? "")"
        let address = (remote?.values["address"] as? String) ?? (remote?.values["ip"] as? String) ?? remoteAddresses[key] ?? ""
        let relayed = remote?.values["candidateType"] as? String == "relay" || local?.values["candidateType"] as? String == "relay"
        if !address.isEmpty || relayed { r.network = networkOf(address, candidateType: relayed ? "relay" : nil) }
        if let rtt = num(pair.values["currentRoundTripTime"]) { r.rttMs = Int((rtt * 1000).rounded()) }
    }
    return (sample, r)
}

/// "1408×792 · 30 fps · 380 kB/s · WebRTC · LAN".
func readoutText(width: Int, height: Int, _ r: Readout?) -> String {
    var parts = ["\(width)×\(height)"]
    if let r { parts += ["\(r.fps) fps", "\(r.kBps) kB/s", r.transport] }
    if let n = r?.network { parts.append(n.rawValue) }
    return parts.joined(separator: " · ")
}

/// Signal bars (1-3): loss reported by mobd, round-trip time measured here.
func signalBars(loss: Double, rttMs: Int?) -> Int {
    let rtt = rttMs ?? 0
    if loss > 0.1 || rtt > 400 { return 1 }
    if loss > 0.02 || rtt > 150 { return 2 }
    return 3
}
