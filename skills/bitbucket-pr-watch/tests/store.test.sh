#!/usr/bin/env bash
# store.test.sh — subscriptions, branch resolution, lock, events cursor.
. "$(dirname "$0")/lib.sh"
. "$SKILL_DIR/tests/fixtures.sh"
FX="$WORK/fx"; mkdir -p "$FX"; use_fixture "$FX"
SUBS="$BBW_STATE_DIR/subscriptions.json"

out="$("$BBW" subscribe "$FX_REPO" 229 --session s1 --harness claude --head aaa111)"
check "positional subscribe prints the PR" '[ "$out" = "subscribed septeo-immobilier/modelo-bill-e#229" ]' "$out"
"$BBW" subscribe "$FX_REPO" 229 --session s1 --harness claude --head bbb222 >/dev/null
check "same key keeps one entry" '[ "$(jq length "$SUBS")" = 1 ]' "$(cat "$SUBS")"
check "own_heads accumulates" '[ "$(jq -c ".[0].own_heads" "$SUBS")" = "[\"aaa111\",\"bbb222\"]" ]' "$(cat "$SUBS")"
check "entry is open with harness" '[ "$(jq -r ".[0].status + \" \" + .[0].harness" "$SUBS")" = "open claude" ]'

# --branch with no open PR: pending.
q='repositories/septeo-immobilier/modelo-bill-e/pullrequests?q=source.branch.name%3D%22feat%2Fnew%22%20AND%20state%3D%22OPEN%22'
fx_put "$q" '{"values":[]}'
out="$("$BBW" subscribe --branch feat/new --repo "$FX_REPO" --session s2 --head ccc333)"
check "branch without PR is pending" '[ "$out" = "pending septeo-immobilier/modelo-bill-e@feat/new" ]' "$out"

# --branch with an open PR, repo from the git remote of the cwd.
q2='repositories/septeo-immobilier/modelo-bill-e/pullrequests?q=source.branch.name%3D%22feat%2Fcascade%22%20AND%20state%3D%22OPEN%22'
fx_put "$q2" '{"values":[{"id":229}]}'
git init -q "$WORK/repo"
git -C "$WORK/repo" remote add origin git@bitbucket.org:septeo-immobilier/modelo-bill-e.git
out="$(cd "$WORK/repo" && "$BBW" subscribe --branch feat/cascade --session s3)"
check "repo resolved from the ssh remote" '[ "$out" = "subscribed septeo-immobilier/modelo-bill-e#229" ]' "$out"
git -C "$WORK/repo" remote set-url origin https://bitbucket.org/septeo-immobilier/modelo-bill-e.git
out="$(cd "$WORK/repo" && "$BBW" subscribe --branch feat/cascade --session s4)"
check "repo resolved from the https remote" '[ "$out" = "subscribed septeo-immobilier/modelo-bill-e#229" ]' "$out"

# A pending entry turns open when the same branch later resolves.
fx_put "$q" '{"values":[{"id":230}]}'
"$BBW" subscribe --branch feat/new --repo "$FX_REPO" --session s2 >/dev/null
check "pending entry replaced by the open one" '[ "$(jq "[.[] | select(.session == \"s2\")] | length" "$SUBS")" = 1 ] && [ "$(jq -r ".[] | select(.session == \"s2\") | .status" "$SUBS")" = open ]' "$(cat "$SUBS")"
check "pending own_heads carried over" '[ "$(jq -c ".[] | select(.session == \"s2\") | .own_heads" "$SUBS")" = "[\"ccc333\"]" ]'

out="$("$BBW" list --session s1)"
check "list --session prints one line" '[ "$out" = "septeo-immobilier/modelo-bill-e#229 open s1" ]' "$out"

"$BBW" ignore-comment "$FX_REPO" 229 4521 --session s1
check "ignore-comment records the id" '[ "$(jq -c ".[] | select(.session == \"s1\") | .ignored_comments" "$SUBS")" = "[\"4521\"]" ]'

"$BBW" unsubscribe "$FX_REPO" 229 --session s1
check "unsubscribe removes the entry" '[ -z "$("$BBW" list --session s1)" ]'

# Lock contention: 20 concurrent subscribes, 20 entries.
for i in $(seq 1 20); do "$BBW" subscribe "$FX_REPO" "$((300 + i))" --session c >/dev/null & done
wait
check "20 concurrent subscribes keep 20 entries" '[ "$(jq "[.[] | select(.session == \"c\")] | length" "$SUBS")" = 20 ]' "$(jq -c "[.[] | select(.session == \"c\") | .pr]" "$SUBS")"

# Events cursor.
lib() { bash -c ". '$SKILL_DIR/scripts/lib/config.sh'; . '$SKILL_DIR/scripts/lib/store.sh'; $1"; }
lib 'events_append "s 9" "{\"text\":\"one\"}
{\"text\":\"two\"}"'
check "events_unread returns both lines" '[ "$(lib "events_unread \"s 9\"" | wc -l | tr -d " ")" = 2 ]'
lib 'events_ack "s 9" 2'
check "events_unread is empty after ack" '[ -z "$(lib "events_unread \"s 9\"")" ]'
lib 'events_append "s 9" "{\"text\":\"three\"}"'
check "only the new line is unread" '[ "$(lib "events_unread \"s 9\"" | jq -r .text)" = three ]'

summary
