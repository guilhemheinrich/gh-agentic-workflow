#!/usr/bin/env bash
# wait.test.sh — the doorbell: `prw wait` returns the released lines once.
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/github-fixtures.sh"
use_fixture "$FX"
fx_pr_open

"$PRW" subscribe "$FX_KEY" 42 --session s1 >/dev/null
lib "events_append s1 '{\"ts\":1,\"text\":\"octo-org/cockpit#42 comment by alice (id 9010)\"}'"

out="$("$PRW" wait --session s1 --timeout 2)"; rc=$?
check "wait returns the released line" '[ "$rc" = 0 ] && [ "$(printf "%s" "$out" | head -n1)" = "octo-org/cockpit#42 comment by alice (id 9010)" ]' "rc=$rc $out"

out="$("$PRW" wait --session s1 --timeout 1)"; rc=$?
check "wait times out with 2 when nothing comes" '[ "$rc" = 2 ]' "rc=$rc"

"$PRW" unsubscribe "$FX_KEY" 42 --session s1
out="$("$PRW" wait --session s1 --timeout 1)"; rc=$?
check "wait exits 3 once nothing is watched" '[ "$rc" = 3 ]' "rc=$rc $out"

out="$("$PRW" status "$FX_KEY" 42)"
check "status says no snapshot before the daemon ran" 'printf "%s" "$out" | grep -q "no snapshot yet"' "$out"

summary
