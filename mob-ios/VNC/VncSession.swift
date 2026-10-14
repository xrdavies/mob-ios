import CoreGraphics
import Foundation
import Observation

enum VncStatus { case idle, connecting, connected, error }

struct VncState: Equatable {
    var status: VncStatus = .idle
    var detail = ""
    var width = 0
    var height = 0
    /// Touches and keys reach the office Mac only while true (full-screen Control mode).
    var control = false
}

/// The single live-view connection to the office Mac, through mobd's /vnc WebSocket relay.
/// The thumbnail and the full-screen view draw the same image; only the full-screen view sends
/// input, and only in Control mode.
@MainActor @Observable
final class VncSession {
    private(set) var state = VncState()
    private(set) var image: CGImage?
    /// Modifiers latched from the keys bar; they apply to the next key, then release.
    private(set) var modifiers: [UInt32] = []

    @ObservationIgnored private var conn: Connection?

    static let buttonLeft = 1
    static let buttonRight = 4
    static let wheelUp = 1 << 3, wheelDown = 1 << 4, wheelLeft = 1 << 5, wheelRight = 1 << 6

    static let xkBackspace: UInt32 = 0xFF08, xkTab: UInt32 = 0xFF09, xkReturn: UInt32 = 0xFF0D, xkEscape: UInt32 = 0xFF1B
    static let xkLeft: UInt32 = 0xFF51, xkUp: UInt32 = 0xFF52, xkRight: UInt32 = 0xFF53, xkDown: UInt32 = 0xFF54
    static let xkShift: UInt32 = 0xFFE1, xkControl: UInt32 = 0xFFE3, xkAlt: UInt32 = 0xFFE9
    /// macOS Screen Sharing maps Meta to Command (as svnc and the desktop app send it).
    static let xkMeta: UInt32 = 0xFFE7
    private static let shifted = Set("~!@#$%^&*()_+{}|:\"<>?")

    func connect(url: URL, username: String, password: String) {
        disconnect()
        state = VncState(status: .connecting, detail: "Connecting…")
        let c = Connection(url: url, username: username, password: password, owner: self)
        conn = c
        c.start()
    }

    func disconnect() {
        guard let c = conn else { return }
        conn = nil
        c.close()
        image = nil
        state = VncState(status: .idle, detail: "Disconnected")
    }

    func setControl(_ on: Bool) {
        state.control = on && state.status == .connected
        if !on { modifiers = [] }
    }

    // MARK: Called by the connection (on the main actor)

    fileprivate func connected(_ c: Connection, width: Int, height: Int) {
        guard conn === c else { return }
        let control = state.control && state.status == .connected
        state = VncState(status: .connected, width: width, height: height, control: control)
    }

    fileprivate func frame(_ c: Connection, _ image: CGImage) {
        guard conn === c else { return }
        self.image = image
    }

    fileprivate func failed(_ c: Connection, _ message: String) {
        guard conn === c else { return }
        conn = nil
        image = nil
        state = VncState(status: .error, detail: message)
    }

    // MARK: Input (Control mode only)

    private var rfb: Rfb? { state.control ? conn?.rfb : nil }

    func pointer(x: Int, y: Int, buttons: Int) { rfb?.pointer(x: x, y: y, buttons: buttons) }

    func click(x: Int, y: Int, button: Int = buttonLeft) {
        pointer(x: x, y: y, buttons: 0)
        pointer(x: x, y: y, buttons: button)
        pointer(x: x, y: y, buttons: 0)
    }

    /// Scroll wheel: one notch per step; negative dy scrolls up, negative dx left.
    func scroll(x: Int, y: Int, dx: Int, dy: Int) {
        guard let rfb else { return }
        func notch(_ mask: Int, _ n: Int) {
            for _ in 0..<n {
                rfb.pointer(x: x, y: y, buttons: mask)
                rfb.pointer(x: x, y: y, buttons: 0)
            }
        }
        if dy != 0 { notch(dy < 0 ? Self.wheelUp : Self.wheelDown, abs(dy)) }
        if dx != 0 { notch(dx < 0 ? Self.wheelLeft : Self.wheelRight, abs(dx)) }
    }

    func toggleModifier(_ keysym: UInt32) {
        if let i = modifiers.firstIndex(of: keysym) { modifiers.remove(at: i) } else { modifiers.append(keysym) }
    }

    /// Presses `keysym` with the latched modifiers (plus `extra`), then releases everything.
    private func press(_ rfb: Rfb, _ keysym: UInt32, extra: [UInt32] = []) {
        let mods = modifiers + extra
        mods.forEach { rfb.key($0, down: true) }
        rfb.key(keysym, down: true)
        rfb.key(keysym, down: false)
        mods.reversed().forEach { rfb.key($0, down: false) }
        modifiers = []
    }

    func tapKey(_ keysym: UInt32) {
        guard let rfb else { return }
        press(rfb, keysym)
    }

    /// Types one character from the phone's keyboard.
    func type(_ c: Character) {
        guard let rfb else { return }
        if c == "\n" { return press(rfb, Self.xkReturn) }
        guard let scalar = c.unicodeScalars.first else { return }
        // With a latched modifier (⌘C) the key goes as its plain letter.
        let shortcut = !modifiers.isEmpty
        let base = shortcut ? (Character(String(c).lowercased()).unicodeScalars.first ?? scalar) : scalar
        let keysym = base.value < 0x100 ? base.value : 0x0100_0000 | base.value
        let shift = !shortcut && (c.isUppercase || Self.shifted.contains(c))
        press(rfb, keysym, extra: shift ? [Self.xkShift] : [])
    }

    /// Types text from the phone's clipboard (no shared clipboard with the Mac).
    func typeText(_ text: String) {
        guard rfb != nil else { return }
        text.prefix(5000).forEach { type($0) }
    }
}

/// Reads WebSocket messages as one ordered byte stream for the RFB reader.
private final class SocketSource: ByteSource {
    let task: URLSessionWebSocketTask
    private var buffer = [UInt8]()
    private var pos = 0

    init(_ task: URLSessionWebSocketTask) { self.task = task }

    func read(_ n: Int) async throws -> [UInt8] {
        while buffer.count - pos < n {
            switch try await task.receive() {
            case .data(let d):
                if pos > 0 {
                    buffer.removeFirst(pos)
                    pos = 0
                }
                buffer.append(contentsOf: d)
            case .string(let s): buffer.append(contentsOf: Array(s.utf8))
            @unknown default: break
            }
        }
        defer { pos += n }
        return Array(buffer[pos..<(pos + n)])
    }
}

/// One live-view connection. RFB runs on its own task; results hop to the main actor.
private final class Connection: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let username: String
    private let password: String
    private weak var owner: VncSession?
    private var reader: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private let outbox: AsyncStream<[UInt8]>.Continuation
    private let outgoing: AsyncStream<[UInt8]>
    private var closed = false
    /// Set once the handshake is done; input goes through it.
    private(set) var rfb: Rfb?

    init(url: URL, username: String, password: String, owner: VncSession) {
        task = URLSession.shared.webSocketTask(with: url, protocols: ["binary"])
        task.maximumMessageSize = 16 << 20
        self.username = username
        self.password = password
        self.owner = owner
        (outgoing, outbox) = AsyncStream.makeStream(of: [UInt8].self)
    }

    func start() {
        task.resume()
        // One sender keeps messages in order.
        sender = Task { [task, outgoing] in
            for await bytes in outgoing { try? await task.send(.data(Data(bytes))) }
        }
        reader = Task.detached { [self] in await self.run() }
    }

    func close() {
        closed = true
        outbox.finish()
        reader?.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }

    private func run() async {
        let rfb = Rfb(input: SocketSource(task), send: { [outbox] in outbox.yield($0) }, username: username, password: password)
        do {
            let fb = try await rfb.handshake()
            self.rfb = rfb
            await publishConnected(fb)
            // Updates are paced by the request/response cycle, so every one is drawn.
            try await rfb.run(
                onResize: { [weak self] fb in Task { await self?.publishConnected(fb) } },
                onUpdate: { [weak self] fb, _ in
                    guard let self, let image = Connection.image(fb) else { return }
                    Task { await self.publish(image) }
                }
            )
        } catch {
            if closed { return }
            let message: String
            if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
                message = http.statusCode == 502
                    ? "Screen Sharing is off on the office Mac (System Settings → General → Sharing)"
                    : "Live view failed: HTTP \(http.statusCode)"
            } else if let e = error as? RfbError {
                message = e.message
            } else {
                message = readable(error)
            }
            await MainActor.run { owner?.failed(self, message) }
        }
    }

    @MainActor private func publishConnected(_ fb: Framebuffer) { owner?.connected(self, width: fb.width, height: fb.height) }
    @MainActor private func publish(_ image: CGImage) { owner?.frame(self, image) }

    static func image(_ fb: Framebuffer) -> CGImage? {
        let data = fb.pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: fb.width, height: fb.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: fb.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
