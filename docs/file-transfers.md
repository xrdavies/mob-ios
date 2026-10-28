# File transfers

Implementation branch: `feat/file-transfers`.

The [shared mobd contract](../../mobd/docs/file-transfers.md) defines the remote directory,
tus 1.0 uploads, authenticated Range downloads, completion/checksums and acceptance cases.

Add Files navigation for the active machine, a document importer and a document exporter.
TUSKit uses a foreground URLSession and bounded upload chunks. Preserve local upload copies,
SDK task metadata and download partial files across restarts. Pause transfers when the app
enters the background; returning to the app allows Continue. Continuous background upload
is deferred because iOS scheduling and TUSKit's unchunked resume path need separate testing.

Use existing pairing credentials, protect machine/address boundaries, and verify downloaded
content before allowing export. Show an update explanation for older mobd versions. Do not
change chat attachments or agent prompts.
