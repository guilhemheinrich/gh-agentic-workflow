#!/usr/bin/env bash
# plan.test.sh — `prw plan` reads a machine without changing it, and
# `prw migrate` moves a legacy bitbucket-pr-watch instance onto the generic
# names. Fixture repositories carry Bitbucket, GitHub and unknown remotes.
. "$(dirname "$0")/lib.sh"

# launchctl is replaced by a stub that only logs: migrate must never reach the
# real launchd of the machine running the tests (it would stop a live daemon).
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho "$@" >>"%s/launchctl.log"\nexit 0\n' "$WORK" >"$WORK/bin/launchctl"
chmod +x "$WORK/bin/launchctl"
# uname says Darwin for -s, so the launchd branch of plan and daemon_start runs
# on Linux too; every other call goes to the real one.
REAL_UNAME="$(command -v uname)"
printf '#!/bin/sh\nif [ "$1" = "-s" ]; then echo Darwin; else exec "%s" "$@"; fi\n' "$REAL_UNAME" >"$WORK/bin/uname"
chmod +x "$WORK/bin/uname"
export PATH="$WORK/bin:$PATH"
: >"$WORK/launchctl.log"

# Fixture code root: 2 Bitbucket repos, 1 GitHub repo, 1 unknown host, one
# worktree that must not be counted, and a repo without remote.
ROOT="$WORK/code"
mkrepo() { mkdir -p "$ROOT/$1" && git -C "$ROOT/$1" init -q && [ -z "${2:-}" ] || git -C "$ROOT/$1" remote add origin "$2"; }
mkrepo bb-one git@bitbucket.org:team/one.git
mkrepo bb-two https://bitbucket.org/team/two.git
mkrepo gh-one git@github.com:octo-org/cockpit.git
mkrepo other-one git@gitlab.example.test:team/app.git
mkrepo no-remote
mkrepo .claude/worktrees/wt git@github.com:octo-org/worktree-copy.git
export PRW_CODE_ROOTS="$ROOT"
export CLAUDE_SETTINGS="$HOME/.claude/settings.json"
unset GITHUB_WATCH_TOKEN

out="$("$PRW" plan 2>&1)"; rc=$?
check "plan succeeds" '[ "$rc" = 0 ]' "$out"
check "plan counts the hosts, ignoring worktrees" 'printf "%s" "$out" | grep -q "^hosts     bitbucket 2 · github 1 · other 1$"' "$out"
check "plan reports tokens by presence only" 'printf "%s" "$out" | grep -q "^tokens    bitbucket ok · github missing$" && ! printf "%s" "$out" | grep -q "tok-SECRET"' "$out"
check "plan does not propose setup --github by default" '! printf "%s" "$out" | grep -q "prw setup --github"' "$out"
check "plan points GitHub repositories to the official integration" 'printf "%s" "$out" | grep -q "^github    1 repositories: use the host.s official integration first" && printf "%s" "$out" | grep -q "bind_pr"' "$out"
out_gh="$("$PRW" plan --github 2>&1)"
check "plan --github proposes the GitHub token because GitHub repos exist" 'printf "%s" "$out_gh" | grep -q "prw setup --github  (GitHub: 1 repositories)" && ! printf "%s" "$out_gh" | grep -q "^github    "' "$out_gh"
check "plan reports the launchd branch" 'printf "%s" "$out" | grep -q "^daemon    launchd$"' "$out"
check "plan creates nothing, launchd branch included: no state dir" '[ ! -e "$PRW_STATE_DIR" ]'

# A GitHub-free machine is not asked for a GitHub token.
EMPTY="$WORK/empty-code"; mkdir -p "$EMPTY"
out="$("$PRW" plan --roots "$EMPTY" 2>&1)"
check "no GitHub repo means no GitHub setup step" '! printf "%s" "$out" | grep -q "setup --github"' "$out"

# A legacy instance is listed and migrate is the first step.
LS="$HOME/.local/state/bitbucket-pr-watch"; mkdir -p "$LS/snapshots" "$HOME/.config/bitbucket-pr-watch" "$HOME/.agents/hooks" "$HOME/.agents/skills/bitbucket-pr-watch" "$HOME/Library/LaunchAgents" "$HOME/.claude"
printf '[]' >"$LS/subscriptions.json"; : >"$LS/daemon.pid"; : >"$LS/heartbeat"
printf 'export BITBUCKET_WATCH_USER="dev@example.test"\nexport BITBUCKET_WATCH_TOKEN="tok-SECRET-123"\n' >"$HOME/.config/bitbucket-pr-watch/env"
chmod 600 "$HOME/.config/bitbucket-pr-watch/env"
printf '#!/bin/sh\n' >"$HOME/.agents/hooks/bitbucket-pr-watch-push.sh"
printf '<plist/>' >"$HOME/Library/LaunchAgents/com.bitbucket-pr-watch.daemon.plist"
printf '\n# bitbucket-pr-watch credential for bbw\n[ -f "$HOME/.config/bitbucket-pr-watch/env" ] && . "$HOME/.config/bitbucket-pr-watch/env"\n# keep me\n' >"$HOME/.zshenv"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash ~/x.sh"}]}],"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash ~/.agents/hooks/bitbucket-pr-watch-push.sh"}]}]}}\n' >"$CLAUDE_SETTINGS"
out="$("$PRW" plan 2>&1)"
check "plan lists the legacy instance" 'for w in "skill copy" "launchd agent" "state " "credential file" "hook scripts" "hook entries"; do printf "%s" "$out" | grep -q "$w" || exit 1; done' "$out"
check "migrate is the first next step" 'printf "%s" "$out" | grep -q "^  1. prw migrate$"' "$out"
check "plan still created no generic state" '[ ! -e "$PRW_STATE_DIR" ]'

# Migrate: a "n" answers leaves everything in place.
out="$(printf 'n\nn\nn\nn\nn\nn\n' | "$PRW" migrate 2>&1)"
check "answering n changes nothing" '[ -d "$LS" ] && [ -f "$HOME/.config/bitbucket-pr-watch/env" ] && [ -d "$HOME/.agents/skills/bitbucket-pr-watch" ]' "$out"

# Migrate --yes, with the generic hooks and env going to their new places.
export PRW_STATE_DIR="$HOME/.local/state/pr-watch"
out="$("$PRW" migrate --yes 2>&1)"; rc=$?
check "migrate --yes succeeds" '[ "$rc" = 0 ]' "$out"
check "state moved with its subscriptions" '[ -f "$PRW_STATE_DIR/subscriptions.json" ] && [ ! -e "$LS" ]'
check "stale daemon markers are dropped from the moved state" '[ ! -e "$PRW_STATE_DIR/daemon.pid" ] && [ ! -e "$PRW_STATE_DIR/heartbeat" ]'
check "credential file moved, mode 600, contents untouched" '[ "$(stat -c %a "$HOME/.config/pr-watch/env" 2>/dev/null || stat -f %Lp "$HOME/.config/pr-watch/env")" = 600 ] && grep -q tok-SECRET-123 "$HOME/.config/pr-watch/env" && [ ! -e "$HOME/.config/bitbucket-pr-watch/env" ]'
check "shell startup file re-pointed, other lines kept" '! grep -q "bitbucket-pr-watch" "$HOME/.zshenv" && grep -q "pr-watch/env" "$HOME/.zshenv" && grep -q "keep me" "$HOME/.zshenv"' "$(cat "$HOME/.zshenv")"
check "the legacy launchd label was booted out, and only through the stub" 'grep -q "bootout gui/.*/com.bitbucket-pr-watch.daemon" "$WORK/launchctl.log"' "$(cat "$WORK/launchctl.log")"
check "the generic daemon is installed from the running script and bootstrapped through the stub" '[ -f "$HOME/Library/LaunchAgents/com.pr-watch.daemon.plist" ] && grep -q "$SKILL_DIR/scripts/prw" "$HOME/Library/LaunchAgents/com.pr-watch.daemon.plist" && grep -q "bootstrap" "$WORK/launchctl.log"' "$(cat "$WORK/launchctl.log")"
check "legacy launchd plist removed" '[ ! -e "$HOME/Library/LaunchAgents/com.bitbucket-pr-watch.daemon.plist" ]'
check "legacy hook scripts removed, generic ones installed" '[ ! -e "$HOME/.agents/hooks/bitbucket-pr-watch-push.sh" ] && [ -f "$HOME/.agents/hooks/pr-watch-push.sh" ]'
check "settings: legacy entries gone, the foreign hook kept, four generic entries" '! grep -q "bitbucket-pr-watch" "$CLAUDE_SETTINGS" && jq -e ".hooks.Stop[0].hooks[0].command == \"bash ~/x.sh\"" "$CLAUDE_SETTINGS" >/dev/null && [ "$(jq "[.hooks | to_entries[] | .value[] | select(any(.hooks[]?; (.command // \"\") | test(\"pr-watch\")))] | length" "$CLAUDE_SETTINGS")" = 4 ]' "$(cat "$CLAUDE_SETTINGS")"
check "stale skill copy removed" '[ ! -e "$HOME/.agents/skills/bitbucket-pr-watch" ]'
out="$("$PRW" migrate 2>&1)"
check "migrate is idempotent" 'printf "%s" "$out" | grep -q "no legacy bitbucket-pr-watch instance found"' "$out"

# The checkout guard: from a worktree, migrate, daemon start and setup --claude
# refuse, because the plist and the hooks would bake that path in.
WT="$WORK/repo/.claude/worktrees/x/skills/pr-watch"; mkdir -p "$(dirname "$WT")"; cp -R "$SKILL_DIR" "$WT"
printf '{}\n' >"$HOME/.claude/settings.json"
out="$(PRW_ALLOW_CHECKOUT=0 bash "$WT/scripts/prw" daemon start 2>&1)"; rc=$?
check "daemon start refuses from a worktree" '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "refusing: it runs from a git checkout"' "rc=$rc $out"
out="$(PRW_ALLOW_CHECKOUT=0 bash "$WT/scripts/prw" setup --claude --non-interactive </dev/null 2>&1)"
check "setup --claude refuses from a worktree and writes no hook" '! [ -f "$HOME/.agents/hooks/pr-watch-find-prw.sh" ] || ! grep -q "$WT" "$HOME/.agents/hooks/pr-watch-find-prw.sh"' "$out"
out="$(PRW_ALLOW_CHECKOUT=0 bash "$WT/scripts/prw" plan --roots "$WORK/empty-code" 2>&1)"
check "plan from a worktree says to install first" 'printf "%s" "$out" | grep -q "a git checkout: install first" && printf "%s" "$out" | grep -q "bash install.sh"' "$out"

summary
