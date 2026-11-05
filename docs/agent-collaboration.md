# Agent collaboration on iOS

Status: architecture COLLAB-1, 2026-11-02. Implemented on main; see the status section below.

The shared [Mob vocabulary](https://github.com/xrdavies/mobd/blob/ddd731dfa64c0070345d423d9ff6add507d877cd/docs/agent-concepts.md) and
[mobd architecture](https://github.com/xrdavies/mobd/blob/ddd731dfa64c0070345d423d9ff6add507d877cd/docs/agent-collaboration.md)
define the overall design. iOS provides the interaction and displays the
collaboration saved by mobd.

## User flow

1. In agent A's chat, select agent B by its handle (`@api`) or by title in the
   `@` picker, and tell A what to
   collaborate on. Each existing conversation is an agent; Codex, Claude Code
   and Pi are the framework choices used to run it.
2. A sends a focused request. Show who contacted whom, what was requested and
   whether it is waiting, being handled, answered or needs user attention.
3. B may ask A for clarification. mobd delivers the exchange and resumes A
   after B's result so A can continue the user's task.
4. Let the user open B's conversation, inspect the exchange and stop or cancel
   the relevant work. Preserve the draft and reading position when navigating.

The handle names the agent; the title describes its work. Show the handle as
a badge next to the title, and lead with it in collaboration views. Archived
agents appear greyed out in the picker and cannot be selected; their row offers
Unarchive or moving the handle to this conversation (mobd's
[handles](https://github.com/xrdavies/mobd/blob/main/docs/agent-collaboration-design.md#handles)).
Mention selection identifies a specific session. Duplicate names need explicit
selection, and renaming an agent preserves that identity. Selecting a mention
alone does not send work to another agent.

## iOS responsibilities

Use the existing composer and chat views. Adapt mention selection and request
details to iPhone and iPad, with accessible labels and input. Keep a compact
pending-collaboration view available even in a very long conversation; load
exchange details when the user opens them.

mobd owns message delivery, execution and continuation. Collaboration continues
when iOS backgrounds or disconnects. On foregrounding, the app refreshes server
state; its local cache supports reading and does not schedule agent work.
This design does not depend on continuous iOS background execution.

## Assessment and scope

The architecture fits the existing app/server split and needs no separate iOS
agent engine. Desktop, iOS and Android must present the same collaboration
behavior, with interaction adapted to each platform. First delivery covers
existing agents on one mobd.

Validate the A/B exchange, user control and background/foreground recovery
first. UI component details, API models and cache changes follow after the
shared implementation contract is defined.

## Status: iOS (feat/agent-collab-core)

Built against mobd's `feat/agent-collab-core` API, matching Desktop's design. Unit tests pass.
Checked on the iPhone 17 Pro simulator against the office mobd running that branch (2026-11-06):
the timeline with peer messages, chips and step titles, the grouped picker and its naming step,
and the handle sheet (new handle, a broken rule, a handle another conversation holds). Not checked
there: starting an exchange from the phone, naming or moving a handle for real, a clarification.

- **Handles:** the badge shows next to the title; the chat list's menu opens a sheet with a fixed
  `@`, input kept to allowed characters, the rule explained as you type, a suggested handle, and an
  explicit "Move @handle here" when another conversation holds it. Remove is a separate action.
- **@ picker:** typing `@` at the end of the message lists "Agents" (with a handle) first, then
  "Conversations", without the open one; archived agents are greyed out. Picking one without a
  handle offers "Name it @suggested" or "Mention as @shortid". Picked and typed mentions are sent
  with the message; an archived one stops the send.
- **Who says what:** only your messages are on the right. Another agent's message is on the left
  with its coloured initial, name (opens its conversation), framework and what it did ("asks",
  "replied"), without mobd's instructions to the recipient. Mentions in your messages are chips
  that open that agent. Collaboration steps read "Asked @heron: …", "Replied: …".
- **Pending requests:** the strip above the timeline, with details and Cancel.

Not done: highlighting mentions while typing (SwiftUI's `TextField` gives no caret or styled text
without replacing the field), and the picker only follows an `@` word at the end of the text.
