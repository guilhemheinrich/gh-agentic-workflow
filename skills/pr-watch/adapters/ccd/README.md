# Claude Desktop relay (`pr-relay`)

The Claude Code adapter wakes a session through its own background
`prw wait` (or legacy `bbw wait`). Two cases escape it:

- **The wait died.** An app restart kills background commands; the session's
  wake lines then sit in `events/<cli>.jsonl` until the human reopens it.
- **Nobody subscribed.** A PR opened from another session, from the terminal,
  or before the hooks existed is never polled.

`pr-relay` covers both, on top of the watcher's state dir, without changing
the watcher. It is the deterministic half; one **relay session** in Claude
Desktop is the other half, because only an agent turn can message another
desktop session.

```text
prw daemon ── events/<cli>.jsonl ──┐
                                   ├─ pr-relay wait (every 300 s) ── exit ──▶ relay session
Bitbucket: my open PRs ── discover ┘        │                                   │ send_message(local_…)
                                  subscribe ◀┘                                   ▼
                                                                         session that owns the PR
```

## Commands

| Command | Does |
|---|---|
| `pr-relay scan` | JSON `deliveries` (sessions with unread lines, no live wait, a desktop session that is not archived) with a ready `message`, and `undeliverable` ones |
| `pr-relay ack CLI N` | advance that session's cursor by N under its wait lock; exit 4 when its own wait is live |
| `pr-relay park CLI` | skip that session until a new line arrives for it |
| `pr-relay discover [--subscribe]` | your open PRs (all workspaces of the subscriptions) no subscription covers, with their owner; `--subscribe` subscribes the PR to that owner |
| `pr-relay wait [--interval S]` | loop: `discover --subscribe`, `scan`; exit 0 with the scan when something is deliverable |

## How a PR finds its session

Claude Desktop keeps one file per session under
`~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json`:

- `cliSessionId` and `priorCliSessionIds` map the watcher's session id (the
  Claude Code one, e.g. `59dcdcf5-…`) to the desktop id `local_…` that
  `send_message` takes;
- `prs[]` lists the PRs the app tied to the session, with their URL;
- `writtenBranches[]` lists `"<repo path>\0<branch>"` for every branch the
  session pushed.

The owner of a PR is the session whose `prs` holds that PR URL, else the most
recently active one that pushed its branch from a clone whose `origin` is the
PR's repository (a branch name such as `staging` alone matches every repo). Archived sessions (`isArchived`, or
listed in `archived-sessions.idx`) never own anything. A PR with no owner is
subscribed to the relay's own inbox (`PR_RELAY_INBOX`, default
`pr-relay-inbox`, an id no desktop session carries): its lines come back in
the scan's `relay` list, for the relay session to tell the human.

## The relay session

Arm, in a desktop session that stays open, with `run_in_background`:

```bash
pr-relay wait
```

When it exits, for each entry of `deliveries`:

1. `pr-relay ack <cli> <count>` first, so a wait the woken session re-arms
   does not hand it the same lines again. Exit 4 means the session's own
   wait came back to life and delivers by itself: send nothing;
2. `send_message` to `<local>` with `<message>` verbatim;
3. if the message was neither delivered nor queued, `pr-relay park <cli>`
   and tell the human which PR news did not get through. Never undo the ack:
   the wait would exit again at once and the relay would loop, one turn per
   round.

For each entry of `relay`, tell the human the lines in one short message,
then `pr-relay ack <cli> <count>`.

Then arm `pr-relay wait` again. `undeliverable` entries need no action.

## Settings

| Variable | Default |
|---|---|
| `PR_RELAY_WATCH_STATE` | `~/.local/state/pr-watch` when it holds subscriptions, else `~/.local/state/bitbucket-pr-watch` |
| `PR_RELAY_WATCH_CLI` | `prw` or `bbw`, matching the state dir |
| `PR_RELAY_WORKSPACES` | the workspaces of the current subscriptions |
| `PR_RELAY_USER_UUID` | read once from the author of a watched PR (the read-only token cannot call `/user`) |
| `PR_RELAY_SESSION_DAYS` | 30: older session files are not read |
| `PR_RELAY_STATE_DIR` | `~/.local/state/pr-relay` |

## Limits

- Bitbucket only: `discover` does not list GitHub PRs.
- A newly subscribed PR starts from a baseline snapshot: its current state
  (a pipeline that already failed) is not announced, only what changes next.
- The relay wait dies with the app like any other; re-arm it when you reopen
  the relay session.
