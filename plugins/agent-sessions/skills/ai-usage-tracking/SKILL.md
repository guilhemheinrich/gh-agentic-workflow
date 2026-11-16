---
name: ai-usage-tracking
description: >-
  Track AI usage and spend per period and per model with a local persistence layer: a report command
  (`conso`) built per environment, plus snapshots that rebuild what the provider does not expose (daily
  out-of-plan spend). Ships the Claude Code on macOS environment (instant report read from a cache that an
  opt-in launchd timer rebuilds in the background with ccusage in Docker, plus the billed out-of-plan
  evolution). Use for "conso", "AI usage", "token spend", "out-of-plan", "how much did Claude cost me",
  "usage per model", "usage snapshot".
---

# AI usage tracking

Goal: answer "how much AI did I use, on which model, and what did it cost" per day / week / month /
session, and keep a local history for the figures the provider only shows as a live counter.

Two layers, whatever the AI or the OS:

1. **Report** — aggregate local transcripts per period × model (cost estimate, tokens, share), **read
   instantly from a precomputed cache** (no Docker, no network when you run it).
2. **Persistence + refresh** — a slow refresh step (the opt-in timer, or `--refresh`) re-aggregates the
   recent transcripts, appends a snapshot of the provider's live counters, and rewrites the cache. Snapshots
   rebuild the *billed* per-day figures from deltas.

## Environments

| Environment | Reference | Scripts |
|---|---|---|
| Claude Code on macOS | `references/claude-code-macos.md` | `scripts/claude-code-macos/` |

Read the reference of your environment first: it holds usage, install, the persistence design and the caveats.

## Quick start (Claude Code, macOS)

```sh
sh skills/ai-usage-tracking/scripts/claude-code-macos/setup-conso.sh --with-timer   # installs `conso` + 10-min refresh
conso                       # last 7 days per day: estimate + billed, billed trend; reads the cache (~0.1 s)
conso -g week -d 60         # per week, last 60 days (cache keeps 90)
conso --refresh             # force a live refresh now (Docker + usage API, ~10 s)
conso -n -j                 # offline JSON, billed figures included
```

Docker is required for the refresh only (ccusage, pinned and installed once, runs in `node:22-slim`); the
reader needs `python3`. Nothing is installed or scheduled without being asked: the timer only exists with
`--with-timer [--interval <duration>]` (default **10 minutes**; `30m`, `12h`, `3600`; minimum 60 s; re-run to
change). Without the timer, the first `conso` builds the cache and later runs show a staleness notice
(older than 3x the interval, default 30 min) until you run `conso --refresh`. launchd only fires while the Mac is on.
Measured: one `conso` went from 9.1 s to 0.13 s; breakdown in the reference.

## Adding a new environment or AI

One reference + one scripts folder, nothing else:

1. `references/<env>.md` — where the usage data lives, how to read it, which live counters exist, the
   snapshot format, and the **caveats** (undocumented endpoints, estimates vs invoices, granularity limits).
2. `scripts/<env>/` — the report script, an idempotent installer with `--uninstall`, an optional opt-in
   timer, and a sandbox test (fake `HOME`, stubbed scheduler; see `test-setup-sandbox.sh` here).
3. Add a row to the table above. Keep the snapshot shape `{"ts","day","used","dp","cur"}` so stores stay comparable.

Rules that every environment keeps: tokens are never printed nor written to a file; offline mode (`-n`)
never refreshes (no call, no snapshot, no Docker); costs are labelled as estimates.
