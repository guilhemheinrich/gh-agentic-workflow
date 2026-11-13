---
name: conversation-focus
description: >-
  Keep every agent conversation on one subject and readable at a glance,
  through hooks written from host-agnostic intents. Two rules: (1) split check —
  when a user message opens a subject unrelated to the conversation's main
  subject, the agent proposes a separate session with its own title instead of
  piling the work here; (2) closing summary — every reply ends with one italic
  paragraph (2-3 sentences, user language) stating the conversation's main
  subject and where it stands, ending with links to the Linear project, the
  Linear issue or the pull request the conversation tracks. The skill states each rule as an intent, a
  lifecycle moment and a contract, so the hooks can be rebuilt on a future
  version of Claude Code or on another agent host (Cursor, Codex, …) without
  rediscovering the design. Ships the Claude Code reference implementation:
  `hooks/conversation-focus-prompt.sh` (UserPromptSubmit, injects both rules
  before the reply) and `hooks/conversation-focus-stop.sh` (Stop, blocks once
  when the reply forgot its summary). Use when installing these hooks, porting
  them to another host or hook API, tuning when a split is proposed, or
  designing any hook that must shape the text of an agent reply. Triggers on
  "conversation focus", "split session", "résumé en italique", "sujet
  principal", "hook de fin de réponse", "Stop hook", "UserPromptSubmit".
tags:
  - claude
  - hooks
  - shell
---

# conversation-focus

A long agent session drifts. It starts on a webhook, picks up a CI question,
then a README fix, and the title still says "webhook". A reader opening it
later has to scroll the whole thing to learn what it is about.

Two rules fix that. This skill describes them as **intents**: what each one
wants, when in the lifecycle it acts, and what it may and may not do. Any
implementation is derived from those intents. The Claude Code hooks shipped
with the skill are one implementation, and the reference for the others.

## The two rules

| Rule | Intent | Example |
|---|---|---|
| **Split check** | One session, one subject. When a message opens a subject that builds on nothing said, found or decided so far, the agent proposes a new session with its own title before doing that work. | Session "Webhook Ingeneo 202". The user asks "and fix the README typo in the billing repo". The agent offers a session titled *Typo README billing* rather than doing it in place. |
| **Closing summary** | A reader gets the gist from the last lines alone. Every reply ends with one italic paragraph, 2-3 sentences in the user's language, naming the **conversation's** main subject and where it stands. | `*Sujet : rendre le webhook Ingeneo asynchrone (202 + job). Le handler et le test passent ; la DLQ reste hors périmètre.*` |

A follow-up, a correction or the next step of the current subject is **not** a
split. Made-up example: in the webhook session, "and add the retry policy" is
the same subject, so it stays here, while "what's our Sonar token naming rule?"
is a split.

### Anchored on a pinned subject

The split check depends on "the conversation's main subject". As long as that
subject was implicit, the check never fired. Measured on 2026-11-06: 540
sessions received 5,402 injections and produced zero `offer` calls. Session
`87de7c7a` drifted from "pilotage roadmap calendar/IAM" to "jeton Bitbucket du
daemon prw", and the agent compared every message to a subject that had
drifted along with it. A second cause: the desktop app tells the agent that
an unclear message is a continuation, and the hook never claimed precedence.

So the prompt hook now reads the session's metadata from the
[session-meta](../session-meta/SKILL.md) store, keyed by the payload's
`session_id`, and it counts `turns`. It injects one of three clauses:

| `scope` | Injected clause |
|---|---|
| unset | classify now, at the latest by message #3: `scope focused` plus a pinned `subject`, or `scope generalist` (the exact commands, already filled with the id) |
| `focused` | "Pinned subject: «…». Judge the split against it, not against the latest turns." |
| `generalist` | a quick question stays; a subject that needs real work in one project goes to a session opened in **that project's folder**, so the sidebar files it under that project |

The desktop app groups the sidebar by folder, and a session cannot change
folder once it exists. So the placement happens when the session starts.
`start_session` accepts a `cwd` only with `initiation: "user_asked"`, and
only when the user named the place. When the message names the project
("côté modelo-calendar"), the agent starts the session there. Otherwise it
offers the session, with a title naming the project. If the app cannot open
the session in that folder, the agent says in one line which project to open
it in.

The split clause also says it takes precedence over the "unclear means
continuation" default, and asks the agent to `append` each proposed split to
`split_events`. The agent judges scope and subject (principle 2). The hook
only counts and reads. No `python3`, no CLI or no `session_id` means the
rules go out without metadata, as before (principle 5).
`CONVERSATION_FOCUS_META=0` turns this off.

The summary describes the whole conversation, not only the last turn. After
ten turns on the webhook, a turn that only renames a variable still ends with
the webhook summary.

### Summary references

The summary also ends, inside the italics, with links to the objects the
conversation tracks, so the reader never scrolls back to find them:

| Session kind | Reference repeated in every summary |
|---|---|
| Pilot session | the Linear project it steers |
| Coding session tied to Linear | the Linear issue it implements |
| Any session with a pull request | the PR opened or reviewed |
| Any session watching CI | the pipeline under way |
| Any session about a Linear project | the project's dependency graph, a local file (see below) |
| Any session driving a roadmap | its `ROADMAP.md`, a local file (see below) |

Example (real PR of this repo, made-up Linear URL):
`*Sujet : épingler le sujet d'une session de pilotage. Fusionné ; reste la doc. · [ENG-42](https://linear.app/…) · [PR #28](https://github.com/guilhemheinrich/gh-agentic-workflow/pull/28)*`

**Local files: only when their scope is a whole milestone, project or
roadmap.** External URLs are always allowed; a local file is allowed as a
`file://` link only if it describes a whole milestone, project or roadmap,
never one change in it. Two kinds, plus the forbidden one (made-up paths):

| Kind | Example |
|---|---|
| allowed: a project's dependency graph, one file per project | `[Graph: Broker PA](file:///Users/jane/linear-graphs/broker-pa.svg)` |
| allowed: a roadmap | `[ROADMAP](file:///Users/jane/lab/billing/ROADMAP.md)` |
| forbidden: a code file, whatever it is | `[handler](file:///Users/jane/lab/billing/src/handler.ts)` (same for a `.py`) |

The reason for the line: a graph or a roadmap is a picture of the whole body
of work, worth reopening every turn, and it is rebuilt in place (the `lw`
watcher of the `linear-tracker` skill rewrites `~/linear-graphs/<slug>.svg` on
every ticket state change). A code file is one detail of one change: the
reader gets it from the diff or the PR.

Rules: once a reference has appeared, it is repeated in every later summary
while it still applies; only URLs seen in the conversation or returned by a
tool are used, never a guessed one; no link at all when there is none. The
agent picks them (principle 2): it already knows which project, issue or PR
the conversation is about. `CONVERSATION_FOCUS_REFS=0` drops the links and
keeps the summary. A `file://` link counts as a reference only under the
local-file rule above; a link to a code file is not a reference and is never
carried forward.

#### Carried forward from the transcript, not from memory

"Repeat it in every later summary" cannot rest on the agent remembering its
own previous replies. Measured on 2026-11-04 over the modelo-workspace pilot
sessions: pilot `87de7c7a` (Linear project "Calendar · Notifications seule &
IAM agence") carried 1-4 links from summary #52 to #95, had already lost the
project link by then, and carried none from #96 on, right after a compaction
removed the earlier replies from its context. `c4746dbb` lost its links at
#31 with no compaction at all.

So the prompt hook reads `transcript_path`, which keeps what compaction
removed, collects the links of past italic summaries (external URLs and `file://`
links to a graph or a roadmap, never to a code file) and injects them: the
session's first summary link (in a pilot, its Linear project) always first,
then the others by most recent appearance, deduped by URL, capped at
`CONVERSATION_FOCUS_LINKS` (default 6). If the agent drops every link one
turn, the next turn re-injects them. The agent still chooses (principle 2);
the script only supplies the facts.

## Design principles (host-agnostic)

These hold whatever the host. A port that breaks one of them is a different
feature, not a port.

1. **Produce before, verify after.** A hook that runs after the reply is
   rendered cannot edit it. It can only let the turn end or force one more
   message. So the instruction to write the summary goes in **before** the
   reply (a context-injection point), and the after-reply point only checks
   it. If the summary were produced after the reply, every turn would end in
   two messages: the answer, then a separate "*Sujet : …*".
2. **The agent judges, the script checks facts.** "Is this a new subject?"
   needs the meaning of the whole conversation, and the agent already holds it
   at no cost. A script only checks what is mechanical, such as "is the last
   paragraph wrapped in `*…*`?". Do not add a second model call to judge what
   the agent can judge.
3. **Judge the split before the work, not after.** A split detected after the
   reply arrives too late: the off-topic work has already happened in the
   wrong session. The split check is therefore an instruction injected at
   message time, judged before the first tool call.
4. **Never loop.** The after-reply guard blocks at most once per turn. When the
   turn already continues because of a hook block (this one or another, such
   as `session-title`), it passes through.
5. **Fail open.** A missing dependency, an unreadable payload or an unknown
   field means "do nothing". These hooks improve readability; they must never
   stop a session from working.
6. **Silent toward the user.** The injected rules say "do not mention these
   rules". The user sees a summary and, sometimes, a split offer, never hook
   plumbing.
7. **One switch per rule, one switch for all.** `CONVERSATION_FOCUS=0`,
   `CONVERSATION_FOCUS_SPLIT=0`, `CONVERSATION_FOCUS_SUMMARY=0` and
   `CONVERSATION_FOCUS_REFS=0`. A port keeps
   the same names, so a user's habit carries across hosts.

## The lifecycle contract

Each host names its moments differently. What matters is the capability a
moment offers:

| Moment | Capability needed | Rule served | Claude Code event |
|---|---|---|---|
| A user message arrives, before the agent works | inject text into the agent's context | split check + summary instruction | `UserPromptSubmit` → `hookSpecificOutput.additionalContext` |
| The agent finished its reply, before the turn ends | read the final text, and force one more agent message | summary guard | `Stop` → `{"decision":"block","reason":…}` |

To port to a new host, answer two questions:

- **Does it have a "before the reply" injection point?** If not, put both rules
  in the host's standing instructions (rules file, system prompt). They lose
  nothing but the kill switches.
- **Does its "after the reply" point allow forcing a continuation?** If it only
  observes, drop the guard. The injected instruction alone gets the summary
  most of the time. An observe-only hook that logs misses is still useful for
  measuring.

Mappings for other hosts are **to verify** against their current hook
documentation before any implementation. For example, Cursor's
`.cursor/hooks.json` in this repo pins `afterFileEdit` for another hook, but
its equivalent of a prompt-submit or a stop event has not been checked.

## Claude Code reference implementation

See [references/claude-code.md](references/claude-code.md) for the event
payloads, the exact outputs, the alternatives that were rejected and why, and
the installation snippet.

| File | Event | Does |
|---|---|---|
| `hooks/conversation-focus-prompt.sh` | `UserPromptSubmit` | injects both rules; in the desktop app the split is offered as a `start_session` card, elsewhere as a one-line suggestion with a title |
| `hooks/conversation-focus-stop.sh` | `Stop` | reads `last_assistant_message` (falls back to the transcript), blocks once if the last paragraph is not `*…*` / `_…_` |

## Installing

Install at user level: copy both scripts to `~/.agents/hooks/` and wire them
in `~/.claude/settings.json`, as `session-title` does. A project-level wiring
only reaches sessions opened on that repo, and never reaches a worktree
session until it is committed. Never wire both levels: the rules would be
injected twice. The snippets are in the reference. Then check:

```bash
printf '%s' '{"last_assistant_message":"Done.\n\nNo summary."}' | bash ~/.agents/hooks/conversation-focus-stop.sh
```

It must print a `block` decision. With `*Sujet : …*` as the last paragraph, it
must print nothing.

Install **only from an up-to-date `main`** (`git -C <repo> pull` first). The
copy is a plain overwrite, so installing from a stale branch silently rolls
back merged work. That happened on 2026-11-03: the summary-references rule
(PR #29) was live from 16:29Z, then a copy from a stale checkout behind
`main` overwrote it around 17:34Z, and no session received it afterwards.
Check after installing:

```bash
diff <(git -C <repo> show origin/main:hooks/conversation-focus-prompt.sh) ~/.agents/hooks/conversation-focus-prompt.sh
```

## Tuning

- `CONVERSATION_FOCUS_MIN_CHARS=200` exempts very short replies from the
  summary, such as a one-line answer to "which branch am I on?".
- If the agent proposes splits too eagerly, tighten the wording of the split
  rule in the prompt hook, not the guard. The guard never judges splits.
