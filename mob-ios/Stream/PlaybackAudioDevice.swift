import AVFoundation
import Foundation
import WebRTC

/// WebRTC's audio device for the office computer's sound (mobd docs/desktop-audio.md): playback
/// only, so the microphone is never opened, and media playback in stereo rather than a voice call.
/// WebRTC's own device is built for calls (voice processing, play-and-record). WebRTC decodes the
/// Opus track and this device pulls its PCM into an AVAudioEngine while the user has sound on.
///
/// ADM calls arrive on WebRTC's worker thread; `audible` is set from the main actor. Both change
/// state under `lock`.
final class PlaybackAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    static let shared = PlaybackAudioDevice()

    private static let rate = 48000.0
    private static let channels: AVAudioChannelCount = 2

    private let lock = NSLock()
    private var delegate: RTCAudioDeviceDelegate?
    private var engine: AVAudioEngine?
    private var playoutInitialized = false
    /// WebRTC wants to play: a remote audio track is being received.
    private var playing = false
    /// The user turned sound on in the live view.
    private var wanted = false
    private var observers: [NSObjectProtocol] = []
    /// What the running engine played, logged when it stops (Settings → Log).
    private final class Meter: @unchecked Sendable {
        var frames: Int64 = 0
        var peak: Int16 = 0
    }
    private var meter = Meter()

    /// Plays while true and WebRTC has sound; false stops the engine and releases the audio session.
    var audible: Bool {
        get { lock.withLock { wanted } }
        set {
            lock.withLock { wanted = newValue }
            update()
        }
    }

    // MARK: RTCAudioDevice: output

    var deviceOutputSampleRate: Double { Self.rate }
    var outputIOBufferDuration: TimeInterval { AVAudioSession.sharedInstance().ioBufferDuration }
    var outputNumberOfChannels: Int { Int(Self.channels) }
    var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }

    // Never records: the input properties only satisfy the protocol.
    var deviceInputSampleRate: Double { Self.rate }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var isRecordingInitialized: Bool { false }
    var isRecording: Bool { false }
    func initializeRecording() -> Bool { false }
    func startRecording() -> Bool { false }
    func stopRecording() -> Bool { true }

    var isInitialized: Bool { lock.withLock { delegate != nil } }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.withLock { self.delegate = delegate }
        let center = NotificationCenter.default
        observers = [
            // A call or Siri stops the engine; play again when it ends, if sound is still on.
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] n in
                let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                if type == .ended { self?.restart() }
            },
            // Headphones in or out, a Bluetooth device: the engine stops and is rebuilt.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in
                self?.restart()
            },
        ]
        return true
    }

    func terminateDevice() -> Bool {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        lock.withLock {
            playing = false
            playoutInitialized = false
            delegate = nil
        }
        update()
        return true
    }

    var isPlayoutInitialized: Bool { lock.withLock { playoutInitialized } }

    func initializePlayout() -> Bool {
        lock.withLock { playoutInitialized = true }
        return true
    }

    var isPlaying: Bool { lock.withLock { playing } }

    func startPlayout() -> Bool {
        lock.withLock { playing = true }
        update()
        return true
    }

    func stopPlayout() -> Bool {
        lock.withLock { playing = false }
        update()
        return true
    }

    // MARK: Engine

    private func restart() {
        lock.withLock {
            engine?.stop()
            engine = nil
        }
        update()
    }

    /// Runs the engine exactly while WebRTC plays and the user wants sound.
    private func update() {
        lock.lock()
        let run = wanted && playing && delegate != nil
        if run == (engine != nil) {
            lock.unlock()
            return
        }
        if !run {
            let e = engine
            engine = nil
            let m = meter
            lock.unlock()
            e?.stop()
            if e != nil {
                let seconds = Double(m.frames) / Self.rate
                let peak = Int(Double(m.peak) / Double(Int16.max) * 100)
                Task { @MainActor in Log.add(String(format: "live view sound: played %.1f s, peak %d%%", seconds, peak)) }
            }
            // Other apps' audio may resume.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        meter = Meter()
        guard let e = makeEngine() else {
            lock.unlock()
            return
        }
        engine = e
        lock.unlock()
        do {
            let session = AVAudioSession.sharedInstance()
            // Media playback: follows the volume buttons and the selected output, plays with the
            // silent switch on like a video app, and never asks for the microphone.
            try session.setCategory(.playback, mode: .default)
            try session.setPreferredSampleRate(Self.rate)
            try session.setActive(true)
            try e.start()
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in Log.error("live view sound: \(message)") }
            lock.withLock { if engine === e { engine = nil } }
            e.stop()
        }
    }

    /// An engine whose source node asks WebRTC for 16-bit interleaved stereo at 48 kHz.
    private func makeEngine() -> AVAudioEngine? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.rate, channels: Self.channels, interleaved: true),
              let delegate else { return nil }
        let getPlayoutData = delegate.getPlayoutData
        let meter = meter
        let source = AVAudioSourceNode(format: format) { _, timestamp, frames, buffers in
            var flags = AudioUnitRenderActionFlags()
            let status = getPlayoutData(&flags, timestamp, 0, frames, buffers)
            for b in UnsafeMutableAudioBufferListPointer(buffers) where b.mData != nil {
                if status != noErr {
                    // Silence rather than noise when WebRTC has nothing to give.
                    memset(b.mData, 0, Int(b.mDataByteSize))
                    continue
                }
                let samples = b.mData!.assumingMemoryBound(to: Int16.self)
                for i in 0..<Int(b.mDataByteSize) / 2 where samples[i] != .min {
                    meter.peak = max(meter.peak, abs(samples[i]))
                }
            }
            meter.frames += Int64(frames)
            return noErr
        }
        let e = AVAudioEngine()
        e.attach(source)
        e.connect(source, to: e.mainMixerNode, format: format)
        e.prepare()
        return e
    }
}
