import AVFoundation
import CoreMedia
import Foundation
import SwiftUI
import UIKit

// The live desktop over mobd's WebSocket fallback (mobd docs/desktop-streaming.md, "WebSocket
// fallback"), where WebRTC's UDP cannot pass. Binary messages from mobd are video:
//
//	byte 0     1 (H.264 access unit, Annex B)
//	bytes 1-8  capture time in microseconds, big endian
//	byte 9     flags: bit 0 keyframe
//	bytes 10-  access unit
//
// Text messages use the data-channel JSON schema both ways; every video message is acknowledged with
// {"t":"ack","pts":N}, which is how mobd measures the link. Native clients send the Bearer header.

struct WsVideoMessage: Equatable {
    /// Capture time, microseconds.
    let pts: UInt64
    let key: Bool
    let data: Data
}

/// A binary message from mobd; nil for anything that is not a video access unit.
func parseWsVideo(_ d: Data) -> WsVideoMessage? {
    let b = [UInt8](d)
    guard b.count >= 11, b[0] == 1 else { return nil }
    var pts: UInt64 = 0
    for i in 1...8 { pts = pts << 8 | UInt64(b[i]) }
    return WsVideoMessage(pts: pts, key: b[9] & 1 != 0, data: Data(b[10...]))
}

/// The NAL units of an Annex B access unit, without start codes.
func annexBUnits(_ d: Data) -> [Data] {
    let b = [UInt8](d)
    var starts: [(at: Int, len: Int)] = []
    var i = 0
    while i + 2 < b.count {
        if b[i] == 0, b[i + 1] == 0 {
            if b[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
            if b[i + 2] == 0, i + 3 < b.count, b[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
        }
        i += 1
    }
    return starts.indices.map { n in
        let from = starts[n].at + starts[n].len
        let to = n + 1 < starts.count ? starts[n + 1].at : b.count
        return Data(b[from..<to])
    }
}

/// An access unit as VideoToolbox wants it: length-prefixed (AVCC) NAL units, parameter sets and
/// access unit delimiters left out (they go in the format description).
func avccSample(_ units: [Data]) -> Data {
    var out = Data()
    for u in units where !u.isEmpty {
        let type = u[u.startIndex] & 0x1f
        if type == 7 || type == 8 || type == 9 { continue }
        var len = UInt32(u.count).bigEndian
        out.append(Data(bytes: &len, count: 4))
        out.append(u)
    }
    return out
}

/// The H.264 format description from a keyframe's SPS and PPS; nil without them.
func h264Format(_ units: [Data]) -> CMVideoFormatDescription? {
    guard let sps = units.first(where: { !$0.isEmpty && $0[$0.startIndex] & 0x1f == 7 }),
          let pps = units.first(where: { !$0.isEmpty && $0[$0.startIndex] & 0x1f == 8 }) else { return nil }
    var format: CMVideoFormatDescription?
    let status = sps.withUnsafeBytes { s in
        pps.withUnsafeBytes { p in
            let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
            let sizes = [sps.count, pps.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        }
    }
    return status == noErr ? format : nil
}

/// One WebSocket session: receives, acknowledges and hands decoded-ready samples to the layers.
@MainActor
final class WsPlayer {
    struct Events {
        /// A control message (stats, ended, error, cursor).
        var control: (String) -> Void
        /// A picture of this size went to the layers.
        var frame: (Int, Int) -> Void
        /// The socket closed; `opened` tells a refused connection from a lost one.
        var close: (_ code: Int, _ opened: Bool) -> Void
    }

    private let task: URLSessionWebSocketTask
    private let events: Events
    private let layers: () -> [AVSampleBufferDisplayLayer]
    private var format: CMVideoFormatDescription?
    private var opened = false
    private var closed = false
    private var lastKeyRequest = Date.distantPast
    /// Totals for the readout.
    private(set) var bytes = 0
    private(set) var frames = 0

    init(request: URLRequest, session: URLSession, layers: @escaping () -> [AVSampleBufferDisplayLayer], events: Events) {
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 << 20
        self.layers = layers
        self.events = events
    }

    func start() {
        task.resume()
        receive()
    }

    func send(_ json: String) {
        guard !closed else { return }
        task.send(.string(json)) { _ in }
    }

    func close() {
        closed = true
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// Asks mobd for a keyframe, at most once a second (a new view, a decoder that failed).
    func askKeyframe() {
        guard Date().timeIntervalSince(lastKeyRequest) >= 1 else { return }
        lastKeyRequest = Date()
        send(#"{"t":"keyframe"}"#)
    }

    private func receive() {
        task.receive { [weak self] result in
            Task { @MainActor in self?.handle(result) }
        }
    }

    private func handle(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        guard !closed else { return }
        switch result {
        case .success(let message):
            opened = true
            switch message {
            case .string(let text): events.control(text)
            case .data(let data): video(data)
            @unknown default: break
            }
            receive()
        case .failure:
            closed = true
            events.close(task.closeCode.rawValue, opened)
        }
    }

    private func video(_ data: Data) {
        guard let m = parseWsVideo(data) else { return }
        send(#"{"t":"ack","pts":\#(m.pts)}"#) // on receipt: mobd times the link from these
        bytes += data.count
        let units = annexBUnits(m.data)
        if m.key, let f = h264Format(units) { format = f }
        guard let format else { return askKeyframe() } // nothing decodable before the first keyframe
        let sample = avccSample(units)
        guard !sample.isEmpty, let buffer = sampleBuffer(sample, format: format, pts: m.pts) else { return }
        for layer in layers() {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
                askKeyframe()
                if !m.key { continue }
            }
            renderer.enqueue(buffer)
        }
        frames += 1
        let size = CMVideoFormatDescriptionGetDimensions(format)
        events.frame(Int(size.width), Int(size.height))
    }

    private func sampleBuffer(_ sample: Data, format: CMVideoFormatDescription, pts: UInt64) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: sample.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: sample.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = sample.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: sample.count) }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 1_000_000), decodeTimeStamp: .invalid)
        var size = sample.count
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr,
              let buffer else { return nil }
        // A remote screen, not a movie: show each picture as soon as it is decoded.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return buffer
    }
}

/// Draws the WebSocket video, scaled to fit; each view on screen registers its own layer.
struct WsVideoView: UIViewRepresentable {
    let session: StreamSession

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.displayLayer.videoGravity = .resizeAspect
        session.addWsLayer(v.displayLayer)
        return v
    }

    func updateUIView(_ view: LayerView, context: Context) {}

    static func dismantleUIView(_ view: LayerView, coordinator: ()) {
        MainActor.assumeIsolated {
            // The session outlives its views; drop this layer from it.
            WsLayers.remove(view.displayLayer)
        }
    }
}

/// The layers showing the WebSocket video, weakly held so a view that goes away is dropped.
@MainActor
enum WsLayers {
    private static let table = NSHashTable<AVSampleBufferDisplayLayer>.weakObjects()
    static func add(_ l: AVSampleBufferDisplayLayer) { table.add(l) }
    static func remove(_ l: AVSampleBufferDisplayLayer) { table.remove(l) }
    static var all: [AVSampleBufferDisplayLayer] { table.allObjects }
}
