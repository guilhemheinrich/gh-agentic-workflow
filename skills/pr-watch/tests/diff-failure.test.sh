#!/usr/bin/env bash
# diff-failure.test.sh — a failed diff holds the change back instead of
# losing it. On 2026-11-02 jq 1.7 failed every diff, the daemon advanced the
# snapshot anyway, and a reviewer comment plus a pipeline end woke nobody.
. "$(dirname "$0")/lib.sh"
. "$SKILL_DIR/tests/fixtures.sh"
FX="$WORK/fx"; mkdir -p "$FX"; use_fixture "$FX"
export PRW_SETTLE_SECONDS=0
T0=1793372000
SNAP="$PRW_STATE_DIR/snapshots/septeo-immobilier__modelo-bill-e__229.json"
lib() { bash -c "for l in '$SKILL_DIR'/scripts/lib/*.sh; do . \"\$l\"; done; $1"; }
unread() { lib "events_unread $1" | wc -l | tr -d ' '; }

# A copy of prw whose diff fails the way jq 1.7 did.
BROKEN="$WORK/broken"
mkdir -p "$BROKEN"
cp -R "$SKILL_DIR/scripts" "$SKILL_DIR/adapters" "$SKILL_DIR/templates" "$BROKEN/"
cat >"$BROKEN/scripts/lib/zz-broken-diff.sh" <<'EOF'
diff_snapshots() {
  echo 'jq: error (at <unknown>): string ("modelo-bill-e#") and object ({"kind":"comment"}) cannot be added' >&2
  return 5
}
EOF

fx_default
"$PRW" subscribe "$FX_REPO" 229 --session s1 --head ownhead000 >/dev/null
PRW_NOW="$T0" "$PRW" daemon once
cp "$SNAP" "$WORK/baseline.json"

fx_comments "[$(fx_comment 4521 'Julien Boutet' src/a.ts 42)]"
fx_statuses abc123 '[{"key":"pr-analysis","name":"PR analysis","state":"SUCCESSFUL"}]'
PRW_NOW=$((T0 + 60)) "$BROKEN/scripts/prw" daemon once
check "a failed diff wakes nobody" '[ "$(unread s1)" = 0 ]'
check "a failed diff keeps the old snapshot" 'cmp -s "$SNAP" "$WORK/baseline.json"'
check "a failed diff leaves no temp file" '[ ! -f "$SNAP.new" ] && [ ! -f "$SNAP.lines" ]'
check "a failed diff is logged with jq's message" 'grep -q "diff error septeo-immobilier/modelo-bill-e#229 .*cannot be added" "$PRW_STATE_DIR/daemon.log"' "$(tail -3 "$PRW_STATE_DIR/daemon.log")"
check "a failed diff is counted for doctor" '[ "$(jq .count "$SNAP.differr")" = 1 ]'
out="$(PRW_LIB="$BROKEN/scripts/lib" lib daemon_health)"
check "doctor reports the held-back change" 'printf "%s" "$out" | grep -q "229: 1 failed diff(s), changes held back"' "$out"

PRW_NOW=$((T0 + 120)) "$PRW" daemon once
check "the fixed diff delivers the comment" 'lib "events_unread s1" | grep -q "comment by Julien Boutet on src/a.ts:42"' "$(lib "events_unread s1")"
check "the fixed diff delivers the pipeline end" 'lib "events_unread s1" | grep -q "INPROGRESS→SUCCESSFUL\|new→SUCCESSFUL"' "$(lib "events_unread s1")"
check "the fixed diff clears the counter" '[ ! -f "$SNAP.differr" ]'
check "the fixed diff advances the snapshot" '! cmp -s "$SNAP" "$WORK/baseline.json"'

# launchd stderr: only what the running daemon wrote counts.
OUT="$PRW_STATE_DIR/daemon.out"
printf 'jq: error (at <unknown>): old line from the previous code\n' >"$OUT"
wc -c <"$OUT" | tr -d ' ' >"$PRW_STATE_DIR/daemon.out.offset"
check "errors from before the daemon started are ignored" '[ -z "$(lib daemon_out_errors)" ]'
printf 'jq: error (at <unknown>): new failure\n' >>"$OUT"
check "an error since the daemon started is reported" 'lib daemon_out_errors | grep -q "1 error line(s) since the daemon started, last: jq: error (at <unknown>): new failure"' "$(lib daemon_out_errors)"

summary
