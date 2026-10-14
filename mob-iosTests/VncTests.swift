import XCTest
@testable import mob_ios

private func hex(_ s: String) -> [UInt8] {
    var out = [UInt8]()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

/// Canned server bytes for the RFB reader.
private final class Bytes: ByteSource {
    var data: [UInt8]
    init(_ data: [UInt8]) { self.data = data }
    func read(_ n: Int) async throws -> [UInt8] {
        guard data.count >= n else { throw RfbError(message: "EOF") }
        defer { data.removeFirst(n) }
        return Array(data.prefix(n))
    }
}

final class VncTests: XCTestCase {
    // Fixtures from Python: pow(b, e, p) with a 512-bit odd p.
    let p = hex("b6f675cc81e74ef5e8e25d940ed904759531985d5d9dc9f81818e811892f902bd23f0824128b2f330c5c7fd0a6a3a4506513270e269e0d37f2a74de452e6b439")
    let b = hex("000a170b39263059f28c105d1fb17c2390c192cfd3ac94af0f21ddb66cad4a268d116ece1738f7d93d9c172411e20b8f6b0d549b6f03675a1600a35a099950d8")
    let e = hex("6b4cb2424a23d5962217beaddbc496cb8e81973e0becd7b03898d190f9ebdacc0cb1e29c658cda1495e60af593bd04cf0fd630f1f29d0da9953f48f1a09f76b5")

    func testModPowMatchesPython() {
        XCTAssertEqual(BigUInt.modPow(b, e, p), hex("b454a42ee67deb20b3218c527c3fb3a8c6ae43cac5d9c6dcf1ac85b711607fe598d142719ee3e5acc30028e11452f5c45481628b477669cc1408b10d96e3198f"))
        XCTAssertEqual(BigUInt.modPow([2], e, p), hex("8f2f4a40e4a9eab16d882ad63f2c9ff2660e8235eff238e5a4422538b93b886f812ea0ed49d7102e4c78114ad8d8f80a2b7e9ade0a8eacb5578657d8c064361b"))
    }

    func testArdResponseDecryptsOnTheServerSide() {
        let serverPrivate = Array(e.prefix(60))
        let serverPublic = BigUInt.modPow([2], serverPrivate, p)
        let out = Ard.response(generator: 2, prime: p, serverKey: serverPublic, username: "alice", password: "s3cret")
        XCTAssertEqual(out.count, 128 + p.count)
        let clientPublic = Array(out[128...])
        let secret = BigUInt.modPow(clientPublic, serverPrivate, p)
        let plain = Ard.aesEcb(Ard.md5(secret), Array(out[0..<128]), encrypt: false)
        XCTAssertEqual(String(decoding: plain.prefix { $0 != 0 }, as: UTF8.self), "alice")
        XCTAssertEqual(String(decoding: plain[64...].prefix { $0 != 0 }, as: UTF8.self), "s3cret")
    }

    func testInflateAcrossSyncFlushes() throws {
        // One zlib stream, two sync-flushed chunks (as ZRLE sends rectangles); from Python's zlib.
        let z = Inflater()
        XCTAssertEqual(String(decoding: try z.inflate(hex("789cca48cdc9c957c81825892001000000ffff")), as: UTF8.self), String(repeating: "hello ", count: 50))
        XCTAssertEqual(String(decoding: try z.inflate(hex("2acf2fca49511c3924000000ffff")), as: UTF8.self), String(repeating: "world!", count: 40))
    }

    private func argb(_ r: UInt32, _ g: UInt32, _ b: UInt32) -> UInt32 { 0xFF00_0000 | r << 16 | g << 8 | b }
    private func cpixel(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] { [b, g, r] }

    func testZrleSolidPaletteAndRunTiles() throws {
        let fb = Framebuffer(width: 6, height: 2)
        let red = argb(255, 0, 0), blue = argb(0, 0, 255)
        try fb.zrleTiles(x: 0, y: 0, w: 2, h: 2, data: [1] + cpixel(255, 0, 0))
        // Packed palette of 2: one bit per pixel, rows padded to bytes: row0 = 1,0 row1 = 0,1
        try fb.zrleTiles(x: 2, y: 0, w: 2, h: 2, data: [2] + cpixel(255, 0, 0) + cpixel(0, 0, 255) + [0x80, 0x40])
        // Palette RLE: index 1 for 3 pixels (run byte 2), then index 0 once.
        try fb.zrleTiles(x: 4, y: 0, w: 2, h: 2, data: [130] + cpixel(255, 0, 0) + cpixel(0, 0, 255) + [0x81, 2, 0])
        XCTAssertEqual(fb.pixels, [red, red, blue, red, blue, blue, red, red, red, blue, blue, red])
    }

    private func server(_ types: [UInt8]) -> [UInt8] {
        Array("RFB 003.889\n".utf8) + [UInt8(types.count)] + types + [0, 0, 0, 0] +
            Rfb.u16(1440) + Rfb.u16(900) + [UInt8](repeating: 0, count: 16) + [0, 0, 0, 3] + Array("Mac".utf8)
    }

    func testHandshakeWithoutSignIn() async throws {
        var sent: [[UInt8]] = []
        let fb = try await Rfb(input: Bytes(server([1])), send: { sent.append($0) }, username: "", password: "").handshake()
        XCTAssertEqual(fb.width, 1440)
        XCTAssertEqual(fb.height, 900)
        XCTAssertEqual(String(decoding: sent[0], as: UTF8.self), "RFB 003.008\n")
        XCTAssertEqual(sent[1], [1])
        XCTAssertEqual(sent[3][0], 0) // SetPixelFormat
        XCTAssertEqual(sent[4][0], 2) // SetEncodings
        XCTAssertEqual(sent[5][0], 3) // first full update request
    }

    func testDesMatchesTheStandardTestVector() {
        XCTAssertEqual(VncAuth.des(hex("133457799bbcdff1"), hex("0123456789abcdef")), hex("85e813540f0ab405"))
        XCTAssertEqual(VncAuth.reverseBits(1), 0x80)
        XCTAssertEqual(VncAuth.reverseBits(0x61), 0x86)
    }

    func testPasswordOnlyUsesVncAuth() async throws {
        let challenge = (0..<16).map(UInt8.init)
        let bytes = Array("RFB 003.889\n".utf8) + [2, 30, 2] + challenge + [0, 0, 0, 0] +
            Rfb.u16(800) + Rfb.u16(600) + [UInt8](repeating: 0, count: 16) + [0, 0, 0, 0]
        var sent: [[UInt8]] = []
        _ = try await Rfb(input: Bytes(bytes), send: { sent.append($0) }, username: "", password: "secret").handshake()
        XCTAssertEqual(sent[1], [2])
        XCTAssertEqual(sent[2], VncAuth.response(password: "secret", challenge: challenge))
    }

    func testArdOnlyServerAsksForCredentials() async {
        do {
            _ = try await Rfb(input: Bytes(server([30])), send: { _ in }, username: "", password: "").handshake()
            XCTFail("expected an error")
        } catch let e as RfbError {
            XCTAssertTrue(e.userFixable)
            XCTAssertTrue(e.message.contains("Settings"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
