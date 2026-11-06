---
name: session-meta
description: >-
  Open, durable metadata for agent sessions: a store of triples keyed by
  harness — (harness, session_id, key) → JSON value — read back as one
  document by session id. Neither the store nor the CLI knows any key, so a
  new tool attaches a new fact to a session by writing a new key: the pinned
  subject, the session's scope (focused or generalist), its parent session,
  its Linear issue, its split events. The harness column (claude-code,
  cursor, …) lets two hosts share one store without colliding on ids. Ships
  `scripts/session-meta.py` (Python 3 standard library, SQLite, atomic
  writes) and is read by the conversation-focus prompt hook to anchor its
  split check on a pinned subject. Use when a hook or skill must remember a
  fact about a session and get it back later, when pinning a session's
  subject or scope, when querying which sessions carry a fact, or when
  porting session state to another agent harness. Triggers on "session
  metadata", "métadonnées de session", "session-meta", "pin the subject",
  "sujet épinglé", "generalist session", "session généraliste".
tags:
  - claude
  - hooks
---

# session-meta

Some facts about a session must survive the conversation: what it is about,
whether it is a hub for unrelated questions, which session spawned it, which
Linear issue it implements. Kept in the agent's memory, they drift or vanish
after a compaction. Kept in one skill's private cache, other tools cannot read
them.

This skill gives every tool one place to put them.

## The model: triples, not a schema

```
(harness,      session_id,                              key,          value)
(claude-code,  4cf2c081-ee93-477d-984a-851b1e6ef7d5,    subject,      "Métadonnées de session")
(claude-code,  4cf2c081-ee93-477d-984a-851b1e6ef7d5,    scope,        "focused")
(claude-code,  4cf2c081-ee93-477d-984a-851b1e6ef7d5,    turns,        3)
(claude-code,  4cf2c081-ee93-477d-984a-851b1e6ef7d5,    split_events, [{"title": "Typo README billing", "turn": 2}])
(cursor,       9b1e…,                                   subject,      "Webhook Ingeneo 202")
```

- **The key is free.** No key is declared anywhere. A new tool writes
  `linear_issue` and from then on `get` returns it. Nothing else changes.
- **The value is any JSON value**: a string, a number, an object, a list.
  `--json` parses the value. Without it, the value is kept as a string, so
  `set s pr 42` stores `"42"`, not `42`.
- **The harness is part of the key.** A Claude Code session id and a Cursor
  conversation id never collide, and a tool can read another harness's
  session by passing `--harness`.

`get <session_id>` returns the whole document:

```bash
session-meta.py get 4cf2c081-ee93-477d-984a-851b1e6ef7d5
# {"scope": "focused", "split_events": [...], "subject": "Métadonnées de session", "turns": 3}
```

## CLI

```bash
session-meta.py get <sid> [--key K]                  # one document, or one value; {} / null when absent
session-meta.py set <sid> <key> <value> [--json]     # replace
session-meta.py append <sid> <key> <value> [--json]  # push onto a JSON array (a scalar becomes [scalar, value])
session-meta.py incr <sid> <key> [--by N]            # counter, from 0
session-meta.py unset <sid> <key>
session-meta.py find --key K [--value V] [--json] [--all-harnesses]   # which sessions carry K (=V)
session-meta.py sessions [--all-harnesses]           # ids with their key count, most recent first
```

Every command takes `--harness` and `--db`:

| Option | Default |
|---|---|
| `--harness` | `$AGENT_HARNESS`, else `claude-code` when `$CLAUDECODE` is set, else `unknown` |
| `--db` | `$AGENT_SESSION_META_DB`, else `$XDG_STATE_HOME/agent-session/meta.sqlite`, else `~/.local/state/agent-session/meta.sqlite` |

The store sits in a **state** directory, not in a cache directory. A cache
cleaner may wipe a cache, and this store is the record.

`append` and `incr` take SQLite's write lock before they read, so two hooks
writing at once both keep their change. The test suite checks this with ten
concurrent appends.

## Where the session id comes from

An agent does not know its own session id. Its hooks do: Claude Code puts
`session_id` in every hook payload. So a hook that wants the agent to write a
fact quotes the full command, with the id already filled in. The
conversation-focus prompt hook does exactly that:

```text
- Session scope not pinned yet (user message #1). … → python3 ".../session-meta.py" set 4cf2c081-… scope focused && … set 4cf2c081-… subject "<subject>"
```

Each new harness needs a port that answers one question: **does its hook
payload carry a stable session id?** If it does, the adapter passes that id
with `--harness <name>`. If it does not, there is nothing to key on, and the
metadata cannot follow the session. For Cursor and Codex this has not been
checked yet, so check their current hook documentation before writing an
adapter.

## Keys in use

This table is documentation, not a schema. It only lists who writes what.

| Key | Written by | Meaning |
|---|---|---|
| `turns` | conversation-focus prompt hook | user messages seen in this session |
| `scope` | the agent, prompted by conversation-focus | `focused` (one subject) or `generalist` (a hub for unrelated questions) |
| `subject` | the agent, for a focused session | the pinned subject: the split check is judged against it, and session-title keeps it as the title subject |
| `pilot` | `session-title.sh pilot --name` | what a pilot session pilots (its Linear project, its roadmap); the title subject, above the spec slug |
| `split_events` | the agent, when it proposes a split | `[{title, turn}]` — the measurement the split check never had |

## Consumers

- **conversation-focus** reads `scope` and `subject`, and injects them into its
  split check. It also counts `turns`. See that skill for the rules. Disable
  with `CONVERSATION_FOCUS_META=0`.
- **session-title** writes `pilot`, and reads `pilot` and, for a focused
  session, `subject`. Once either one is pinned, the title subject stops
  following the agent's per-turn topic.

## Installing

Copy the folder to `~/.agents/skills/session-meta/`, next to the installed
hooks in `~/.agents/hooks/`. The conversation-focus prompt hook finds the CLI
at `../skills/session-meta/scripts/session-meta.py` relative to itself, or at
`$SESSION_META_CLI`. Copy only from an up-to-date `main`, for the reason the
conversation-focus skill gives.

Tests, in Docker:

```bash
docker run --rm -v "$PWD:/repo" -w /repo/skills/session-meta/scripts python:3.12-alpine python3 -m unittest -v
```
