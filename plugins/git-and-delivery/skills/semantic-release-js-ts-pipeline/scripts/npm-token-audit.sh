#!/usr/bin/env bash
# npm-token-audit.sh — list npm tokens, soonest expiry first.
#
# Since 2025-12-09 npm has only granular tokens, and a write token is capped at
# 90 days. This prints the rotation queue: whatever expires next comes first,
# already-expired tokens come before that.
#
# `npm token list` renders no expiry column (checked against npm 11.17.0 and
# 12.0.2), so this reads `--json`, which dumps the raw /-/npm/v1/tokens payload.
# Which expiry field that payload carries is not documented, so the script
# probes for one instead of assuming a name, and says so when it finds none.
#
# Usage:
#   ./npm-token-audit.sh                 # human table
#   ./npm-token-audit.sh --json          # machine-readable, same ordering
#   ./npm-token-audit.sh --warn-days 30  # exit 3 if a token expires within 30d
#   ./npm-token-audit.sh --raw-keys      # print the payload's field names, then exit
#
# Honours NPM_BIN so the npm call can be wrapped, e.g. for a Docker-only host:
#   NPM_BIN="docker run --rm -v $HOME/.npmrc:/root/.npmrc:ro node:24 npm"
#
# Never prints a token value: npm truncates it in the payload, and this script
# truncates again on top.

set -euo pipefail

NPM_BIN="${NPM_BIN:-npm}"
WARN_DAYS=14
OUTPUT=table

while [ $# -gt 0 ]; do
	case "$1" in
	--json) OUTPUT=json ;;
	--raw-keys) OUTPUT=raw-keys ;;
	--warn-days)
		shift
		WARN_DAYS="${1:?--warn-days needs a number}"
		;;
	-h | --help)
		sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		printf 'unknown argument: %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

case "$WARN_DAYS" in
'' | *[!0-9]*)
	echo "--warn-days must be a whole number of days" >&2
	exit 2
	;;
esac

payload=$($NPM_BIN token list --json 2>/tmp/npm-token-audit.err) || {
	echo "npm token list failed. Its output:" >&2
	grep -viE '^npm notice|npm_[A-Za-z0-9]{10,}' /tmp/npm-token-audit.err >&2 || true
	echo >&2
	echo "E401 here usually means the local token is itself expired or revoked:" >&2
	echo "  all classic tokens were revoked on 2025-12-09. Run 'npm login'." >&2
	exit 1
}

printf '%s' "$payload" | node -e '
const WARN = Number(process.argv[1]);
const MODE = process.argv[2];
let raw = "";
process.stdin.on("data", d => raw += d);
process.stdin.on("end", () => {
  let tokens;
  try { tokens = JSON.parse(raw); } catch { fail("npm returned output that is not JSON."); }
  if (tokens && tokens.error) fail("npm returned an error: " + JSON.stringify(tokens.error));
  if (!Array.isArray(tokens)) fail("expected a JSON array of tokens, got " + typeof tokens);

  // The payload field carrying the expiry is undocumented. Probe, do not assume.
  const CANDIDATES = ["expires", "expires_at", "expiresAt", "expiration", "expiry"];
  const present = new Set(tokens.flatMap(t => Object.keys(t || {})));
  const expiryKey = CANDIDATES.find(k => present.has(k));

  if (MODE === "raw-keys") {
    console.log([...present].sort().join("\n"));
    console.log("\nexpiry field detected: " + (expiryKey || "NONE"));
    process.exit(0);
  }

  const now = Date.now();
  const rows = tokens.map(t => {
    const rawExp = expiryKey ? t[expiryKey] : undefined;
    // Accept an ISO date, an epoch in seconds, or an epoch in milliseconds.
    let expMs = null;
    if (rawExp != null && rawExp !== "") {
      if (typeof rawExp === "number") expMs = rawExp < 1e12 ? rawExp * 1000 : rawExp;
      else { const p = Date.parse(rawExp); if (!Number.isNaN(p)) expMs = p; }
    }
    return {
      id: t.id || (t.key ? String(t.key).slice(0, 8) : "?"),
      name: t.name || "",
      created: t.created ? String(t.created).slice(0, 10) : "",
      readonly: !!t.readonly,
      expires: expMs === null ? null : new Date(expMs).toISOString().slice(0, 10),
      daysLeft: expMs === null ? null : Math.floor((expMs - now) / 86400000),
    };
  });

  // Soonest expiry first; already expired sorts before that; unknown expiry last.
  rows.sort((a, b) => {
    if (a.daysLeft === null && b.daysLeft === null) return 0;
    if (a.daysLeft === null) return 1;
    if (b.daysLeft === null) return -1;
    return a.daysLeft - b.daysLeft;
  });

  if (MODE === "json") { console.log(JSON.stringify(rows, null, 2)); }
  else {
    if (!expiryKey) {
      console.log("The registry payload carries no expiry field, so no expiry-based");
      console.log("ordering is possible. Fields seen: " + [...present].sort().join(", "));
      console.log("Read the expiry on npmjs.com/settings/~/tokens instead.\n");
    }
    const pad = (s, n) => String(s).padEnd(n);
    console.log([pad("STATUS", 9), pad("EXPIRES", 12), pad("DAYS", 6), pad("ID", 10), pad("PERM", 6), "NAME"].join(""));
    for (const r of rows) {
      const status = r.daysLeft === null ? "unknown"
        : r.daysLeft < 0 ? "EXPIRED"
        : r.daysLeft <= WARN ? "SOON" : "ok";
      console.log([
        pad(status, 9), pad(r.expires ?? "-", 12),
        pad(r.daysLeft ?? "-", 6), pad(r.id, 10),
        pad(r.readonly ? "read" : "write", 6), r.name,
      ].join(""));
    }
  }

  const urgent = rows.filter(r => r.daysLeft !== null && r.daysLeft <= WARN).length;
  if (urgent > 0) {
    if (MODE !== "json") console.error(`\n${urgent} token(s) expired or expiring within ${WARN} days.`);
    process.exit(3);
  }
});
function fail(m) { console.error(m); process.exit(1); }
' "$WARN_DAYS" "$OUTPUT"
