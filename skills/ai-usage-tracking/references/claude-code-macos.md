# Claude Code on macOS

## Usage

```
conso [-g day|week|month|session] [-d DAYS | -s DATE -u DATE] [-e EUR] [-n] [-S] [-j] [--refresh]
```

| Flag | Meaning |
|---|---|
| `-g` | granularity, default `day` (`session` is not in the cache: it runs one live Docker scan) |
| `-d` / `-s` `-u` | last DAYS days, **today included**, default **7** (today + the 6 previous) / explicit range `YYYY-MM-DD` |
| `-e EUR` | out-of-plan spend given by hand (only shown when no live figure exists) |
| `-n` | offline: never refresh (no Docker, no network). With `--refresh`: refresh without the API call |
| `--refresh` | force a live refresh (Docker + usage API), then report |
| `-S` | silent refresh, prints nothing (what the timer runs) |
| `-j` | JSON instead of the table, billed figures included |

Default view (made-up values): a per-day table (estimate per model, total, tokens, **billed EUR**), then
`Billed consumption`: month to date, last 7 days, previous 7 days with the change in %, and a sparkline
(`▁▃▅█`, `·` = day before the first snapshot) — then the plan limits of the last live fetch.

## Architecture: slow work in the timer, instant read

```
timer (10 min) ──> conso -S ──> conso-refresh.sh ──> cache.json   (atomic, mode 600)
                                   │  usage API ──> extra.jsonl (+1 snapshot line)
conso ──> conso.sh ──> conso-report.py ──reads──> cache.json + extra.jsonl      (no Docker, no network)
```

Files (installed in `~/.config/conso/`): `conso.sh` (wrapper), `conso-report.py` (reader, Python 3.9+ stdlib,
the macOS system python3 is enough), `conso-refresh.sh` (slow half), `conso-merge.js` (merge, runs in the container).

**Where the time went** (measured 2026-11-13, 9 GB / 12.9k transcript files, `conso -n`, 14-day window):

| Step | Before | After |
|---|---|---|
| `docker run` container start | 0.2 s | 0 (reader) / 0.2 s (refresh, background) |
| `npx -y ccusage@latest` package fetch, **every run** | ~3.5-4 s | 0: pinned version installed once into `~/.local/share/conso/ccusage-<ver>` |
| ccusage scan + aggregation (14 d; 7 d = 3.5 s) | ~5.7 s (scales with transcript volume) | in the background only; 10.6 s measured for the 14-day incremental refresh |
| usage API (host connect 0.4 s + response) | ~0.5-1 s | background only |
| **Total of one `conso`** | **9.1 s** | **0.13 s** (cache read, same real data) |

The scan itself cannot be made free; it is moved out of the interactive path and bounded: only the last
`CONSO_OVERLAP_DAYS` (default 14) days are re-aggregated, older days stay as the cache holds them.
First refresh (or unusable cache): last `CONSO_HISTORY_DAYS` (default 90) days, plus the one-time ccusage install
(18.7 s measured end to end).

### Cache: `~/.local/share/conso/cache.json` (override `CONSO_CACHE`; mode 600, written to a temp file then renamed)

```json
{
 "schema": 1,
 "generated_at": "2026-11-13T17:12:55Z",
 "ccusage_version": "20.0.50",
 "history_days": 90,
 "covers_since": "2026-08-15",
 "days": {
  "2026-11-13": {"cost": 269.98, "tokens": 649900000,
                 "models": {"opus-5-5": {"cost": 191.78, "tokens": 400000000}}}
 },
 "usage": {"ok": true, "fetched_at": "2026-11-13T17:12:55Z",
           "limits": [{"kind": "five_hour", "percent": 42, "severity": "ok", "resets_at": "..."}],
           "extra_usage": {"is_enabled": true, "used_credits": 1240, "decimal_places": 2, "currency": "EUR"}}
}
```

`cost` is the ccusage **estimate** in USD. `usage` is the last response of the usage endpoint; when a fetch fails,
the previous figures are kept with `"ok": false` and an `"error"`. A refresh never leaves a half-written cache.

### Freshness

- Stale threshold: `CONSO_STALE_AFTER` (`30m`, `2h`, `90`...), else 3x the timer interval (recorded by the installer in
  `~/.config/conso/interval`), else 30 min. A stale cache still prints, with one line on top:
  `! cache is 3h00m old (threshold 30m) — run conso --refresh, or enable the timer`.
- Missing or unreadable cache (malformed JSON, other schema): `conso` builds it once (foreground, a few seconds),
  except with `-n`, which exits 1 with the reason.

## Billed consumption (real money, not the estimate)

The out-of-plan counter claude.ai exposes is the only billed figure. Each refresh appends one line to
`~/.local/share/conso/extra.jsonl` (override `CONSO_STORE`):

```json
{"ts":"2026-11-13T09:00:00Z","day":"2026-11-13","used":1240,"dp":2,"cur":"EUR"}
```

`used` is the cumulative out-of-plan amount of the month in minor units (`dp` decimal places).
Per-day billed = delta between consecutive snapshots, attributed to the day of the later one.
A drop (`used` smaller than the previous one) means the month rolled over: the new value counts in full.
Torn lines are skipped. Needs 2+ snapshots for any per-day figure (the report says so plainly with fewer); the
previous-7-days comparison appears only once snapshots cover that whole week. Estimate (USD) and billed
(account currency) are shown side by side and never converted: the gap is for you to read.
With the 10-minute timer the day attribution is accurate to ~10 minutes.

## Install

```sh
sh skills/ai-usage-tracking/scripts/claude-code-macos/setup-conso.sh              # install
sh skills/ai-usage-tracking/scripts/claude-code-macos/setup-conso.sh --with-timer # + 10-minute refresh
sh skills/ai-usage-tracking/scripts/claude-code-macos/setup-conso.sh --with-timer --interval 12h # custom interval
sh skills/ai-usage-tracking/scripts/claude-code-macos/setup-conso.sh --uninstall  # remove all (keeps the store)
```

Installed form: `conso.sh` copied to `~/.config/conso/`, symlink `~/.local/bin/conso`, a
`# >>> conso >>>` / `# <<< conso <<<` block in `~/.zshrc` and `~/.bashrc` (stripped and re-appended on each run
so it survives rewrites by other managers), and `~/.config/fish/conf.d/conso.fish`. Idempotent.

**Timer (opt-in, never installed by default)**: `--with-timer` writes
`~/Library/LaunchAgents/com.gh-agentic.conso-snapshot.plist` from the template
(`StartInterval` = the interval in seconds, `RunAtLoad`, runs `conso -S` = silent refresh, log in
`~/.local/share/conso/snapshot.log`) and loads it with `launchctl`. `--uninstall` unloads and removes it.

- `--interval <duration>`: seconds, or a number plus `s`, `m`, `h` or `d` (`3600`, `90m`, `12h`, `1d`).
  Default **10 minutes**. Zero, negative, malformed or `< 60 s` values exit non-zero before anything is changed;
  `--interval` without `--with-timer` is an error too.
- Changing it: re-run with a new `--interval`; the plist is rewritten and reloaded (unload then load).
- `RunAtLoad` is kept, so a refresh also runs at login. Changing the interval also changes the stale threshold (3x).
- Each refresh costs ~10 s of CPU/Docker in the background (14-day re-scan); raise `--interval` on a busy laptop.
- launchd only fires while the Mac is on; an interval that elapsed during sleep or shutdown runs once at
  wake (not once per missed tick).
- Trade-off: billed figures are deltas between snapshots, attributed to the day of the later one. With a long
  interval, spend made just before midnight is lumped onto the next day if the next snapshot lands after it, and the
  cache gets stale sooner than you read it. `12h` is fine for per-day reports; the 10-minute default keeps both fresh.

**Tests** (fixtures and a fake HOME with a stubbed `launchctl`; nothing touches the real machine):

```sh
S="$PWD/skills/ai-usage-tracking/scripts/claude-code-macos"
docker run --rm -v "$S":/t:ro alpine:3.20 sh /t/test-setup-sandbox.sh                 # installer
docker run --rm -v "$S":/t:ro python:3.12-alpine python -I /t/test-conso-report.py    # reader, billed deltas, window, freshness
docker run --rm -v "$S":/t:ro python:3.9-alpine python -I /t/test-conso-report.py     # same, macOS system python line
docker run --rm -v "$S":/t:ro node:22-slim node /t/test-conso-merge.js                # cache merge
```

## Caveats

- **Undocumented endpoint**: `/api/oauth/usage` is not a public API and may change or vanish without notice.
- **Only the month's cumulative out-of-plan spend**: claude.ai exposes just the current month's running total;
  its `daily` / `weekly` fields are null, and `/usage/history`, `/usage/extra`, `/extra_usage` returned 404.
  That is why snapshots exist: per-day figures are reconstructed, not read.
- **Cost is an estimate, not an invoice**: ccusage prices tokens at public API rates; a subscription plan bills differently.
  The *billed* section is the only real money, and only for the out-of-plan part.
- **Cache age**: figures are as fresh as the last refresh; without the timer `conso` shows the staleness notice.
- **Behaviour changes** vs the previous version: `-d` counts today (default 7, was 14 days back); `-S` now refreshes
  the whole cache, not only the snapshot; `-n` means "never refresh"; `-g session` is a live scan.
- **Expired token → HTTP 401**: run any `claude` command, it refreshes the token, then retry. The report degrades
  to "Plan (live): unavailable" and keeps working; use `-e <EUR>` to type the value by hand.
- **No hour granularity**: ccusage aggregates per day at best, so there is no per-hour report.
