import Foundation

/// Bytes from the server, in order.
protocol ByteSource: AnyObject {
    func read(_ n: Int) async throws -> [UInt8]
}

/// Area of the framebuffer changed by one update.
struct Dirty: Equatable {
    var x, y, w, h: Int

    func union(_ o: Dirty) -> Dirty {
        let l = min(x, o.x), t = min(y, o.y)
        return Dirty(x: l, y: t, w: max(x + w, o.x + o.w) - l, h: max(y + h, o.y + o.h) - t)
    }
}

/// RFB 3.8 client: handshake (None, VNC password or Apple Remote Desktop sign-in), then framebuffer updates
/// and input. Ported from mob-android (itself from svnc's session).
final class Rfb {
    static let none = 1
    static let vncAuth = 2
    static let ard = 30

    static let raw: Int32 = 0
    static let copyRect: Int32 = 1
    static let zrle: Int32 = 16
    static let desktopSize: Int32 = -223
    static let lastRect: Int32 = -224

    /// 32 bpp, depth 24, little endian, true colour, max 255, shifts R16 G8 B0, padding.
    static let pixelFormat: [UInt8] = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]

    private let input: ByteSource
    private let send: ([UInt8]) -> Void
    private let username: String
    private let password: String
    private(set) var fb: Framebuffer?

    init(input: ByteSource, send: @escaping ([UInt8]) -> Void, username: String, password: String) {
        self.input = input
        self.send = send
        self.username = username
        self.password = password
    }

    private func u8() async throws -> Int { Int(try await input.read(1)[0]) }
    private func u16() async throws -> Int { let b = try await input.read(2); return Int(b[0]) << 8 | Int(b[1]) }
    private func u32() async throws -> UInt32 {
        let b = try await input.read(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
    private func skip(_ n: Int) async throws { if n > 0 { _ = try await input.read(n) } }

    private func reason() async throws -> String {
        let len = Int(try await u32())
        let bytes = try await input.read(min(len, 512))
        return String(decoding: bytes, as: UTF8.self)
    }

    func handshake() async throws -> Framebuffer {
        let version = String(decoding: try await input.read(12), as: UTF8.self)
        guard version.hasPrefix("RFB ") else {
            throw RfbError(message: "Not a VNC server (got \"\(version.trimmingCharacters(in: .whitespacesAndNewlines))\")")
        }
        send(Array("RFB 003.008\n".utf8))

        let count = try await u8()
        if count == 0 { throw RfbError(message: "Screen Sharing refused the connection: \(try await reason())", userFixable: true) }
        let types = try await input.read(count).map(Int.init)
        // Like svnc: a user name signs in to that user's session (ARD); a password alone uses
        // classic VNC Authentication, which lands on the login window.
        let hasPassword = !password.isEmpty
        let signIn = !username.isEmpty && hasPassword
        let chosen: Int
        if signIn && types.contains(Rfb.ard) { chosen = Rfb.ard }
        else if hasPassword && types.contains(Rfb.vncAuth) { chosen = Rfb.vncAuth }
        else if types.contains(Rfb.none) { chosen = Rfb.none }
        else if types.contains(Rfb.ard) {
            throw RfbError(message: "Enter the office Mac's user name and password in Settings → Machines → Edit (Desktop sign-in)", userFixable: true)
        } else if types.contains(Rfb.vncAuth) {
            throw RfbError(message: "Enter the Screen Sharing (VNC) password in Settings → Machines → Edit (Desktop sign-in)", userFixable: true)
        } else { throw RfbError(message: "No supported sign-in method (server offers \(types))") }
        send([UInt8(chosen)])
        if chosen == Rfb.vncAuth {
            send(VncAuth.response(password: password, challenge: try await input.read(16)))
        } else if chosen == Rfb.ard {
            let generator = try await u16()
            let keyLength = try await u16()
            let prime = try await input.read(keyLength)
            let serverKey = try await input.read(keyLength)
            send(Ard.response(generator: generator, prime: prime, serverKey: serverKey, username: username, password: password))
        }
        if try await u32() != 0 {
            let why = (try? await reason()) ?? ""
            let base = chosen == Rfb.ard ? "Sign-in failed: check the Mac user name and password."
                : chosen == Rfb.vncAuth ? "Sign-in failed: check the Screen Sharing (VNC) password." : "Sign-in failed."
            throw RfbError(message: "\(base) \(why)".trimmingCharacters(in: .whitespaces), userFixable: true)
        }

        send([1]) // ClientInit: shared, so the agent's own session is not kicked off
        let width = try await u16()
        let height = try await u16()
        try await skip(16) // server pixel format; we set our own
        try await skip(Int(try await u32())) // desktop name
        let fb = Framebuffer(width: width, height: height)
        self.fb = fb
        send([0, 0, 0, 0] + Rfb.pixelFormat)
        send(Rfb.setEncodings([Rfb.zrle, Rfb.copyRect, Rfb.raw, Rfb.desktopSize, Rfb.lastRect]))
        requestUpdate(incremental: false)
        return fb
    }

    /// Reads server messages until the connection ends.
    func run(onResize: @escaping (Framebuffer) -> Void, onUpdate: @escaping (Framebuffer, Dirty) -> Void) async throws {
        while true {
            let type = try await u8()
            switch type {
            case 0: try await update(onResize, onUpdate)
            case 1: // SetColourMapEntries (unused with true colour)
                try await skip(3)
                try await skip(try await u16() * 6)
            case 2: break // Bell
            case 3: // ServerCutText
                try await skip(3)
                try await skip(Int(try await u32()))
            default: throw RfbError(message: "Unknown VNC message type \(type)")
            }
        }
    }

    private func update(_ onResize: (Framebuffer) -> Void, _ onUpdate: (Framebuffer, Dirty) -> Void) async throws {
        try await skip(1)
        let rects = try await u16()
        var dirty: Dirty?
        for _ in 0..<rects {
            let x = try await u16(), y = try await u16(), w = try await u16(), h = try await u16()
            let enc = Int32(bitPattern: try await u32())
            guard let fb else { throw RfbError(message: "Update before handshake") }
            switch enc {
            case Rfb.raw: fb.raw(x: x, y: y, w: w, h: h, data: try await input.read(w * h * 4))
            case Rfb.copyRect: fb.copyRect(x: x, y: y, w: w, h: h, srcX: try await u16(), srcY: try await u16())
            case Rfb.zrle: try fb.zrle(x: x, y: y, w: w, h: h, compressed: try await input.read(Int(try await u32())))
            case Rfb.desktopSize:
                let resized = Framebuffer(width: w, height: h)
                self.fb = resized
                onResize(resized)
                dirty = nil
                continue
            case Rfb.lastRect: break
            default: throw RfbError(message: "Unexpected VNC encoding \(enc)")
            }
            if enc == Rfb.lastRect { break }
            if w > 0 && h > 0 {
                let r = Dirty(x: x, y: y, w: w, h: h)
                dirty = dirty?.union(r) ?? r
            }
        }
        if let dirty, let fb { onUpdate(fb, dirty) }
        requestUpdate(incremental: true)
    }

    func requestUpdate(incremental: Bool) {
        guard let fb else { return }
        send([3, incremental ? 1 : 0] + Rfb.u16(0) + Rfb.u16(0) + Rfb.u16(fb.width) + Rfb.u16(fb.height))
    }

    func pointer(x: Int, y: Int, buttons: Int) {
        send([5, UInt8(truncatingIfNeeded: buttons)] + Rfb.u16(x) + Rfb.u16(y))
    }

    func key(_ keysym: UInt32, down: Bool) {
        send([4, down ? 1 : 0, 0, 0] + Rfb.u32(keysym))
    }

    static func setEncodings(_ encodings: [Int32]) -> [UInt8] {
        [2, 0] + u16(encodings.count) + encodings.flatMap { u32(UInt32(bitPattern: $0)) }
    }

    static func u16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
    static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }
}
