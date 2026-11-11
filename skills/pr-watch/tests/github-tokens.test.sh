#!/usr/bin/env bash
# github-tokens.test.sh — a list of GitHub tokens: one machine, several owners.
# Fine-grained tokens (one owner each) and a classic `repo` token (every owner)
# are used the same way; the working token of a repo is remembered by hash.
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/github-fixtures.sh"
use_fixture "$FX"
export FAKE_CURL_AUTHLOG="$WORK/auth.log"
export PRW_RETRY_SLEEP=0
unset GITHUB_WATCH_TOKEN GITHUB_WATCH_TOKENS
unset BITBUCKET_WATCH_USER BITBUCKET_WATCH_TOKEN

mkdir -p "$FX/tokens"
fx_pr_open
fx_put "repos/octo-org/cockpit" '{"full_name":"octo-org/cockpit"}'
fx_put "repos/other-org/api" '{"full_name":"other-org/api"}'
fx_put "repos/other-org/api/pulls/7" '{"number":7}'
fx_put "user" '{"login":"me"}'
# FG1 reads octo-org only, FG2 other-org only, CLASSIC (a `repo` scope token) everything.
printf 'octo-org/cockpit\n' >"$FX/tokens/FG1-AAA.repos"
printf 'other-org/api\n' >"$FX/tokens/FG2-BBB.repos"
: >"$FX/tokens/CLASSIC-CCC.classic"
fresh() { : >"$FAKE_CURL_LOG"; : >"$FAKE_CURL_AUTHLOG"; rm -rf "$PRW_STATE_DIR"; }
reqs() { wc -l <"$FAKE_CURL_AUTHLOG" | tr -d ' '; }

# --- the list --------------------------------------------------------------
out="$(GITHUB_WATCH_TOKENS="t1, t2  t3,t1" GITHUB_WATCH_TOKEN=t2 lib 'github_tokens' | tr '\n' ' ')"
check "the list splits on spaces and commas and deduplicates, TOKEN included" '[ "$out" = "t1 t2 t3 " ]' "$out"
out="$(GITHUB_WATCH_TOKENS="" GITHUB_WATCH_TOKEN=solo lib 'github_tokens')"
check "GITHUB_WATCH_TOKEN alone is a one-element list" '[ "$out" = solo ]' "$out"
out="$(GITHUB_WATCH_TOKENS="" GITHUB_WATCH_TOKEN=PASTE_YOUR_TOKEN_HERE lib 'github_tokens')"
check "the placeholder is not a token" '[ -z "$out" ]' "$out"

# --- a classic token alone covers every repo, with no extra configuration ----
fresh
export GITHUB_WATCH_TOKEN=CLASSIC-CCC
lib 'gh_get repos/octo-org/cockpit/pulls/42 >/dev/null; gh_get repos/other-org/api/pulls/7 >/dev/null'
check "one classic token reads two owners" '[ "$(reqs)" = 2 ]' "$(cat "$FAKE_CURL_AUTHLOG")"
check "a single token costs one request per call and writes no cache" '[ ! -e "$PRW_STATE_DIR/github-tokens" ]'
out="$(lib 'gh_get repos/other-org/api/pulls/7 | jq -r .number')"
check "the classic token sends the same bearer call" '[ "$out" = 7 ]'
unset GITHUB_WATCH_TOKEN

# The same list given as the original variable and as a list keeps working.
fresh
out="$(GITHUB_WATCH_TOKENS="CLASSIC-CCC FG1-AAA" lib 'gh_get repos/other-org/api/pulls/7 | jq -r .number; gh_get repos/octo-org/cockpit/pulls/42 | jq -r .number' | tr '\n' ' ')"
check "a classic token first in a list answers every repo" '[ "$out" = "7 42 " ]' "$out"
check "classic token: a probe plus the call the first time, then one per call" '[ "$(reqs)" = 4 ]' "$(cat "$FAKE_CURL_AUTHLOG")"

# --- fine-grained tokens, one per owner ------------------------------------
fresh
export GITHUB_WATCH_TOKENS="FG1-AAA FG2-BBB"
out="$(lib 'gh_get repos/other-org/api/pulls/7 | jq -r .number')"
check "the second token is found for the second owner" '[ "$out" = 7 ]' "$out"
check "first use: FG1 refused, FG2 accepted, then the call" '[ "$(cat "$FAKE_CURL_AUTHLOG")" = "FG1-AAA repos/other-org/api
FG2-BBB repos/other-org/api
FG2-BBB repos/other-org/api/pulls/7" ]' "$(cat "$FAKE_CURL_AUTHLOG")"
: >"$FAKE_CURL_AUTHLOG"
lib 'for i in 1 2 3 4 5; do gh_get repos/other-org/api/pulls/7 >/dev/null; done; for i in 1 2 3 4 5; do gh_get repos/octo-org/cockpit/pulls/42 >/dev/null; done'
# 5 calls on other-org (cached: 5 requests), 5 on octo-org (1 discovery probe + 5 calls)
check "later polls make one request each: the fallback does not multiply requests" '[ "$(reqs)" = 11 ]' "$(reqs): $(cat "$FAKE_CURL_AUTHLOG")"
check "the cache holds hashes, never a token" '! grep -rq -e FG1-AAA -e FG2-BBB "$PRW_STATE_DIR" && grep -rq "^ok " "$PRW_STATE_DIR/github-tokens"'
check "no token in the request URL log" '! grep -q -e FG1-AAA -e FG2-BBB "$FAKE_CURL_LOG"'

# A 404 on a resource of a readable repo does not drop the token.
: >"$FAKE_CURL_AUTHLOG"
lib 'gh_get repos/octo-org/cockpit/pulls/999 >/dev/null 2>&1; echo $? >"$1"' "$WORK/rc" 2>/dev/null
rc="$(lib 'gh_get repos/octo-org/cockpit/pulls/999 >/dev/null 2>&1; echo $?')"
check "the resource 404 is reported as 404" '[ "$rc" = 11 ]' "$rc"
: >"$FAKE_CURL_AUTHLOG"
lib 'gh_get repos/octo-org/cockpit/pulls/42 >/dev/null'
check "the token is kept after a resource 404: one request next time" '[ "$(reqs)" = 1 ] && grep -q "^FG1-AAA" "$FAKE_CURL_AUTHLOG"' "$(cat "$FAKE_CURL_AUTHLOG")"

# A rate-limited token is not abandoned for another one (same user, same quota).
touch "$FX/tokens/FG2-BBB.ratelimited"; : >"$FAKE_CURL_AUTHLOG"
rc="$(lib 'gh_get repos/other-org/api/pulls/7 >/dev/null 2>&1; echo $?')"
check "a spent quota answers 12 and keeps the cache" '[ "$rc" = 12 ] && grep -q "^ok " "$PRW_STATE_DIR/github-tokens/other-org__api"' "$rc"
check "no other token is tried on a spent quota" '! grep -q "^FG1-AAA" "$FAKE_CURL_AUTHLOG"'
rm -f "$FX/tokens/FG2-BBB.ratelimited"

# A token that starts failing is dropped, another one takes over.
export GITHUB_WATCH_TOKENS="FG1-AAA FG2-BBB CLASSIC-CCC"
touch "$FX/tokens/FG2-BBB.invalid"; : >"$FAKE_CURL_AUTHLOG"
out="$(lib 'gh_get repos/other-org/api/pulls/7 | jq -r .number')"
check "a revoked token is replaced by one that reads the repo" '[ "$out" = 7 ] && grep -q "^CLASSIC-CCC repos/other-org/api/pulls/7" "$FAKE_CURL_AUTHLOG"' "$out"
: >"$FAKE_CURL_AUTHLOG"
lib 'gh_get repos/other-org/api/pulls/7 >/dev/null'
check "and the new choice is remembered" '[ "$(cat "$FAKE_CURL_AUTHLOG")" = "CLASSIC-CCC repos/other-org/api/pulls/7" ]' "$(cat "$FAKE_CURL_AUTHLOG")"
rm -f "$FX/tokens/FG2-BBB.invalid"

# A repo nobody reads: every token asked once, then silence until the list changes.
fx_put "repos/lost-org/nope" '{}'
export GITHUB_WATCH_TOKENS="FG1-AAA FG2-BBB"; : >"$FAKE_CURL_AUTHLOG"
rc="$(lib 'gh_get repos/lost-org/nope/pulls/1 >/dev/null 2>&1; echo $?')"
check "a repo no token reads answers 404" '[ "$rc" = 11 ] && [ "$(reqs)" = 2 ]' "rc=$rc $(reqs)"
: >"$FAKE_CURL_AUTHLOG"
lib 'for i in 1 2 3; do gh_get repos/lost-org/nope/pulls/1 >/dev/null 2>&1; done'
check "an unreadable repo is not asked again every poll" '[ "$(reqs)" = 0 ]' "$(reqs)"
printf 'lost-org/nope\n' >"$FX/tokens/FG3-DDD.repos"
export GITHUB_WATCH_TOKENS="FG1-AAA FG2-BBB FG3-DDD"; : >"$FAKE_CURL_AUTHLOG"
lib 'gh_get repos/lost-org/nope/pulls/1 >/dev/null 2>&1'
check "adding a token makes the repo readable at once" 'grep -q "^FG3-DDD repos/lost-org/nope/pulls/1" "$FAKE_CURL_AUTHLOG"' "$(cat "$FAKE_CURL_AUTHLOG")"
rc="$(GITHUB_WATCH_TOKENS="" lib 'gh_get repos/octo-org/cockpit >/dev/null 2>&1; echo $?')"
check "no token at all is the credential error" '[ "$rc" = 10 ]' "$rc"

# --- setup --github --------------------------------------------------------
unset GITHUB_WATCH_TOKENS
sx="$(mktemp -d)"; senv="$sx/pr-watch/env"
gsetup() { env -u GITHUB_WATCH_TOKENS -u GITHUB_WATCH_TOKEN XDG_CONFIG_HOME="$sx" SHELL=/bin/zsh "$PRW" setup --non-interactive --github "$@" 2>&1; }
mkdir -p "$sx/pr-watch"; printf 'export GITHUB_WATCH_TOKEN="old-LEGACY-1"\n' >"$sx/pr-watch/env"
out1="$(printf 'ghp-FIRST-111\n' | gsetup)"; rc=$?
check "a run adds a token and folds the legacy variable into the list" '[ "$rc" = 0 ] && grep -q "^export GITHUB_WATCH_TOKENS=\"old-LEGACY-1 ghp-FIRST-111\"$" "$senv" && ! grep -q "^export GITHUB_WATCH_TOKEN=" "$senv"' "$out1 $(cat "$senv")"
out2="$(printf 'github_pat_SECOND-222\n' | gsetup)"
check "the second run adds a second token" 'grep -q "^export GITHUB_WATCH_TOKENS=\"old-LEGACY-1 ghp-FIRST-111 github_pat_SECOND-222\"$" "$senv"' "$out2"
check "setup never prints a token" '! printf "%s%s" "$out1" "$out2" | grep -q -e LEGACY -e FIRST-111 -e SECOND-222' "$out1 $out2"
mode="$(stat -c %a "$senv" 2>/dev/null || stat -f %Lp "$senv")"
check "the env file stays 0600" '[ "$mode" = 600 ]' "$mode"
out="$(printf 'ghp-FIRST-111\n' | gsetup)"
check "a token already in the list is not added twice" 'printf "%s" "$out" | grep -q "already in the list" && [ "$(grep -o ghp-FIRST-111 "$senv" | wc -l)" = 1 ]' "$out"
out="$(printf 'bad token\n' | gsetup)"; rc=$?
check "a token with a space is refused" '[ "$rc" = 1 ] && [ "$(grep -o "github_pat" "$senv" | wc -l)" = 1 ]' "$out"

out="$(printf 'ghp-ROT-333\n' | gsetup --rotate 2)"
check "--rotate N replaces token N in place" 'grep -q "GITHUB_WATCH_TOKENS=\"old-LEGACY-1 ghp-ROT-333 github_pat_SECOND-222\"" "$senv" && ! grep -q FIRST-111 "$senv"' "$out"
out="$(printf 'x\n' | gsetup --rotate 2>&1)"; rc=$?
check "--rotate without a number is refused when several tokens exist" '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "say which one"' "$out"
out="$(gsetup --remove 1)"
check "--remove N removes token N" 'grep -q "GITHUB_WATCH_TOKENS=\"ghp-ROT-333 github_pat_SECOND-222\"" "$senv" && ! printf "%s" "$out" | grep -q -e ROT-333 -e SECOND' "$out"
out="$(gsetup --remove 9)"; rc=$?
check "--remove out of range is refused" '[ "$rc" = 1 ]' "$out"

# --list: how many, what each reaches, no token.
printf 'FG1-AAA FG2-BBB\n' >/dev/null
printf 'export GITHUB_WATCH_TOKENS="FG1-AAA FG2-BBB CLASSIC-CCC"\n' >"$senv"
CR="$WORK/code"; mkdir -p "$CR"
for r in "octo-org cockpit" "other-org api" "lost-org nope"; do
  set -- $r; mkdir -p "$CR/$2"; git -C "$CR/$2" init -q; git -C "$CR/$2" remote add origin "git@github.com:$1/$2.git"
done
out="$(PRW_CODE_ROOTS="$CR" XDG_CONFIG_HOME="$sx" env -u GITHUB_WATCH_TOKENS -u GITHUB_WATCH_TOKEN "$PRW" setup --github --list 2>&1)"
check "--list counts the tokens" 'printf "%s" "$out" | grep -q "^3 GitHub token(s)"' "$out"
check "--list shows what each token reaches" 'printf "%s" "$out" | grep -q "^  1  fine-grained\? .*reads 1 of 3 known repos (owners: octo-org)" && printf "%s" "$out" | grep -q "^  3  classic  reads 3 of 3"' "$out"
check "--list never prints a token" '! printf "%s" "$out" | grep -q -e FG1-AAA -e FG2-BBB -e CLASSIC-CCC' "$out"
check "--list is read-only" '[ "$(grep -c . "$senv")" = 1 ]'
rm -rf "$sx"

# --- doctor ------------------------------------------------------------------
mkdir -p "$PRW_STATE_DIR"; date -u +%s >"$PRW_STATE_DIR/heartbeat"
printf '[{"repo":"github:octo-org/cockpit","pr":42,"status":"open","session":"s"},{"repo":"github:lost-org/nope","pr":1,"status":"open","session":"s"}]' >"$PRW_STATE_DIR/subscriptions.json"
out="$(GITHUB_WATCH_TOKENS="FG1-AAA FG2-BBB CLASSIC-CCC" XDG_CONFIG_HOME="$WORK/none" "$PRW" doctor 2>&1)"
check "doctor: one line per token with its kind and reach" 'printf "%s" "$out" | grep -q "^ok GitHub token 1 (fine-grained) accepted; reads 1 of 2 watched repositories" && printf "%s" "$out" | grep -q "^ok GitHub token 3 (classic) accepted; reads 2 of 2 watched"' "$out"
check "a classic token reading everything leaves no gap" '! printf "%s" "$out" | grep -q "no token can read it"' "$out"
out="$(GITHUB_WATCH_TOKENS="FG1-AAA FG2-BBB" XDG_CONFIG_HOME="$WORK/none" "$PRW" doctor 2>&1)"
check "doctor: the repo no token reads is the failure" 'printf "%s" "$out" | grep -q "^FAIL github:lost-org/nope: no token can read it"' "$out"
check "doctor never prints a token" '! printf "%s" "$out" | grep -q -e FG1-AAA -e FG2-BBB -e CLASSIC-CCC' "$out"
check "doctor no longer says the credential is missing on a GitHub-only machine" '! printf "%s" "$out" | grep -q "credential missing"' "$out"
touch "$FX/tokens/FG2-BBB.invalid"
out="$(GITHUB_WATCH_TOKENS="FG1-AAA FG2-BBB" XDG_CONFIG_HOME="$WORK/none" "$PRW" doctor 2>&1)"
check "doctor: a rejected token is named by number" 'printf "%s" "$out" | grep -q "^FAIL GitHub token 2 rejected (401)"' "$out"
rm -f "$FX/tokens/FG2-BBB.invalid"

# --- plan --------------------------------------------------------------------
rm -rf "$PRW_STATE_DIR" "$HOME/.claude"
out="$(GITHUB_WATCH_TOKENS="FG1-AAA FG2-BBB" PRW_CODE_ROOTS="$CR" XDG_CONFIG_HOME="$WORK/none" "$PRW" plan 2>&1)"
check "plan lists the owners and the one with no working token" 'printf "%s" "$out" | grep -q "octo-org  1 repos · all readable" && printf "%s" "$out" | grep -q "lost-org  1 repos · NO WORKING TOKEN"' "$out"
check "plan names the owners to add a token for" 'printf "%s" "$out" | grep -q "prw setup --github  (add a token for: lost-org)"' "$out"
check "plan still creates nothing" '[ ! -e "$PRW_STATE_DIR" ]'
out="$(PRW_CODE_ROOTS="$CR" XDG_CONFIG_HOME="$WORK/none" "$PRW" plan 2>&1)"
check "plan without a token says so per owner" 'printf "%s" "$out" | grep -q "lost-org  1 repos · no token"' "$out"

summary
