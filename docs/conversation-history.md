# Conversation history: local copy and paging (iOS)

Status: implemented

Mob Mobile for iPhone and iPad keeps a local copy of each conversation and loads older turns as
you scroll. The protocol is in
[mobd](https://github.com/xrdavies/mobd/blob/main/docs/conversation-history.md):
`GET /sessions/{id}/history` for pages and bounded changes, `seq` for turn order, `sessionHistory`
in `/health`. Without that feature the app keeps today's full-snapshot request.

The [agent collaboration draft](agent-collaboration.md) keeps pending requests
visible independently of loaded chat turns. The shared architecture is proposed;
its synchronization and cache details will be defined during implementation.

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
| Opening a chat with no saved copy | Spinner in place of the conversation, also while retrying |
| That first load failed | **Couldn't load this conversation** with the reason and **Retry**; polling keeps retrying |
| Opening a saved chat, returning to the foreground, reconnecting | Spinner and **Syncing…** under the title |
| Up to date | Nothing |
| mobd unreachable | **Offline · showing saved copy** |
| Sync failed while online | **Couldn't sync · Retry** |
| Loading older turns | Spinner row at the top |
| Older turns failed to load | The reason and **Retry** at the top, until Retry is tapped |
| Older turns not saved, offline | **Older messages aren't available offline** |

The status appears only after about 300 ms, and routine polls show nothing unless they fail; a
running turn keeps its live status. Reading and sending continue while syncing. Offline, the chat
list comes from the local copy and saved conversations can be read; sending is disabled (the
composer follows the connection) and images show their placeholder. Returning to the foreground
and a reconnected event stream sync with "Syncing…".

## Timeline

When older turns are added above, what is on screen stays where it is, also in the middle of a
long message (mob-ios#6). On iOS 18 the timeline keeps the last layout seen with each first turn;
when the first turn changes because older turns were added, the content grew above by the new
height minus the old one, and the offset grows by as much (`ScrollPosition.scrollTo(y:)`). The
change of first turn and the layout with the new turns arrive in either order, and SwiftUI does not
always report the layout just before, so both are matched by the first turn. The new offset is
set in the layout after the one with the new turns. A page that lands while a finger is on the
screen can still be off by about one drag step: the gesture keeps scrolling from where it started.
At the end of the conversation the
bottom anchor keeps the end in view instead. The row above the oldest turn has one
height whether it shows a spinner, an error or nothing, so it never moves the turns below. On iOS 17
the whole scroll view is anchored at the bottom, which keeps the text in place when turns are
added above; "at the end" is whether the bottom marker is on screen, so new content only scrolls
down there.

A long reply or message from another agent is several timeline rows of about 500 characters of
Markdown each (`markdownChunks`: whole blocks, a long paragraph cut after a sentence, a code block
every 20 lines), drawn as one message. The timeline is a lazy stack, which estimates the rows it has
not laid out; one row far taller than that estimate could make it alternate between the row laid
out and estimated in every layout while the end was followed or the keyboard moved, and the app
hung. When a conversation opens, it scrolls to the end again shortly after, as rows laid out then
can leave it short of the end, unless the timeline was touched.

On iOS 18 the load starts when the offset comes within 400 points of the top
(`onScrollGeometryChange`); once a page is laid out and the timeline is still that close (a short
page), the next one loads. On iOS 17 the row above the oldest turn starts it when it appears. A
page load does not scroll to the bottom; a failed page leaves the cursor unchanged and waits for
Retry instead of retrying on its own.

Each request for older turns belongs to one visit of the conversation (`visit`, counted by every
open): opening another conversation cancels it, and an answer for an earlier visit (A, then B, then
A again) changes neither the turns, the cursors, the error nor the spinner of the current one.

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
copy, an old changed turn not appended, `reset`, removal after a `404`, offline reading, an older
page from an earlier visit dropped while the current one keeps loading, and a failed first load
without a saved copy showing its error, then the spinner while retrying.

`mob-iosUITests/HistoryScrollTests.swift` (opt-in, against a real mobd with a long conversation):
no turn far from the newest is on screen when the chat opens, and while scrolling up with slow
drags the text on screen follows
each drag as two older pages are added. With `MOBD_SETTLE` it waits after each drag, for a mobd
behind a proxy that delays older pages, and requires that nothing moves while the timeline is at
rest.

Checked on the iPhone simulator (iOS 26) against mobd with a 45-turn conversation of long replies,
older pages delayed by 2 s through a proxy, pausing 3 s after each 300-point drag: nothing moved at
rest after any drag, the second page landed with the text exactly in place, and the last page,
landing during a drag, left it 119 points from where the drag put it. The same test on the previous
timeline failed at the second page (158 points). Not checked: iOS 17 (no simulator runtime here),
iPad, rotation and the keyboard.
