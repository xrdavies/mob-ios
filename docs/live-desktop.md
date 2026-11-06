# Live desktop on iOS

Status: implemented (WebRTC and WebSocket fallback, with system audio)

A thumbnail drawer under the Chat top bar (hidden by default, toggled with the monitor button; always view-only) and a full-screen view with a **View / Control** switch: tap = click, long-press = right-click, drag = drag, two fingers = scroll, pinch = zoom; a keys bar adds ⌘ ⌥ ⌃ ⇧ (latched for the next key), Esc, Tab, arrows and typing the device's clipboard. Control is released when the app stops.

## Transport

- **WebRTC**: `POST /stream` with a non-trickle offer; receive-only H.264 shown by `RTCMTLVideoView`; input on the `input` / `pointer` / `control` data channels, with points normalized to the desktop inside the letterbox. Protocol: [mobd desktop streaming](https://github.com/xrdavies/mobd/blob/main/docs/desktop-streaming.md).
- **WebSocket fallback**: if WebRTC has not connected after 15 s (or fails sooner), the same session continues on `/stream/ws` with the Bearer header, decoded by VideoToolbox. Used where UDP cannot pass (Tailscale Funnel, HTTPS gateways). A machine that needed it remembers that (`liveWebSocket`): next time WebRTC gets 1 s, then the WebSocket races beside it and the first frame wins.
- **Quality** Auto / High / Low per machine, from the view or Settings; applies at once (an open view reconnects). The actual canvas size and display scale size the stream; changes are sent as `resize` without reconnecting when mobd advertises `streamResize`. The full-screen canvas takes priority over the thumbnail; layout transitions are coalesced over 150 ms, and hidden canvases cannot restart the stream. A readout shows size, fps, kB/s, transport and network (LAN, Tailscale, Internet, relay) with signal bars.
- **Snapshots**: when the live view is off, `/screen` at the view width × screen scale, quality 65, with `If-None-Match` so an unchanged screen costs a 304; mobd's reason is shown when the screen is unavailable (asleep, no Screen Recording).
- mobd without the `stream` feature shows "Update mobd".

## Audio

You hear the office computer's sound in the live view. The protocol, stages and capture are in [mobd's desktop audio doc](https://github.com/xrdavies/mobd/blob/main/docs/desktop-audio.md): `streamAudio` in `/health`, `audio: true` on `POST /stream`, and `{"t":"audio","on":…}` on the control channel.

WebRTC's own iOS audio device is built for calls: voice processing and play-and-record, which can open the microphone and route sound like a phone call. `Stream/PlaybackAudioDevice.swift` replaces it:

- It only plays. Its recording methods refuse, so WebRTC never records and iOS never asks for the microphone.
- An `AVAudioEngine` source node pulls WebRTC's decoded 48 kHz stereo PCM.
- The audio session is `.playback`, mode `.default`: media, following the volume buttons and the chosen output, and playing with the silent switch on, like a video app.
- The engine runs only while WebRTC has sound **and** the user turned it on; otherwise the audio session is released.
- After a call or Siri, and after an output change (headphones, Bluetooth), it starts again if sound is still on.
- When it stops it logs `live view sound: played N s, peak P%` (Settings → Log).

A new live view starts with sound off. Reconnects within the view (resize, quality) keep the choice. Closing the view or going to the background turns it off. Over the WebSocket, sound is unavailable by decision (mobd's doc: sound that stutters is worse than none).

## Acceptance gaps

Not yet checked on a real iPhone or iPad: clicks, typing, gestures by hand; a throttled link; the real Funnel path and a phone off Wi-Fi; the TestFlight check for camera/microphone purpose-string warnings from the WebRTC binary; no microphone indicator; built-in, wired and Bluetooth output; calls and Siri; the silent switch; and audible delay.

iPhone Duo simulator checks and remaining acceptance gaps are recorded in the [adaptation tasks](iphone-duo.md). Real-device acceptance remains open.

## Verification

- `StreamTests.testSoundMessagesAndRequest`: control messages, the request and answer.
- `testSoundStaysOffUntilTurnedOnAndClosingTheViewTurnsItOff`: the lifecycle.
- `LiveStreamTests`: WebRTC, blocked-UDP WebSocket fallback, remembered fallback and return to WebRTC, including continued frames, pointer movement and resize. Require a real mobd; see [Development](development.md).
- The two control cases check real desktop input with an isolated probe window; see [Development](development.md).
- By hand in the simulator against a mobd on this Mac: sound turned on from the full-screen view, and the device logged playback time and peak while system sounds played.
