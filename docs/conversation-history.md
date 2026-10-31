# Conversation history: local copy and paging (iOS)

Status: implemented on `feat/conversation-history`

Mob Mobile for iPhone and iPad keeps a local copy of each conversation and loads older turns as
you scroll. The protocol is in
[mobd](https://github.com/xrdavies/mobd/blob/main/docs/conversation-history.md):
`GET /sessions/{id}/history` for pages and bounded changes, `seq` for turn order, `sessionHistory`
in `/health`. Without that feature the app keeps today's full-snapshot request.

## Local copy

SQLite through the system `libsqlite3` (`Data/HistoryStore.swift`, an actor), in
`history.sqlite` under Application Support, excluded from backup, with file protection
`completeUntilFirstUserAuthentication`. Tables:

- `turns`: one row per turn (machine, conversation, task ID, `seq`, `rev`, size) holding the JSON
  of the turn with its messages, steps and questions, and mobd's cursor when the turn was the
  oldest of a page;
- `conversations`: the session row, `syncRev`, last opened order and stored size.

The schema version is SQLite's `user_version`. The oldest saved turn is the lowest `seq`.

Rows are keyed by the machine's `serverId` from pairing (the local machine ID when absent). A
corrupt file or a different schema version is deleted and rebuilt from mobd.

`ChatStore` writes in order through the actor: pages and changes as they arrive, the current turn
when it finishes or the conversation is left, and at most every 5 seconds while one runs, never
for each streamed event or poll. A turn is only replaced by a copy with at least its `rev`. With
paged history it replaces the eight-conversation memory cache; without it nothing is saved.

## Opening a conversation

1. Show the newest 20 saved turns at once, if any.
2. Sync: with a saved copy, `since=<syncRev>`; without one, the newest page. A `reset` answer drops
   the saved turns and loads the newest page. The existing polling and stream recovery use the
   same `since` request. `ChatStore` asks `/health` for `sessionHistory` itself; a saved copy
   counts as paged history while `/health` does not answer.
3. Scrolling near the top of `ChatTimeline` loads the 20 turns before the oldest shown: from the
   local copy while it has them, then from mobd with the cursor of the oldest saved turn.

Merging is by task ID, keeping the higher `rev` (`ChatDetail.mergedTurns`; the `AgentTask` model
gains `seq` and `rev`). Only turns from the oldest shown `seq` up are shown; a changed turn older
than that is saved (when inside the saved range) but not added to the end, so it can never become
`current`.

## Sync status

| State | Shown |
|---|---|
| Opening a saved chat, returning to the foreground, reconnecting | Spinner and **Syncing…** under the title |
| Up to date | Nothing |
| mobd unreachable | **Offline · showing saved copy** |
| Sync failed while online | **Couldn't sync · Retry** |
| Loading older turns | Spinner row at the top |
| Older turns not saved, offline | **Older messages aren't available offline** |

The status appears only after about 300 ms, and routine polls show nothing unless they fail; a
running turn keeps its live status. Reading and sending continue while syncing. Offline, the chat
list comes from the local copy and saved conversations can be read; sending is disabled (the
composer follows the connection) and images show their placeholder. Returning to the foreground
and a reconnected event stream sync with "Syncing…".

## Timeline

When older turns are prepended, the timeline scrolls back to the turn that was first
(`ScrollViewReader.scrollTo`, anchor top), so the visible turn stays in place. On iOS 18 the load
starts when the scroll offset comes within 400 points of the top (`onScrollGeometryChange`); after
the position is restored it is lower down, so one scroll loads one page. On iOS 17 a row above the
oldest turn starts it when it appears. A page load does not scroll to the bottom or start a second
request; an error leaves the cursor unchanged with Retry.

## Storage limit

At most 500 MB. Above it, the app removes the saved turns of the least recently opened
conversation, then the next, until it is under about 450 MB. A single conversation over the limit
keeps its newest turns and loses its oldest. The open conversation and any with a running turn are
never trimmed (the open one is trimmed when left). Conversations stay in the chat list.

Settings → **Saved conversations** shows the space used and **Clear local copy**.

## Removal

- `session.deleted`, a `404`, or a conversation missing from the list after being offline:
  delete it locally.
- Removing a machine, or mobd refusing this device (`markNeedsPairing`): delete that machine's copy.

## Verification

`mob-iosTests/HistoryTests.swift`: merging, the store's pages, `rev` rule and cursors, eviction
order and trimming, a corrupt file rebuilt and excluded from backup; `ChatStore` against a fake
mobd for first and older pages, a relaunch that syncs only changes and reads older turns from the
copy, an old changed turn not appended, `reset`, removal after a `404`, offline reading.

Checked on the simulator against a mobd from the `feat/conversation-history` branch with a 45-turn
conversation: pairing, the newest page, and scrolling up loads the page before without moving
the visible turn.
