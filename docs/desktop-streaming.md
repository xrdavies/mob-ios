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
| I1 | Snapshot size | Simulator |
| I2 | View-only live view; "Update mobd" when `/health` lacks `stream` | Simulator + phone |
| I3 | Control over data channels | phone |
| I4 | Quality setting and readout | throttled link |
| I5 | WebSocket fallback (VideoToolbox) | Funnel address |
| I6 | Remove VNC/RFB/ARD code, `VncTests`, Desktop sign-in | build |
| I7 | Tests: signaling, message encoding, transport choice, migration | `xcodebuild … -only-testing:mob-iosTests test` |

Starts after the desktop app (D2) confirms the protocol. Merges with the other repos at release.
