---
name: linear-watch
description: >-
  Wake agent sessions when something changes in Linear. `lw`, a daemon next to
  pr-watch, polls Linear every 5 minutes and delivers new comments and state
  transitions to the sessions that subscribed to a Linear project or issue, so
  a pilot waiting on a decision hears about it without the human relaying it.
  Subscriptions end on their own: on unsubscribe, when the session is archived
  or stops renewing, or when the watched issue or project is finished. Ships
  `scripts/lw` (Python 3 standard library, one SQLite store). Work in
  progress: only the store and the subscribe / unsubscribe / list commands
  exist today; see ROADMAP.md. Use when a session must be woken by a Linear
  comment or state change, when subscribing a session to a Linear project or
  issue, or when listing what a session watches. Triggers on "linear watch",
  "lw subscribe", "réveiller la session sur Linear", "watch this ticket",
  "surveiller le projet Linear".
tags:
  - linear
  - claude
  - python
---

# linear-watch

> **Status:** skeleton (LW-1 of [ROADMAP.md](ROADMAP.md)). The store and the
> subscription commands work; polling, delivery (`lw wait`), expiry and the
> Claude adapter come with LW-2 → LW-8.

## Commands

| Command | Does |
|---|---|
| `lw subscribe --session ID --project SLUG\|URL [--since 3d] [--harness claude-code]` | Watch a project. A URL or a slug is reduced to its slugId. |
| `lw subscribe --session ID --issue TT-123 [--since 3d]` | Watch one issue (identifier or issue URL). |
| `lw unsubscribe --session ID (--project … \| --issue … \| --all)` | Close the matching open subscriptions, reason `unsubscribed`. |
| `lw list [--session ID] [--closed] [--json]` | Show open subscriptions (`--closed` adds closed ones). |

Every command takes `--state-dir` (default `$LW_STATE_DIR`, else
`~/.local/state/linear-watch`); the store is `lw.sqlite` in it.

## Behaviour worth knowing

- **Idempotent.** Subscribing twice to the same target keeps one open row and
  renews it. Re-subscribing after an unsubscribe opens a new row; the closed
  one stays as history.
- **One target, many spellings.** These three give the same target
  `5842ed0c2bcd`:

  ```bash
  lw subscribe --session S --project 5842ed0c2bcd
  lw subscribe --session S --project broker-pa-run-and-evolutions-courant-5842ed0c2bcd
  lw subscribe --session S --project https://linear.app/septeo-proptech/project/broker-pa-run-and-evolutions-courant-5842ed0c2bcd/overview
  ```

- **`--since` is capped at 7 days.** `--since 30d` is stored as 7 days before
  the subscription. Without `--since`, the first poll is a silent baseline;
  with it, changes after that point are delivered once (the "decision already
  taken" case). A second subscribe keeps the earliest `--since`.
- Errors go to stderr with exit 2; nothing is written on a bad target.

## Tests

```bash
bash skills/linear-watch/tests/run-in-docker.sh
```
