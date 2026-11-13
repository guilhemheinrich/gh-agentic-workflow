---
name: ai-usage-tracking
description: >-
  Track AI usage and spend per period and per model with a local persistence layer: a report command
  (`conso`) built per environment, plus snapshots that rebuild what the provider does not expose (daily
  out-of-plan spend). Ships the Claude Code on macOS environment (ccusage in Docker, plan and out-of-plan
  figures, opt-in hourly launchd timer). Use for "conso", "AI usage", "token spend", "out-of-plan",
  "how much did Claude cost me", "usage per model", "usage snapshot".
---

# AI usage tracking

Goal: answer "how much AI did I use, on which model, and what did it cost" per day / week / month /
session, and keep a local history for the figures the provider only shows as a live counter.

Two layers, whatever the AI or the OS:

1. **Report** — aggregate local transcripts per period × model (cost estimate, tokens, share).
2. **Persistence** — append a small snapshot of the provider's live counters on every run (and on a
   timer), so per-period figures can be reconstructed from deltas.

## Environments

| Environment | Reference | Scripts |
|---|---|---|
| Claude Code on macOS | `references/claude-code-macos.md` | `scripts/claude-code-macos/` |

Read the reference of your environment first: it holds usage, install, the persistence design and the caveats.

## Quick start (Claude Code, macOS)

```sh
sh skills/ai-usage-tracking/scripts/claude-code-macos/setup-conso.sh   # installs `conso`
conso                       # per day, last 14 days
conso -g week -d 60         # per week, last 60 days
conso -S                    # silent snapshot (what the timer runs)
```

Docker is required (ccusage runs in `node:22-slim`). Nothing is installed or scheduled without being asked:
the hourly timer only exists with `setup-conso.sh --with-timer`.

## Adding a new environment or AI

One reference + one scripts folder, nothing else:

1. `references/<env>.md` — where the usage data lives, how to read it, which live counters exist, the
   snapshot format, and the **caveats** (undocumented endpoints, estimates vs invoices, granularity limits).
2. `scripts/<env>/` — the report script, an idempotent installer with `--uninstall`, an optional opt-in
   timer, and a sandbox test (fake `HOME`, stubbed scheduler; see `test-setup-sandbox.sh` here).
3. Add a row to the table above. Keep the snapshot shape `{"ts","day","used","dp","cur"}` so stores stay comparable.

Rules that every environment keeps: tokens are never printed nor written to a file; offline mode (`-n`)
makes no call and writes no snapshot; costs are labelled as estimates.
