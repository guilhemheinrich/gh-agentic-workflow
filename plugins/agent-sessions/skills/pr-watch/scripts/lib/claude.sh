#!/usr/bin/env bash
# claude.sh — install, detect and remove the Claude Code adapter hooks.
# The settings file is persistent harness configuration: nothing is written
# before the human answers "y" to the shown change.

PRW_ADAPTER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../adapters/claude" && pwd)"
claude_settings() { printf '%s\n' "${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"; }
claude_hooks_dir() { printf '%s\n' "${PRW_HOOKS_DIR:-$HOME/.agents/hooks}"; }

# claude_merge_filter — jq program adding each snippet entry whose command is
# not registered yet, keeping everything else untouched.
CLAUDE_MERGE='
  . as $cur | ($cur.hooks // {}) as $h
  | reduce ($snip[0].hooks | to_entries[]) as $ev ($cur;
      reduce $ev.value[] as $entry (.;
        ($entry.hooks[0].command) as $c
        | if any((.hooks[$ev.key] // [])[]; (.matcher // "") == ($entry.matcher // "") and any(.hooks[]?; .command == $c)) then .
          else .hooks[$ev.key] = ((.hooks[$ev.key] // []) + [$entry]) end))'

claude_install() {
  local settings hooks_dir answer f name
  prw_require_installed || return 1
  settings="$(claude_settings)"; hooks_dir="$(claude_hooks_dir)"
  [ -f "$settings" ] || { mkdir -p "$(dirname "$settings")"; printf '{}\n' >"$settings"; }
  echo "Claude hooks to register in $settings:"
  jq -r '.hooks | to_entries[] | .key as $k | .value[] | "  \($k)\(if .matcher then " [" + .matcher + "]" else "" end): \(.hooks[0].command)"' \
    "$PRW_ADAPTER/settings-snippet.json"
  if [ "${PRW_ASSUME_YES:-0}" = 1 ]; then answer=y; else printf 'Apply? [y/N] ' >&2; IFS= read -r answer || answer=n; fi
  case "$answer" in y|Y|yes) ;; *) echo "not applied"; return 0 ;; esac

  mkdir -p "$hooks_dir"
  for f in push-hook comment-hook session-start-hook; do
    name="pr-watch-${f%-hook}.sh"
    cp "$PRW_ADAPTER/$f.sh" "$hooks_dir/$name"
  done
  sed "s|@PRW@|$PRW_SELF|" "$PRW_ADAPTER/find-prw.sh" >"$hooks_dir/pr-watch-find-prw.sh"
  jq --slurpfile snip "$PRW_ADAPTER/settings-snippet.json" "$CLAUDE_MERGE" "$settings" >"$settings.tmp" \
    && mv "$settings.tmp" "$settings"
  echo "hooks installed in $hooks_dir and registered in $settings"
}

# claude_hooks_wired — the three commands are registered.
claude_hooks_wired() {
  local settings; settings="$(claude_settings)"
  [ -f "$settings" ] || return 1
  [ "$(jq '[.. | .command? // empty | select(type == "string" and test("pr-watch-(push|comment|session-start)"))] | unique | length' "$settings" 2>/dev/null)" = 3 ]
}

claude_uninstall() {
  local settings hooks_dir
  settings="$(claude_settings)"; hooks_dir="$(claude_hooks_dir)"
  if [ -f "$settings" ]; then
    # Settings first: deleting the scripts while settings still names them
    # would make every later tool call report a hook error.
    if ! jq 'if has("hooks") then
               .hooks |= (with_entries(.value |= map(select(any(.hooks[]?; (.command? // "") | test("pr-watch-")) | not)))
                          | with_entries(select(.value | length > 0)))
             else . end' "$settings" >"$settings.tmp"; then
      rm -f "$settings.tmp"
      echo "prw: could not edit $settings; nothing removed" >&2
      return 1
    fi
    mv "$settings.tmp" "$settings"
  fi
  rm -f "$hooks_dir"/pr-watch-*.sh
  echo "Claude hooks removed"
}

cmd_uninstall() {
  case "${1:-}" in
    --claude) claude_uninstall ;;
    *) echo "prw uninstall --claude" >&2; return 64 ;;
  esac
}
