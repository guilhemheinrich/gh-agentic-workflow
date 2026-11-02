#!/usr/bin/env bash
# config.sh — paths, dependency check and credential loading for bbw.
# Sourced by scripts/bbw and by the tests. bash 3.2 compatible.

BBW_VERSION="0.1.0"

# bbw_state_dir — print the state root, creating it. The root may contain
# spaces: every caller quotes it.
bbw_state_dir() {
  local root="${BBW_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/bitbucket-pr-watch}"
  mkdir -p "$root" || return 1
  printf '%s\n' "$root"
}

# bbw_env_file — print the credential file path (never creates it).
bbw_env_file() {
  printf '%s\n' "${BBW_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/bitbucket-pr-watch/env}"
}

# bbw_require_deps — print "missing: <tool>" per absent tool; return 1 if any.
bbw_require_deps() {
  local tool missing=0
  for tool in curl jq git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf 'missing: %s\n' "$tool"
      missing=1
    fi
  done
  return "$missing"
}

# bbw_load_credentials — export BITBUCKET_WATCH_USER / _TOKEN from the
# environment, else from the env file. A launchd or systemd unit starts with
# an empty environment, so every command sources the file itself.
bbw_load_credentials() {
  local file
  if [ -z "${BITBUCKET_WATCH_USER:-}" ] || [ -z "${BITBUCKET_WATCH_TOKEN:-}" ]; then
    file="$(bbw_env_file)"
    # shellcheck disable=SC1090
    [ -f "$file" ] && . "$file"
  fi
  if [ -z "${BITBUCKET_WATCH_USER:-}" ] || [ -z "${BITBUCKET_WATCH_TOKEN:-}" ] \
    || [ "$BITBUCKET_WATCH_TOKEN" = "PASTE_YOUR_TOKEN_HERE" ]; then
    echo "credential missing: run bbw setup" >&2
    return 1
  fi
  export BITBUCKET_WATCH_USER BITBUCKET_WATCH_TOKEN
}

# bbw_now — epoch seconds; BBW_NOW pins it in tests.
bbw_now() { printf '%s\n' "${BBW_NOW:-$(date -u +%s)}"; }

# bbw_iso — UTC ISO-8601 timestamp, identical on BSD and GNU date.
bbw_iso() {
  if [ -n "${BBW_NOW:-}" ]; then
    date -u -d "@$BBW_NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -r "$BBW_NOW" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}
