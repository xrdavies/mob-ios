# Agent collaboration on iOS

Status: draft COLLAB-1, 2026-11-02. Not implemented or released.

Use the pinned [Mob vocabulary](https://github.com/xrdavies/mobd/blob/7db3f83c218bcf3ac7c9a3b75bbae5c3929f6c28/docs/agent-concepts.md) and
[mobd collaboration contract](https://github.com/xrdavies/mobd/blob/7db3f83c218bcf3ac7c9a3b75bbae5c3929f6c28/docs/agent-collaboration.md)
as the authority for IDs, messages, request states, tools and recovery. This
companion owns iPhone/iPad interaction, lifecycle and cached state. Update all
companions together when the canonical revision changes.

## Agent references and drafts

An existing conversation is an agent. The new-chat framework picker chooses
Codex, Claude Code or Pi and should say **Agent framework**. The `@` picker
chooses a particular session, using the proposed directory endpoint rather
than the framework entries in `/health.agents`.

In [Composer](../mob-ios/UI/Composer.swift), offer a compact candidate sheet or
popover appropriate to available space. Search only the selected paired server,
showing name, unique short ID, framework and busy/archive state. Support
`@name` and ID lookup, VoiceOver, Dynamic Type, software/hardware keyboards
and IME composition. Selecting a candidate never sends the current draft.

Store chips as `{serverId, sessionId, displayName}` in
[ChatDraft](../mob-ios/State/ChatDraft.swift), scoped to its machine/conversation.
IDs remain stable across rename; duplicate names and ambiguous prefixes require
selection. Quoted text, code and email addresses never dispatch messages.
There is no cross-platform character-offset encoding for mentions initially.

Include optional `agentRefs` in user turn creation and supported user steering.
Preserve references, text and attachments until the submitted draft version is
accepted; an error or unsupported route must not silently discard references.
Keep chips through rotation, scene transitions, split view and ordinary
background/foreground transitions. Current drafts are in memory; this plan does
not claim they already survive process termination or introduce automatic sending
of saved drafts. Reconcile an uncertain submission before offering a retry.

Use the pairing `serverId` for identity, even when the client switches LAN/remote
addresses. If pairing identifies a different server, invalidate old references.

## Conversation presentation

In [ChatView](../mob-ios/UI/ChatView.swift) and
[timeline views](../mob-ios/UI/TimelineViews.swift), render peer messages with
verified sender/recipient labels, framework where useful, request status and a
link to the other conversation. Preserve name-at-send in details. Do not render
a peer's content as a human instruction merely because its framework receives
text through a user-input channel.

A compact pending-collaboration summary is independent of the newest history
page. Open bounded request detail from it; an older request must not require
loading all intervening chat turns. On iPhone, use a detail sheet/view; on iPad,
use existing navigation without introducing a second independent session store.
Keep the source draft and reading position when following an agent link.

| Server request state | Label |
| --- | --- |
| `open` | Queued / Processing / Waiting for clarification / Waiting for collaborator, derived from current request/turn state |
| `answered` | Answered |
| `needs_attention` | Needs attention |
| `failed` | Failed |
| `cancelled` | Cancelled |
| `expired` | Expired |

Before normal handling-turn completion, a proposed final result is **Result
recorded; finishing**. Answered does not certify overall task completion.
Progress/notices can be visible without starting a model run.

Keep **Stop current turn**, **Cancel collaboration** and **Pause automatic
continuation** distinct. Show partial/late answers and interrupted delivery;
explicit resumption uses the current expected revision. Cancellation cannot
terminate unrelated work in the peer. Unavailable/archived targets keep an
explanatory link state rather than resolving a new same-name agent.

## Networking, backgrounding and storage

Gate controls on `agentCollaboration` in the server's feature list. A server
without it retains existing chat/history/live-view behavior. When offline,
saved request state is read-only and marked stale; keep drafts but disable send,
cancel and resume. Do not infer capability support from cached request records.

Extend [models](../mob-ios/Data/Models.swift),
[APIClient](../mob-ios/Data/APIClient.swift) and
[ChatStore](../mob-ios/State/ChatStore.swift) for bounded directory searches,
collaboration snapshots/changes, request details and scoped actions.
Cancel stale UI fetches when selection changes, without cancelling daemon work.
Use the server's proposed routes and state names from the contract.

SSE is an invalidation signal. Foregrounding, reconnection and event gaps trigger
bounded state recovery. Maintain `collaborationRev` separately from chat
`syncRev`; only a completed snapshot or successful change response advances
it. Apply tombstones and reset to the appropriate cache. Do not append a changed
old turn to the newest end, duplicate cards, or move the user's scroll anchor.

Extend [HistoryStore](../mob-ios/Data/HistoryStore.swift) through its existing
actor and SQLite copy: preserve provenance in turn payloads, and store pending
request summaries/detail pages independently. Upsert by ID/revision. Keep
pending summaries when old chat turns are evicted; bound cached bodies and
reload details as needed. A cache schema rebuild is a read-only resync, not a
reason to replay messages or restart work. Follow the current
[history removal rules](conversation-history.md) for server removal/revocation.

iOS suspension may disconnect SSE; mobd continues the exchange and owns every
continuation. No background execution entitlement or guaranteed background
socket is assumed. Existing foreground/watch notification delivery can surface
results when connected; do not promise remote push delivery without a separate
push implementation. Navigation or backgrounding must not gain desktop control.

## Implementation and acceptance

Implement API/model and cache additions, then reference selection/draft handling,
then cards and detail navigation. Validate shared wire fixtures with Desktop and
Android, including unknown states shown without implying success.

Extend state/history tests and focused UI checks for:

- Name/ID ambiguity, rename/delete, server replacement and paired-address changes.
- IME, VoiceOver, hardware keyboard, text size, rotation and iPad split layouts;
  draft/chip preservation and failed/uncertain submission.
- One-slot clarification round-trip, a busy recipient and final result before
  turn exit; correct sender identity and request/turn status separation.
- Suspension during each exchange step, foreground resync, process relaunch from
  saved request data, lost SSE and duplicate HTTP/SSE updates.
- Old pending requests outside the loaded history range, paginated details,
  reset/tombstones, cache eviction and stable scroll position.
- Stop/cancel/pause/resume conflicts, late replies, archive/delete and old-server
  fallback. Real framework runs follow mobd's approved integration workflow.

These are planned acceptance checks. This documentation change does not enable
collaboration or claim successful device/framework verification.
