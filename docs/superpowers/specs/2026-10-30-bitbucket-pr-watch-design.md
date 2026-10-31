# bitbucket-pr-watch — design

Date: 2026-10-30. Status: draft for approval.

## Intent

An agent session that opened a Bitbucket pull request must learn, on its own and
within about a minute, when that PR changes state: the pipeline fails or ends, a
reviewer comments or approves, a merge conflict appears, the PR is merged or
declined. Today the human checks Bitbucket by hand. Example: on 2026-10-30 the
bill-e sessions for specs 167 and 168 both ended on "PR #228 / #229 awaits your
review" and knew nothing about the running PR-analysis pipeline or reviewer
comments.

The overriding constraint is **token economy**. Everything that can be
deterministic is deterministic (bash, curl, jq). The only LLM cost per event is
the one unavoidable turn of the session that owns the PR. That turn is
expensive: the 168 session held 652 messages, and an idle session's prompt cache
is cold after an hour, so each wake re-reads the whole context. Two
consequences drive the design:

1. No intermediary agent. A "watcher session" that relays to the owning session
   costs two turns per event instead of one, because only an agent can call
   `send_message`.
2. No wake without a real transition. PR #229 produced 3 webhook events in
   70 seconds (15:04:06 → 15:05:12); unfiltered, that is 3 full-context wakes.

## What the deliverable is

A **skill factory**: `skills/bitbucket-pr-watch/` in this repo. Activated in any
environment, it tells the agent how to install and configure the solution, and
it ships a reference implementation. It stays harness-agnostic: the core is a
CLI; each harness (Claude Code, pi, Cursor, …) gets a thin adapter. The skill
documents the adapter contract and ships the Claude Code adapter as the
concrete, working example.

## Goals

- G1. A session subscribes to its PR with no human action, triggered by a push.
- G2. The owning session is woken directly, once per real transition, with the
  measured fact already in the wake message (no follow-up API call needed).
- G3. Watched transitions: pipeline/commit-status state change (incl. failure
  and completion), new comment (any author, incl. inline/review comments),
  approval or request-changes added/removed, merge-conflict appears/clears, PR
  merged or declined, new commits pushed by someone else (my call, see below).
- G4. Self-configuring: `setup` stores a read-only Bitbucket credential
  properly; `doctor` verifies the install end to end.
- G5. Dependencies declared explicitly, checked by `doctor`.

## Non-goals

- No dependency on the Tiger Bus SharePoint folder (`evenements-pr/`) or on the
  Power Automate webhook. The human prefers a self-contained CLI that polls
  subscribed PRs, so the skill works on any machine.
- No write access to Bitbucket. The daemon never comments, approves, merges.
- No cross-machine coordination. One machine, one daemon, its own sessions.
- No UI, no dashboard.
- No relay ("postman") agent session, not even as a fallback. Accepted
  limitation, decided by the human on 2026-10-30 ("nothing critical here"):
  background waits die when the app restarts, and an idle session is re-armed
  only when the human reopens it (SessionStart). Transitions that occur in
  between stay in the events file and are delivered on the first `wait` after
  re-arming, so nothing is lost, only late.

## Anti-goals (failure even if it "works")

- A wake that carries nothing new (duplicate or no-op transition).
- An LLM turn spent anywhere other than the owning session.
- A silent failure: expired token, dead daemon or API errors that look like
  "nothing happened". `doctor` and the daemon log must surface them.
- A token committed to a repo or readable by other users.

## Architecture

```
git push ──> [git pre-push hook]  bbw subscribe --branch <b>     (harness-agnostic)
         └─> [harness hook]       arms the wake (Claude: PostToolUse on Bash `git push`)

bbw daemon (launchd / systemd --user, 0 token)
  every N s, for each subscribed PR:
    GET Bitbucket API  ->  normalised snapshot
    diff with previous snapshot  ->  append transition lines to events file
  PR merged/declined  ->  final event, subscription closed

session (background task)  bbw wait --session <id>
  blocks on the events file, exits on the first unseen transition,
  prints it  ->  the harness re-invokes the session  ->  agent acts, re-arms
```

### Core CLI `bbw` (bash ≥ 3.2, curl, jq)

Subcommands (names are my call):

| Command | Does |
|---|---|
| `bbw setup` | prompts for credentials (`read -s`), writes the env file, wires shells, installs the daemon unit |
| `bbw doctor` | checks deps, env in *this* shell, credential validity and scopes, daemon alive, last poll age, log errors |
| `bbw subscribe <workspace/repo> <pr> [--session <id>]` | adds a subscription; `--branch <b>` resolves the open PR of that branch |
| `bbw unsubscribe …` / `bbw list` | maintenance |
| `bbw wait --session <id> [--timeout s]` | blocks until an unseen transition for that session's PRs, prints it, exits 0; exits 2 on timeout, 3 when the session has no open subscription |
| `bbw daemon run` / `start` / `stop` | the poll loop and its unit management |
| `bbw status [<repo> <pr>]` | prints the current snapshot, for the agent or the human |

State lives under `${XDG_STATE_HOME:-~/.local/state}/bitbucket-pr-watch/`:

- `subscriptions.json` — `[{repo, pr, session, harness, since}]`. This is the
  PR ↔ session relation; it exists because the subscriber records its own id.
- `snapshots/<workspace>__<repo>__<pr>.json` — last normalised snapshot.
- `events/<session>.jsonl` — append-only transitions; a cursor file per session
  records the last line delivered by `wait`.
- `daemon.log` — one line per poll error, per transition, per start/stop.

Writes are atomic (`tmp` + `mv`); `subscriptions.json` is edited under a lock
(`mkdir` lock, portable to macOS).

### Snapshot and transitions

The snapshot keeps only fields whose change justifies a wake:

- PR `state` (OPEN / MERGED / DECLINED / SUPERSEDED), source commit hash.
- Participants: per user, `approved` and `state` (approved / changes_requested).
- Commit statuses on the source commit (pipelines and external builds such as
  the PR-analysis pipeline): `key → state`.
- Comments: set of ids, with author, created date, inline path:line, deleted
  flag. A new id is a transition; an edit is not (my call).
- Merge conflict: boolean, from the diffstat entries whose status is
  `merge conflict`. Computed only when the source commit or destination branch
  head changed, because the diffstat call is the heaviest one.

Each transition becomes one compact line, for example:

```
modelo-bill-e#229 pipeline "PR analysis" INPROGRESS→FAILED · https://bitbucket.org/…/pull-requests/229
modelo-bill-e#229 comment by Julien Boutet on src/cockpit/filters.ts:42 (id 4521)
modelo-bill-e#228 merged by Julien Boutet
```

Comment bodies are **not** included: they are third-party text and the agent
should read them deliberately, as untrusted data. The line names the id so the
agent can fetch it with the harness's Bitbucket tool or `bbw status`.

### Wake rules (what reaches the session)

Not every transition is a wake. The daemon records every transition in the
snapshot history, but releases a wake only for these:

- A commit status reaching a **terminal** state: SUCCESSFUL, FAILED, STOPPED.
  `→INPROGRESS` never wakes: the session usually caused it by pushing.
- A new comment, an approval / request-changes added or removed, a conflict
  appearing or clearing, a foreign head commit, PR merged or declined.

**Settle window.** A pending wake is released only after 30 s with no further
transition on that PR (`BBW_SETTLE_SECONDS`), and all pending transitions go
out as one batch. A FAILED status bypasses the window: failures are released at
once. Example: PR #229's 3 events in 70 s become 1 wake.

**Own actions do not wake.** The agent and the human share one Bitbucket
account, so author-based filtering cannot work (it would also hide the human's
own review comments). Instead:

- Each push recorded by the harness hook stores the expected head hash in the
  subscription. Only a head hash the session did not push is "foreign".
- Comments the agent posts are recorded by id through a hook on the harness's
  Bitbucket comment tool (Claude: PostToolUse on
  `mcp__bitbucket__add_pull_request_comment`), and `bbw ignore-comment` exists
  for other paths. Everything else, the human's comments included, wakes.

The first poll after a subscription only records a baseline and wakes nobody.

### Polling budget

Bitbucket Cloud allows about 1,000 API requests per hour per user (builder to
confirm current limit). Default: poll every 60 s; drop to 20 s while any status
on the PR is INPROGRESS (my call). Per PR and poll, at most 3 calls (PR,
statuses, comments since last seen) plus the diffstat when the heads moved.
With 5 open PRs that is about 900 calls per hour at the 60 s rate in the worst
case, so the daemon must back off on HTTP 429 and honour `Retry-After`, and use
conditional or `updated_on`-filtered queries where the API allows it. Interval
is configurable (`BBW_POLL_SECONDS`).

A subscription is dropped automatically when the PR closes, or when its session
is gone for 7 days (no `wait` call), so the poll set does not grow forever.

## Configuration (credential)

Two precedents in the human's own repos, combined:

- `gh-espanso-config/match/ai/spell-check.unix.yml`: environment variable first,
  then a 0600 file under `~/.config/<tool>/`, because a GUI-launched process
  does not inherit the shell environment; a missing dependency or key returns
  an explicit marker, never a silent no-op.
- `skills/sonarqube-config/templates/sonar-env.sh` + `sonarctl.sh doctor`:
  an idempotent template that writes the 0600 env file and sources it from
  `.bashrc`, `.bash_profile`, `.profile`, `.zshenv` (created for zsh users,
  because the Claude desktop shell tool runs `zsh -c`) and a fish `conf.d`
  loader; a `doctor` that proves the variable reaches *this* shell.

Applied here:

- File: `~/.config/bitbucket-pr-watch/env`, mode 0600, containing
  `BITBUCKET_WATCH_USER` (Atlassian account email) and
  `BITBUCKET_WATCH_TOKEN` (Atlassian API token, read-only scopes:
  `read:repository:bitbucket`, `read:pullrequest:bitbucket`,
  `read:pipeline:bitbucket`). A dedicated read-only token, not the one the
  Bitbucket MCP uses, so revoking one never breaks the other (my call).
- `bbw setup` writes it interactively with `read -s` (never echoed, never in
  shell history, never in argv), wires the shells, and prints the URL where the
  token is created plus the exact scopes to tick.
- The daemon and every `bbw` command **source the file themselves** when the
  variables are absent, so launchd/systemd units need no environment.
- `doctor` calls one cheap endpoint per scope and reports which scope is
  missing; it redacts the token in all output.

## Dependencies

Declared in the SKILL.md and checked by `doctor`:

- `bash` ≥ 3.2 (macOS default), `curl`, `jq` ≥ 1.6.
- macOS: `launchctl` (built in). Linux: `systemd --user`. Elsewhere: documented
  fallback `nohup bbw daemon run &` plus the SessionStart check that restarts it.
- `git` (for the pre-push hook and branch resolution).
- A Bitbucket Cloud account and API token. Bitbucket Data Center is out of
  scope (different API).

These run on the host. They are CLI tooling, like the host Python allowance of
2026-09-10; the Docker-only rule stays for builds and tests. The skill's own
tests (bats or plain bash with a fake `curl`) run in Docker.

## Harness adapters

### The contract (any harness)

An adapter provides three things:

1. **Subscribe on push.** Call `bbw subscribe --branch "$(git branch --show-current)" --session <id> --harness <name>`.
2. **Arm the wake.** Make the harness run `bbw wait --session <id>` so that its
   exit re-invokes the agent. If the harness cannot do that, the adapter
   documents the degraded mode: `bbw status` at the start of each turn.
3. **Ensure the daemon.** At session start, `bbw doctor --quiet || bbw daemon start`,
   and re-arm the wake if the session still has open subscriptions.

A push may come before the PR exists, so `subscribe --branch` with no open PR
records a pending subscription that the daemon resolves on its next polls
(one branch lookup per pending subscription, given up after 24 h).

Subscriptions are keyed by `(repo, pr, session)`. Re-subscribing the same key
only updates the expected head hash.

**Git `pre-push` hook: out of v1.** A git hook has no harness session id, so it
can neither wake an agent nor key a subscription. It is documented as the
fallback for a harness with no hook mechanism: the hook subscribes with
`--session human`, and that subscription is read with `bbw status` only.

### `bbw wait` lifetime

`bbw wait` has no timeout by default: a timeout exit is itself a full-context
wake carrying nothing. Exit 2 exists only when `--timeout` is passed. If the
adapter learns that its harness kills long background commands, it re-arms
silently on exit 2 and says nothing to the human.

**First task of the build: verify the wake assumption** in the Claude desktop
app and the CLI, before any other code. Arm `sleep 900; echo done` with
`run_in_background` in an idle session, and check three things: the session is
re-invoked, a 1 h background command survives, and the `session_id` survives a
resume. If any fails, stop and report: the adapter design changes, not a
detail.

### Claude Code (concrete example shipped)

- `hooks/bitbucket-pr-watch-push.sh`, PostToolUse, matcher `Bash`, acts only
  when the command contains `git push` (or when a Bitbucket MCP
  `create_pull_request` call succeeds). It runs `bbw subscribe` with the
  `session_id` from the hook payload, then returns two lines of
  `additionalContext`: "Subscribed modelo-bill-e#229. Run `bbw wait --session <id>`
  with run_in_background now." Claude's background Bash re-invokes the session
  when the command exits: that is the wake.
- `hooks/bitbucket-pr-watch-session-start.sh`, SessionStart: ensures the daemon;
  if `bbw list --session <id>` is non-empty, asks the agent to re-arm the
  background wait (background tasks do not survive an app restart).
- Wake handling rule in the SKILL.md: on a `bbw wait` exit, act on the fact,
  then re-arm while the PR is open. On exit 3, do not re-arm.

**Install location.** Same as the session-title hooks: scripts under
`~/.agents/hooks/`, wired at user level in `~/.claude/settings.json`. `bbw
setup --claude` prints the settings snippet and applies it only after the
human confirms; `doctor` checks the hooks are wired; `bbw uninstall --claude`
removes them. If a resumed session gets a new `session_id`, the SessionStart
hook re-keys that session's subscriptions (old id given in the payload, if the
harness provides one; otherwise matched by repo and branch of the cwd).

### pi, Cursor, others

The SKILL.md describes the contract and the Claude example; it does not ship
untested adapters. Building one for a given harness is a task the skill guides
the agent through when activated there.

## Repo integration

- `skills/bitbucket-pr-watch/` with `SKILL.md`, `scripts/bbw`,
  `templates/` (env, fish loader, launchd plist, systemd unit, pre-push hook),
  `adapters/claude/` (the two hooks + settings snippet), `tests/`.
- `asset-registry.yml` entry (path ending `/`, type `skill`, existing category
  and tags such as `claude`, `hooks`, `shell`; add a `bitbucket` tag to both the
  YAML and the schema enum if missing).

## Increments

The human pilots this session, so the first increment aims at something they
can run today on their Mac.

- **v1 (macOS, Claude):** wake-assumption check; `bbw setup` / `doctor` with
  bash, zsh (`.zshenv`) and fish wiring (the human's shell is fish); `subscribe`,
  `wait`, `status`, `list`; daemon under launchd; wake rules and settle window;
  the Claude push, comment and SessionStart hooks; registry entry. Acceptance:
  on a real PR, a reviewer comment and a pipeline end each wake the owning
  session exactly once.
- **Scope OUT of v1, next increment:** systemd unit, git `pre-push` fallback,
  MCP `create_pull_request` trigger, 7-day expiry, adapters for other harnesses.

## Left to the builder

- Exact Bitbucket endpoints and query parameters, and the current rate limit.
- Comment pagination strategy and how to detect "new since last poll" cheaply.
- Test approach details, within "fake curl, run in Docker".
- Internal file layout of `bbw` (one file or sourced libs).

## Calls I made (to check)

- Name `bitbucket-pr-watch`, CLI `bbw`.
- New commits by someone else count as a transition; comment edits do not.
- 60 s default poll, 20 s while a status is INPROGRESS.
- Dedicated read-only token rather than reusing the MCP's.
- Comment bodies left out of the wake line (untrusted third-party text).
- Subscriptions auto-expire 7 days after the session stops calling `wait`.
- Only terminal pipeline states wake; 30 s settle window, FAILED bypasses it.
- Own pushes and own comments filtered by recorded hash and comment id, not by
  author.
- Git `pre-push` hook deferred out of v1.
- `wait` has no default timeout.
- Hooks installed at user level, like session-title, after confirmation.
- v1 = macOS + Claude; systemd and other harnesses next.
