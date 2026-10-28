# mob-ios

Mob for iPhone and iPad (Swift, SwiftUI). **Mob** is mob programming with your AI agents: they work on your office computer (via [mobd](https://github.com/xrdavies/mobd)), you steer from your iPhone or iPad: send tasks, answer their questions, watch and control the live desktop. The name comes from [mob programming](https://en.wikipedia.org/wiki/Mob_programming), where a team works on one computer together: one at the keyboard, the others steering. In Mob the team is you and your agents.

## Requirements

- iOS 17.0+
- Xcode 26 (the project uses Xcode 16+ synchronized folders: new files in `mob-ios/` need no project edits)
- An office computer (macOS or Linux) running [mobd](https://github.com/xrdavies/mobd) (API v3) with the `stream` feature

## Features

Same as [mob-android](https://github.com/xrdavies/mob-android):

- **Several office computers**: add, edit and switch machines (Settings, or the switcher in the chat list); each has its own chats, pairing and live view quality
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
- **Quality** Auto / High / Low per machine, from the view or Settings; applies at once (an open view reconnects). The actual canvas size and display scale size the stream; changes are sent as `resize` without reconnecting when mobd advertises `streamResize`. The full-screen canvas takes priority over the thumbnail; layout transitions are coalesced over 150 ms, and hidden canvases cannot restart the stream. A readout shows size, fps, kB/s, transport and network (LAN, Tailscale, Internet, relay) with signal bars.
- **Snapshots**: when the live view is off, `/screen` at the view width × screen scale, quality 65, with `If-None-Match` so an unchanged screen costs a 304; mobd's reason is shown when the screen is unavailable (asleep, no Screen Recording).
- mobd without the `stream` feature shows "Update mobd".

Not yet checked: a real phone by hand (clicks, typing, gestures), a throttled link, the real Funnel path and a phone off Wi-Fi, and the TestFlight check for camera/microphone purpose-string warnings from the WebRTC binary.

iPhone Duo simulator checks and remaining acceptance gaps are recorded in the [adaptation tasks](docs/iphone-duo.md). Real-device acceptance remains open.

## Setup

1. Clone: `git clone git@github.com:xrdavies/mob-ios.git`
2. Open `mob-ios.xcodeproj` in Xcode, pick a simulator or device, Run (Duo simulator tested with Xcode 27.1 / iOS 27.1; the app still targets iOS 17)
3. On the office computer run `mobd link`; in the app, Settings → Add machine, scan the QR code or paste the link, then Pair

From the command line:

```bash
xcodebuild -project mob-ios.xcodeproj -scheme mob-ios -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

`LiveStreamTests` require a real mobd. Set `TEST_RUNNER_MOBD_USE_PAIRED_MACHINE=1` to reuse the simulator's active paired machine and its Keychain credential, or supply `TEST_RUNNER_MOBD_URL` / `TEST_RUNNER_MOBD_TOKEN`. Four cases check WebRTC, blocked-UDP WebSocket fallback, remembered fallback and return to WebRTC, including continued frames, pointer movement and resize.

The two control cases additionally require `TEST_RUNNER_MOBD_INPUT_PROBE_PATH=/tmp/mob-ios-input-probe.json`. On the Mac running both mobd and the simulator, unlock the desktop and run this isolated input window first:

```bash
swiftc scripts/input-probe.swift -o /tmp/mob-ios-input-probe
/tmp/mob-ios-input-probe
```

It covers the desktop and records test clicks, drag, text, arrow keys and scroll; Esc closes it. Tests check release on the background notification and suppression of input in View mode. They refuse a locked, inactive, stale or different-host probe. The window redraws a heartbeat so an unchanged desktop does not stall the frame assertions. Run `-only-testing:mob-iosTests/LiveStreamTests` with the environment above; omit the probe variable to skip control cases.

UI tests expect a paired machine. `testDraftSurvivesRotationAndBackground` verifies an unsent draft after rotation and a confirmed switch to Settings. `testLiveViewResizeAndControlRelease` checks decoded video, actual UI resize messages and return to View after backgrounding. `testSendAndStreamReply` sends one new-chat message only with `TEST_RUNNER_MOBD_SEND_TEST_MESSAGE=1`; approve the real model request before enabling it. It checks the exact outgoing text, zero attachments, the displayed reply and usage, completion, and a received SSE message event. `testSentReplySurvivesRelaunch` is read-only: open that test conversation, then set `TEST_RUNNER_MOBD_VERIFY_TEST_REPLY=1` to check the reply and usage after restarting the app without sending again.

`testDraftAcrossDisplayChanges` is an operator-assisted test: set `TEST_RUNNER_MOBD_DISPLAY_CHANGES` to the number of transitions, then fold/unfold or resize in Device Hub at each `display-transition[n]` checkpoint. It waits for an actual window-size change and checks that the draft and Send button survive. It fails if no transition happens; it is skipped by default. UI screenshots include every screen reported by XCTest (including the Duo inner screen); use `simctl io … screenshot --display=primary-1` to verify the inner screen if XCTest returns black images.

`testLiveTouchCoordinatesAndZoom` uses the same local probe to check the actual full-screen UI: View suppresses input, pinch/pan/double-tap affect coordinates, letterbox taps are ignored, and rotation, right-click, drag and keyboard input reach the probe. Keep the probe in the foreground during these cases.

Optional UI checks (all disabled unless explicitly configured):

- Set `TEST_RUNNER_MOBD_TEST_PHOTO_LABEL` to the exact accessibility label of a synthetic photo imported with `simctl addmedia`. Draft tests select only that photo, upload it to local mobd, and verify the attachment count after transitions; they never send it to a model. The label is the picker date/time, not the filename.
- Set `TEST_RUNNER_MOBD_SPLIT_VIEW=1` on the Duo's open inner display for `testDraftAcrossSplitView`. It drags the app into both split sides and checks the draft and any seeded attachment.
- Set `TEST_RUNNER_MOBD_HISTORY_CHAT_TITLE` and `TEST_RUNNER_MOBD_DISPLAY_CHANGES` for `testHistoryAcrossDisplayChanges`. Choose an existing conversation with enough history; it only reads it and checks that the visible text survives each operator-assisted display transition.
- Set `TEST_RUNNER_MOBD_ACCESSIBILITY_AUDIT=1` for `testAccessibilityAudit`. This intentionally reports all issues without suppressions; current failures are recorded in the Duo task document.

`LayoutTests.testSettingsAndPairingAcrossRotation` needs no paired machine; repeat it with Device Hub's inner and outer screens. `testPairMachineFromLink` adds a paired device only when `TEST_RUNNER_MOBD_PAIR_LINK` contains a fresh, single-use `mobd link` invitation. Neither layout test sends a chat message. On this Xcode/runtime combination, add `-collect-test-diagnostics never` if automatic simulator diagnostics stall after tests finish; normal result bundles and attachments are still generated.

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
