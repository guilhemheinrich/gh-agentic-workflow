#!/usr/bin/env bash
# store.test.sh — subscriptions, the repo a remote names, and coexistence with
# a Bitbucket clone on the same machine.
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/github-fixtures.sh"
use_fixture "$FX"
fx_pr_open

out="$("$PRW" subscribe "$FX_KEY" 42 --session s1 --harness claude --head aaa111)"
check "subscribe a known PR" '[ "$out" = "subscribed github:octo-org/cockpit#42" ]' "$out"
"$PRW" subscribe "$FX_KEY" 42 --session s1 --harness claude --head bbb222 >/dev/null
check "re-subscribe keeps one entry and both own heads" '[ "$("$PRW" list --session s1 | wc -l | tr -d " ")" = 1 ] && [ "$(jq "[.[] | .own_heads | length] | max" "$PRW_STATE_DIR/subscriptions.json")" = 2 ]'

# Branch lookup goes through GitHub's head filter ("owner:branch").
q="$(fixture_key "repos/$FX_REPO/pulls?state=open&head=octo-org%3Afeat%2Fnew")"
fx_put "repos/$FX_REPO/pulls?state=open&head=octo-org%3Afeat%2Fnew" '[{"number": 77}]'
out="$("$PRW" subscribe --branch feat/new --repo "$FX_KEY" --session s2 --head ccc333)"
check "branch resolves to its open PR" '[ "$out" = "subscribed github:octo-org/cockpit#77" ]' "$out"

fx_put "repos/$FX_REPO/pulls?state=open&head=octo-org%3Afeat%2Fnone" '[]'
out="$("$PRW" subscribe --branch feat/none --repo "$FX_KEY" --session s3)"
check "a branch without PR is pending" '[ "$out" = "pending github:octo-org/cockpit@feat/none" ]' "$out"

# Remotes: a GitHub clone names its repo; a Bitbucket clone names none.
REPO="$WORK/repo"
mkdir -p "$REPO" && git -C "$REPO" init -q
git -C "$REPO" remote add origin git@github.com:octo-org/cockpit.git
out="$(cd "$REPO" && "$PRW" subscribe --branch feat/cascade --session s4 2>&1)"; rc=$?
check "a GitHub origin is read without --repo" '[ "$rc" != 64 ] && ! printf "%s" "$out" | grep -q "no GitHub origin"' "$out"
git -C "$REPO" remote set-url origin git@gitlab.example.test:team/app.git
out="$(cd "$REPO" && "$PRW" subscribe --branch feat/cascade --session s5 2>&1)"; rc=$?
check "an unknown host is refused, not subscribed" '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "no Bitbucket or GitHub origin"' "rc=$rc $out"

"$PRW" ignore-comment "$FX_KEY" 42 9001 --session s1
check "ignore-comment records the id" 'jq -e ".[] | select(.session == \"s1\") | .ignored_comments | index(\"9001\")" "$PRW_STATE_DIR/subscriptions.json" >/dev/null'

"$PRW" unsubscribe "$FX_KEY" 42 --session s1
check "unsubscribe removes the entry" '[ -z "$("$PRW" list --session s1)" ]'

summary
