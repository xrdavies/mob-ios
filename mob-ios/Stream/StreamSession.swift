import Foundation
import Observation
import SwiftUI
import UIKit
import WebRTC

/// The live desktop over WebRTC (mobd docs/desktop-streaming.md): one non-trickle POST /stream with
/// the offer, a receive-only H.264 track, `control` for stats and `ended`, and `input` (reliable) and
/// `pointer` (unreliable, latest wins) for Control mode. Shared by the thumbnail and the full-screen
/// view like VncSession; mobd builds without the `stream` feature keep VncSession.
@MainActor @Observable
final class StreamSession {
    /// Status, size and control, in the same shape as the VNC view's.
    private(set) var state = VncState()
    /// The received video, for the renderers of the views on screen.
    private(set) var track: RTCVideoTrack?
    /// mobd's encoder target and reported loss.
    private(set) var kbps = 0
    private(set) var loss = 0.0
    /// Measured once a second while connected.
    private(set) var readout: Readout?
    /// Where mobd last reported the office pointer, normalized.
    private(set) var cursor: CGPoint?
    /// Key codes latched from the keys bar; they apply to the next key, then release.
    private(set) var modifiers: [String] = []

    /// Frames drawn since connecting (for checks; not observed).
    @ObservationIgnored private(set) var frames = 0
    @ObservationIgnored var onUnauthorized: (() -> Void)?

    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var pc: RTCPeerConnection?
    @ObservationIgnored private var bridge: Bridge?
    @ObservationIgnored private var channels: [String: RTCDataChannel] = [:]
    @ObservationIgnored private var watcher: FrameWatcher?
    @ObservationIgnored private var session: (client: APIClient, id: String)?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var held = HeldInput()
    @ObservationIgnored private var takeControl = false
    @ObservationIgnored private var started = Date()
    /// The size the session was opened or last resized at, in pixels.
    @ObservationIgnored private(set) var size = (width: 0, height: 0)

    private static let connectTimeout: Duration = .seconds(15)
    nonisolated(unsafe) private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    init() {
        // A touch or key in flight never ends once the app leaves the screen.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setControl(false) }
        }
    }

    // MARK: Connecting

    /// Opens a session sized to the view (pixels); `control` takes control once the picture arrives.
    func connect(client: APIClient, maxWidth: Int, maxHeight: Int, quality: LiveQuality, control: Bool = false) {
        disconnect()
        attempt += 1
        let a = attempt
        takeControl = control
        started = Date()
        frames = 0
        size = (maxWidth, maxHeight)
        state = VncState(status: .connecting, detail: "Connecting…")
        Log.add("live view: connecting over WebRTC (\(maxWidth)×\(maxHeight), \(quality.rawValue))")
        Task { await run(a, client: client, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality) }
        Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard let self, self.attempt == a, self.state.status == .connecting else { return }
            self.fail(a, "The live view did not start. Is the office Mac reachable from here?")
        }
    }

    private func run(_ a: Int, client: APIClient, maxWidth: Int, maxHeight: Int, quality: LiveQuality) async {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan // host candidates only: LAN and Tailscale
        let bridge = Bridge(owner: self, attempt: a)
        guard let pc = Self.factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: bridge) else {
            return fail(a, "Could not start WebRTC")
        }
        self.pc = pc
        self.bridge = bridge
        let recv = RTCRtpTransceiverInit()
        recv.direction = .recvOnly
        let video = pc.addTransceiver(of: .video, init: recv)
        if let t = video?.receiver.track as? RTCVideoTrack {
            let w = FrameWatcher(owner: self, attempt: a)
            t.add(w)
            watcher = w
            track = t
        }
        for (label, reliable) in [("control", true), ("input", true), ("pointer", false)] {
            let c = RTCDataChannelConfiguration()
            if !reliable {
                c.isOrdered = false
                c.maxRetransmits = 0
            }
            if let dc = pc.dataChannel(forLabel: label, configuration: c) {
                dc.delegate = bridge
                channels[label] = dc
            }
        }
        do {
            let offer = try await withCheckedThrowingContinuation { (k: CheckedContinuation<RTCSessionDescription, Error>) in
                pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, err in
                    if let sdp { k.resume(returning: sdp) } else { k.resume(throwing: err ?? APIError(message: "No WebRTC offer", status: nil)) }
                }
            }
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                pc.setLocalDescription(offer) { err in if let err { k.resume(throwing: err) } else { k.resume() } }
            }
            // Non-trickle: host candidates gather in milliseconds; wait at most 2 s.
            for _ in 0..<40 where pc.iceGatheringState != .complete { try await Task.sleep(for: .milliseconds(50)) }
            guard attempt == a else { return }
            let answer = try await client.openStream(offer: pc.localDescription?.sdp ?? offer.sdp, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality.rawValue)
            guard attempt == a else { return client.closeStream(answer.session) }
            session = (client, answer.session)
            Log.add("live view: answered in \(ms()) ms, \(answer.width)×\(answer.height)")
            guard let sdp = answer.answer, !sdp.isEmpty else { return fail(a, "mobd answered without WebRTC; update mobd on the office Mac") }
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { err in if let err { k.resume(throwing: err) } else { k.resume() } }
            }
        } catch {
            if error.isUnauthorized { onUnauthorized?() }
            let status = (error as? APIError)?.status
            fail(a, status == 404 || status == 405 ? "Update mobd on the office Mac to use the live desktop" : readable(error))
        }
    }

    private func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

    // MARK: Called from WebRTC (hopped to the main actor)

    fileprivate func picture(_ a: Int, width: Int, height: Int) {
        guard a == attempt else { return }
        frames += 1
        if state.status == .connecting {
            Log.add("live view: first picture after \(ms()) ms, \(width)×\(height)")
            state = VncState(status: .connected, width: width, height: height)
            watchStats(a)
            if takeControl { setControl(true) }
        } else if width != state.width || height != state.height {
            state.width = width
            state.height = height
        }
    }

    fileprivate func connectionState(_ a: Int, _ s: RTCPeerConnectionState) {
        guard a == attempt else { return }
        switch s {
        case .failed: fail(a, "The live view connection was lost")
        case .closed where state.status == .connected:
            teardown()
            state = VncState(status: .idle, detail: "Disconnected")
        default: break
        }
    }

    fileprivate func control(_ a: Int, _ data: Data) {
        guard a == attempt else { return }
        switch ControlMessage.parse(data) {
        case .stats(let k, _, _, _, let l, _):
            kbps = k
            loss = l
        case .ended(let message): fail(a, message)
        case .error(let about, let message): Log.error("live view: \(about): \(message)")
        case .cursor(let x, let y): cursor = CGPoint(x: x, y: y)
        case nil: break
        }
    }

    private func watchStats(_ a: Int) {
        statsTask?.cancel()
        let addresses = candidateAddresses(pc?.remoteDescription?.sdp ?? "")
        statsTask = Task { [weak self] in
            var prev: StatsSample?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.attempt == a, let pc = self.pc else { return }
                let report = await withCheckedContinuation { (k: CheckedContinuation<[String: (type: String, values: [String: Any])], Never>) in
                    pc.statistics { r in
                        k.resume(returning: r.statistics.mapValues { (type: $0.type, values: $0.values as [String: Any]) })
                    }
                }
                guard self.attempt == a else { return }
                let (sample, r) = readStats(report, prev: prev, now: Date().timeIntervalSince1970, remoteAddresses: addresses)
                if prev != nil { self.readout = r }
                prev = sample
            }
        }
    }

    private func fail(_ a: Int, _ message: String) {
        guard a == attempt else { return }
        attempt += 1 // later events from this connection are ignored
        Log.error("live view: \(message)")
        teardown()
        state = VncState(status: .error, detail: message)
    }

    private func teardown() {
        release()
        statsTask?.cancel()
        statsTask = nil
        if let w = watcher { track?.remove(w) }
        watcher = nil
        track = nil
        channels.values.forEach { $0.delegate = nil }
        channels = [:]
        pc?.close()
        pc = nil
        bridge = nil
        if let s = session { s.client.closeStream(s.id) }
        session = nil
        readout = nil
        kbps = 0
        loss = 0
        cursor = nil
        modifiers = []
    }

    func disconnect() {
        attempt += 1
        teardown()
        if state.status != .idle { state = VncState(status: .idle, detail: "Disconnected") }
    }

    /// Refits the running session to a new view (mobd with `streamResize`); false if not sent.
    @discardableResult
    func resize(maxWidth: Int, maxHeight: Int) -> Bool {
        guard state.status == .connected, channels["control"]?.readyState == .open else { return false }
        guard maxWidth != size.width || maxHeight != size.height else { return true }
        size = (maxWidth, maxHeight)
        send([.resize(maxWidth: maxWidth, maxHeight: maxHeight)])
        return true
    }

    // MARK: Input (Control mode only)

    func setControl(_ on: Bool) {
        let control = on && state.status == .connected && channels["input"] != nil
        if !control {
            release()
            modifiers = []
        }
        if control != state.control { state.control = control }
    }

    private func send(_ messages: [InputMessage]) {
        for m in messages {
            guard let dc = channels[m.channel], dc.readyState == .open else { continue }
            dc.sendData(RTCDataBuffer(data: m.json, isBinary: false))
        }
    }

    private func release() { send(held.releaseAll()) }

    /// Sends input only while controlling.
    private func input(_ messages: [InputMessage]) {
        if state.control { send(messages) }
    }

    func move(_ x: Double, _ y: Double) {
        held.point(x, y)
        input([.move(x: x, y: y)])
    }

    func click(_ x: Double, _ y: Double, right: Bool = false) {
        guard state.control else { return }
        let b: MouseButton = right ? .right : .left
        send([.move(x: x, y: y)] + held.buttonDown(b, x, y) + held.buttonUp(b, x, y))
    }

    func drag(_ x: Double, _ y: Double, _ phase: UIGestureRecognizer.State) {
        guard state.control else { return }
        switch phase {
        case .began: send([.move(x: x, y: y)] + held.buttonDown(.left, x, y))
        case .changed:
            held.point(x, y)
            send([.move(x: x, y: y)])
        default: send(held.buttonUp(.left, x, y))
        }
    }

    /// Wheel in pixels, positive = down/right like WheelEvent.
    func scroll(_ x: Double, _ y: Double, dx: Double, dy: Double) { input([.scroll(x: x, y: y, dx: dx, dy: dy)]) }

    func toggleModifier(_ code: String) {
        if let i = modifiers.firstIndex(of: code) { modifiers.remove(at: i) } else { modifiers.append(code) }
    }

    /// Presses `code` with the latched modifiers, then releases everything.
    func tapKey(_ code: String) {
        guard state.control else { return }
        var out: [InputMessage] = []
        modifiers.forEach { out += held.keyDown($0) }
        out += held.keyDown(code) + held.keyUp(code)
        modifiers.reversed().forEach { out += held.keyUp($0) }
        modifiers = []
        send(out)
    }

    /// Types one character from the phone's keyboard: as text, or as its key with a latched modifier.
    func type(_ c: Character) {
        guard state.control else { return }
        if c == "\n" { return tapKey("Enter") }
        if !modifiers.isEmpty, let code = webKeyCode(for: c) { return tapKey(code) }
        send([.text(String(c))])
    }

    /// Types text from the phone's clipboard; mobd caps a message at 4096 characters.
    func typeText(_ text: String) {
        guard state.control else { return }
        var rest = Substring(text.prefix(20000))
        while !rest.isEmpty {
            send([.text(String(rest.prefix(4000)))])
            rest = rest.dropFirst(4000)
        }
    }
}

/// WebRTC delegate callbacks arrive on its signaling thread; they hop to the main actor.
private final class Bridge: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    weak var owner: StreamSession?
    let attempt: Int

    init(owner: StreamSession, attempt: Int) {
        self.owner = owner
        self.attempt = attempt
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let a = attempt
        Task { @MainActor [weak owner] in owner?.connectionState(a, newState) }
    }

    func dataChannel(_ dc: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard dc.label == "control", !buffer.isBinary else { return }
        let a = attempt, data = buffer.data
        Task { @MainActor [weak owner] in owner?.control(a, data) }
    }

    func dataChannelDidChangeState(_ dc: RTCDataChannel) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// Sees every decoded frame: the first one marks the session connected, later ones its size.
private final class FrameWatcher: NSObject, RTCVideoRenderer {
    weak var owner: StreamSession?
    let attempt: Int
    private var last = (0, 0)
    private var count = 0

    init(owner: StreamSession, attempt: Int) {
        self.owner = owner
        self.attempt = attempt
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let rotated = frame.rotation == ._90 || frame.rotation == ._270
        let w = Int(rotated ? frame.height : frame.width), h = Int(rotated ? frame.width : frame.height)
        count += 1
        // Every size change, and a heartbeat for the frame counter.
        guard count == 1 || (w, h) != last || count % 30 == 0 else { return }
        last = (w, h)
        let a = attempt
        Task { @MainActor [weak owner] in owner?.picture(a, width: w, height: h) }
    }
}

/// Draws the received video, scaled to fit; each view on screen adds its own renderer.
struct StreamVideoView: UIViewRepresentable {
    let track: RTCVideoTrack?

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView(frame: .zero)
        v.videoContentMode = .scaleAspectFit
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        guard context.coordinator.track !== track else { return }
        context.coordinator.track?.remove(view)
        track?.add(view)
        context.coordinator.track = track
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
        coordinator.track = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var track: RTCVideoTrack?
    }
}
