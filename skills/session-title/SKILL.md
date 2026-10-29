---
name: session-title
description: >-
  Keep a Claude desktop session title equal to the next action its human owes —
  "🔀 À merger #12 · 042-webhook", "🧪 À tester · Mes Mailles impersonation",
  "📐 À planifier · 042-webhook" — chosen from 13 fixed templates instead of
  being reinvented each time. A Stop hook (`hooks/session-title-sync.sh`) runs
  at the end of each turn, gathers deterministic facts through
  `scripts/session-title.sh` (spec or free session, spec-kit stage, git state,
  PR state, whether the turn ended on a question) and, once per new set of
  facts, asks the agent to judge the human's next action and rename the
  session; only the agent can call the app's `set_session_title` tool. An age
  dot (🟢 under 5 min, 🟡, 🟠, 🔴, ⚫ over 4 days) is kept current by a watcher
  session that a bash loop over the app's session files wakes only when a dot
  must change, with a timed scheduled sweep as fallback. Works
  for spec-kit sessions (any spec-kit flow, not only /dev-it) and for free
  "vibe coding" sessions alike. Use when installing the title hook, when the
  hook asks for a title update, when a session's title no longer says what to
  do next, or when adding a status to the template set. Triggers on "session
  title", "rename session", "titre de session", "intitulé", "à merger",
  "à tester", "à clôturer".
tags:
  - spec-kit
  - claude
  - hooks
  - shell
---

# session-title

A sidebar of 30 sessions is useful only if each title says what the human must
do next. The title is read while the agent is idle, so it never describes what
the agent is doing — it names what the **human** does next.

## The split of work

| Who | Does what |
|---|---|
| `session-title.sh` | gathers facts, detects the session mode, renders titles from templates |
| `session-title-sync.sh` (Stop hook) | at the end of a turn, blocks the stop **once per new set of facts** with the facts and the allowed statuses |
| `session-title-ask.sh` (PreToolUse hook, `AskUserQuestion`) | before a click-to-answer question, denies the call **once** so the agent sets `decide` first |
| the agent | judges the status, picks the topic of a free session, calls `set_session_title` |
| `session-title.sh watch` (in a watcher session) | while sessions sit idle, wakes its agent only when an age dot or a merged PR changes a title |

The script proposes and the agent decides. The facts cannot tell a merged
webhook (to test on staging) from a merged README (to close). Only the
agent's judgement separates them.

## Session mode: spec or free

A session is **spec** when one of these holds, checked in order:

1. The session wrote into `specs/NNN-slug/` with `Write`, `Edit` or `MultiEdit`, as the transcript records.
2. The branch names an existing spec folder (`042-webhook`, `feat/042-webhook`).
3. Someone typed a `/speckit.*` command in this session.

Every other session is **free**: questions, investigations, vibe coding. The
spec mode is sticky once detected. A *read* of a spec does not count, so a hook
that prints `specs/012-…/context-keep.md` at session start cannot misclassify
the session.

The slug is the spec folder's name, never the agent's wording, and it follows
the folder. A scope change that renames `specs/295-parent-acts` to
`specs/295-child-tenant-acts` retitles the session at the next Stop, even when
nothing is written in the folder afterwards: a missing slug is followed
through its number. When two folders share the number, the script does not
guess and keeps the last known slug.

The title subject follows the mode. A spec session is named by its slug
(`042-webhook`). A free session is named by a 2-5 word topic that the agent
writes once (`Mes Mailles impersonation`). That topic stays until the agent
passes a new one.

## The template set

`templates/titles.json` is the single source. Format `{icon} {label} · {subject}`,
at most 60 characters; the script truncates the subject with `…`.

| Status | Title (fr) | Modes | Human's next action | Suggested when |
|---|---|---|---|---|
| `to-clarify` | ❓ À clarifier · 042-webhook | spec | answer, or `/speckit.clarify` | `spec.md` has `[NEEDS CLARIFICATION` |
| `to-plan` | 📐 À planifier · 042-webhook | spec | review spec, `/speckit.plan` | `spec.md` only |
| `to-split` | 🧩 À découper · 042-webhook | spec | review plan, `/speckit.tasks` | `plan.md`, no `tasks.md` |
| `to-implement` | 🔨 À implémenter 3/10 · 042-webhook | spec | `/speckit.implement` or "continue" | open tasks in `tasks.md` |
| `to-read` | 💬 À lire · <topic> | both | read the answer | nothing changed on disk |
| `decide` | 🙋 À trancher · <topic> | both | answer the question | the turn ended on `?` |
| `paused` | ⏸️ En pause · <topic> | both | say "continue" | agent judgement |
| `to-test` | 🧪 À tester #12 · <topic> | both | exercise the change | uncommitted work, or merged PR |
| `to-ship` | 🚀 À pousser · <topic> | both | approve commit / push / PR | uncommitted or unpushed work |
| `to-merge` | 🔀 À merger #12 · <topic> | both | review and merge | PR open, or branch pushed without a PR found |
| `merged` | 🏁 Mergé #12 · <topic> | both | test the change, or archive | set by the sweep only, never at Stop |
| `to-close` | 📦 À clôturer · <topic> | both | archive session and branch | merged PR |
| `blocked` | ⛔ Bloqué · <topic> | both | chase the outside dependency | agent judgement |
| `closed` | ✅ Clos · <topic> | both | nothing | PR closed |

## Language: one setting for every label

`SESSION_TITLE_LANG` sets the language of every fixed label, statuses and
activities alike. It defaults to `en`; `fr` is the other choice. The table
above shows the `fr` labels. The free-text subject is not a label: the agent
writes it in the session's language.

| `SESSION_TITLE_LANG` | At Stop | While working |
|---|---|---|
| unset or `en` | 🟢 🔀 To merge #12 · Pastilles et activités | 🔵 🛠️ Coding 4/5 · 295-child-tenant-acts |
| `fr` | 🟢 🔀 À merger #12 · Pastilles et activités | 🔵 🛠️ Code 4/5 · 295-child-tenant-acts |

## When the hook speaks to you

A Stop hook's block reason reaches you as an instruction to continue. It
carries the facts, a suggestion and the allowed statuses with their meaning.
Then:

1. **Judge** the human's next action. The suggestion is a starting point only.
   Example: the facts show 5 uncommitted files, so the suggestion is
   `to-test or to-ship`. The 5 files are a new skill with nothing to run, so
   the answer is `to-ship`.
2. **Run** the `set` command quoted in the reason. Add `--subject` in a free
   session.
3. **Rename** only if `set` printed a title: call
   `mcp__ccd_session_mgmt__set_session_title` with `session_id: "self"` and that
   exact title. On `UNCHANGED`, do nothing.
4. **Say nothing** about it to the user, and stop.

For a merged PR, apply this rule:

- `to-test`: the change has a surface a human can exercise (UI, endpoint, job,
  CLI), and nobody has confirmed it works. Example: a webhook that now answers 202.
- `to-close`: nothing to exercise by hand, or the human already said it works.
  Example: a skill, a README, a refactor covered by green tests.

## Questions the human answers by clicking

A click-to-answer question (`AskUserQuestion`) does not end the turn. The
tool call waits for the click, so the Stop hook never runs. Without help, the
sidebar would keep "💬 À lire" while the session waits on the human.

`session-title-ask.sh` closes that gap. When the agent calls
`AskUserQuestion`, the hook refuses the first call, with a reason that asks
the agent to:

1. run `set decide --subject "<topic of the question>"`;
2. rename the session with the printed title, for example
   "🙋 À trancher · PR 147 Analytics";
3. call `AskUserQuestion` again, which now goes through.

`session-title.sh gate` decides deny or allow. It allows when the status is
already `decide`. It never denies twice within `SESSION_TITLE_GATE_TTL`
seconds (default 300), so a declined rename cannot loop. It also clears the
Stop fingerprint, so the turn after the click re-titles the session.

## Working dot: the agent has the floor

When the human sends a message, the old title lies: "🟠 🧪 À tester" says the
human owes a test, yet the human now waits on the agent.
`session-title-working.sh` (UserPromptSubmit) asks the agent to make its
first tool call a rename, right after reading the message. The title then
says what the **agent** does, from the `activities` catalogue of
`templates/titles.json`, in the language of `SESSION_TITLE_LANG`.

| Activity (en) | (fr) | Agent is |
|---|---|---|
| 🔍 Investigating | Analyse | reading code, logs or docs to understand |
| 💭 Thinking | Réflexion | answering a question, weighing options |
| 📝 Specifying | Spécification | writing or amending a spec |
| 🗺️ Planning | Planification | writing a plan or a task list |
| 🛠️ Coding 3/14 | Code 3/14 | writing or changing code (counter in a spec with open tasks) |
| 🔬 Testing | Tests | running or writing tests, trying the change |
| 🐛 Debugging | Débogage | chasing a failure |
| 👀 Reviewing | Relecture | reviewing a diff, a PR or a document |
| ✍️ Writing | Rédaction | writing docs, a report or a message |
| 📤 Shipping | Livraison | committing, pushing, opening a PR |

- **Free session**: "🔵 🛠️ Coding · Verbes d'activité", with a topic that fits
  the new message.
- **Spec session**: the subject stays the spec folder,
  "🔵 🛠️ Coding 3/14 · 295-parent-acts". A spec session keeps its slug until
  it is closed or merged; `set` ignores `--subject` there.

At Stop, the working title goes away:

- **Facts changed**: the usual judgement runs.
- **Facts unchanged, spec session**: `restore` hands back the previous title
  with a 🟢 dot, in one call. The slug is not the agent's to choose.
- **Facts unchanged, free session**: the usual judgement runs too. The topic
  can move without any trace in git, so restoring would bring back a stale
  topic, such as "À tester · lancer Run now" long after the run.

The activities and the `working` fallback are never offered at Stop. A
session that crashed mid-turn keeps its activity and ages like any other, so
an orange "🛠️ Coding" means a turn that never finished.

## Live implementation counter

A long `/speckit.implement` or `/dev-it` turn may run for an hour without a
Stop. `session-title-progress.sh` (PostToolUse, matcher
`Agent|Task|Edit|Write|MultiEdit`) keeps the counter moving meanwhile:
"🔵 🛠️ Coding 0/14" becomes "🔵 🛠️ Coding 5/14" when phase 1 of
`tasks.md` is all checked.

- `session-title.sh progress` decides. It reads the cache and `tasks.md`
  only, with no git and no `gh`, and prints a title once per boundary.
- A boundary is a finished section of `tasks.md` (a `##` or `###` heading)
  by default. `"progress": { "every": "task" }` in the user config renames
  on every checked task instead.
- Subagents often tick `tasks.md`, and a subagent cannot rename its parent.
  The hook ignores calls made inside a subagent (`agent_id` in the payload)
  and fires on the parent's next call, usually the `Agent` call returning.
- The agent receives the exact title as `additionalContext`. One rename call
  per boundary, with no judgement, keeps the cost to a single short step.

Every hook stays silent in a scheduled-task run, detected by the
`<scheduled-task` tag at the top of its transcript.

## A PR merged while the session was idle

A PR is often merged from the forge while its session sits idle. No turn
runs, so no hook fires, and the title keeps saying "🔀 To merge #12". The
desktop app's PR bar does notice, but it covers GitHub only. Bitbucket
repositories such as `modelo-broker-pa` get no PR bar at all.

The sweep closes that gap for every forge, in the watcher and the scheduled
task alike. For each session whose title is `to-merge`, it reads `cwd` and
`branch` (from the session files, or from `list_sessions`), then checks:

- **GitHub** (`origin` on github.com, `gh` installed): `gh pr view <branch>`
  reports `MERGED`, and the PR number comes from there.
- **Any other forge**: `git fetch origin <base>`, then
  `git merge-base --is-ancestor <branch> origin/<base>`. Only a branch that
  exists on `origin` qualifies, so a fresh local branch never reads as merged.

A merged PR turns "🟠 🔀 To merge #12 · x" into "🟠 🏁 Merged #12 · x", and the
age dot keeps counting. The sweep cannot tell whether the change needs a hand
test, so `merged` leaves that call to the human: the next turn in the session
judges `to-test` or `to-close` as usual. Every network call is bounded
(`SESSION_TITLE_GH_TIMEOUT` for `gh`, 10 s for `git fetch`).

## Freshness dot: how long the session has waited

Every title starts with a dot that ages with the session:
"🟠 🔀 À merger #12 · 042-webhook" means this PR has waited more than 1 h 30.

| Age since the session's last activity | Dot |
|---|---|
| under 5 min | 🟢 |
| 5 min to 1 h 30 | 🟡 |
| 1 h 30 to 1 day | 🟠 |
| 1 day to 4 days | 🔴 |
| over 4 days | ⚫ |

No hook fires on an idle session, so two pieces share the work:

1. `set` always renders 🟢, because the turn has just ended.
2. A **watcher session** repaints idle sessions, and wakes only when a dot
   has to change. Its prompt is `templates/freshness-watch.md`.

A rename leaves `lastActivityAt` unchanged: renaming `local_3f5a96d8…` kept
`14:13:50.723Z`. Only titles built from the templates are repainted; running
and archived sessions are skipped. A title the human typed, such as "Horloge
de fraîcheur du titre", stays as it is.

### The watcher session (default)

The watcher splits the sweep in two halves:

1. **The trigger is pure bash.** `session-title.sh watch` reads the app's own
   session files, one `local_*.json` per session, which carry `title` and
   `lastActivityAt`. It runs `sweep` on them every 60 seconds and prints a
   line only for a rename not printed before. Silence costs no token.
2. **The rename stays with an agent.** One open desktop session runs
   `watch --once` in a background Bash call. The command exits on the first
   pending rename, which wakes the agent. The agent checks each printed
   session with `get_session` (running? archived? re-titled meanwhile?),
   renames, and relaunches the watch.

Example: a session goes idle at 10:00 with "🟢 💬 To read · x". At 10:05 the
watch prints `{"sessionId":"local_…","title":"🟡 💬 To read · x"}` and exits.
The watcher wakes once, renames it, and sleeps until 11:30 (🟠). Each session
costs at most 4 wakes, one per level, against 288 runs a day for a 5-minute
scheduled task.

**Start it once**: open a desktop session with the prompt "Read and follow
~/.agents/skills/session-title/templates/freshness-watch.md". Leave it open.
If a `session-title-freshness` scheduled task exists, disable it.

| Platform | Session files (`SESSION_TITLE_APP_DIR` overrides) |
|---|---|
| macOS | `~/Library/Application Support/Claude/claude-code-sessions/<org>/<account>/` |
| Windows (Git Bash) | `%APPDATA%\Claude\claude-code-sessions\<org>\<account>\` |

Facts measured on 2026-10-29 shape the design:

- **The files are read-only for us.** A title written into a session file
  with `jq` never reached the sidebar: `get_session` kept the old title, so
  the app holds titles in memory. Only `set_session_title` renames.
- **The files carry no `isRunning`, and lag behind the app.** `snapshot`
  treats a 🔵 title active in the last 5 minutes as running. A crashed turn
  still ages past that. The app does not rewrite the file during a turn: a
  session running at 11:03 still read `lastActivityAt` 10:57:20 on disk. A
  turn longer than 5 minutes therefore costs one false wake, and the
  agent's `get_session` check (`isRunning: true`) skips it. The file also
  trails the app by up to 10 s after a turn, so `snapshot` adds 15 s to
  `lastActivityAt`.
- **Most files are scheduled runs, and they still need dots.** On the
  author's machine, 3,270 of 3,723 files carry `scheduledTaskId`. Runs carry
  template titles too, such as "🟡 ✅ Closed · Balayage pastilles".
  `snapshot` drops only archived sessions, with `grep` before `jq` parses
  anything. The first pass scans every file (12 s for 3,336), later passes
  only files touched in the last 6 days (0.3 s for 170).
- **The watcher only ages dots.** A prompt bumps `lastActivityAt` before the
  working hook re-titles the session, so a 🟡 title briefly looks 🟢-fresh.
  The live run woke once for that. A younger dot is always the Stop hook's
  job, so `watch` drops any rename that would make a dot younger.
- **The watcher must not watch itself.** Each wake re-titles the watcher
  session, which would turn 🟡 five minutes later and wake it forever.
  `watch --session <its local id>` excludes it, and records its CLI id in
  `~/.cache/session-title/watcher.json` so the title hooks stay silent there,
  as they do in scheduled runs.

The pending set persists in `~/.cache/session-title/watch-seen.txt`. A
declined rename, or a session `get_session` reports as running, therefore
wakes nobody twice.

### Fallback: the scheduled task

Without an open watcher, a scheduled task can sweep on a timer instead. It
costs one full agent run per tick, even when no dot moves (limit 5). Its
prompt is `templates/freshness-sweep.md`, and its frequency lives in **one**
user-level file, `~/.config/session-title/config.json`
(`SESSION_TITLE_CONFIG` overrides the path):

```json
{ "freshness": { "enabled": true, "sweepMinutes": 5 } }
```

Without the file, the sweep runs every 5 minutes. Accepted values are 1 to 59
minutes, or a whole number of hours (120 → `0 */2 * * *`). Each run checks its
own cron against `session-title.sh cron` and corrects it. `"enabled": false`
strips every dot, for the task and the watcher alike.

Install it from a desktop session: ask the agent to create a scheduled task
with `taskId: "session-title-freshness"`, the cron printed by
`session-title.sh cron`, and the prompt "Read and follow
~/.agents/skills/session-title/templates/freshness-sweep.md".

## Install (Claude Code, user scope)

`install.sh` / `install.ps1` copy the skill to `~/.claude/skills/` (and to the
other agent directories), copy `hooks/` to `~/.agents/hooks/` and `scripts/` to
`~/.agents/scripts/`, then register the four hooks in `~/.claude/settings.json`
through `scripts/hooktools/merge-claude-hooks.cjs` (requires Node.js). The merge
is idempotent and leaves every other setting and hook untouched; pass
`--no-claude-hooks` (`-NoClaudeHooks` on PowerShell) to skip it. The manifest is
`scripts/hooktools/claude-code-hooks.json`. For a manual setup, register them in
`~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "bash ~/.agents/hooks/session-title-sync.sh" }] }],
    "PreToolUse": [{ "matcher": "AskUserQuestion", "hooks": [{ "type": "command", "command": "bash ~/.agents/hooks/session-title-ask.sh" }] }],
    "PostToolUse": [{ "matcher": "Agent|Task|Edit|Write|MultiEdit", "hooks": [{ "type": "command", "command": "bash ~/.agents/hooks/session-title-progress.sh" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "bash ~/.agents/hooks/session-title-working.sh" }] }]
  }
}
```

Both hooks run only where the rename tool exists
(`CLAUDE_CODE_ENTRYPOINT=claude-desktop`) and only in attended sessions.
`SESSION_TITLE_FORCE=1` lifts both gates. It requires `jq`; `gh` is optional.

## Commands

```bash
session-title.sh facts  --session <id> --repo . --transcript <jsonl>   # what the hook sees
session-title.sh set to-ship --session <id> --repo . --subject "Mes Mailles impersonation"
session-title.sh gate --session <id>                                  # deny once before a question, then allow
session-title.sh render to-merge --subject 042-webhook --pr 12
session-title.sh list --mode free
session-title.sh forget --session <id>                                 # drop the cache
session-title.sh sweep --sessions list-sessions.json                   # renames the freshness dot needs
session-title.sh snapshot --days 6                                     # list_sessions-shaped JSON from the app's files
session-title.sh watch --once --interval 60                            # exits on the first pending rename
session-title.sh cron                                                  # schedule from the user config
session-title.sh config                                                # effective config, file path, cron
```

## Limits

1. **One extra agent step per change of facts.** A turn that changes nothing
   (same git state, same PR, same question/no-question ending) costs nothing.
   A turn that changes something costs one short continuation.
   A click-to-answer question costs one more step: the refused first call.
2. **A topic shift alone does not wake the hook.** In a free session, a new
   subject with the same git state keeps the old topic. Run `set` with a new
   `--subject` to refresh it.
3. **Bitbucket has no `gh`.** The script reads merge state from git ancestry
   against `origin/<base>`. That state is stale until the next `git fetch`,
   and there is no PR number to show.
4. **The current title comes from the transcript.** The script reads the app's
   `custom-title` entries. That format is undocumented, so a missing title only
   disables the `UNCHANGED` shortcut.

5. **The watcher reads an undocumented format.** The session file layout may
   change with any app update. An empty or missing directory makes `watch`
   silent, never wrong. The Windows path is derived from `%APPDATA%` and has
   not been tested on a Windows machine yet.
6. **The watcher session must stay open.** If the app quits or closes it,
   no dot moves until it is started again.
7. **Fallback only: each scheduled sweep is one agent run, on the app's
   default model.** A scheduled task cannot pick its model: all 3,412
   scheduled runs recorded on the author's machine ran on Opus with a 1M
   context. At 5 minutes, that makes 288 Opus runs a day, even when no dot
   changes. Its runs also show in the sidebar, since a scheduled run cannot
   archive itself.

## Implementation Status

Fully implemented. Tested on fixture repos in spec mode, with mode detected
from a transcript `Write` while the branch named another spec:

- `🙋 À trancher` → `📐 À planifier` → `🧩 À découper` → `🔨 À implémenter 1/3`;
- `🚀 À pousser`, then pushed without a PR → `to-merge`;
- fast-forward merge → `to-test`/`to-close`.

Tested in free mode on a real desktop transcript: 5 dirty files led to the
suggestion `to-test`/`to-ship`. The current title was read back from
`custom-title`, and a repeated stop stayed silent. Also tested through `gh`
on this repository: PR #7 came back `MERGED`.

Freshness: `sweep` tested on 9 fixture sessions aged 2 min to 5 days. It
repainted the 5 stale dots, left a correct one, a typed title, a running and
an archived session alone, and stripped all dots with `enabled: false`. A
real scheduled run on 2026-10-28 repainted 9 sessions.

Live counter: tested on a 2-phase, 4-task fixture. It stayed silent at 1/4,
inside a subagent and on a repeat. It renamed at 2/4 (phase done), at 3/4
with `every: task`, and left 4/4 to the Stop hook.

Working dot: tested on the same fixture. A spec prompt gave
"🔵 🔨 À implémenter 3/4 · 295-parent-acts" twice in a row, and `restore`
gave back the 🟢 title once. A stray `--subject` in spec mode kept the slug.
A crashed "🔵 🛠️ Coding 4/5" aged to 🟠. A free session with unchanged facts got JUDGE (full re-title), a spec one its 🟢 title back; the counter kept the status "working".

Watcher: `watch` tested on 7 fixture session files. It printed the
10-minute-old answer and the crashed 🔵 turn. It skipped a fresh one, an
archived one, a running 🔵 turn and a typed title. A second pass stayed
silent, and a later aging printed only the new rename. Then a live run on
2026-10-29, scheduled task disabled, from 11:48 to 13:56: 33 wakes, each
from an idle session, with no wake between dot changes. It turned 🟢→🟡,
🟡→🟠, 🟠→🔴 and 🔀→🏁, each within 15 s plus one interval of its level. One
session went 🟢→🟡→🟠 across the run. `get_session` skipped an archived
session and two long running turns. Not tested: ⚫, and Windows.

Merged PR: on a fake Bitbucket (a local bare origin, no `gh`), the sweep turned
the merged branch into "🏁 Merged" and left the open one and a session without
`cwd` alone. On GitHub it saw PR #12 of this repository as merged.
