# mob-ios

Native iOS app (Swift, SwiftUI) for [mob](https://github.com/xrdavies/mob): dispatch AI agent tasks to your office Mac and monitor the desktop from your iPhone or iPad.

## Requirements

- iOS 17.0+
- Xcode 26 (the project uses Xcode 16+ synchronized folders: new files in `mob-ios/` need no project edits)
- Office Mac running [mobd](https://github.com/xrdavies/mobd) (API v3) with the `stream` feature; Screen Sharing is not needed

## Features

Same as [mob-android](https://github.com/xrdavies/mob-android):

- **Several office Macs**: add, edit and switch machines (Settings, or the switcher in the chat list); each has its own chats, pairing and live view quality
- **Chats**: chat list with New chat, Pinned / Recent / Archived; swipe or long-press to rename, pin, archive or delete
- **Composer**: up to 10 photos (uploaded as JPEG), agent for a new chat, model and reasoning effort (remembered per machine and agent), **Stop**, adding a message to a running Codex turn (steer), queue position while waiting for the desktop
- **Timeline** like the desktop app: Markdown replies (copyable), agent steps folded into groups and expandable (commands, output, tools, reasoning, plans, file changes, screenshots), per-turn duration, tokens and cost, failures with Retry
- **Question and approval cards** in the chat
- **Live updates** over mobd's `/events` and `/tasks/{id}/events` streams
- **Notifications** for questions and finished or failed tasks on every machine; tap opens the chat. iOS allows no live connection in the background, so there the app checks when iOS grants a background refresh (typically every 15 minutes or more)
- **Setup warnings** from mobd's readiness checks
- **Live desktop**: a thumbnail under the title (hidden by default, toggled from the top bar; view-only) and a full-screen view with **View / Control**. Control: tap = click, long-press = right-click, drag = drag, two fingers = scroll, pinch = zoom, plus the phone keyboard and a keys bar (⌘ ⌥ ⌃ ⇧ for shortcuts, Esc, Tab, arrows, Paste). Streamed by mobd over WebRTC (H.264), falling back to mobd's WebSocket where UDP cannot pass (Tailscale Funnel, HTTPS gateways); quality Auto / High / Low from the view or Settings, with a readout of size, fps, kB/s, transport and signal bars. When the live view is off it shows `/screen` snapshots
- **No login required**: paste your office Mac's mobd URL and connect

## Setup

1. Clone: `git clone git@github.com:xrdavies/mob-ios.git`
2. Open `mob-ios.xcodeproj` in Xcode, pick a simulator or device, Run
3. Settings → Machines → Add machine: your office Mac's mobd URL (e.g. `http://192.168.1.100:8080` or via Tailscale; `http://` is added if omitted)

From the command line:

```bash
xcodebuild -project mob-ios.xcodeproj -scheme mob-ios -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The UI tests (`mob-iosUITests`) drive the app against a real mobd and expect a machine saved in the simulator; they create and send in a new chat.

## Architecture

- **SwiftUI** on iOS 17 Observation (`@Observable`)
- `Data/`: API models, `APIClient` (URLSession), SSE reader, timeline builder, Markdown blocks
- `State/`: `AppState` (machines, health, notifications, one `MachineWatcher` per machine on `/events`) owns `ChatStore` (chat list and the open conversation) and `StreamSession`
- `Stream/`: the live desktop: `StreamSession` (WebRTC with [stasel/WebRTC](https://github.com/stasel/WebRTC), receive-only H.264 and data channels), `WsPlayer` (WebSocket fallback decoded by VideoToolbox through `AVSampleBufferDisplayLayer`), and the pure protocol code in `StreamProtocol`
- `UI/`: views; touch handling for the desktop uses UIKit gesture recognizers

## License

MIT (same as [mob](https://github.com/xrdavies/mob))

---

Part of the **mob** family:
- [mob](https://github.com/xrdavies/mob) — office daemon + desktop app
- [mob-ios](https://github.com/xrdavies/mob-ios) — this repo
- [mob-android](https://github.com/xrdavies/mob-android) — Android app
