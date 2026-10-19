# mob-ios

Native iOS app (Swift, SwiftUI) for [mob](https://github.com/xrdavies/mob): dispatch AI agent tasks to your office Mac and monitor the desktop from your iPhone or iPad.

## Requirements

- iOS 17.0+
- Xcode 26 (the project uses Xcode 16+ synchronized folders: new files in `mob-ios/` need no project edits)
- Office Mac running [mobd](https://github.com/xrdavies/mobd) (API v3) with the `stream` feature

## Features

Same as [mob-android](https://github.com/xrdavies/mob-android):

- **Several office Macs**: add, edit and switch machines (Settings, or the switcher in the chat list); each has its own chats, pairing and live view quality
- **Pairing**: scan or paste the link from `mobd link`; the device credential is kept in the Keychain and sent as `Authorization: Bearer`. When mobd no longer accepts it (revoked, auth reset) the machine shows **Pair again**
- **Chats**: chat list with New chat, Pinned / Recent / Archived; swipe or long-press to rename, pin, archive or delete
- **Composer**: up to 10 photos (uploaded as JPEG), agent for a new chat, model and reasoning effort (remembered per machine and agent), **Stop**, adding a message to a running Codex turn (steer), queue position while waiting for the desktop
- **Timeline** like the desktop app: Markdown replies (copyable), agent steps folded into groups and expandable (commands, output, tools, reasoning, plans, file changes, screenshots), per-turn duration, tokens and cost, failures with Retry
- **Question and approval cards** in the chat
- **Live updates** over mobd's `/events` and `/tasks/{id}/events` streams
- **Notifications** for questions and finished or failed tasks on every machine; tap opens the chat. iOS allows no live connection in the background, so there the app checks when iOS grants a background refresh (typically every 15 minutes or more)
- **Setup warnings** from mobd's readiness checks
- **Live desktop**: see below

## Live desktop

A thumbnail under the title (hidden by default, toggled from the top bar; view-only; beside the chat on iPad) and a full-screen view with **View / Control**. Control: tap = click, long-press = right-click, drag = drag, two fingers = scroll, pinch = zoom, plus the phone keyboard and a keys bar (⌘ ⌥ ⌃ ⇧ latched for the next key, Esc, Tab, arrows, Paste types the phone's clipboard). Held input is released on View and in the background.

- **WebRTC**: `POST /stream` with a non-trickle offer; receive-only H.264 shown by `RTCMTLVideoView`; input on the `input` / `pointer` / `control` data channels, with points normalized to the desktop inside the letterbox. Protocol: [mobd desktop streaming](https://github.com/xrdavies/mobd/blob/main/docs/desktop-streaming.md).
- **WebSocket fallback**: if WebRTC has not connected after 5 s (or fails sooner), the same session continues on `/stream/ws` with the Bearer header, decoded by VideoToolbox. Used where UDP cannot pass (Tailscale Funnel, HTTPS gateways). A machine that needed it remembers that (`liveWebSocket`): next time WebRTC gets 1 s, then the WebSocket races beside it and the first frame wins.
- **Quality** Auto / High / Low per machine, from the view or Settings; applies at once (an open view reconnects). View size changes are sent as `resize` without reconnecting. A readout shows size, fps, kB/s, transport and network (LAN, Tailscale, Internet, relay) with signal bars.
- **Snapshots**: when the live view is off, `/screen` at the view width × screen scale, quality 65, with `If-None-Match` so an unchanged screen costs a 304; mobd's reason is shown when the screen is unavailable (asleep, no Screen Recording).
- mobd without the `stream` feature shows "Update mobd".

Not yet checked: a real phone by hand (clicks, typing, gestures), a throttled link, the real Funnel path and a phone off Wi-Fi, and the TestFlight check for camera/microphone purpose-string warnings from the WebRTC binary.

## Setup

1. Clone: `git clone git@github.com:xrdavies/mob-ios.git`
2. Open `mob-ios.xcodeproj` in Xcode, pick a simulator or device, Run
3. On the office Mac run `mobd link --url <address the phone can reach>`; in the app, Settings → Add machine, scan the QR code or paste the link, then Pair

From the command line:

```bash
xcodebuild -project mob-ios.xcodeproj -scheme mob-ios -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

`LiveStreamTests` open a real live view and are skipped unless `MOBD_URL` and `MOBD_TOKEN` (a paired device credential) are set; they only move the office pointer. The UI tests (`mob-iosUITests`) drive the app against a real mobd and expect a paired machine in the simulator; they create and send in a new chat.

## Releases

Not on the App Store yet. Releases go through TestFlight and the App Store by hand (no CI); see [docs/releases.md](docs/releases.md) for the release runbook (signing, App Store Connect, review, checklist).

## Architecture

- **SwiftUI** on iOS 17 Observation (`@Observable`)
- `Data/`: API models, `APIClient` (URLSession), pairing, Keychain, SSE reader, timeline builder, Markdown blocks
- `State/`: `AppState` (machines, health, notifications, one `MachineWatcher` per machine on `/events`) owns `ChatStore` (chat list and the open conversation) and `StreamSession`
- `Stream/`: the live desktop: `StreamSession` (WebRTC with [stasel/WebRTC](https://github.com/stasel/WebRTC), receive-only H.264 and data channels), `WsPlayer` (WebSocket fallback decoded by VideoToolbox through `AVSampleBufferDisplayLayer`), and the pure protocol code in `StreamProtocol`
- `UI/`: views; touch handling for the desktop uses UIKit gesture recognizers

## License

MIT (same as [mob](https://github.com/xrdavies/mob))

---

Part of the **mob** family:
- [mob](https://github.com/xrdavies/mob) — macOS desktop app
- [mobd](https://github.com/xrdavies/mobd) — office daemon
- [mob-ios](https://github.com/xrdavies/mob-ios) — this repo
- [mob-android](https://github.com/xrdavies/mob-android) — Android app
