import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit
import WebRTC

/// What carries the live picture once connected.
enum LiveTransport: String {
    case webRTC = "WebRTC"
    case webSocket = "WebSocket"
}

/// The live desktop over WebRTC (mobd docs/desktop-streaming.md): one non-trickle POST /stream with
/// the offer, a receive-only H.264 track, `control` for stats and `ended`, and `input` (reliable) and
/// `pointer` (unreliable, latest wins) for Control mode. Where UDP cannot pass, the same session
/// continues over mobd's WebSocket (WsPlayer): WebRTC gets a head start, then the WebSocket replaces
/// it, or races beside it where it was needed last time; mobd sends video on the first transport to
/// connect, so the first frame says which one won. Shared by the thumbnail and the full-screen view
/// like VncSession; mobd builds without the `stream` feature keep VncSession.
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
    /// The transport carrying the picture, once one has won.
    private(set) var transport: LiveTransport?

    /// Frames drawn since connecting (for checks; not observed).
    @ObservationIgnored private(set) var frames = 0
    @ObservationIgnored var onUnauthorized: (() -> Void)?
    /// Called once per session when a transport wins, so the machine can remember the WebSocket.
    @ObservationIgnored var onTransport: ((LiveTransport) -> Void)?
    /// Tests only: drop ICE candidates both ways, like a network without UDP.
    @ObservationIgnored var blockWebRTC = false

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
    @ObservationIgnored private var via: LiveTransport?
    @ObservationIgnored private var player: WsPlayer?
    @ObservationIgnored private var startWs: ((Bool) -> Void)?
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var lastRtt: Int?
    /// The size the session was opened or last resized at, in pixels.
    @ObservationIgnored private(set) var size = (width: 0, height: 0)

    private static let connectTimeout: Duration = .seconds(15)
    /// WebRTC's head start: usually well under a second on the LAN or a tailnet, but a relayed path can
    /// take a few seconds, and losing it to the WebSocket costs quality.
    static let webRTCGrace: Duration = .seconds(5)
    /// Where the WebSocket was needed last time. Not zero: TCP opens faster than WebRTC, so a race from
    /// the start would keep such a machine on the WebSocket even where WebRTC works again.
    static let rememberedGrace: Duration = .seconds(1)
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
    /// `preferWebSocket`: the WebSocket carried this machine's last session; race it after 1 s.
    func connect(client: APIClient, maxWidth: Int, maxHeight: Int, quality: LiveQuality, control: Bool = false, preferWebSocket: Bool = false) {
        disconnect()
        attempt += 1
        let a = attempt
        takeControl = control
        started = Date()
        frames = 0
        size = (maxWidth, maxHeight)
        state = VncState(status: .connecting, detail: "Connecting…")
        Log.add("live view: connecting over WebRTC (\(maxWidth)×\(maxHeight), \(quality.rawValue))")
        Task { await run(a, client: client, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality, preferWebSocket: preferWebSocket) }
        Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard let self, self.attempt == a, self.state.status == .connecting else { return }
            self.fail(a, "The live view did not start. Is the office Mac reachable from here?")
        }
    }

    private func run(_ a: Int, client: APIClient, maxWidth: Int, maxHeight: Int, quality: LiveQuality, preferWebSocket: Bool) async {
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
            var sdpOffer = pc.localDescription?.sdp ?? offer.sdp
            if blockWebRTC { sdpOffer = withoutCandidates(sdpOffer) }
            let answer = try await client.openStream(offer: sdpOffer, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality.rawValue)
            guard attempt == a else { return client.closeStream(answer.session) }
            session = (client, answer.session)
            Log.add("live view: answered in \(ms()) ms, \(answer.width)×\(answer.height)")
            startWs = { [weak self] race in self?.openWebSocket(a, client: client, session: answer.session, race: race) }
            let grace = preferWebSocket ? Self.rememberedGrace : Self.webRTCGrace
            graceTask = Task { [weak self] in
                try? await Task.sleep(for: grace)
                guard !Task.isCancelled, let self, self.attempt == a else { return }
                self.startWs?(preferWebSocket)
            }
            guard var sdp = answer.answer, !sdp.isEmpty else { return startWs?(false) ?? () }
            if blockWebRTC { sdp = withoutCandidates(sdp) }
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

    private func withoutCandidates(_ sdp: String) -> String {
        sdp.components(separatedBy: "\r\n").filter { !$0.hasPrefix("a=candidate") }.joined(separator: "\r\n")
    }

    // MARK: The WebSocket fallback

    /// Opens the session's WebSocket. `race`: WebRTC keeps trying beside it; otherwise it is closed and
    /// mobd keeps the session for the WebSocket.
    private func openWebSocket(_ a: Int, client: APIClient, session id: String, race: Bool) {
        guard a == attempt, via == nil, player == nil else { return }
        Log.add(race ? "live view: WebSocket beside WebRTC after \(ms()) ms (needed here last time)" : "live view: no WebRTC after \(ms()) ms, using the WebSocket")
        if !race { dropWebRTC() }
        let p = WsPlayer(request: client.streamSocketRequest(session: id), session: client.streamSession, layers: { WsLayers.all }, events: .init(
            control: { [weak self] text in
                guard let self, self.attempt == a, self.via == .webSocket else { return }
                self.control(a, Data(text.utf8))
            },
            frame: { [weak self] w, h in
                guard let self, self.attempt == a else { return }
                if self.via == nil { self.choose(a, .webSocket) }
                if self.via == .webSocket { self.picture(a, width: w, height: h) }
            },
            close: { [weak self] code, opened in
                guard let self, self.attempt == a, self.via != .webRTC else { return }
                Log.add("live view: WebSocket closed (code \(code), \(opened ? "after messages" : "before any message"))")
                self.player = nil
                if !opened {
                    // Still racing: WebRTC may yet connect.
                    if self.pc == nil { self.fail(a, "The office Mac could not be reached over WebRTC or the WebSocket fallback") }
                } else if code == URLSessionWebSocketTask.CloseCode.normalClosure.rawValue {
                    self.teardown()
                    self.state = VncState(status: .idle, detail: "Disconnected")
                } else {
                    self.fail(a, "The live view connection was lost")
                }
            }))
        player = p
        p.start()
    }

    /// The first transport to deliver a picture carries the session; the other is closed.
    private func choose(_ a: Int, _ t: LiveTransport) {
        guard a == attempt, via == nil else { return }
        via = t
        transport = t
        graceTask?.cancel()
        Log.add("live view: \(t.rawValue) carries the picture after \(ms()) ms")
        if t == .webRTC {
            player?.close()
            player = nil
        } else {
            dropWebRTC()
        }
        onTransport?(t)
    }

    /// Closes the peer connection and its channels, leaving the session to the WebSocket.
    private func dropWebRTC() {
        if let w = watcher { track?.remove(w) }
        watcher = nil
        track = nil
        channels.values.forEach { $0.delegate = nil }
        channels = [:]
        pc?.close()
        pc = nil
        bridge = nil
    }

    /// A view showing the WebSocket video appeared; it has nothing to decode until the next keyframe.
    func addWsLayer(_ layer: AVSampleBufferDisplayLayer) {
        WsLayers.add(layer)
        player?.askKeyframe()
    }

    fileprivate func webRTCFrame(_ a: Int, width: Int, height: Int) {
        guard a == attempt else { return }
        if via == nil { choose(a, .webRTC) }
        if via == .webRTC { picture(a, width: width, height: height) }
    }

    // MARK: Called from WebRTC (hopped to the main actor)

    private func picture(_ a: Int, width: Int, height: Int) {
        guard a == attempt else { return }
        frames += 1
        if state.status == .connecting {
            Log.add("live view: first picture over \(via?.rawValue ?? "?") after \(ms()) ms, \(width)×\(height)")
            state = VncState(status: .connected, width: width, height: height)
            if via == .webSocket { watchWsStats(a) } else { watchStats(a) }
            if takeControl { setControl(true) }
        } else if width != state.width || height != state.height {
            state.width = width
            state.height = height
        }
    }

    fileprivate func connectionState(_ a: Int, _ s: RTCPeerConnectionState) {
        guard a == attempt else { return }
        switch s {
        case .connected: graceTask?.cancel() // the picture follows unless the racing WebSocket won at mobd
        case .failed:
            if via == .webRTC { fail(a, "The live view connection was lost") }
            else if player != nil { dropWebRTC() } // the WebSocket is already trying
            else if let startWs { startWs(false) } // no UDP path: don't wait out the head start
            else { fail(a, "The office Mac could not be reached over WebRTC") }
        case .closed where state.status == .connected && via == .webRTC:
            teardown()
            state = VncState(status: .idle, detail: "Disconnected")
        default: break
        }
    }

    fileprivate func control(_ a: Int, _ data: Data) {
        guard a == attempt else { return }
        switch ControlMessage.parse(data) {
        case .stats(let k, _, _, _, let l, let rtt):
            kbps = k
            loss = l
            lastRtt = rtt > 0 ? rtt : nil
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

    /// The WebSocket's readout: bytes and frames counted by the player, round-trip time from mobd.
    private func watchWsStats(_ a: Int) {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            var prev = (at: Date(), bytes: 0, frames: 0)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.attempt == a, let p = self.player else { return }
                let now = (at: Date(), bytes: p.bytes, frames: p.frames)
                let seconds = max(now.at.timeIntervalSince(prev.at), 0.001)
                self.readout = Readout(transport: LiveTransport.webSocket.rawValue,
                                       kBps: Int(Double(now.bytes - prev.bytes) / 1000 / seconds),
                                       fps: Int((Double(now.frames - prev.frames) / seconds).rounded()), rttMs: self.lastRtt)
                prev = now
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
        graceTask?.cancel()
        graceTask = nil
        startWs = nil
        player?.close()
        player = nil
        dropWebRTC()
        via = nil
        transport = nil
        lastRtt = nil
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
        guard state.status == .connected, via == .webSocket ? player != nil : channels["control"]?.readyState == .open else { return false }
        guard maxWidth != size.width || maxHeight != size.height else { return true }
        size = (maxWidth, maxHeight)
        send([.resize(maxWidth: maxWidth, maxHeight: maxHeight)])
        return true
    }

    // MARK: Input (Control mode only)

    func setControl(_ on: Bool) {
        let control = on && state.status == .connected && (via == .webSocket ? player != nil : channels["input"] != nil)
        if !control {
            release()
            modifiers = []
        }
        if control != state.control { state.control = control }
    }

    private func send(_ messages: [InputMessage]) {
        if via == .webSocket {
            for m in messages { player?.send(String(decoding: m.json, as: UTF8.self)) }
            return
        }
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
        Task { @MainActor [weak owner] in owner?.webRTCFrame(a, width: w, height: h) }
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
