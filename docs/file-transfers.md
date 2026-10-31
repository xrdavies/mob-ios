# File transfers

Implementation branch: `feat/file-transfers`.

The [shared mobd contract](https://github.com/xrdavies/mobd/blob/feat/file-transfers/docs/file-transfers.md) defines the remote directory,
tus 1.0 uploads, authenticated Range downloads, completion/checksums and acceptance cases.

The Files tab lists the office computer's shared folder (`~/mob-files`): folders first, opened by
tapping, never above the shared folder. Tapping a file downloads it straight into Mob's Documents
folder, which the Files app shows as *On My iPhone › Mob* (a name already there gets " (1)"); the
finished row offers Share. **+** uploads one or more files from the system importer into the open
folder. Long-press or swipe: Rename and Delete (a folder with everything in it, confirmed), with
mobd's `fileFolders`. Folders are not uploaded or downloaded as a whole on the phone. At most two
transfers run at once, shown at the top of the list.
TUSKit uses a foreground URLSession and bounded upload chunks. Preserve local upload copies,
SDK task metadata and download partial files across restarts. Pause transfers when the app
enters the background; returning to the app allows Continue. Continuous background upload
is deferred because iOS scheduling and TUSKit's unchunked resume path need separate testing.

Use existing pairing credentials, protect machine/address boundaries, and verify downloaded
content before allowing export. Show an update explanation for older mobd versions. Do not
change chat attachments or agent prompts.

## Verification

`FileTransferTests` exercises TUSKit and the transfer store against an isolated mobd. Pass `TEST_RUNNER_MOB_FILE_TEST_URL` and `TEST_RUNNER_MOB_FILE_TEST_TOKEN` from the fixture to `xcodebuild test -only-testing:mob-iosTests`. It pauses both directions, reconstructs the store, resumes, verifies exported bytes and checks empty uploads.

See the [shared verification record](https://github.com/xrdavies/mobd/blob/feat/file-transfers/docs/file-transfer-verification.md) for coverage and limits.
