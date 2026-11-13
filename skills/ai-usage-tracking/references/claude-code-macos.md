# Claude Code on macOS

## Usage

```
conso [-g day|week|month|session] [-d DAYS | -s DATE -u DATE] [-e EUR] [-n] [-S] [-j]
```

| Flag | Meaning |
|---|---|
| `-g` | granularity, default `day` |
| `-d` / `-s` `-u` | look-back days (default 14) / explicit date range `YYYY-MM-DD` |
| `-e EUR` | out-of-plan spend given by hand (when the live value is unavailable) |
| `-n` | fully offline: no API call, no snapshot |
| `-S` | silent snapshot only, prints nothing (for timers) |
| `-j` | raw aggregated JSON instead of the table |

Output: a period × model table (cost, tokens, model share), then the live plan limits and the out-of-plan
spend of the current month, then the out-of-plan per day rebuilt from snapshots.
Example (made-up values): `2026-11-12  $41.20  8.1M tokens`, `out-of-plan spent 12.40 EUR (current month)`.

## How it works

- **Report**: `ccusage` runs in Docker (`node:22-slim`), with `~/.claude/projects` mounted read-only.
- **Live figures**: Claude Code's own OAuth token (macOS keychain item `Claude Code-credentials`, else
  `~/.claude/.credentials.json`) calls `GET https://api.anthropic.com/api/oauth/usage` with header
  `anthropic-beta: oauth-2025-04-20`. The token lives in a shell variable only: never printed, never written.

## Persistence design

Each run, and `conso -S`, appends one line to `~/.local/share/conso/extra.jsonl` (override with `CONSO_STORE`):

```json
{"ts":"2026-11-13T09:00:00Z","day":"2026-11-13","used":1240,"dp":2,"cur":"EUR"}
```

`used` is the cumulative out-of-plan amount of the month in minor units (`dp` decimal places).
Per-day out-of-plan = delta between consecutive snapshots, attributed to the day of the later one.
A drop (`used` smaller than the previous one) means the month rolled over: the new value counts in full.
Accuracy equals snapshot frequency: run `conso -S` often enough (timer below; hourly by default) or the day's spend is lumped
onto the next snapshot's day. The report needs 2+ snapshots before showing any per-day figure.

## Install

```sh
sh skills/ai-usage-tracking/scripts/claude-code-macos/setup-conso.sh              # install
sh skills/ai-usage-tracking/scripts/claude-code-macos/setup-conso.sh --with-timer # + hourly snapshots
sh skills/ai-usage-tracking/scripts/claude-code-macos/setup-conso.sh --with-timer --interval 12h # custom interval
sh skills/ai-usage-tracking/scripts/claude-code-macos/setup-conso.sh --uninstall  # remove all (keeps the store)
```

Installed form: `conso.sh` copied to `~/.config/conso/`, symlink `~/.local/bin/conso`, a
`# >>> conso >>>` / `# <<< conso <<<` block in `~/.zshrc` and `~/.bashrc` (stripped and re-appended on each run
so it survives rewrites by other managers), and `~/.config/fish/conf.d/conso.fish`. Idempotent.

**Timer (opt-in, never installed by default)**: `--with-timer` writes
`~/Library/LaunchAgents/com.gh-agentic.conso-snapshot.plist` from the template
(`StartInterval` = the interval in seconds, `RunAtLoad`, runs `conso -S`, log in
`~/.local/share/conso/snapshot.log`) and loads it with `launchctl`. `--uninstall` unloads and removes it.

- `--interval <duration>`: seconds, or a number plus `s`, `m`, `h` or `d` (`3600`, `90m`, `12h`, `1d`).
  Default 1 hour. Zero, negative, malformed or `< 60 s` values exit non-zero before anything is changed;
  `--interval` without `--with-timer` is an error too.
- Changing it: re-run with a new `--interval`; the plist is rewritten and reloaded (unload then load).
- `RunAtLoad` is kept, so a snapshot is also taken at login.
- launchd only fires while the Mac is on; an interval that elapsed during sleep or shutdown runs once at
  wake (not once per missed tick).
- Trade-off: figures are deltas between snapshots, attributed to the day of the later one. With a long
  interval, spend made just before midnight is lumped onto the next day if the next snapshot lands after it.
  `12h` is fine for per-day reports; keep the default (or shorter) when the day boundary matters.

**Test** (fake HOME, stubbed `launchctl`, no effect on the real machine):

```sh
docker run --rm -v "$PWD/skills/ai-usage-tracking/scripts/claude-code-macos":/t:ro alpine:3.20 sh /t/test-setup-sandbox.sh
```

## Caveats

- **Undocumented endpoint**: `/api/oauth/usage` is not a public API and may change or vanish without notice.
- **Only the month's cumulative out-of-plan spend**: claude.ai exposes just the current month's running total;
  its `daily` / `weekly` fields are null, and `/usage/history`, `/usage/extra`, `/extra_usage` returned 404.
  That is why snapshots exist: per-day figures are reconstructed, not read.
- **Cost is an estimate, not an invoice**: ccusage prices tokens at public API rates; a subscription plan bills differently.
- **Expired token → HTTP 401**: run any `claude` command, it refreshes the token, then retry. The report degrades
  to "Plan (live): unavailable" and keeps working; use `-e <EUR>` to type the value by hand.
- **No hour granularity**: ccusage aggregates per day at best, so there is no per-hour report.
