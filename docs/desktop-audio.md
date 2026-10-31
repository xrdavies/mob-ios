# Remote desktop audio

Status: draft, 2026-11-01. Not implemented.

Follow the [mobd audio contract](https://github.com/xrdavies/mobd/blob/main/docs/desktop-audio.md)
for `streamAudio`, the optional `audio:true` request/result, Opus, WebSocket
type `2`/`audioAck`, shared clocks, failure behavior and acceptance targets.
Both WebRTC and WebSocket are required for feature completion on iPhone/iPad.

## Current state and change boundaries

`StreamSession` currently offers only video through the existing stasel WebRTC
package. `WsPlayer` handles H.264 and `AVSampleBufferDisplayLayer`. There is no
remote-audio player. Reuse these session lifetimes rather than opening another
remote session or adding a full media SDK.

| Area | Planned change |
| --- | --- |
| `mob-ios/Data/APIClient.swift` and response models | Audio request/result and capability handling |
| `mob-ios/Stream/StreamSession.swift` | Audio transceiver, output ownership, transport race and interruption handling |
| `mob-ios/Stream/WsPlayer.swift`, `StreamProtocol.swift` | Audio packet validation, acknowledgement, decode/playback and timestamp mapping |
| `mob-ios/UI/Desktop.swift` | Sound/mute state, unavailable/retry explanation and accessibility |
| `mob-ios/Info.plist`, package configuration | Review existing microphone usage description; package only the decoder needed for WebSocket |
| `mob-iosTests/StreamTests.swift`, `LiveStreamTests.swift` and UI tests | Pure protocol cases plus audible playback/lifecycle coverage |

## Sound flow and WebRTC

A newly opened live view starts with sound off. Explicit Sound checks capability
and reopens a video-only session with `audio:true`, keeping view geometry and
releasing held remote input. Add an audio `.recvOnly` transceiver and consume
the remote track through the existing WebRTC library. Do not create an audio
source, send track or microphone capture session.

The session, not an individual thumbnail/full-screen renderer, owns audio.
Only the winning transport may play; close the losing audio path. Local mute
and system media volume do not change the office computer's output volume or
promise to stop capture. Muting must not queue sound for later playback.

Audio failure leaves video/input working. Use the server result and
`about:audio` errors for explanations and retry; do not interpret a silent
application as missing support. Preserve the user's sound choice during a
transient reconnect inside the same view, but resume only current audio.

## iOS audio session

Configure playback deliberately and coordinate `AVAudioSession` through the
WebRTC audio-session API while WebRTC owns the output. Upstream defaults use
voice-chat/play-and-record settings and may prefer mono; they are not the
acceptance criteria for game sound. Start from a playback-oriented category and
normal media mode, stereo output where the route supports it, without enabling
recording. Verify the exact pinned WebRTC package accepts this configuration.
If its default audio device requires voice-processing I/O, use its supported
playback-only device integration rather than activating the microphone.

Receive-only SDP alone does not prove that the audio device never opens input.
Verify no microphone prompt/indicator on clean installs and reconnects. The
existing `NSMicrophoneUsageDescription` entry is a packaging detail, not
authorization to record. Review its wording during implementation without
removing required package declarations speculatively.

Handle interruption begin/end, audio route changes and engine reconfiguration.
Do not force the earpiece or a Bluetooth hands-free input route for media.
Respect system output/volume selection; report actual stereo capability and
measure Bluetooth separately. Return from an interruption only if this view
still owns playback and the user had enabled sound.

## WebSocket playback and sync

Parse the negotiated raw Opus packets separately from video and acknowledge
network consumption using `audioAck`, including while muted. Use a pinned
libopus decoder for this path unless a verified public platform decoder consumes
the exact raw packet format. The WebRTC package's internal decoder is not
assumed to be a public general-purpose Opus decoder.

Feed PCM to `AVAudioEngine`/`AVAudioPlayerNode` using a bounded queue; start with
60 ms target and 200 ms maximum pending audio. Decode off the main actor and
avoid one unbounded scheduled buffer per network packet. Flush stale audio on
discontinuity, reconnect and output reset; account for codec priming/latency in
the shared fixture. Use audio render sample time to map host PTS to local time
and drive the video layer's presentation timing. Hold the last image when the
screen is idle; audio must continue without new video frames.

WebRTC and the fallback engine must not compete to configure the audio session.
Switch ownership once a transport wins, and release the other engine. Decoding,
route or playback failure must not tear down an otherwise usable video stream.

## Lifecycle and acceptance

Follow the existing foreground live-view lifecycle. Backgrounding, closing the
view, switching machine/conversation, revocation or stream replacement stops
output and flushes samples. Do not add a background-audio entitlement. On return,
resume through the live-view connection flow with no old audio replay. Controls
need VoiceOver labels and the same state in thumbnail/full-screen views.

Add pure tests for format/result decoding, packet bounds, acknowledgements,
queue limits, discontinuity and stale callback suppression. Extend existing
`LiveStreamTests` with an isolated stereo-tone/flash fixture over WebRTC and
forced WebSocket, without asking an agent to generate sound.

Verify on physical iPhone and iPad, including the minimum supported iOS version:
left/right playback, no microphone access, built-in/wired/Bluetooth output,
phone/Siri interruptions, route changes, mute/unmute, background/foreground,
reconnect, duplicate-renderer ownership and 30-minute A/V drift. Compare latency
and skew to the mobd targets; simulator results alone do not establish routing
or real speaker latency. Exact audio-device compatibility and Opus packaging
remain implementation validation gates, not completed work.

## References

- [WebRTC audio-session defaults](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/components/audio/RTCAudioSessionConfiguration.m): reason to verify playback/route/stereo settings in the pinned build.
- [AVAudioPlayerNode](https://developer.apple.com/documentation/avfaudio/avaudioplayernode): scheduled PCM playback for the fallback path.
- [libopus](https://opus-codec.org/docs/): raw Opus decoding.
