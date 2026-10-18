import XCTest
@testable import mob_ios

/// Opens a real live view against a running mobd, so WebRTC, H.264 decoding and the data channels
/// are exercised in the simulator. Skipped unless MOBD_URL and MOBD_TOKEN are set, e.g.
/// `TEST_RUNNER_MOBD_URL=http://… TEST_RUNNER_MOBD_TOKEN=… xcodebuild … test`.
/// It only moves the office pointer: no clicks or keys.
@MainActor
final class LiveStreamTests: XCTestCase {
    func testLiveViewAgainstMobd() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["MOBD_URL"], let token = env["MOBD_TOKEN"] else {
            throw XCTSkip("set MOBD_URL and MOBD_TOKEN to run against a mobd")
        }
        let s = StreamSession()
        let started = Date()
        s.connect(client: APIClient(baseURL: url, token: token), maxWidth: 1280, maxHeight: 832, quality: .auto)
        try await wait("first picture", 15) { s.state.status != .connecting }
        XCTAssertEqual(s.state.status, .connected, s.state.detail)
        let first = Date().timeIntervalSince(started)
        let opened = (s.state.width, s.state.height)

        // Without control, moves are not sent.
        s.move(0.1, 0.1)
        try await Task.sleep(for: .seconds(1))
        let before = s.cursor

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
        let readout = s.readout.map { readoutText(width: s.state.width, height: s.state.height, $0) } ?? ""
        print("live: first picture \(Int(first * 1000)) ms at \(opened.0)×\(opened.1); cursor before control \(String(describing: before)); \(readout); \(s.frames) frame events")
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
