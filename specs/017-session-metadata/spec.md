# Feature Specification: Open session metadata, and a split check anchored on it

**Feature Branch**: `017-session-metadata`
**Created**: 2026-11-06
**Status**: Draft
**Input**: The conversation-focus split check has never fired. Many agent features need to attach durable facts to a session (its subject, its scope, its parent, its tracker links) and read them back by session id, from any harness.

## Context

Measured on 2026-11-06 over `~/.claude/projects`: 540 sessions received the `[conversation-focus]` injection 5,402 times, and no `start_session` call with `initiation: "offer"` came out of it. The same search found 29 `own_initiative` calls, so the zero is real. The sessions do drift. Session `87de7c7a` started as "pilotage roadmap calendar/IAM" and later carried the title "jeton Bitbucket du daemon prw". Session `039d7349` went from "fix calendar roadmap Linear" to "content vs payload notifications".

Three causes:

1. **No anchor.** The rule compares a message to "the conversation's main subject", which is written nowhere. The agent re-derives it every turn, so the subject drifts along with the conversation.
2. **A competing instruction wins.** The desktop app's system prompt says that when in doubt a message is a continuation, because an offer interrupts the user. The hook's context never says it takes precedence over that.
3. **No notion of a generalist session.** Some sessions are hubs on purpose: they take unrelated questions one after the other. Comparing each message to one subject is wrong there. What such a session should do is route each sizeable subject to a session in the project it belongs to.

The per-session state that already exists, `~/.cache/session-title/<id>.json`, has a fixed shape (`prevTitle`, `prevStatus`, `status`), lives in a cache directory that cleaners may wipe, and is private to one skill.

## Requirements

- **FR-1 — Open schema.** Metadata is a set of triples keyed by harness: `(harness, session_id, key) → value`, where the value is any JSON value. Neither the store nor the CLI knows any key. A new tool adds a key by writing it.
- **FR-2 — One read by id.** `session-meta get <session_id>` returns every key of that session as one JSON document. `--key` returns a single value.
- **FR-3 — Atomic writes.** `set` (replace), `append` (push onto a JSON array) and `unset`. Each one is atomic under concurrent hooks.
- **FR-4 — Cross-harness.** The harness column holds values such as `claude-code` or `cursor`. It defaults to the environment's harness. Two harnesses may use the same session id without colliding.
- **FR-5 — Durable location.** The store lives at `${AGENT_SESSION_META_DB:-${XDG_STATE_HOME:-~/.local/state}/agent-session/meta.sqlite}`. It is a state directory, not a cache.
- **FR-6 — Query.** `find --key K [--value V]` lists the sessions that carry a key (or a key/value pair), so later diagnoses are a query, not a grep over transcripts.
- **FR-7 — Anchored split check.** The conversation-focus prompt hook reads the session's `subject` and `scope` and injects them, with the exact `session-meta` commands, under the session's real id:
  - no `scope` yet: once the subject is clear (within the first few user messages), the agent pins `scope` (`focused` or `generalist`), and pins `subject` for a focused session;
  - `focused`: the split check compares the message to the pinned `subject`;
  - `generalist`: a sizeable subject that belongs to a project goes to a session opened in that project's folder, so the sidebar files it under that project.
  
  The split clause states that it overrides the "when in doubt, continuation" default.
- **FR-8 — Mechanical facts from the hook.** The prompt hook counts user messages in `turns`. When the agent proposes a split, it appends `{at, title}` to `split_events`.
- **FR-10 — One pin for the title and the split.** `session-title.sh pilot --name` writes `pilot` to the store, and session-title reads the title subject from the store in this order: `pilot`, then the spec slug, then `subject` when `scope=focused`, then the agent's `--subject`. When the store holds nothing, the cache's `pilot` still applies.
- **FR-9 — Fail open.** If `python3` or the store is missing or unreadable, the hook injects the rules without metadata, as it does today.

## Scope: OUT

- The Cursor and Codex adapters: their hook payloads have not been checked for a stable session id field. The store accepts `--harness cursor` already.
- A second model call to judge the session's scope. The agent judges it, as it judges splits (conversation-focus principle 2).
- Migrating the rest of `session-title`'s cache (`status`, `prevTitle`) into the store.
- Moving a session to another project's group after it was created. The sidebar groups sessions by folder, and a session cannot change its folder.

## Success criteria

- `get` on an unknown id prints `{}` and exits 0.
- Two concurrent `append` calls on the same key keep both items.
- A prompt-hook run for a session with `scope=focused` and a `subject` injects that subject. With no store, it injects the same rules as before.
