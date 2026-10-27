import CoreMedia
import XCTest
@testable import mob_ios

final class StreamTests: XCTestCase {
    func testQualityProfiles() {
        XCTAssertEqual(LiveQuality.auto.rawValue, "auto")
        XCTAssertEqual(LiveQuality.high.rawValue, "high")
        XCTAssertEqual(LiveQuality.low.rawValue, "low")
        XCTAssertEqual(LiveQuality.allCases.count, 3)
    }

    func testDevicePixels() {
        XCTAssertEqual(devicePixels(100, scale: 2), 256) // 200 → 256
        XCTAssertEqual(devicePixels(100, scale: 3), 320) // 300 → 320
        XCTAssertEqual(devicePixels(1000, scale: 1), 1024) // 1000 → 1024
        XCTAssertEqual(devicePixels(30, scale: 1), 64) // min
        XCTAssertEqual(devicePixels(10000, scale: 1), 8192) // max
    }

    func testDesktopSizesKeepFullScreenPriorityAndIgnoreStaleViews() {
        var sizes = DesktopSizes()
        let thumbnail = UUID(), replacement = UUID(), full = UUID()
        XCTAssertNil(sizes.size)
        sizes.update(thumbnail, size: CGSize(width: 640, height: 360), fullScreen: false)
        sizes.update(full, size: CGSize(width: 1280, height: 960), fullScreen: true)
        sizes.update(thumbnail, size: CGSize(width: 1920, height: 1080), fullScreen: false)
        XCTAssertEqual(sizes.size, CGSize(width: 1280, height: 960))
        sizes.update(full, size: CGSize(width: 960, height: 1280), fullScreen: true)
        XCTAssertEqual(sizes.size, CGSize(width: 960, height: 1280))
        sizes.update(full, size: .zero, fullScreen: true)
        XCTAssertEqual(sizes.size, CGSize(width: 960, height: 1280))
        sizes.remove(full)
        XCTAssertEqual(sizes.size, CGSize(width: 1920, height: 1080))
        sizes.update(replacement, size: CGSize(width: 800, height: 600), fullScreen: false)
        sizes.remove(thumbnail)
        XCTAssertEqual(sizes.size, CGSize(width: 800, height: 600))
        sizes.remove(replacement)
        XCTAssertTrue(sizes.isEmpty)
    }

    func testControlMessageParsing() {
        let stats = ControlMessage.parse("""
        {"t":"stats","kbps":1200,"width":1920,"height":1080,"fps":30,"loss":0.01,"rttMs":25}
        """.data(using: .utf8)!)
        XCTAssertEqual(stats, .stats(kbps: 1200, width: 1920, height: 1080, fps: 30, loss: 0.01, rttMs: 25))

        let ended = ControlMessage.parse("""
        {"t":"ended","message":"Session closed"}
        """.data(using: .utf8)!)
        XCTAssertEqual(ended, .ended("Session closed"))

        let error = ControlMessage.parse("""
        {"t":"error","about":"resize","message":"too large"}
        """.data(using: .utf8)!)
        XCTAssertEqual(error, .error(about: "resize", message: "too large"))

        let cursor = ControlMessage.parse("""
        {"t":"cursor","x":0.5,"y":0.75}
        """.data(using: .utf8)!)
        XCTAssertEqual(cursor, .cursor(x: 0.5, y: 0.75))

        XCTAssertNil(ControlMessage.parse("""
        {"t":"unknown"}
        """.data(using: .utf8)!))
    }

    func testInputMessages() {
        let move = InputMessage.move(x: 0.5, y: 0.5)
        XCTAssertEqual(move.channel, "pointer")
        XCTAssert(String(data: move.json, encoding: .utf8)!.contains("\"t\":\"move\""))

        let click = InputMessage.button(x: 0.5, y: 0.5, button: .left, down: true)
        XCTAssertEqual(click.channel, "input")
        XCTAssert(String(data: click.json, encoding: .utf8)!.contains("\"button\":\"left\""))

        let key = InputMessage.key(code: "KeyA", down: true)
        XCTAssertEqual(key.channel, "input")

        let text = InputMessage.text("hello")
        XCTAssert(String(data: text.json, encoding: .utf8)!.contains("\"text\":\"hello\""))

        let scroll = InputMessage.scroll(x: 0.5, y: 0.5, dx: 10, dy: -20)
        XCTAssertEqual(scroll.channel, "input")

        let resize = InputMessage.resize(maxWidth: 1920, maxHeight: 1080)
        XCTAssertEqual(resize.channel, "control")
    }

    func testNormalizePoint() {
        // 1920×1080 video in 1920×1080 box: no letterbox
        let a = normalizePoint(CGPoint(x: 960, y: 540), in: CGSize(width: 1920, height: 1080), video: CGSize(width: 1920, height: 1080))!
        XCTAssertEqual(a.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(a.y, 0.5, accuracy: 0.01)
        XCTAssertTrue(a.inside)

        // 1920×1080 video in 1920×1200 box: letterbox top/bottom
        let b = normalizePoint(CGPoint(x: 960, y: 600), in: CGSize(width: 1920, height: 1200), video: CGSize(width: 1920, height: 1080))!
        XCTAssertEqual(b.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(b.y, 0.5, accuracy: 0.01)
        XCTAssertTrue(b.inside)

        // Point in the letterbox
        let c = normalizePoint(CGPoint(x: 960, y: 10), in: CGSize(width: 1920, height: 1200), video: CGSize(width: 1920, height: 1080))!
        XCTAssertFalse(c.inside)
        XCTAssertEqual(c.y, 0.0) // clamped
    }

    func testZoomedAndPannedInputMatchesTheVisibleDesktop() {
        let box = CGSize(width: 400, height: 250)
        let video = CGSize(width: 1600, height: 1000)
        let zoomed = normalizePoint(CGPoint(x: 300, y: 125), in: box, video: video, scale: 2)!
        XCTAssertEqual(zoomed.x, 0.625, accuracy: 0.0001)
        let panned = normalizePoint(CGPoint(x: 300, y: 125), in: box, video: video, scale: 2, offset: CGSize(width: 100, height: 0))!
        XCTAssertEqual(panned.x, 0.5, accuracy: 0.0001)
        XCTAssertTrue(panned.inside)
        XCTAssertNil(normalizePoint(.zero, in: box, video: video, scale: 0))
    }

    func testWebKeyCode() {
        XCTAssertEqual(webKeyCode(for: "a"), "KeyA")
        XCTAssertEqual(webKeyCode(for: "Z"), "KeyZ")
        XCTAssertEqual(webKeyCode(for: "5"), "Digit5")
        XCTAssertEqual(webKeyCode(for: " "), "Space")
        XCTAssertEqual(webKeyCode(for: "-"), "Minus")
        XCTAssertEqual(webKeyCode(for: "="), "Equal")
        XCTAssertNil(webKeyCode(for: "😀"))
    }

    func testHeldInput() {
        var held = HeldInput()
        XCTAssertTrue(held.keys.isEmpty)
        XCTAssertTrue(held.buttons.isEmpty)

        let down = held.keyDown("KeyA")
        XCTAssertEqual(down.count, 1)
        XCTAssertEqual(held.keys, ["KeyA"])

        let up = held.keyUp("KeyA")
        XCTAssertEqual(up.count, 1)
        XCTAssertTrue(held.keys.isEmpty)

        _ = held.keyDown("MetaLeft")
        _ = held.keyDown("KeyC")
        _ = held.buttonDown(.left, 0.5, 0.5)
        let released = held.releaseAll()
        XCTAssertTrue(released.count >= 3) // KeyC, MetaLeft, left button
        XCTAssertTrue(held.keys.isEmpty)
        XCTAssertTrue(held.buttons.isEmpty)
    }

    func testNetworkDetection() {
        XCTAssertEqual(networkOf("100.64.5.10"), .tailscale)
        XCTAssertEqual(networkOf("192.168.1.1"), .lan)
        XCTAssertEqual(networkOf("10.0.0.1"), .lan)
        XCTAssertEqual(networkOf("8.8.8.8"), .internet)
        XCTAssertEqual(networkOf("fd7a:115c:a1e0::1"), .tailscale)
        XCTAssertEqual(networkOf("fe80::1"), .lan)
        XCTAssertEqual(networkOf("any", candidateType: "relay"), .relay)
    }

    func testCandidateAddresses() {
        let sdp = """
        v=0
        a=candidate:1 1 udp 2130706431 192.168.1.100 54321 typ host
        a=candidate:2 1 tcp 1234 10.0.0.5 9 typ host
        """
        let addrs = candidateAddresses(sdp)
        XCTAssertEqual(addrs["udp:54321"], "192.168.1.100")
        XCTAssertEqual(addrs["tcp:9"], "10.0.0.5")
    }

    func testReadStats() {
        let report: [String: (type: String, values: [String: Any])] = [
            "video": (type: "inbound-rtp", values: ["kind": "video", "bytesReceived": 100000, "framesDecoded": 30]),
            "pair": (type: "candidate-pair", values: ["selected": true, "state": "succeeded", "currentRoundTripTime": 0.025, "remoteCandidateId": "remote"]),
            "remote": (type: "remote-candidate", values: ["address": "192.168.1.5", "port": 12345, "protocol": "udp"]),
        ]
        let prev = StatsSample(at: 1.0, bytes: 50000, frames: 15)
        let (sample, readout) = readStats(report, prev: prev, now: 2.0, remoteAddresses: [:])
        XCTAssertEqual(sample.bytes, 100000)
        XCTAssertEqual(sample.frames, 30)
        XCTAssertEqual(readout.kBps, 50) // (100000-50000)/1000/1s
        XCTAssertEqual(readout.fps, 15) // (30-15)/1s
        XCTAssertEqual(readout.network, .lan)
        XCTAssertEqual(readout.rttMs, 25)
    }

    func testReadoutText() {
        let r = Readout(transport: "WebRTC", kBps: 380, fps: 30, network: .lan, rttMs: 15)
        let text = readoutText(width: 1408, height: 792, r)
        XCTAssertTrue(text.contains("1408×792"))
        XCTAssertTrue(text.contains("30 fps"))
        XCTAssertTrue(text.contains("380 kB/s"))
        XCTAssertTrue(text.contains("WebRTC"))
        XCTAssertTrue(text.contains("LAN"))
        let still = Readout(transport: "WebRTC", kBps: 0, fps: 0, network: .lan, rttMs: 15)
        XCTAssertEqual(readoutText(width: 1408, height: 792, still), "1408×792 · Idle · WebRTC · LAN")
        let trickle = Readout(transport: "WebRTC", kBps: 0, fps: 4, network: .lan, rttMs: 15)
        XCTAssertEqual(readoutText(width: 1408, height: 792, trickle), "1408×792 · Idle · WebRTC · LAN")
    }

    func testSignalBars() {
        XCTAssertEqual(signalBars(loss: 0.0, rttMs: 10), 3)
        XCTAssertEqual(signalBars(loss: 0.05, rttMs: 200), 2)
        XCTAssertEqual(signalBars(loss: 0.15, rttMs: 500), 1)
    }
}

final class SnapshotSizeTests: XCTestCase {
    func testDevicePixelsRoundUpTo64WithinLimits() {
        XCTAssertEqual(devicePixels(375, scale: 3), 1152)
        XCTAssertEqual(devicePixels(320, scale: 2), 640)
        XCTAssertEqual(devicePixels(0, scale: 3), 64)
        XCTAssertEqual(devicePixels(400, scale: 0), 448) // unknown scale counts as 1
        XCTAssertEqual(devicePixels(10000, scale: 2), 8192)
    }
}

final class WebSocketVideoTests: XCTestCase {
    private let sps: [UInt8] = [0x67, 0x42, 0xe0, 0x1f, 0xda, 0x01, 0x40, 0x16, 0xec, 0x04, 0x40, 0x00, 0x00, 0x03, 0x00, 0x40, 0x00, 0x00, 0x0f, 0x23, 0xc6, 0x0c, 0x92]
    private let pps: [UInt8] = [0x68, 0xce, 0x3c, 0x80]
    private var keyframe: Data { Data([0, 0, 0, 1, 0x09, 0xf0, 0, 0, 0, 1] + sps + [0, 0, 0, 1] + pps + [0, 0, 1, 0x65, 0x88, 0x84]) }

    func testParsesVideoMessages() {
        var msg = Data([1])
        var pts = UInt64(1_792_294_424_594_123).bigEndian
        msg.append(Data(bytes: &pts, count: 8))
        msg.append(1)
        msg.append(keyframe)
        XCTAssertEqual(parseWsVideo(msg), WsVideoMessage(pts: 1_792_294_424_594_123, key: true, data: keyframe))
        msg[0] = 2 // a cursor image, not video
        XCTAssertNil(parseWsVideo(msg))
        XCTAssertNil(parseWsVideo(Data(count: 10)))
    }

    func testAnnexBToAVCCAndFormat() {
        let units = annexBUnits(keyframe)
        XCTAssertEqual(units.map { [UInt8]($0) }, [[0x09, 0xf0], sps, pps, [0x65, 0x88, 0x84]])
        // Parameter sets and the delimiter go in the format description; the slice gets a 4-byte length.
        XCTAssertEqual([UInt8](avccSample(units)), [0, 0, 0, 3, 0x65, 0x88, 0x84])
        let format = h264Format(units)
        XCTAssertNotNil(format)
        if let format { XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).width, 1280) }
        XCTAssertNil(h264Format(annexBUnits(Data([0, 0, 0, 1, 0x41, 0x9a])))) // a delta frame has no SPS
    }
}
