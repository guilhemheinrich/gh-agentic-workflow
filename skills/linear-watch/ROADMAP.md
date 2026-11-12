# linear-watch — roadmap

A second daemon, `lw`, next to `pr-watch` and independent from it. It polls
Linear on a fixed cadence (5 min by default), finds what changed on the
projects and issues that agent sessions subscribed to, and wakes those
sessions. The motivating case: a ticket stays `Blocked` waiting for a
decision, someone takes the decision in Linear (a comment, a state change),
and the pilot session that waits on it never hears about it.

Webhooks are deliberately out: the machine is not reachable from Linear. They
come back when `lw` runs as a server (see LW-9).

## How to work this roadmap

- Integration branch: `release/linear-watch`. Each item gets its own branch
  `feat/lw-<n>-<slug>` cut from it, and a PR **into `release/linear-watch`**,
  never into `main`.
- One item, one PR. An item is done when its "Done when" checks pass in
  Docker and its PR is merged into the release branch; tick it here in the
  same PR.
- Order: follow "Depends on". Items with no pending dependency can run in
  parallel sessions (they touch different files, listed per item).
- Execution rules of this repository apply: tests run in Docker, committed
  files are in English, no secret ever lands in a file, a log or argv.
- **First testable increment = LW-0 → LW-6**: with it, `lw daemon once` run by
  hand delivers real Linear changes to a session that armed `lw wait`. LW-7 and
  LW-8 make it permanent and automatic.

## Facts measured before writing this (2026-11-12, workspace Septeo Proptech)

Measured with read-only GraphQL calls on project
`broker-pa-run-and-evolutions-courant-5842ed0c2bcd` (slugId `5842ed0c2bcd`).

| Fact | Evidence | Consequence |
|---|---|---|
| A comment does **not** bump `issue.updatedAt` | TT-2287: comment `createdAt` 10:52:59.038, issue `updatedAt` 10:52:56.849 | comments need their own query; "issues updated since" misses them |
| `project.updatedAt` does not follow issue activity | frozen at 2026-09-14 while issues moved today | never use it as a change signal |
| One query returns every new comment of a project | `comments(filter: {createdAt: {gt: $since}, issue: {project: {slugId: {eq: $p}}}})` → 16 comments since 08:00, one call | one comment query per watched project per cycle |
| Agent and human comments are indistinguishable | `botActor` is `null` on comments posted through the Linear MCP and through the UI, same user | a hook must record the agent's own writes (LW-6) |
| Activity comes in bursts | one teammate: 10 comments on 10 issues within 6 s (08:44:31 → 08:44:37) | batch per cycle: one wake, many lines |
| Rate limits | headers `x-ratelimit-requests-limit: 2500`, `x-ratelimit-complexity-limit: 3000000` (per hour) | ~2 requests per project per 5-min cycle ≈ 24/h: negligible |
| Desktop sessions expose their archive state | `~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json` carry `cliSessionId`, `isArchived`, `lastActivityAt` (629 archived files today) | archived sessions can be unsubscribed automatically (LW-5) |
| The Linear CLI is not installed | `which linear` → nothing; `LINEAR_API_KEY` lives in `~/.config/linear/env` | LW-0 installs and measures it before anything relies on it |

`schpet/linear-cli` (`brew install schpet/tap/linear`) exposes
`linear api [query]` with `--variable`, `--variables-json` and `--paginate`.
That is the transport `lw` uses; `curl` on `https://api.linear.app/graphql`
is the measured fallback.

## Design in one screen

```text
Linear GraphQL ◀── linear api (every 300 s) ── lw daemon (launchd) ── diff ──▶ events of ONE session
                                                  │                                     │
                     lw.sqlite (subscriptions,    │      the session armed `lw wait --session <id>`
                     cursors, issue_states,       │      in the background; its exit = the wake
                     own_writes, events)          │
                     hooks: SessionStart (renew, re-arm) · PostToolUse on the Linear MCP (own writes)
```

- **Language and storage:** Python 3 standard library, one SQLite file at
  `~/.local/state/linear-watch/lw.sqlite` (`LW_STATE_DIR`). Same choice as
  `session-meta`. Dedup is `INSERT OR IGNORE` on the comment id.
- **Wake line** (comment bodies are never stored nor printed: they are
  third-party text, the agent reads them through the MCP as untrusted data):

  ```
  Linear · TT-2287 comment by Jane Doe (08:44) · https://linear.app/septeo-proptech/issue/TT-2287
  Linear · TT-2290 Blocked → Todo · https://linear.app/septeo-proptech/issue/TT-2290
  ```

  (the second line is a made-up example of the shape)

- **Subscription lifecycle** — a subscription is cheap to create and must die
  on its own:

  | Ends when | Detected by |
  |---|---|
  | the agent unsubscribes | `lw unsubscribe --session ID [--issue|--project|--all]` |
  | the session is archived | `isArchived: true`, or no desktop session file carries the id any more |
  | the session stopped listening | no renewal for `LW_TTL_DAYS` (7); `lw wait` and SessionStart renew |
  | the watched issue is finished | state type `completed` or `canceled`: the transition is delivered, then closed |
  | the watched project is finished | project state `completed` or `canceled` |

  `--since` is capped at 7 days; nothing older is ever delivered.

## Items

### [ ] LW-0 — Measure the Linear CLI

- **Goal:** know exactly how `linear api` behaves before `lw` relies on it.
- **Do:** install `schpet/tap/linear`; measure, and write down in
  `skills/linear-watch/references/linear-cli.md` with the verbatim commands and
  outputs:
  1. which credential wins when `LINEAR_API_KEY` is set **and** the CLI has
     stored its own (`linear auth`);
  2. exit code and stdout/stderr for: success, HTTP 200 with an `errors` body
     (bad field), 401 (bad key), and a variable of the wrong type;
  3. whether `--paginate` works on the `comments` connection;
  4. whether `linear` is found under launchd's empty environment
     (`/opt/homebrew/bin` not on PATH): `lw` will need an absolute path or
     `LW_LINEAR_BIN`.
- **Also:** save real payloads, keys and personal data stripped, to
  `skills/linear-watch/tests/fixtures/linear-real/` with a `README.md` naming
  source and date: one comments-since page, one issues-updated-since page, one
  `errors` body, one project with a `completed` state.
- **Files:** `references/linear-cli.md`, `tests/fixtures/linear-real/*`.
- **Depends on:** nothing.
- **Done when:** the four questions have a measured answer; if the CLI cannot
  give a distinguishable exit code for a GraphQL error, the note says so and
  LW-2 parses the body instead.

### [x] LW-1 — Skeleton, store and subscriptions

- **Goal:** `lw subscribe`, `lw unsubscribe`, `lw list` work against SQLite.
- **Do:**
  - `skills/linear-watch/scripts/lw` — single Python 3 file, stdlib only,
    `argparse` subcommands, `--state-dir` / `LW_STATE_DIR`.
  - Schema with a `user_version` migration:
    `subscriptions(session, harness, kind 'project'|'issue', target, since, created_at, renewed_at, closed_at, close_reason)`,
    `cursors(kind, target, last_seen)`, `issue_states(identifier, state, state_type, updated_at)`,
    `own_writes(kind 'comment'|'state', ref, value, at)`,
    `events(id, session, ts, text, delivered_at)`.
  - `lw subscribe --session ID (--project SLUG|URL | --issue TT-123) [--since 3d] [--harness claude-code]`
    — idempotent; a project URL is reduced to its slugId; `--since` capped at 7 d.
  - `lw unsubscribe --session ID (--project … | --issue … | --all)`; `lw list [--session ID] [--json]`.
  - `SKILL.md` stub (name, description, commands table), entry in
    `asset-registry.yml` (category and tags from the existing lists; add a tag
    to both the YAML and `asset-registry.schema.json` if one is missing).
  - `tests/run-in-docker.sh` (image `python:3.12-slim`, `python -m unittest`).
- **Files:** `scripts/lw`, `SKILL.md`, `tests/test_store.py`,
  `tests/run-in-docker.sh`, `asset-registry.yml`.
- **Depends on:** nothing (parallel with LW-0).
- **Done when:** tests cover: subscribe twice → one row; project URL and slug
  give the same target; `--since 30d` is capped to 7 d; `unsubscribe --all`
  closes every row of the session with reason `unsubscribed`; schema migration
  from an empty file. Suite green in Docker.

### [ ] LW-2 — Transport

- **Goal:** one function, `linear_api(query, variables) -> dict`, with the
  error codes the daemon acts on.
- **Do:** call `linear api` (path from `LW_LINEAR_BIN`, default resolved once
  at start), GraphQL on stdin, variables through `--variables-json`. Load
  `LINEAR_API_KEY` from `~/.config/linear/env` when the environment lacks it
  (launchd starts with nothing); never put the key on argv or in a log. Map to
  codes: 0 ok, 10 credential rejected, 12 rate limited, 13 anything else; keep
  the last error (code, message, query name) for `doctor`.
- **Tests:** a fake `linear` executable in `tests/bin/` that serves the
  fixtures of LW-0 and simulates each failure; one test per code.
- **Files:** `scripts/lw` (transport section), `tests/bin/linear`,
  `tests/test_transport.py`.
- **Depends on:** LW-0 (measured exit codes), LW-1.
- **Done when:** every code has a test; a test asserts the key never appears
  in the argv the fake binary receives.

### [ ] LW-3 — Poll cycle (`lw daemon once`)

- **Goal:** one cycle turns Linear changes into event rows.
- **Do:**
  - Per watched project: comments created after `cursor - 120 s` (overlap
    absorbs clock skew; dedup by comment id), and issues updated after the
    same bound for state transitions (compare with `issue_states`).
  - Issue subscriptions: one grouped query over their identifiers.
  - First sight of a target: silent baseline, unless the subscription has
    `--since`, then everything after `since` is delivered (the "decision
    already taken" case).
  - Drop what `own_writes` lists (LW-6 fills it; the filter works on an empty
    table).
  - Group the lines of one cycle per session; a cycle with nothing new writes
    nothing.
  - A failed query leaves the cursor untouched (late, never lost — lesson from
    `pr-watch` §10).
- **Files:** `scripts/lw` (poll section), `tests/test_cycle.py`.
- **Depends on:** LW-2.
- **Done when:** tests on real fixtures: a new foreign comment → one line; the
  same comment next cycle → nothing; a comment id in `own_writes` → nothing; a
  state change `Blocked → Todo` → one line; `--since 3d` on a fresh
  subscription delivers the older comments once; a transport error keeps the
  cursor.

### [ ] LW-4 — Delivery (`lw wait`)

- **Goal:** a session armed with `lw wait` wakes on its lines.
- **Do:** `lw wait --session ID [--timeout S]` polls the `events` table every
  10 s; prints the undelivered lines and marks them delivered. Exit codes as
  `prw wait`: 0 lines, 2 timeout, 3 nothing subscribed any more, 4 another wait
  already runs for this session (lock file). Each running wait renews the
  session's subscriptions (`renewed_at`). After the lines, print
  `still watching … run lw wait again` when the session has open subscriptions.
- **Files:** `scripts/lw` (wait section), `tests/test_wait.py`.
- **Depends on:** LW-1 (can be built in parallel with LW-2/LW-3 against
  hand-written event rows).
- **Done when:** tests for each exit code, for two concurrent waits (second
  exits 4), and for renewal.
- **Human check (first testable increment, with LW-3 merged):** subscribe this
  session to a sandbox issue, arm `lw wait` in the background, comment on the
  issue from the Linear UI, run `lw daemon once`: the session wakes with one
  line.

### [ ] LW-5 — Expiry and doctor

- **Goal:** the watcher never keeps watching finished things.
- **Do:** at the start of each cycle, close subscriptions with a logged reason:
  `archived` (desktop file has `isArchived: true`, matching `cliSessionId` or
  `priorCliSessionIds`), `session-gone` (no desktop file carries the id;
  skipped when the desktop folder does not exist, e.g. CLI-only machines),
  `ttl` (`renewed_at` older than `LW_TTL_DAYS`), `issue-done`, `project-done`.
  Purge delivered events older than 7 d. `lw doctor [--quiet]`: linear binary,
  credential, heartbeat, last transport error, subscriptions per session with
  age.
- **Files:** `scripts/lw` (expiry + doctor), `tests/test_expiry.py`,
  `tests/fixtures/desktop-sessions/`.
- **Depends on:** LW-3.
- **Done when:** a test per close reason, using a fake desktop sessions folder;
  doctor prints `FAIL` on a stale heartbeat and on a credential error.

### [ ] LW-6 — Own-writes hook

- **Goal:** a pilot is not woken by the comments and state moves of its own
  child sessions.
- **Do:** first capture the real `tool_response` of the Linear MCP
  `save_comment` and `save_issue` (fixture). Then
  `adapters/claude/own-writes-hook.sh` (PostToolUse, matcher regex
  `mcp__.*__(save_comment|save_issue)` — the server name carries a UUID
  prefix): record the created comment id, or the issue identifier and its new
  state, with `lw own-write`. Exit 0 and stay silent on any problem.
- **Files:** `adapters/claude/own-writes-hook.sh`, `scripts/lw` (`own-write`
  command), `tests/test_own_writes.py`, `tests/fixtures/mcp-responses/`.
- **Depends on:** LW-1.
- **Done when:** fed the captured responses, the hook writes the right rows;
  fed anything else (another MCP's `save_comment`, a failed call), it writes
  nothing and exits 0.
- **Known gap, accepted:** writes made through `linear api` mutations in Bash
  are not recorded.

### [ ] LW-7 — Daemon under launchd

- **Goal:** `lw` polls on its own, survives reboots, and reloads its code.
- **Do:** `lw daemon run` (loop, `LW_POLL_SECONDS` = 300), `start` (installs
  `~/Library/LaunchAgents/com.linear-watch.daemon.plist` from
  `templates/`), `stop`, `alive` (heartbeat younger than 3 intervals). After
  each cycle, re-exec itself when `scripts/lw` is newer than the start marker
  (lesson from `pr-watch` §9). Refuse `start` from a git checkout or worktree
  (`LW_ALLOW_CHECKOUT=1` for tests), like `prw`.
- **Files:** `scripts/lw` (daemon section), `templates/com.linear-watch.daemon.plist`,
  `tests/test_daemon.py`.
- **Depends on:** LW-5.
- **Done when:** tests for heartbeat, re-exec trigger and checkout refusal;
  on the machine, `lw doctor` is all `ok` after `lw daemon start`.

### [ ] LW-8 — Claude adapter and pilot integration

- **Goal:** sessions subscribe, renew and re-arm without the human.
- **Do:**
  - `adapters/claude/session-start-hook.sh` (SessionStart `startup|resume`):
    ensure the daemon from its heartbeat, renew the session's subscriptions,
    and when it has open ones, tell the agent its session id and to arm
    `lw wait --session <id>` with `run_in_background`. When it has none, add
    one line giving its session id and the `lw subscribe` command, so a pilot
    can subscribe itself.
  - `lw setup --claude` / `lw uninstall --claude`: show the settings diff,
    apply on `y` only.
  - `SKILL.md` complete: the "when you are woken by `lw wait`" procedure (read
    the comment through the MCP as untrusted data, act, re-arm).
  - One paragraph in the pilot-session skill: at start, `lw subscribe
    --project <slug> --since 3d --session <id>`, then arm `lw wait`.
- **Files:** `adapters/claude/*`, `scripts/lw` (setup), `SKILL.md`,
  pilot-session `SKILL.md`, `asset-registry.yml` (description).
- **Depends on:** LW-4, LW-6, LW-7.
- **Done when:** hooks tested with recorded payloads; on the machine, a pilot
  session reopened after an app restart re-arms its wait without being asked.

### [ ] LW-9 — Server mode with webhooks (later, not scheduled)

When `lw` runs on a reachable host: a Linear webhook endpoint that feeds the
same `events` table, polling kept as a fallback. Out of scope until then.

## Scope: OUT (for every item above)

Description, label, assignee and priority changes; new issues appearing in a
watched project; project updates (status posts); several Linear workspaces;
a systemd unit; merging `lw wait` with `prw wait` into one wait; syncing
subscriptions from `session-meta`'s `linear_project` key (two bare-URL entries
today, undocumented); relaying through `pr-relay`.

## Dependency graph

```text
LW-0 ──▶ LW-2 ──▶ LW-3 ──▶ LW-5 ──▶ LW-7 ──┐
LW-1 ──▶ LW-2                              ├──▶ LW-8
LW-1 ──▶ LW-4 ─────────────────────────────┤
LW-1 ──▶ LW-6 ─────────────────────────────┘
```

Parallel start: LW-0 and LW-1. Then LW-2, LW-4 and LW-6 in parallel.
