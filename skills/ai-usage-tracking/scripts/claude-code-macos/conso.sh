#!/bin/sh
# conso.sh - Claude Code consumption per period and per model, built on ccusage (run in Docker).
#
# Usage: conso.sh [-g day|week|month|session] [-s YYYY-MM-DD] [-u YYYY-MM-DD] [-d DAYS]
#                 [-e EXTRA_EUR] [-j]
#   -g  granularity (default: day)
#   -d  look-back window in days when -s is not given (default: 14)
#   -s  start date (overrides -d), -u end date (default: today)
#   -e  out-of-plan spend (EUR) given by hand; overrides the live value
#   -n  do not query Anthropic (offline: no live figures, no snapshot)
#   -S  snapshot only: record the current out-of-plan figure, print nothing
#       (for cron/launchd). Every normal run also records one.
#   -j  raw aggregated JSON instead of the table
#
# Costs are ccusage estimates at public API prices, NOT your invoice.
# Live figures: Claude Code's own OAuth token (macOS keychain or
# ~/.claude/.credentials.json) calls api.anthropic.com/api/oauth/usage. The token
# is never printed. If it expired, any `claude` call refreshes it. That endpoint
# is undocumented and reports the CURRENT month's out-of-plan spend only, not a
# per-period figure. Snapshots go to $CONSO_STORE (default
# ~/.local/share/conso/extra.jsonl); per-day out-of-plan = delta between snapshots.
set -eu

GRAN=day
DAYS=14
SINCE=
UNTIL=
EXTRA=
JSON=0
API=1
SNAP_ONLY=0
STORE=${CONSO_STORE:-$HOME/.local/share/conso/extra.jsonl}

while getopts "g:d:s:u:e:nSjh" opt; do
  case "$opt" in
    g) GRAN=$OPTARG ;;
    d) DAYS=$OPTARG ;;
    s) SINCE=$OPTARG ;;
    u) UNTIL=$OPTARG ;;
    e) EXTRA=$OPTARG ;;
    j) JSON=1 ;;
    n) API=0 ;;
    S) SNAP_ONLY=1 ;;
    h) sed -n "2,24p" "$0"; exit 0 ;;
    *) sed -n "2,24p" "$0"; exit 1 ;;
  esac
done

case "$GRAN" in
  day) CMD=daily ;;
  week) CMD=weekly ;;
  month) CMD=monthly ;;
  session) CMD=session ;;
  *) echo "granularity must be day|week|month|session" >&2; exit 1 ;;
esac

# Portable date arithmetic (BSD/macOS first, then GNU).
back() { date -v-"$1"d +%Y-%m-%d 2>/dev/null || date -d "$1 days ago" +%Y-%m-%d; }
[ -n "$UNTIL" ] || UNTIL=$(date +%Y-%m-%d)
[ -n "$SINCE" ] || SINCE=$(back "$DAYS")

PROJECTS=${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}

# --- Live plan / out-of-plan figures (best effort, never fatal) ----------------
USAGE_JSON=
USAGE_ERR=
if [ "$API" = 1 ]; then
  CREDS=
  if command -v security >/dev/null 2>&1; then
    CREDS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
  fi
  [ -n "$CREDS" ] || { [ -f "$HOME/.claude/.credentials.json" ] && CREDS=$(cat "$HOME/.claude/.credentials.json"); } || true
  TOKEN=$(printf '%s' "$CREDS" | sed -n 's/.*"accessToken" *: *"\([^"]*\)".*/\1/p' | head -1)
  if [ -z "$TOKEN" ]; then
    USAGE_ERR="no Claude Code OAuth token found (log in with claude)"
  else
    RESP=$(curl -s -m 15 -w '\n%{http_code}' https://api.anthropic.com/api/oauth/usage \
      -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null || true)
    CODE=$(printf '%s' "$RESP" | tail -1)
    if [ "$CODE" = 200 ]; then
      USAGE_JSON=$(printf '%s' "$RESP" | sed '$d')
    else
      USAGE_ERR="usage endpoint answered HTTP ${CODE:-none} (expired token? run any claude command, then retry)"
    fi
  fi
  unset TOKEN CREDS RESP
  # Record a snapshot (append-only JSONL, one line per observation).
  if [ -n "$USAGE_JSON" ]; then
    USED=$(printf '%s' "$USAGE_JSON" | sed -n 's/.*"used_credits": *\([0-9.]*\).*/\1/p' | head -1)
    DP=$(printf '%s' "$USAGE_JSON" | sed -n 's/.*"decimal_places": *\([0-9]*\).*/\1/p' | head -1)
    CUR=$(printf '%s' "$USAGE_JSON" | sed -n 's/.*"currency": *"\([A-Z]*\)".*/\1/p' | head -1)
    if [ -n "$USED" ]; then
      mkdir -p "$(dirname "$STORE")"
      printf '{"ts":"%s","day":"%s","used":%s,"dp":%s,"cur":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date +%Y-%m-%d)" "$USED" "${DP:-2}" "${CUR:-EUR}" >> "$STORE"
    fi
  fi
fi

if [ "$SNAP_ONLY" = 1 ]; then
  [ -n "$USAGE_JSON" ] || { echo "conso: snapshot failed: ${USAGE_ERR:-API disabled (-n)}" >&2; exit 1; }
  exit 0
fi

mkdir -p "$(dirname "$STORE")"

# Everything runs in Docker; transcripts are mounted read-only.
docker run --rm -i \
  -e GRAN="$GRAN" -e SINCE="$SINCE" -e UNTIL="$UNTIL" -e EXTRA="$EXTRA" -e JSON="$JSON" -e CMD="$CMD" \
  -e USAGE_JSON="$USAGE_JSON" -e USAGE_ERR="$USAGE_ERR" \
  -e STORE_FILE=/store/$(basename "$STORE") -e GRAN_DAYS_FROM="$SINCE" \
  -v "$PROJECTS":/root/.claude/projects:ro \
  -v "$(dirname "$STORE")":/store:ro \
  node:22-slim sh -c '
    npx -y ccusage@latest "$CMD" --json --breakdown \
      --since "$(echo "$SINCE" | tr -d -)" --until "$(echo "$UNTIL" | tr -d -)" \
      > /tmp/c.json 2>/dev/null
    node -e '"'"'
const d = JSON.parse(require("fs").readFileSync("/tmp/c.json", "utf8"));
const rows = d[Object.keys(d).find(k => Array.isArray(d[k]))] || [];
const short = m => m.replace(/^claude-/, "").replace(/-\d{8}$/, "");
const models = new Set(), out = [];
const tot = { cost: 0, tokens: 0, byModel: {} };
for (const r of rows) {
  const by = {};
  for (const b of r.modelBreakdowns || []) {
    const m = short(b.modelName); models.add(m);
    by[m] = (by[m] || 0) + b.cost;
    tot.byModel[m] = (tot.byModel[m] || 0) + b.cost;
  }
  const tokens = r.totalTokens || 0;
  tot.cost += r.totalCost || 0; tot.tokens += tokens;
  out.push({ period: r.period || r.date || r.sessionId || r.month || r.week, cost: r.totalCost || 0, tokens, by });
}
if (process.env.JSON === "1") {
  console.log(JSON.stringify({ since: process.env.SINCE, until: process.env.UNTIL, granularity: process.env.GRAN, rows: out, total: tot }, null, 2));
  process.exit(0);
}
const cols = [...models].sort((a, b) => (tot.byModel[b] || 0) - (tot.byModel[a] || 0));
const $ = n => "$" + n.toFixed(2);
const tk = n => (n / 1e6).toFixed(1) + "M";
const W = Math.max(8, ...out.map(r => String(r.period).length));
const head = ["period".padEnd(W), ...cols.map(c => c.padStart(18)), "total".padStart(11), "tokens".padStart(10)];
console.log(`Claude Code usage ${process.env.SINCE} -> ${process.env.UNTIL} (per ${process.env.GRAN})\n`);
console.log(head.join("  "));
console.log("-".repeat(head.join("  ").length));
for (const r of out)
  console.log([String(r.period).padEnd(W), ...cols.map(c => $(r.by[c] || 0).padStart(18)), $(r.cost).padStart(11), tk(r.tokens).padStart(10)].join("  "));
console.log("-".repeat(head.join("  ").length));
console.log(["TOTAL".padEnd(W), ...cols.map(c => $(tot.byModel[c] || 0).padStart(18)), $(tot.cost).padStart(11), tk(tot.tokens).padStart(10)].join("  "));
console.log("\nShare: " + cols.map(c => `${c} ${(100 * (tot.byModel[c] || 0) / (tot.cost || 1)).toFixed(1)}%`).join(" | "));
let u = null;
try { u = process.env.USAGE_JSON ? JSON.parse(process.env.USAGE_JSON) : null; } catch (e) {}
console.log("");
if (u) {
  console.log("Plan (live, claude.ai):");
  for (const l of u.limits || []) {
    const sc = l.scope ? (l.scope.model?.display_name || l.scope.surface?.display_name || "") : ""; const lab = l.kind + (sc ? ":" + sc : "");
    console.log(`  ${lab.padEnd(18)} ${String(l.percent).padStart(3)}%  ${l.severity}${l.resets_at ? "  resets " + l.resets_at.slice(0, 16).replace("T", " ") + " UTC" : ""}`);
  }
  const x = u.extra_usage;
  if (x && x.is_enabled) {
    const v = x.used_credits / Math.pow(10, x.decimal_places ?? 2);
    console.log(`  out-of-plan spent  ${v.toFixed(2)} ${x.currency}  (current month, as reported)` + (x.monthly_limit ? `  limit ${x.monthly_limit / Math.pow(10, x.decimal_places ?? 2)}` : "  no limit set"));
  }
} else if (process.env.USAGE_ERR) {
  console.log("Plan (live): unavailable - " + process.env.USAGE_ERR);
}
// Per-day out-of-plan from local snapshots: delta between consecutive observations,
// attributed to the day of the later one; a drop means the month rolled over.
let snaps = [];
try { snaps = require("fs").readFileSync(process.env.STORE_FILE, "utf8").split("\n").filter(Boolean).map(l => JSON.parse(l)); } catch (e) {}
snaps.sort((a, b) => a.ts.localeCompare(b.ts));
const perDay = {};
for (let i = 1; i < snaps.length; i++) {
  const a = snaps[i - 1], b = snaps[i], f = 10 ** (b.dp ?? 2);
  const d = b.used >= a.used ? b.used - a.used : b.used;
  perDay[b.day] = (perDay[b.day] || 0) + d / f;
}
const days = Object.keys(perDay).filter(k => k >= process.env.SINCE && k <= process.env.UNTIL).sort();
console.log(`Out-of-plan per day (local snapshots: ${snaps.length}${snaps[0] ? ", since " + snaps[0].ts.slice(0, 16).replace("T", " ") + " UTC" : ""}):`);
if (days.length) { for (const k of days) console.log(`  ${k}  ${perDay[k].toFixed(2).padStart(9)} ${snaps[0].cur}`); }
else console.log("  not enough snapshots yet (need 2+). Run `conso -S` regularly, e.g. hourly.");
console.log("");
const extra = process.env.EXTRA;
if (extra) console.log(`Out-of-plan (given by hand): ${extra} EUR = ${(100 * Number(extra) / (tot.cost || 1)).toFixed(1)}% of the estimated API cost above`);
else if (!u) console.log("Out-of-plan: pass -e <EUR> (claude.ai > Settings > Usage) when the live value is unavailable.");
'"'"'
  '
