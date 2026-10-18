# Live desktop over WebRTC: iOS plan

Status: **draft**, branch `feat/webrtc-stream`. Design and protocol: [mobd desktop streaming](https://github.com/xrdavies/mobd/blob/feat/webrtc-stream/docs/desktop-streaming.md).

## Why

The live view is a native RFB client (`mob-ios/VNC/`) receiving the office Mac's full 4K framebuffer
over mobd's `/vnc`. mobd now streams H.264 at the size the client shows, over WebRTC (Pion) with a
WebSocket fallback. VNC is removed; mobd and the apps are released together.

## What changes here

| Area | Today | After |
| --- | --- | --- |
| Live view | `VNC/VncSession.swift`, `Rfb.swift`, `Framebuffer.swift`, `Ard.swift` | `Stream/StreamSession.swift` with the native WebRTC SDK (libwebrtc build); video view |
| Control | RFB pointer/key messages | data channels `input` / `pointer` / `control`; same gestures (tap, long-press, drag, two-finger scroll, pinch) and keys bar |
| Fallback | none | `/stream/ws` with the Bearer header, decoded with VideoToolbox |
| Snapshot | 960 / 1600 px | view width × screen scale, quality ≈ 65, `ETag` |
| Settings | Desktop sign-in (Keychain password) | removed; **Live view quality: Auto / High / Low** |
| Data | `Machine.vncUsername`, Keychain `<id>.vncPassword` | removed on first launch |

Open choice in I2: which WebRTC package (prebuilt libwebrtc XCFramework via Swift Package Manager);
check size, bitcode/arch, and license notices.

## Steps

| Step | Content | Verified by |
| --- | --- | --- |
| I1 | **Done.** Snapshot at the view width × screen scale (rounded up to 64 px), quality 65, `If-None-Match` so an unchanged screen costs a 304; the label shows mobd's reason (locked, asleep, no Screen Recording) | `SnapshotSizeTests`; office mobd |
| I2 | **Done.** `Stream/StreamSession.swift` with stasel/WebRTC 155.0.0 (SPM): recvonly H.264, non-trickle `POST /stream`, `control`/`input`/`pointer` channels, `RTCMTLVideoView`; VNC stays for mobd without `stream`; mobd's `ended`/errors shown | `StreamTests`, `LiveStreamTests` (simulator vs office mobd) |
| I3 | **Done.** Tap = click, long-press = right-click, one-finger drag, two-finger scroll; keys bar with latched modifiers and the phone keyboard (web key codes, Unicode text); points normalized inside the letterbox; held input released on View and in the background | `LiveStreamTests` pointer moves; clicks and typing by hand on a phone |
| I4 | **Done.** Auto / High / Low in the live view (gauge menu) and Settings, reconnecting with control kept; `resize` with mobd's `streamResize`; readout (size, fps, kB/s, transport, network) with signal bars | `LiveStreamTests`; throttled link still to do |
| I5 | **Done.** `Stream/WsPlayer.swift`: when WebRTC has not connected after 5 s (or fails sooner), the same session continues on `/stream/ws` with the Bearer header; Annex B access units become AVCC samples with a format description from the keyframe's SPS/PPS, shown by `AVSampleBufferDisplayLayer` (VideoToolbox), each frame acked; input, control and `resize` as text. Machines that needed it remember `liveWebSocket`: next time WebRTC gets 1 s, then the WebSocket races beside it; the first frame decides, as mobd does | `WebSocketVideoTests`, `LiveStreamTests` (4 cases); Funnel still to do |
| I6 | **Done.** `VNC/` (RFB, ARD sign-in, VNC auth, framebuffer), `VncTests`, the `/vnc` request and Desktop sign-in removed; `VncState` became `LiveState`. The live view waits for `/health` and shows "Update mobd" when mobd lacks `stream`. Saved machines drop `vncUsername`, and the Keychain `<id>.vncPassword` items are deleted once. Also fixed: a 401 on opening the live view now marks the machine for pairing, the phone keyboard typed into the VNC session instead of the stream, `liveWebSocket` was never saved, and the Settings quality picker did nothing (it now applies at once) | 35 unit tests; `LiveStreamTests` |
| I7 | Tests: signaling, message encoding, transport choice, migration | `xcodebuild … -only-testing:mob-iosTests test` |

Unblocked: the desktop app confirmed the protocol (D2) and built steps 3–5. I5 uses the WebSocket
protocol as revised in mobd M7b (540p start, `resize`, try the WebSocket first where it was needed).
I6 happens together with mobd M8 and desktop D6. Order across repos: see mobd's plan, "Order".

Follow the desktop design where it applies: the inline view only watches and the large view controls,
with a View/Control switch; quality switched from the view as well as Settings; a readout of size, fps,
kB/s, transport and network with signal bars; WebRTC gets a 5 s head start before the WebSocket.

### I2–I4 check (2026-10-19)

`LiveStreamTests` in the iPhone 17 Pro simulator (iOS 26.5) against the office mobd (`7a06a64`), with
a temporary client revoked afterwards. It only moves the office pointer.

| Check | Result |
| --- | --- |
| First picture (LAN, WebRTC, VideoToolbox decode in the simulator) | 318–369 ms at 1280×720 |
| Move while in View | not sent |
| Control, move to (0.25, 0.25) then (0.75, 0.6) | mobd's `cursor` reports both exactly |
| `resize` to 640 px | 640×360 without reconnecting |
| Readout | `640×360 · 1 fps · 62 kB/s · WebRTC · LAN` (idle screen) |

Not yet: the app on a real phone (clicks, typing, gestures by hand), a throttled link, and the
TestFlight check for camera/microphone purpose-string warnings from the WebRTC binary.

### I5 check (2026-10-19)

`LiveStreamTests` against the office mobd (`7a06a64`) in the simulator, two full runs; "blocked" drops
ICE candidates both ways. Each case also checks pointer moves (via mobd's `cursor`) and `resize`.

| WebRTC | WebSocket remembered | Carried by | First picture |
| --- | --- | --- | --- |
| works | no | WebRTC | 0.21–0.41 s |
| works | yes | WebRTC (returns to it) | 0.35–0.41 s |
| blocked | no | WebSocket after the 5 s head start, 960×540 | 5.3 s |
| blocked | yes | WebSocket, racing after 1 s | 1.3–1.4 s |

The remembered/blocked case failed twice in seven full runs: mobd ended those sessions because the
office Mac's screen had locked ("stream ended: screen unavailable"), not a client fault; alone, with the
screen awake, it passed every time. Not yet: the real
Funnel path, and a phone off Wi-Fi.

