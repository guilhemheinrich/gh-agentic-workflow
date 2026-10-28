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
  session; only the agent can call the app's `set_session_title` tool. Works
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
| the agent | judges the status, picks the topic of a free session, calls `set_session_title` |

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
| `to-close` | 📦 À clôturer · <topic> | both | archive session and branch | merged PR |
| `blocked` | ⛔ Bloqué · <topic> | both | chase the outside dependency | agent judgement |
| `closed` | ✅ Clos · <topic> | both | nothing | PR closed |

`SESSION_TITLE_LANG=en` switches the labels to English.

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

## Install (Claude Code, user scope)

`install.sh` copies the skill to `~/.claude/skills/` and the hook to
`~/.agents/hooks/`. Register the hook in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "bash ~/.agents/hooks/session-title-sync.sh" }] }]
  }
}
```

The hook runs only where the rename tool exists
(`CLAUDE_CODE_ENTRYPOINT=claude-desktop`) and only in attended sessions.
`SESSION_TITLE_FORCE=1` lifts both gates. It requires `jq`; `gh` is optional.

## Commands

```bash
session-title.sh facts  --session <id> --repo . --transcript <jsonl>   # what the hook sees
session-title.sh set to-ship --session <id> --repo . --subject "Mes Mailles impersonation"
session-title.sh render to-merge --subject 042-webhook --pr 12
session-title.sh list --mode free
session-title.sh forget --session <id>                                 # drop the cache
```

## Limits

1. **One extra agent step per change of facts.** A turn that changes nothing
   (same git state, same PR, same question/no-question ending) costs nothing.
   A turn that changes something costs one short continuation.
2. **A topic shift alone does not wake the hook.** In a free session, a new
   subject with the same git state keeps the old topic. Run `set` with a new
   `--subject` to refresh it.
3. **Bitbucket has no `gh`.** The script reads merge state from git ancestry
   against `origin/<base>`. That state is stale until the next `git fetch`,
   and there is no PR number to show.
4. **The current title comes from the transcript.** The script reads the app's
   `custom-title` entries. That format is undocumented, so a missing title only
   disables the `UNCHANGED` shortcut.

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
