#!/usr/bin/env bash
# setup.sh — `bbw setup` and `bbw doctor`.

BBW_TEMPLATES="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../templates" && pwd)"

# file_mode FILE — octal permission bits, on GNU and BSD stat.
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

cmd_setup() {
  local interactive=1 rotate=0 claude=0 env_file user token fish_dir
  while [ $# -gt 0 ]; do
    case "$1" in
      --non-interactive) interactive=0 ;;
      --rotate) rotate=1 ;;
      --claude) claude=1 ;;
      *) echo "bbw setup: unknown option $1" >&2; return 64 ;;
    esac
    shift
  done

  bash "$BBW_TEMPLATES/bbw-env.sh" || return 1
  env_file="$(bbw_env_file)"

  fish_dir="${XDG_CONFIG_HOME:-$HOME/.config}/fish"
  if [ -d "$fish_dir" ]; then
    mkdir -p "$fish_dir/conf.d"
    sed "s|@ENV_FILE@|$env_file|" "$BBW_TEMPLATES/bbw-env.fish" >"$fish_dir/conf.d/bitbucket-pr-watch.fish"
    echo "fish loader installed: $fish_dir/conf.d/bitbucket-pr-watch.fish"
  fi

  if [ "$rotate" = 1 ] || grep -q 'PASTE_YOUR_TOKEN_HERE' "$env_file"; then
    echo "Create a token at https://id.atlassian.com/manage-profile/security/api-tokens"
    echo "  (API token with scopes, Bitbucket app): read:repository:bitbucket read:pullrequest:bitbucket read:pipeline:bitbucket"
    if [ "$interactive" = 1 ]; then
      printf 'Atlassian account email: ' >&2; IFS= read -r user
      printf 'API token (hidden): ' >&2; IFS= read -rs token; echo >&2
    else
      IFS= read -r user; IFS= read -r token
    fi
    case "$user$token" in *'"'*|*'$'*|*'`'*|*'\'*) echo "refused: quote, dollar, backtick or backslash in the input" >&2; return 1 ;; esac
    if [ -z "$user" ] || [ -z "$token" ]; then echo "refused: empty email or token" >&2; return 1; fi
    (
      umask 077
      {
        grep '^#' "$env_file"
        printf 'export BITBUCKET_WATCH_USER="%s"\n' "$user"
        printf 'export BITBUCKET_WATCH_TOKEN="%s"\n' "$token"
      } >"$env_file.tmp" && mv "$env_file.tmp" "$env_file"
    )
    chmod 600 "$env_file"
    echo "credential stored in $env_file (token not shown)"
  else
    echo "credential already set in $env_file — use --rotate to replace it"
  fi

  if [ "$claude" = 1 ]; then
    if [ "$(type -t claude_install 2>/dev/null)" = "function" ]; then claude_install; else echo "claude adapter not available in this version" >&2; return 1; fi
  fi
  echo "Next: open a new shell, then run: bbw doctor"
}

cmd_doctor() {
  local quiet=0 fails=0 src out l env_file mode rc
  [ "${1:-}" = "--quiet" ] && quiet=1
  report() { # STATUS TEXT
    [ "$quiet" = 1 ] || printf '%s %s\n' "$1" "$2"
    [ "$1" = FAIL ] && fails=1
    return 0
  }

  if out="$(bbw_require_deps)"; then report ok "deps (curl, jq, git)"
  else printf '%s\n' "$out" | while IFS= read -r l; do [ "$quiet" = 1 ] || echo "FAIL $l"; done; fails=1; fi

  src="file"
  [ -n "${BITBUCKET_WATCH_TOKEN:-}" ] && src="environment"
  if bbw_load_credentials 2>/dev/null; then
    report ok "credential loaded ($src)"
    bb_get user >/dev/null 2>&1; rc=$?
    case "$rc" in
      0) report ok "credential accepted by Bitbucket" ;;
      10) report FAIL "credential rejected ($BB_HTTP_CODE)" ;;
      14) report FAIL "credential lacks a scope (403): see bbw setup for the three read scopes" ;;
      *) report FAIL "Bitbucket API unreachable (HTTP $BB_HTTP_CODE)" ;;
    esac
  else
    report FAIL "credential missing: run bbw setup"
  fi

  env_file="$(bbw_env_file)"
  if [ -f "$env_file" ]; then
    mode="$(file_mode "$env_file")"
    if [ "$mode" = 600 ]; then report ok "env file mode 600"; else report FAIL "env file mode $mode (want 600): chmod 600 $env_file"; fi
  fi

  if [ "$(type -t daemon_alive 2>/dev/null)" = "function" ]; then
    if daemon_alive; then report ok "daemon alive"; else report FAIL "daemon not running: bbw daemon start"; fi
  else report skip "daemon check"; fi

  if [ "$(type -t claude_hooks_wired 2>/dev/null)" = "function" ]; then
    if claude_hooks_wired; then report ok "claude hooks"; else report skip "claude hooks not wired (bbw setup --claude)"; fi
  else report skip "claude hooks check"; fi

  return "$fails"
}
