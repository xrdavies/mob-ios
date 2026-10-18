import AVFoundation
import XCTest
@testable import mob_ios

/// Opens real live views against a running mobd, so WebRTC, the WebSocket fallback, H.264 decoding and
/// the input channels are exercised in the simulator. Skipped unless MOBD_URL and MOBD_TOKEN are set,
/// e.g. `TEST_RUNNER_MOBD_URL=http://… TEST_RUNNER_MOBD_TOKEN=… xcodebuild … test`.
/// It only moves the office pointer: no clicks or keys. "Blocked" drops ICE candidates both ways, like
/// a network without UDP.
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

    private func check(blocked: Bool, remembered: Bool, expect: LiveTransport) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["MOBD_URL"], let token = env["MOBD_TOKEN"] else {
            throw XCTSkip("set MOBD_URL and MOBD_TOKEN to run against a mobd")
        }
        let s = StreamSession()
        s.blockWebRTC = blocked
        let layer = AVSampleBufferDisplayLayer()
        s.addWsLayer(layer)
        defer { WsLayers.remove(layer) }
        let started = Date()
        s.connect(client: APIClient(baseURL: url, token: token), maxWidth: 1280, maxHeight: 832, quality: .auto, preferWebSocket: remembered)
        try await wait("first picture", 15) { s.state.status != .connecting }
        // Why it did not start; TEST_RUNNER_PRINT_LOG=1 prints it always.
        if s.state.status != .connected || ProcessInfo.processInfo.environment["PRINT_LOG"] != nil { print(Log.shared.text) }
        XCTAssertEqual(s.state.status, .connected, s.state.detail)
        XCTAssertEqual(s.transport, expect)
        let first = Date().timeIntervalSince(started)
        let opened = (s.state.width, s.state.height)

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

        XCTAssertTrue(s.resize(maxWidth: 640, maxHeight: 640))
        try await wait("640×360 after resize", 5) { s.state.width == 640 }
        try await wait("readout", 4) { s.readout != nil }
        if expect == .webSocket {
            XCTAssertNotEqual(layer.sampleBufferRenderer.status, .failed, "VideoToolbox refused the WebSocket video")
        }
        let readout = s.readout.map { readoutText(width: s.state.width, height: s.state.height, $0) } ?? ""
        print("live: blocked=\(blocked) remembered=\(remembered): first picture \(Int(first * 1000)) ms over \(s.transport?.rawValue ?? "?") at \(opened.0)×\(opened.1); \(readout); layer \(layer.sampleBufferRenderer.status.rawValue)")
        s.disconnect()
    }

    private func wait(_ what: String, _ seconds: Double, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
