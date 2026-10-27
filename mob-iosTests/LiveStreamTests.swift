import AVFoundation
import XCTest
import UIKit
@testable import mob_ios

/// Opens real live views against a running mobd, so WebRTC, the WebSocket fallback, H.264 decoding and
/// the input channels are exercised in the simulator. Opt in with MOBD_URL and MOBD_TOKEN, or
/// MOBD_USE_PAIRED_MACHINE=1 to reuse the active machine without exporting its Keychain credential.
/// e.g. `TEST_RUNNER_MOBD_URL=http://… TEST_RUNNER_MOBD_TOKEN=… xcodebuild … test`.
/// The basic cases only move the pointer. Control cases require MOBD_INPUT_PROBE_PATH and an isolated
/// probe window. "Blocked" drops ICE candidates both ways, like a network without UDP.
@MainActor
final class LiveStreamTests: XCTestCase {
    func testWebRTC() async throws {
        try await check(blocked: false, remembered: false, expect: .webRTC)
    }

    func testWebSocketWhenWebRTCIsBlocked() async throws {
        try await check(blocked: true, remembered: false, expect: .webSocket)
    }

    func testRememberedWebSocketStartsSooner() async throws {
        try await check(blocked: true, remembered: true, expect: .webSocket)
    }

    func testRememberedMachineReturnsToWebRTC() async throws {
        try await check(blocked: false, remembered: true, expect: .webRTC)
    }

    func testWebRTCControlAndBackgroundRelease() async throws {
        try await check(blocked: false, remembered: false, expect: .webRTC, probe: probePath())
    }

    func testWebSocketControlAndBackgroundRelease() async throws {
        try await check(blocked: true, remembered: true, expect: .webSocket, probe: probePath())
    }

    private func probePath() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["MOBD_INPUT_PROBE_PATH"] else {
            throw XCTSkip("Run the local input probe and set MOBD_INPUT_PROBE_PATH")
        }
        return path
    }

    private func check(blocked: Bool, remembered: Bool, expect: LiveTransport, probe: String? = nil) async throws {
        let client = try client()
        let s = StreamSession()
        s.blockWebRTC = blocked
        let layer = AVSampleBufferDisplayLayer()
        s.addWsLayer(layer)
        defer { s.disconnect(); WsLayers.remove(layer) }
        let started = Date()
        s.connect(client: client, maxWidth: 1280, maxHeight: 832, quality: .auto, preferWebSocket: remembered)
        try await wait("first picture", 15) { s.state.status != .connecting }
        // Why it did not start; TEST_RUNNER_PRINT_LOG=1 prints it always.
        if s.state.status != .connected || ProcessInfo.processInfo.environment["PRINT_LOG"] != nil { print(Log.shared.text) }
        XCTAssertEqual(s.state.status, .connected, s.state.detail)
        XCTAssertEqual(s.transport, expect)
        let first = Date().timeIntervalSince(started)
        let opened = (s.state.width, s.state.height)
        let frames = s.frames
        try await wait("continuing video frames", 5) { s.frames > frames }

        if let probe {
            try await checkInput(s, path: probe, host: client.baseURL.host ?? "")
        } else {
            // Without control, moves are not sent.
            s.move(0.1, 0.1)
            try await Task.sleep(for: .seconds(1))
            s.setControl(true)
            XCTAssertTrue(s.state.control)
            s.move(0.25, 0.25)
            try await wait("cursor at (0.25, 0.25)", 5) { s.cursor.map { abs($0.x - 0.25) < 0.01 && abs($0.y - 0.25) < 0.01 } ?? false }
            s.move(0.75, 0.6)
            try await wait("cursor at (0.75, 0.6)", 5) { s.cursor.map { abs($0.x - 0.75) < 0.01 && abs($0.y - 0.6) < 0.01 } ?? false }
            s.setControl(false)
        }

        XCTAssertTrue(s.resize(maxWidth: 640, maxHeight: 640))
        try await wait("640×360 after resize", 5) { s.state.width == 640 }
        try await wait("readout", 4) { s.readout != nil }
        if expect == .webSocket {
            XCTAssertNotEqual(layer.sampleBufferRenderer.status, .failed, "VideoToolbox refused the WebSocket video")
        }
        let readout = s.readout.map { readoutText(width: s.state.width, height: s.state.height, $0) } ?? ""
        print("live: blocked=\(blocked) remembered=\(remembered): first picture \(Int(first * 1000)) ms over \(s.transport?.rawValue ?? "?") at \(opened.0)×\(opened.1); \(readout); layer \(layer.sampleBufferRenderer.status.rawValue)")
    }

    /// Only opt in while the supplied probe window covers the office desktop.
    private func checkInput(_ s: StreamSession, path: String, host: String) async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let probe = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        guard probe["name"] as? String == "mob-ios-input-probe", probe["ready"] as? Bool == true,
              (probe["hosts"] as? [String])?.contains(host) == true,
              Date().timeIntervalSince1970 - (probe["at"] as? Double ?? 0) < 2 else {
            throw NSError(domain: "LiveStreamTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unlock the Mac and open the full-screen input probe before sending input"])
        }
        func events() -> [[String: Any]] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["name"] as? String == "mob-ios-input-probe" else { return [] }
            return obj["events"] as? [[String: Any]] ?? []
        }
        let baseline = events().count
        func count(_ kind: String) -> Int { events().dropFirst(baseline).filter { $0["kind"] as? String == kind }.count }
        s.setControl(true)
        s.click(0.5, 0.5)
        try await wait("probe click", 5) { count("down") == 1 && count("up") == 1 }
        s.click(0.5, 0.5, right: true)
        try await wait("probe right click", 5) { count("rightDown") == 1 && count("rightUp") == 1 }
        s.typeText("duo-input")
        try await wait("probe text", 5) {
            events().dropFirst(baseline).filter { $0["kind"] as? String == "keyDown" }
                .compactMap { $0["text"] as? String }.joined().contains("duo-input")
        }
        s.tapKey("ArrowLeft")
        try await wait("probe arrow key released", 5) {
            events().dropFirst(baseline).contains { $0["kind"] as? String == "keyUp" && $0["keyCode"] as? Int == 123 }
        }
        s.scroll(0.5, 0.5, dx: 0, dy: 80)
        try await wait("probe scroll", 5) { count("scroll") > 0 }
        s.drag(0.4, 0.45, .began)
        try await wait("probe drag start", 5) { count("down") == 2 }
        s.drag(0.6, 0.55, .changed)
        try await wait("probe drag movement", 5) { count("drag") > 0 }
        s.toggleModifier("ShiftLeft")
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertFalse(s.state.control)
        XCTAssertTrue(s.modifiers.isEmpty)
        try await wait("drag released on background", 5) { count("up") == 2 }
        let released = try XCTUnwrap(events().last { $0["kind"] as? String == "up" })
        XCTAssertEqual(try XCTUnwrap(released["x"] as? Double), try XCTUnwrap(probe["width"] as? Double) * 0.6, accuracy: 3)
        XCTAssertEqual(try XCTUnwrap(released["y"] as? Double), try XCTUnwrap(probe["height"] as? Double) * 0.55, accuracy: 3)
        let after = events().count
        s.click(0.5, 0.5)
        s.typeText("must-not-arrive")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(events().count, after, "View mode sent input")
    }

    private func client() throws -> APIClient {
        let env = ProcessInfo.processInfo.environment
        if let url = env["MOBD_URL"], let token = env["MOBD_TOKEN"] {
            return APIClient(baseURL: url, token: token)
        }
        guard env["MOBD_USE_PAIRED_MACHINE"] == "1" else {
            throw XCTSkip("Set MOBD_URL/MOBD_TOKEN or MOBD_USE_PAIRED_MACHINE=1")
        }
        let defaults = UserDefaults.standard
        let data = try XCTUnwrap(defaults.data(forKey: "machines"), "Pair a machine in the app first")
        let machines = try JSONDecoder().decode([Machine].self, from: data)
        let machine = try XCTUnwrap(machines.first { $0.id == defaults.string(forKey: "activeMachine") })
        XCTAssertFalse(machine.needsPairing)
        return APIClient(baseURL: machine.mobdUrl, token: try XCTUnwrap(machine.token))
    }

    private func wait(_ what: String, _ seconds: Double, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > deadline { throw NSError(domain: "LiveStreamTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(what)"]) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
