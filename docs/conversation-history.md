# Conversation history pagination and incremental sync

Status: draft

The iOS client should adopt the mobd history-page contract while keeping
revision sync as the source of truth for live changes. See the shared protocol
draft in [mobd](https://github.com/xrdavies/mobd/blob/main/docs/conversation-history.md).

## API and state

Extend `APIClient` with a history-page request:

```text
GET /sessions/{id}/history?limit=50
GET /sessions/{id}/history?before=<cursor>&limit=50
```

`ChatStore` keeps `syncRev`, `historyBefore`, `historyHasMore`, and an
in-flight page flag per open session. The first open loads the newest page and
uses its `snapshotRev` as the initial revision baseline. Refreshes and SSE
recovery continue to call `session(_:since:)`; older-page responses do not
advance `syncRev`.

Tasks remain the merge unit. A revision response replaces the returned task and
all related messages, activities and questions. A page response inserts older
tasks by ID. If a revision update arrives for a task outside the loaded range,
keep it in the detail store so a later page cannot replace it with stale data.

When the server lacks `sessionHistoryPaging`, use the current full-session
request. Existing cached-session behavior remains valid during rollout.

## SwiftUI timeline behavior

`ChatTimeline` should detect that the scroll view is near its top and ask the
store to load the next older page. Use a stable first-visible `TimelineItem`
ID and its geometry to restore the scroll position after prepending rows. The
user must see the same content after a page loads.

Keep the existing bottom-follow behavior for live output. A top-page load must
not scroll to the bottom, clear an unseen-output state, or start a second page
request. Show a compact loading row at the top and leave the cursor unchanged
when a request fails so the user can retry.

## Cache and lifecycle

The existing eight-session in-memory cache can retain loaded pages, cursors and
the revision baseline. It is cleared with the current machine attachment and
does not become persistent storage in this draft. Background transitions keep
the loaded history; returning to the foreground reconciles through
`session(_:since:)` before resuming live output.

## Verification

Add tests for the API decoder, first-page and older-page merges, duplicate task
IDs, an old-task update received after paging, and full-snapshot fallback.
Exercise a SwiftUI scroll test that prepends rows without changing the first
visible item, plus an SSE reconnect test that reconciles through `since`.
