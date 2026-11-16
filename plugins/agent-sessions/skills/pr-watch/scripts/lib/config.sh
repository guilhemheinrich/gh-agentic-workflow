#!/usr/bin/env bash
# config.sh — paths, dependency check and credential loading for prw.
# Sourced by scripts/prw and by the tests. bash 3.2 compatible.

PRW_VERSION="0.1.0"

# prw_state_path — print the state root without creating it (plan is read-only).
prw_state_path() { printf '%s\n' "${PRW_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/pr-watch}"; }

# prw_state_dir — print the state root, creating it. The root may contain
# spaces: every caller quotes it.
prw_state_dir() {
  local root
  root="$(prw_state_path)"
  mkdir -p "$root" || return 1
  printf '%s\n' "$root"
}

# prw_env_file — print the credential file path (never creates it).
prw_env_file() {
  printf '%s\n' "${PRW_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/pr-watch/env}"
}

# prw_require_deps — print "missing: <tool>" per absent tool; return 1 if any.
prw_require_deps() {
  local tool missing=0
  for tool in curl jq git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf 'missing: %s\n' "$tool"
      missing=1
    fi
  done
  return "$missing"
}

# prw_load_credentials — export BITBUCKET_WATCH_USER / _TOKEN from the
# environment, else from the env file. A launchd or systemd unit starts with
# an empty environment, so every command sources the file itself.
prw_load_credentials() {
  local file
  if [ -z "${BITBUCKET_WATCH_USER:-}" ] || [ -z "${BITBUCKET_WATCH_TOKEN:-}" ]; then
    file="$(prw_env_file)"
    # shellcheck disable=SC1090
    [ -f "$file" ] && . "$file"
  fi
  if [ -z "${BITBUCKET_WATCH_USER:-}" ] || [ -z "${BITBUCKET_WATCH_TOKEN:-}" ] \
    || [ "$BITBUCKET_WATCH_TOKEN" = "PASTE_YOUR_TOKEN_HERE" ]; then
    echo "credential missing: run prw setup" >&2
    return 1
  fi
  export BITBUCKET_WATCH_USER BITBUCKET_WATCH_TOKEN
}

# prw_source_credentials — export every credential the env file holds, without
# requiring any of them: each host checks its own (provider.sh check_credential).
prw_source_credentials() {
  local file
  file="$(prw_env_file)"
  # shellcheck disable=SC1090
  [ -f "$file" ] && . "$file"
  return 0
}

# prw_in_checkout — prw runs from a git checkout or a worktree, not from the
# installed skill copy.
prw_in_checkout() {
  local dir="${PRW_SELF:-}"
  [ "${PRW_ALLOW_CHECKOUT:-0}" = 1 ] && return 1
  [ -n "$dir" ] || return 1
  dir="$(dirname "$dir")"
  case "$dir" in */worktrees/*) return 0 ;; esac
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# prw_require_installed — refuse to bake a checkout path into the launchd plist
# or the hook scripts: they would keep pointing at it after the checkout or the
# worktree is gone, and fail silently. PRW_ALLOW_CHECKOUT=1 overrides (tests).
prw_require_installed() {
  [ "${PRW_ALLOW_CHECKOUT:-0}" = 1 ] && return 0
  prw_in_checkout || return 0
  echo "prw: refusing: it runs from a git checkout (${PRW_SELF:-?}); the daemon and the hooks would keep pointing at it." >&2
  echo "  Install the skill first (bash install.sh, from the repository) and run ~/.agents/skills/pr-watch/scripts/prw." >&2
  return 1
}

# prw_now — epoch seconds; PRW_NOW pins it in tests.
prw_now() { printf '%s\n' "${PRW_NOW:-$(date -u +%s)}"; }

# prw_iso — UTC ISO-8601 timestamp, identical on BSD and GNU date.
prw_iso() {
  if [ -n "${PRW_NOW:-}" ]; then
    date -u -d "@$PRW_NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -r "$PRW_NOW" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}
