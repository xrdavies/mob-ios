# mob-ios

Mob for iPhone and iPad (Swift, SwiftUI). **Mob** is mob programming with your AI agents: they work on your office computer (via [mobd](https://github.com/xrdavies/mobd)), you steer from your iPhone or iPad: send tasks, answer their questions, watch and control the live desktop. The name comes from [mob programming](https://en.wikipedia.org/wiki/Mob_programming), where a team works on one computer together: one at the keyboard, the others steering. In Mob the team is you and your agents.

## Requirements

- iOS or iPadOS 17.0+
- Xcode 27.1 or later (Swift 6, iOS 27.1 SDK) for building
- An office computer (macOS or Linux) running [mobd](https://github.com/xrdavies/mobd) (API v3) with the `stream` feature

## Features

- **Chat with your office agent** (Codex or Claude Code): send tasks, steer running turns, answer questions, and retry failed turns
- **Agent collaboration**: name agents with handles like `@api`, mention them in messages to delegate work, and see their exchanges in the timeline. Cancel pending requests and stop their turn. [Details](docs/agent-collaboration.md)
- **Files**: upload images and local files, download from the machine's shared directory, with pause/continue, persistent partial transfers and SHA-256 verification. Choose files and save locations with the system picker. [Details](docs/file-transfers.md)
- **Several office computers**: add, edit and switch machines (Settings → Machines, or the switcher at the top of the chat list); each has its own chats, pairing and live view quality
- **Pairing**: scan or paste the link from `mobd link`; the device credential is stored encrypted in the Keychain and sent as `Authorization: Bearer`. When mobd no longer accepts it (revoked, auth reset) the machine shows **Pair again**
- **Chats**: chat list with New chat, Pinned / Recent / Archived, and rename, pin, archive, delete per chat. Local copy with paging loads older turns as you scroll and shows saved conversations offline. [Details](docs/conversation-history.md)
- **Composer**: attach up to 10 images (re-encoded to JPEG when needed), pick the agent for a new chat and its model / reasoning effort (remembered per machine and agent), **Stop** a running turn, add a message to a running Codex turn (steer), queue position while waiting for the desktop
- **Timeline** like the desktop app: Markdown replies (copyable), agent steps (commands, tools, reasoning, plans, file changes, screenshots) folded into groups and expandable for details, per-turn footer with duration, tokens, cost, failure and Retry
- **Question and approval cards** in the chat when the agent needs your input; settled ones show the answer
- **Live updates**: each machine's `/events` stream keeps the chat list current, and the open chat follows its running turn over `/tasks/{id}/events` (polling as a fallback)
- **Notifications** when the agent asks something or a task finishes or fails, for every machine in the list; tap to open the chat. Optional background watching (Settings → Notifications) keeps the streams open with a background refresh task
- **Setup warnings**: mobd's readiness checks (Accessibility, Screen Recording, display, agent CLIs) show in the chat header and Settings
- **Live desktop**: a thumbnail under the Chat top bar (hidden by default, toggled with the monitor button; always view-only) and a full-screen view with **View / Control** switch. Tap = click, long-press = right-click, drag = drag, two fingers = scroll, pinch = zoom; a keys bar adds ⌘ ⌥ ⌃ ⇧ (latched for the next key), Esc, Tab, arrows and typing the device's clipboard. Control is released when the app stops. WebRTC (H.264, data channels for input); WebSocket fallback when UDP blocked (Tailscale Funnel, HTTPS gateways); remembered fallback preference. Quality Auto / High / Low per machine; readout shows size, fps, kB/s, transport and network with signal bars. System audio plays over WebRTC (media, not a call; no microphone). Snapshots when the view is off. [Live desktop details](docs/live-desktop.md)
- **USB redirection**: nothing to build in iOS for the first version; phones neither share USB devices nor control Desktop's shares. [Scope](docs/usb-redirection.md)

## Setup

1. Clone: `git clone git@github.com:xrdavies/mob-ios.git`
2. Open `mob-ios.xcodeproj` in Xcode, pick a simulator or device, Run (tested with Xcode 27.1 / iOS 27.1; the app targets iOS 17)
3. On the office computer run `mobd link`; in the app, Settings → Add machine, scan the QR code or paste the link, then Pair

From the command line:

```bash
xcodebuild -project mob-ios.xcodeproj -scheme mob-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

`LiveStreamTests` require a real mobd. Set `TEST_RUNNER_MOBD_USE_PAIRED_MACHINE=1` to reuse the simulator's active paired machine and its Keychain credential, or supply `TEST_RUNNER_MOBD_URL` / `TEST_RUNNER_MOBD_TOKEN`. Four cases check WebRTC, blocked-UDP WebSocket fallback, remembered fallback and return to WebRTC, including continued frames, pointer movement and resize.

The two control cases additionally require `TEST_RUNNER_MOBD_INPUT_PROBE_PATH=/tmp/mob-ios-input-probe.json`. On the Mac running both mobd and the simulator, unlock the desktop and run the isolated input window first: see [Development](docs/development.md).

## Releases

Signed IPAs are published to TestFlight and the App Store. Run `make release-patch` (or `release-minor`, `release-major`, or `make release VERSION=vX.Y.Z`): it bumps the version, asks for confirmation, commits it, tags that commit and pushes both; see [docs/releases.md](docs/releases.md) for the release runbook (Team ID and certificates, checklist, rollback, and TestFlight / App Store, which are not set up yet).

## Documentation

- [Agent collaboration](docs/agent-collaboration.md) — handles, @ picker, request details with Cancel and stop its turn
- [Live desktop](docs/live-desktop.md) — WebRTC/WebSocket, quality, audio, snapshots, acceptance gaps
- [Conversation history](docs/conversation-history.md) — local copy, paging, sync status, storage limit
- [File transfers](docs/file-transfers.md) — shared folder, tus uploads, Range downloads, SHA-256 verification
- [Development](docs/development.md) — test environment variables, input probe, accessibility audit
- [Releases](docs/releases.md) — runbook, App Store Connect, privacy, export compliance
- [USB redirection scope](docs/usb-redirection.md) — Desktop-only; nothing to build in iOS
- [iPhone Duo adaptation](docs/iphone-duo.md) — inner/outer screen, folding, split view acceptance
- [Conversation regressions](docs/conversation-regressions.md) — 12 findings and fixes from `830a232` review

## Architecture

- **SwiftUI** for all UI
- **Async/await + Combine** for async/reactive state
- **URLSession** for HTTP + Server-Sent Events
- **Live desktop** (`Stream/`): `StreamSession` over WebRTC (`stasel/WebRTC` 155.0.0, receive-only H.264 and data channels), `WsPlayer` (WebSocket fallback decoded by VideoToolbox into the same renderers), and `PlaybackAudioDevice` (media playback without the microphone)
- **State**: `AppState` (machines, health, live view) owns one `ChatStore` (chat list and the open conversation) for the active machine; `MobApp` holds the one `AppState`
- **SQLite** for conversation history (`Data/HistoryStore.swift`)

## License

MIT (same as [mob](https://github.com/xrdavies/mob))

---

Part of the **mob** family:
- [mob](https://github.com/xrdavies/mob) — macOS desktop app
- [mobd](https://github.com/xrdavies/mobd) — office daemon
- [mob-ios](https://github.com/xrdavies/mob-ios) — this repo
- [mob-android](https://github.com/xrdavies/mob-android) — Android app
