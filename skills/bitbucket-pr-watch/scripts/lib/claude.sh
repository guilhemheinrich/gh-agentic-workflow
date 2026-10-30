#!/usr/bin/env bash
# claude.sh — install, detect and remove the Claude Code adapter hooks.
# The settings file is persistent harness configuration: nothing is written
# before the human answers "y" to the shown change.

BBW_ADAPTER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../adapters/claude" && pwd)"
claude_settings() { printf '%s\n' "${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"; }
claude_hooks_dir() { printf '%s\n' "${BBW_HOOKS_DIR:-$HOME/.agents/hooks}"; }

# claude_merge_filter — jq program adding each snippet entry whose command is
# not registered yet, keeping everything else untouched.
CLAUDE_MERGE='
  . as $cur | ($cur.hooks // {}) as $h
  | reduce ($snip[0].hooks | to_entries[]) as $ev ($cur;
      reduce $ev.value[] as $entry (.;
        ($entry.hooks[0].command) as $c
        | if any((.hooks[$ev.key] // [])[]; any(.hooks[]?; .command == $c)) then .
          else .hooks[$ev.key] = ((.hooks[$ev.key] // []) + [$entry]) end))'

claude_install() {
  local settings hooks_dir answer f name
  settings="$(claude_settings)"; hooks_dir="$(claude_hooks_dir)"
  [ -f "$settings" ] || { mkdir -p "$(dirname "$settings")"; printf '{}\n' >"$settings"; }
  echo "Claude hooks to register in $settings:"
  jq -r '.hooks | to_entries[] | .key as $k | .value[] | "  \($k)\(if .matcher then " [" + .matcher + "]" else "" end): \(.hooks[0].command)"' \
    "$BBW_ADAPTER/settings-snippet.json"
  if [ "${BBW_ASSUME_YES:-0}" = 1 ]; then answer=y; else printf 'Apply? [y/N] ' >&2; IFS= read -r answer || answer=n; fi
  case "$answer" in y|Y|yes) ;; *) echo "not applied"; return 0 ;; esac

  mkdir -p "$hooks_dir"
  for f in push-hook comment-hook session-start-hook; do
    name="bitbucket-pr-watch-${f%-hook}.sh"
    cp "$BBW_ADAPTER/$f.sh" "$hooks_dir/$name"
  done
  sed "s|@BBW@|$BBW_SELF|" "$BBW_ADAPTER/find-bbw.sh" >"$hooks_dir/bitbucket-pr-watch-find-bbw.sh"
  jq --slurpfile snip "$BBW_ADAPTER/settings-snippet.json" "$CLAUDE_MERGE" "$settings" >"$settings.tmp" \
    && mv "$settings.tmp" "$settings"
  echo "hooks installed in $hooks_dir and registered in $settings"
}

# claude_hooks_wired — the three commands are registered.
claude_hooks_wired() {
  local settings; settings="$(claude_settings)"
  [ -f "$settings" ] || return 1
  [ "$(jq '[.. | .command? // empty | select(type == "string" and test("bitbucket-pr-watch-(push|comment|session-start)"))] | unique | length' "$settings" 2>/dev/null)" = 3 ]
}

claude_uninstall() {
  local settings hooks_dir
  settings="$(claude_settings)"; hooks_dir="$(claude_hooks_dir)"
  if [ -f "$settings" ]; then
    jq '(.hooks // {}) |= with_entries(.value |= map(select(any(.hooks[]?; .command | test("bitbucket-pr-watch-")) | not))
         | select(.value | length > 0))' "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
  fi
  rm -f "$hooks_dir"/bitbucket-pr-watch-*.sh
  echo "Claude hooks removed"
}

cmd_uninstall() {
  case "${1:-}" in
    --claude) claude_uninstall ;;
    *) echo "bbw uninstall --claude" >&2; return 64 ;;
  esac
}
