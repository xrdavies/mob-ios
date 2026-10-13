# mob-ios

Native iOS app (Swift, SwiftUI) for [mob](https://github.com/xrdavies/mob): dispatch AI agent tasks to your office Mac and monitor the desktop from your iPhone or iPad.

## Requirements

- iOS 16.0+
- Xcode 15.0+
- Office Mac running [mobd](https://github.com/xrdavies/mob/tree/main/cmd/mobd) (API v3) with Screen Sharing enabled

## Features

- **Chat with your office agent** (Codex or Claude Code)
- **Task timeline** with live status updates
- **Question cards** when the agent needs your input
- **Live desktop view** (optional drawer; VNC over WebSocket)
- **Local notifications** for questions and completed tasks
- **No login required**: paste your office Mac's mobd URL and connect

## Setup

1. Clone: `git clone git@github.com:xrdavies/mob-ios.git`
2. Open `mob-ios.xcodeproj` in Xcode
3. Build and run on simulator or device
4. In Settings, enter your office Mac's mobd URL (e.g. `http://192.168.1.100:8080` or via Tailscale)

## Architecture

- **SwiftUI** for all UI
- **Combine** for reactive state
- **URLSession** for HTTP + Server-Sent Events
- **Starscream** (or native URLSessionWebSocketTask) for `/vnc` WebSocket
- **MVVM**: `APIClient` → `ChatViewModel` / `TaskViewModel` → Views

## License

MIT (same as [mob](https://github.com/xrdavies/mob))

---

Part of the **mob** family:
- [mob](https://github.com/xrdavies/mob) — office daemon + desktop app
- [mob-ios](https://github.com/xrdavies/mob-ios) — this repo
- [mob-android](https://github.com/xrdavies/mob-android) — Android app
