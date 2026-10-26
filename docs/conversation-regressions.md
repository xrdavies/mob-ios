# Conversation regression checks

The fixes below address the 12 findings from the review of `830a232`.

| Finding | Result |
| --- | --- |
| 1. Drafts and uploads appear in another conversation | Text and attachments belong to a machine and conversation; callbacks retain that draft. |
| 2. Switching machines leaves the old desktop connected | Activation disconnects first, releasing held input; snapshots restart with the API client. |
| 3. Zoomed desktop input hits the wrong point | Clicks, drags and scrolls invert the displayed zoom and pan before normalization. Letterbox clicks are ignored. |
| 4. Failed sends lose text and images | The draft stays until acceptance; editing and attachment removal are disabled during submission. Failure preserves both. |
| 5. An old request's 401 invalidates the new machine | Direct requests carry their client; obsolete stream attempts and API clients cannot invalidate the active machine. |
| 6. Failed answers cannot be retried | Failure releases the question card; accepted answers remain disabled until refreshed. |
| 7. Slow sends reopen an old conversation | Completion checks the machine generation and navigation selection; attaching a machine clears transient send state. |
| 8. Failed uploads are silently omitted | A failed or unfinished attachment blocks sending; steering requires no attachments. |
| 9. The model is missing | Replies, working rows and turn metadata show the model. Codex app-server and Claude initialization now report it through mobd's resume event and persisted task. |
| 10. The desktop thumbnail shrinks with the keyboard | Width determines its aspect-fit frame, including the iPad side column. |
| 11. Confirmation dialogs show literal interpolation | Delete/archive titles and the desktop-loss warning interpolate correctly. |
| 12. Covered chats suppress notifications | Suppression requires the Chat tab, no list/pairing sheet and no full-screen desktop, as well as the foreground conversation. |

The separately reported keyboard/history disappearance has not been reproduced on a device. The confirmed output-following defect is fixed: the timeline observes content rather than the working row's unchanging ID. On iOS 18+, scroll geometry controls whether new output follows the bottom, and initial position, alignment and size-change anchors are configured separately. Conversation changes reset the scroll view. iOS 17 retains its bottom-anchor fallback.

## Validation

- Run `make test` on Xcode 26 with an iPhone 17 Pro simulator. The new state tests use `URLProtocol` with a reserved `.invalid` host, so no message reaches a real mobd.
- Run `go test -race ./internal/task ./internal/runner/claude ./internal/runner/codex ./internal/api` in the companion mobd repository for model persistence, stream events and runner contracts. Its runner tests use fake processes.
- On the development Mac without Xcode, 32 existing/new XCTest method bodies passed in a temporary Swift assertion harness. UIKit image and logging dependencies were stubbed; this does not validate UI or transport behavior.
- Swift syntax checks passed. UI and state code also passed a Mac Catalyst type check using the installed SDK and temporary stream stubs; WebRTC and a complete iOS build remain unchecked.

Before release, test on iPhone and iPad: A/B and machine switching with text/images/upload failure; delayed and failed sends; failed approval then retry; zoom/pan clicks and drag release; delete/archive cancel paths; notifications in Settings, Tasks, sheets and full-screen desktop. With desktop preview open, repeat keyboard open/close with a six-line draft, scroll up while output arrives and check rotation. `AppFlowTests.testDesktopThumbnailAndFullScreen` includes width and visible-history assertions while the keyboard is open; these UI tests require a paired test machine and have not run here.

Actual default-model names require the companion mobd update. Old tasks, older daemons and runtimes that do not report the effective model display `Default model (not reported)`; no model is guessed. Drafts remain in memory for the current app process. No dependency, release or deployment is added.
