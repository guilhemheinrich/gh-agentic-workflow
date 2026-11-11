#!/usr/bin/env bash
# setup.test.sh — credential file, shell wiring, secrecy, doctor verdicts.
. "$(dirname "$0")/lib.sh"

ENVF="$XDG_CONFIG_HOME/pr-watch/env"
touch "$HOME/.bashrc" "$HOME/.zshrc"
mkdir -p "$XDG_CONFIG_HOME/fish"

run_setup() { # extra args...
  printf 'me@example.test\ntok-NEW-456\n' | env -u BITBUCKET_WATCH_USER -u BITBUCKET_WATCH_TOKEN \
    SHELL=/bin/zsh "$PRW" setup --non-interactive "$@" 2>&1
}

out="$(run_setup)"
check "env file exists" '[ -f "$ENVF" ]'
mode="$(stat -c %a "$ENVF" 2>/dev/null || stat -f %Lp "$ENVF")"
check "env file mode is 600" '[ "$mode" = 600 ]' "mode=$mode"
check "env file exports the user" 'grep -q "^export BITBUCKET_WATCH_USER=\"me@example.test\"$" "$ENVF"'
check "env file exports the token" 'grep -q "^export BITBUCKET_WATCH_TOKEN=\"tok-NEW-456\"$" "$ENVF"'
check "setup never prints the token" '! printf "%s" "$out" | grep -q "tok-NEW-456"' "$out"
check "setup names the token page" 'printf "%s" "$out" | grep -q "id.atlassian.com/manage-profile/security/api-tokens"'
check "setup names the three scopes" 'printf "%s" "$out" | grep -q "read:repository:bitbucket" && printf "%s" "$out" | grep -q "read:pullrequest:bitbucket" && printf "%s" "$out" | grep -q "read:pipeline:bitbucket"'

out2="$(printf 'other@example.test\ntok-OTHER\n' | env -u BITBUCKET_WATCH_USER -u BITBUCKET_WATCH_TOKEN SHELL=/bin/zsh "$PRW" setup --non-interactive 2>&1)"
check "second setup keeps existing values" 'grep -q "tok-NEW-456" "$ENVF" && ! grep -q "tok-OTHER" "$ENVF"' "$out2"
check "zshenv sourced exactly once" '[ "$(grep -c "pr-watch/env" "$HOME/.zshenv")" = 1 ]'
check "bashrc sourced exactly once" '[ "$(grep -c "pr-watch/env" "$HOME/.bashrc")" = 1 ]'
check "fish loader installed" '[ -f "$XDG_CONFIG_HOME/fish/conf.d/pr-watch.fish" ]'

sed 's/tok-NEW-456/tok-OLD-000/' "$ENVF" >"$ENVF.x" && cat "$ENVF.x" >"$ENVF" && rm "$ENVF.x"
run_setup --rotate >/dev/null
check "--rotate replaces the token" 'grep -q "tok-NEW-456" "$ENVF" && ! grep -q "tok-OLD-000" "$ENVF"'

# --github alone: a GitHub-only machine is never asked for an Atlassian account.
gh_env="$(mktemp -d)"
out="$(printf 'ghp-ONLY-789\n' | env -u BITBUCKET_WATCH_USER -u BITBUCKET_WATCH_TOKEN \
  XDG_CONFIG_HOME="$gh_env" SHELL=/bin/zsh "$PRW" setup --non-interactive --github 2>&1)"; rc=$?
check "--github alone stores the GitHub token" '[ "$rc" = 0 ] && grep -q "^export GITHUB_WATCH_TOKEN=\"ghp-ONLY-789\"$" "$gh_env/pr-watch/env"' "rc=$rc $out"
check "--github alone never asks for Bitbucket" '! printf "%s" "$out" | grep -q "id.atlassian.com"' "$out"
check "--github alone leaves the Bitbucket placeholder" 'grep -q "^export BITBUCKET_WATCH_USER=\"PASTE_YOUR_EMAIL_HERE\"$" "$gh_env/pr-watch/env"'

# --claude on that machine: wiring the hooks must not stop on a Bitbucket prompt.
out="$(env -u BITBUCKET_WATCH_USER -u BITBUCKET_WATCH_TOKEN XDG_CONFIG_HOME="$gh_env" SHELL=/bin/zsh \
  PRW_ASSUME_YES=1 "$PRW" setup --non-interactive --claude </dev/null 2>&1)"; rc=$?
check "--claude alone never asks for Bitbucket" '[ "$rc" = 0 ] && ! printf "%s" "$out" | grep -q "id.atlassian.com"' "rc=$rc $out"
rm -rf "$gh_env"

# doctor
mkdir -p "$WORK/fx"
use_fixture "$WORK/fx"
printf '{"display_name":"Dev"}' >"$WORK/fx/user.json"
mkdir -p "$PRW_STATE_DIR" && date -u +%s >"$PRW_STATE_DIR/heartbeat"
out="$("$PRW" doctor 2>&1)"; rc=$?
check "doctor accepts a valid credential" 'printf "%s" "$out" | grep -q "^ok credential accepted" && [ "$rc" = 0 ]' "rc=$rc $out"
check "doctor never prints the token" '! printf "%s" "$out" | grep -q "SECRET"' "$out"
printf 403 >"$WORK/fx/user.code"
out="$("$PRW" doctor 2>&1)"; rc=$?
check "a scoped token (403 on /user) is accepted" 'printf "%s" "$out" | grep -q "^ok credential accepted" && [ "$rc" = 0 ]' "rc=$rc $out"
printf 401 >"$WORK/fx/user.code"
out="$("$PRW" doctor 2>&1)"; rc=$?
check "doctor reports a rejected credential" 'printf "%s" "$out" | grep -q "^FAIL credential rejected (401)" && [ "$rc" = 1 ]' "rc=$rc $out"
out="$("$PRW" doctor --quiet 2>&1)"; rc=$?
check "doctor --quiet is silent and keeps the exit code" '[ -z "$out" ] && [ "$rc" = 1 ]' "rc=$rc $out"
check "the token never reaches curl argv log" '! grep -q SECRET "$FAKE_CURL_LOG"'

summary
