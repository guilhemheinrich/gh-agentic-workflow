#!/usr/bin/env bash
# install-lifecycle.sh — install the Linear lifecycle hook into a consumer repo, once.
#
# Copies, into <target>:
#   .claude/hooks/linear-lifecycle.sh   the Stop hook
#   .claude/hooks/linear-record.sh      the per-spec event log writer
#   .claude/linear/phases.json          the switch (`team`), phase switches, state names
#   .claude/linear/*.md                 per-phase templates
# and merges the Stop hook registration into .claude/settings.json
# (command: "$CLAUDE_PROJECT_DIR/.claude/hooks/linear-lifecycle.sh").
# Consumers are Claude Code only.
#
# phases.json carries "team": "<name>". Its non-empty `team` is what arms the
# hook; without one the hook stays silent. --team writes (or updates) it, in a
# phases.json that already exists too. There is no repository-level project:
# the project is recorded per spec (linear-record.sh <spec-dir> project NAME).
#
# After this the target depends on nothing in this skill. Files that already
# exist are kept (the repo owns its templates); pass --force to overwrite them.
# Re-running is safe: the settings entry is added once.
#
# Usage: install-lifecycle.sh <target-repo> [--team NAME] [--force]

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$SKILL_DIR/templates"

target="" force=0 team=""
while (( $# )); do
  case "$1" in
    --force) force=1 ;;
    --team) shift; team="${1:-}"; [[ -n "$team" ]] || { echo "--team needs a name" >&2; exit 2; } ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) [[ -z "$target" ]] && target="$1" || { echo "unexpected argument: $1" >&2; exit 2; } ;;
  esac
  shift
done
[[ -n "$target" && -d "$target" ]] || { echo "usage: install-lifecycle.sh <target-repo> [--team NAME] [--force]" >&2; exit 2; }
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

copy "$TPL/hooks/linear-lifecycle.sh" "$target/.claude/hooks/linear-lifecycle.sh" 755
copy "$TPL/hooks/linear-record.sh"    "$target/.claude/hooks/linear-record.sh"    755
for f in "$TPL"/linear/*; do
  copy "$f" "$target/.claude/linear/$(basename "$f")" 644
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

phases="$target/.claude/linear/phases.json"
if [[ -n "$team" ]]; then
  tmp="$phases.$$"
  jq --arg t "$team" '.team = $t' "$phases" >"$tmp" && mv "$tmp" "$phases"
  echo "team       .claude/linear/phases.json -> \"$team\""
fi
if [[ -z "$(jq -r '.team // ""' "$phases")" ]]; then
  echo "note: .claude/linear/phases.json names no team — the hook stays silent until it does (re-run with --team NAME)." >&2
fi
