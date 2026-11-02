#!/usr/bin/env bash
# mixed-hosts.test.sh — one machine, two hosts: a Bitbucket PR and a GitHub PR
# are polled by the same daemon, and a rejected GitHub token does not stop the
# Bitbucket PR from being polled.
. "$(dirname "$0")/lib.sh"
. "$SKILL_DIR/tests/fixtures.sh"
FX="$WORK/fx"; mkdir -p "$FX"; use_fixture "$FX"
fx_default
BB_REPO="$FX_REPO"
. "$SKILL_DIR/tests/github-fixtures.sh"
FX="$WORK/fx"
fx_pr_open
T0=1793372000

"$PRW" subscribe "$BB_REPO" 229 --session sb >/dev/null
"$PRW" subscribe "$FX_KEY" 42 --session sg >/dev/null

# The GitHub token is rejected; the Bitbucket PR must still be fetched.
fx_put "repos/$FX_REPO/pulls/42" '{}' 401
: >"$FAKE_CURL_LOG"
PRW_NOW="$T0" "$PRW" daemon once
check "the Bitbucket PR was fetched in the same cycle" 'grep -q "pullrequests/229$" "$FAKE_CURL_LOG"' "$(cat "$FAKE_CURL_LOG")"
check "the Bitbucket snapshot was written" '[ -f "$PRW_STATE_DIR/snapshots/septeo-immobilier__modelo-bill-e__229.json" ]'
check "the rejected GitHub PR was asked once, not once per page" '[ "$(grep -c "pulls/42$" "$FAKE_CURL_LOG")" = 1 ]' "$(cat "$FAKE_CURL_LOG")"
check "the daemon logs the rejected credential" 'grep -q "auth error" "$PRW_STATE_DIR/daemon.log"'

# With the token valid again, the GitHub PR is polled on the next cycle.
fx_pr_open
PRW_NOW=$((T0 + 60)) "$PRW" daemon once
check "the GitHub PR is polled again once its token works" '[ -f "$PRW_STATE_DIR/snapshots/github:octo-org__cockpit__42.json" ]'

# A machine with only a GitHub token still polls: no Bitbucket credential is required.
unset BITBUCKET_WATCH_USER BITBUCKET_WATCH_TOKEN
"$PRW" unsubscribe "$BB_REPO" 229 --session sb
PRW_ENV_FILE="$WORK/none" PRW_NOW=$((T0 + 120)) "$PRW" daemon once
check "a GitHub-only machine keeps polling" '[ "$(cat "$PRW_STATE_DIR/heartbeat")" = "$((T0 + 120))" ] && ! grep -q "credential missing" "$PRW_STATE_DIR/daemon.log"' "$(tail -3 "$PRW_STATE_DIR/daemon.log")"

summary
