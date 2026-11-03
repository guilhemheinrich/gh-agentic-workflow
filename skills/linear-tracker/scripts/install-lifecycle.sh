#!/usr/bin/env bash
# install-lifecycle.sh — install the Linear lifecycle hook into a consumer repo, once.
#
# Copies, into <target>:
#   .agents/hooks/linear-lifecycle.sh   the Stop hook
#   .agents/hooks/linear-record.sh      the per-spec event log writer
#   .agents/linear/phases.json          phase switches and state names
#   .agents/linear/*.md                 per-phase templates
# and merges the Stop hook registration into .claude/settings.json.
#
# After this the target depends on nothing in this skill. Files that already
# exist are kept (the repo owns its templates); pass --force to overwrite them.
# Re-running is safe: the settings entry is added once.
#
# Usage: install-lifecycle.sh <target-repo> [--force]

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$SKILL_DIR/templates"

target="" force=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) [[ -z "$target" ]] && target="$arg" || { echo "unexpected argument: $arg" >&2; exit 2; } ;;
  esac
done
[[ -n "$target" && -d "$target" ]] || { echo "usage: install-lifecycle.sh <target-repo> [--force]" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "install-lifecycle: jq is required" >&2; exit 2; }
target="$(cd "$target" && pwd)"

copy() { # SRC DEST MODE
  if [[ -e "$2" && "$force" != 1 ]]; then
    echo "kept       ${2#"$target"/}"
    return
  fi
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2"; chmod "$3" "$2"
  echo "installed  ${2#"$target"/}"
}

copy "$TPL/hooks/linear-lifecycle.sh" "$target/.agents/hooks/linear-lifecycle.sh" 755
copy "$TPL/hooks/linear-record.sh"    "$target/.agents/hooks/linear-record.sh"    755
for f in "$TPL"/linear/*; do
  copy "$f" "$target/.agents/linear/$(basename "$f")" 644
done

settings="$target/.claude/settings.json"
mkdir -p "$target/.claude"
[[ -s "$settings" ]] || echo '{}' >"$settings"
jq -e . "$settings" >/dev/null 2>&1 || { echo "install-lifecycle: $settings is not valid JSON; merge templates/claude-settings.json by hand" >&2; exit 1; }
cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$TPL/claude-settings.json")"
if jq -e --arg c "$cmd" 'any(.hooks.Stop[]?.hooks[]?; .command == $c)' "$settings" >/dev/null; then
  echo "kept       .claude/settings.json (Stop hook already registered)"
else
  tmp="$settings.$$"
  jq --slurpfile add "$TPL/claude-settings.json" \
    '.hooks.Stop = ((.hooks.Stop // []) + $add[0].hooks.Stop)' "$settings" >"$tmp" && mv "$tmp" "$settings"
  echo "registered .claude/settings.json (Stop hook)"
fi

if [[ ! -f "$target/.linear.json" ]]; then
  echo "note: no .linear.json in $target — the hook stays silent until one names a team and a project." >&2
fi
