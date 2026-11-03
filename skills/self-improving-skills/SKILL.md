---
name: self-improving-skills
description: >-
  Turn the corrections a human makes during Claude Code sessions into durable
  rules and better skills, instead of repeating them every session. Explains
  the principle (session introspection → proposed amendment → human review →
  scoped write), compares the eight public implementations surveyed on
  2026-10-29 with their maturity, and installs the recommended one,
  BayramAnnakov/claude-reflect (https://github.com/BayramAnnakov/claude-reflect).
  Covers where a learning must land (most specific target wins), the
  measure-before-and-after discipline no mature tool ships yet, and the
  settings that keep session history long enough to mine. Use when the user
  asks for a skill that "improves itself", "learns from corrections",
  "reflects on the session", wants to stop repeating the same correction, or
  wants to set up /reflect. Triggers on "self-improving", "auto-improve",
  "reflect", "claude-reflect", "learn from corrections", "retrospective",
  "introspection de session".
tags:
  - claude
  - hooks
  - meta
  - process
---

# Self-improving skills

A skill is a static file used in a changing environment. The human corrects the
agent in session ("no, use `uv`, not `pip`"), the agent complies, and the next
session makes the same mistake because nothing was written down. A
self-improving setup closes that loop.

## The principle

```
session transcript ──► detect signals ──► propose amendment ──► human review ──► write to the most specific target
        ▲                                                                                     │
        └─────────────────────────── next session reads the amended file ◄────────────────────┘
```

1. **Signals come from the transcript.** Claude Code stores each session as
   JSONL under `~/.claude/projects/<project>/<session-id>.jsonl`. The useful
   signals, strongest first:
   - an explicit marker — `remember: always run tests in Docker`;
   - a correction — "no, use X", "don't do Y", "actually…";
   - an approval — "perfect, always do it that way";
   - a repeated request — the same intent asked in 10 sessions is a missing
     command, not a missing rule.
2. **A model, not a regex, decides what is a rule.** Regex catches "no, use
   X" in English and misses "non, utilise toujours ruff". It also cannot tell
   a reusable rule from a one-off redirect ("no, the other file").
3. **The human approves every write.** An unreviewed rule is how a
   misunderstanding becomes permanent.
4. **The most specific target wins.** A rule loaded in every session costs
   context in every session. Example: "validate input on API endpoints" goes
   to `src/api/AGENTS.md`, not to the root `AGENTS.md`; a correction made
   during `/deploy` goes to that command's file, not to `CLAUDE.md`.
5. **An amendment is a hypothesis.** Back up the previous version, and check
   later that the amended skill fails less — or roll it back.

## Landscape (surveyed 2026-10-29)

| Repository | Writes to | Detects with | When | Stars | Maturity |
|---|---|---|---|---|---|
| [BayramAnnakov/claude-reflect](https://github.com/BayramAnnakov/claude-reflect) | `CLAUDE.md`, `AGENTS.md`, commands | regex at capture + model at review; model-only in the mod | every prompt, reviewed later or at once (mod) | 1 894 | 🟢 17 releases, 8 contributors, active |
| [haddock-development/claude-reflect-system](https://github.com/haddock-development/claude-reflect-system) | `SKILL.md`, promoted to global `CLAUDE.md` | regex, or model with `--semantic` | end of session | 384 | 🟠 no commit since 2026-01-17 |
| [unisone/self-improving-skills](https://github.com/unisone/self-improving-skills) | `SKILL.md`, versioned | usage/outcome hooks + manual ratings | weekly audit | 15 | 🟡 small, maintained |
| [yorrick/agent-skills](https://github.com/yorrick/agent-skills) (`self-improve-skill/`) | `SKILL.md`, left uncommitted | model | `SessionEnd` hook | 11 | 🟡 small, maintained |
| [bokan/claude-skill-self-improvement](https://github.com/bokan/claude-skill-self-improvement) | nothing — `CLAUDE_IMPROVEMENTS.md` report | parallel agents over many sessions | on demand | 12 | ⚪ single commit |
| [accidentalrebel/claude-skill-session-retrospective](https://github.com/accidentalrebel/claude-skill-session-retrospective) | nothing — human retrospective | model | on demand | 14 | ⚪ frozen |
| [k1000/reflect](https://github.com/k1000/reflect) | any target, via a scoping matrix | classifier + 3 specialist agents | `SessionEnd` + web UI | 0 | ⚪ frozen |
| [vladdu/reflect-skills](https://github.com/vladdu/reflect-skills) | `SKILL.md`, merged into existing sections | model | end of session | 0 | ⚪ one-day project |

Two ideas worth keeping from the small ones, since no mature tool ships them:

- **Measure the amendment** (unisone): log every skill invocation and its
  outcome, compare before and after, verdict `IMPROVED` / `NO CHANGE` /
  `DEGRADED`, roll back on `DEGRADED`.
- **Scope matrix** (k1000): module `AGENTS.md` < project skill < project
  command < project `AGENTS.md`. Write as low in that list as the rule allows.

## Install the recommended tool: claude-reflect

Source: <https://github.com/BayramAnnakov/claude-reflect>. Pick **one** of the
two variants; installing both captures every correction twice.

### Variant A — Python plugin (queue, reviewed with `/reflect`)

```bash
claude plugin marketplace add bayramannakov/claude-reflect
claude plugin install claude-reflect@claude-reflect-marketplace
```

Restart Claude Code. Hooks register themselves: one queues corrections on every
prompt, one reminds at session start, one backs up the queue before
compaction, one reminds after a `git commit`.

| Command | Use |
|---|---|
| `/reflect` | review queued learnings, apply / edit / skip each |
| `/reflect --scan-history --days 90` | mine past sessions on first install |
| `/reflect --targets` | show which `CLAUDE.md` / `AGENTS.md` / command files it would write |
| `/reflect --dedupe` | merge near-duplicate rules |
| `/reflect-skills --days 30` | find repeated requests worth a new command |

Choose this variant for history mining, `/reflect-skills`, or Codex/Cursor
users (it writes `AGENTS.md` too).

### Variant B — `reflect-mod` (review at once, in a band above the prompt)

```bash
claude plugin marketplace add bayramannakov/claude-reflect
claude plugin install reflect-mod@claude-reflect-marketplace
```

Needs Claude Code 2.1.286+ with mods enabled. Every short prompt costs one
small model call (`haiku`) on the user's account. Choose this variant when a
queue would never be reviewed — the author measured 102 queued items, about 16
real rules, none cleared.

### Settings to change after install

Claude Code deletes local sessions after 30 days, which starves history mining:

```json
{ "cleanupPeriodDays": 99999 }
```

in `~/.claude/settings.json`.

## House rules for this fleet

- **Review every write.** Never enable an auto-apply mode on a shared repo.
- **Language.** The learned rule is a committed artifact: write it in English,
  even when the correction was typed in French.
- **A learning about a tool goes to that tool's repo.** If the correction is
  about a skill shipped from `gh-agentic-workflow` or `claude-flow`, amend the
  skill there through a PR, not the copy installed under `~/.claude/skills/`,
  which the next install overwrites.
- **Not a grievance.** A learned rule changes agent behaviour. A finding about
  the code itself belongs in `specs/GRIEVANCES.md` (see the `grievances`
  skill).

## Implementation status

**Scaffold.** This skill documents the principle and installs a third-party
tool; it ships no script of its own. Not yet started: a fleet-specific
before/after measurement of amended skills.
