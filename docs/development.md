# Development

## Test environment variables

Pass via `xcodebuild test` with `-only-testing:` or set in the scheme's Test action (Edit Scheme → Test → Arguments).

### LiveStreamTests

`LiveStreamTests` require a real mobd:

- `TEST_RUNNER_MOBD_USE_PAIRED_MACHINE=1`: reuse the simulator's active paired machine and its Keychain credential.
- Or supply `TEST_RUNNER_MOBD_URL` and `TEST_RUNNER_MOBD_TOKEN` directly.

Four cases check WebRTC, blocked-UDP WebSocket fallback, remembered fallback and return to WebRTC, including continued frames, pointer movement and resize.

### Input control tests

The two control cases additionally require `TEST_RUNNER_MOBD_INPUT_PROBE_PATH=/tmp/mob-ios-input-probe.json`. On the Mac running both mobd and the simulator, unlock the desktop and run the isolated input window first:

```bash
swiftc scripts/input-probe.swift -o /tmp/mob-ios-input-probe
/tmp/mob-ios-input-probe /tmp/mob-ios-input-probe.json &
```

The probe continuously writes click, key, drag and scroll events to the JSON file. Tests send input through the live view and verify the probe received them.

### Other test variables

- `MOBD_SEND_TEST_MESSAGE=1`: opt into sending a real message to mobd (costs tokens); default skipped.
- `MOBD_TALL_CHAT=<title>`: use an existing conversation with many turns for history scroll tests.
- `MOBD_OTHER_CHAT=<title>`: a second conversation for switching tests.
- `MOBD_LONG_CHAT=<title>`: a conversation with long replies for paging tests.
- `MOBD_PAIR_LINK=<link>`: a `mobd link` output for pairing tests.

## Accessibility audit

Run with `ACCESSIBILITY_AUDIT=1` to enable VoiceOver checks in UI tests:

```bash
xcodebuild test -project mob-ios.xcodeproj -scheme mob-ios \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:mob-iosUITests/AccessibilityTests \
  ACCESSIBILITY_AUDIT=1
```

Known failures as of 2026-10-28 (iPhone Duo adaptation): toolbar text clipping or insufficient Dynamic Type support; Settings selected icons, edit buttons and address rows have hit targets below 44×44 pt. Fixes and VoiceOver verification on a real device remain open.

## iPhone Duo simulator

Tested with Xcode 27.1 (27A9275), iOS Simulator 27.1 (24A94425), iPhone Duo. The app targets iOS 17.0 but has not been verified on an iOS 17 runtime or on a physical Duo device. See [iPhone Duo adaptation](iphone-duo.md) for acceptance status, inner/outer screen testing, folding, split view, and remaining gaps.
