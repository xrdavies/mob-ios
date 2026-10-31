# Remote desktop audio (iOS)

Status: implemented on `feat/remote-audio` (WebRTC). No sound over the WebSocket fallback, by decision.

You hear the office computer's sound in the live view on iPhone and iPad. The protocol, stages
and capture are in [mobd's desktop audio doc](https://github.com/xrdavies/mobd/blob/main/docs/desktop-audio.md):
`streamAudio` in `/health`, `audio: true` on `POST /stream`, and `{"t":"audio","on":…}` on the
control channel.

## Playback without the microphone

WebRTC's own iOS audio device is built for calls: voice processing and play-and-record, which
can open the microphone and route sound like a phone call. `Stream/PlaybackAudioDevice.swift`
replaces it (`RTCPeerConnectionFactory(…, audioDevice:)`):

- It only plays. Its recording methods refuse, so WebRTC never records and iOS never asks for
  the microphone.
- An `AVAudioEngine` source node pulls WebRTC's decoded 48 kHz stereo PCM (`getPlayoutData`).
- The audio session is `.playback`, mode `.default`: media, following the volume buttons and the
  chosen output, and playing with the silent switch on, like a video app.
- The engine runs only while WebRTC has sound **and** the user turned it on; otherwise the audio
  session is released (`notifyOthersOnDeactivation`).
- After a call or Siri, and after an output change (headphones, Bluetooth), it starts again if
  sound is still on.
- When it stops it logs `live view sound: played N s, peak P%` (Settings → Log), so silence can be
  told apart from nothing arriving.

## Session and UI

`StreamSession`:

- With `streamAudio`, the offer gets a receive-only audio transceiver and the request
  `audio: true`.
- The answer's `audio` sets `sound`: `.off`, or `.unavailable(reason)`.
- `setSound(_:)` sends the control message and tells the audio device.
- mobd's `audio` messages move it to `.on`, `.unavailable` or `.error`.
- Over the WebSocket, sound is unavailable by decision (mobd's doc: sound that stutters is worse than none).

Turning sound on and off:

- A new live view starts with sound off.
- Reconnects within the view keep the choice.
- Closing the view (the last thumbnail or full-screen view gone) or going to the background turns
  it off.

`SoundButton` in `UI/Desktop.swift`: on the thumbnail (bottom right) and in the full-screen
toolbar. A speaker icon, green while on, a spinner while starting; when unavailable it explains
why.

## Verification

- `StreamTests.testSoundMessagesAndRequest`: control messages, the request and answer.
- `testSoundStaysOffUntilTurnedOnAndClosingTheViewTurnsItOff`: the lifecycle.
- By hand in the simulator against a mobd from the branch on this Mac: sound turned on from the
  full-screen view, and the device logged 7.4 s of playback at a 9% peak while system sounds
  played.

Still to check on a physical iPhone and iPad: no microphone indicator, built-in, wired and
Bluetooth output, calls and Siri, the silent switch, and audible delay. The simulator does not
show real routing or latency.
