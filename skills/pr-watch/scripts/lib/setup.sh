#!/usr/bin/env bash
# setup.sh — `prw setup` and `prw doctor`.

PRW_TEMPLATES="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../templates" && pwd)"

# file_mode FILE — octal permission bits, on GNU and BSD stat.
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

cmd_setup() {
  local interactive=1 rotate=0 rotate_n="" claude=0 github=0 list=0 remove_n="" env_file user token gtoken fish_dir
  while [ $# -gt 0 ]; do
    case "$1" in
      --non-interactive) interactive=0 ;;
      --rotate) rotate=1; case "${2:-}" in ''|*[!0-9]*) ;; *) rotate_n="$2"; shift ;; esac ;;
      --list) list=1 ;;
      --remove) remove_n="${2:-}"; shift 2>/dev/null; case "$remove_n" in ''|*[!0-9]*) echo "prw setup: --remove needs a token number (see --github --list)" >&2; return 64 ;; esac ;;
      --claude) claude=1 ;;
      --github) github=1 ;;
      *) echo "prw setup: unknown option $1" >&2; return 64 ;;
    esac
    shift
  done

  if [ "$github" = 0 ] && { [ "$list" = 1 ] || [ -n "$remove_n" ]; }; then
    echo "prw setup: --list and --remove manage the GitHub tokens: use --github --list / --github --remove N" >&2; return 64
  fi
  if [ "$github" = 1 ] && [ "$list" = 1 ]; then setup_github_list; return $?; fi

  bash "$PRW_TEMPLATES/prw-env.sh" || return 1
  env_file="$(prw_env_file)"

  fish_dir="${XDG_CONFIG_HOME:-$HOME/.config}/fish"
  if [ -d "$fish_dir" ]; then
    mkdir -p "$fish_dir/conf.d"
    sed "s|@ENV_FILE@|$env_file|" "$PRW_TEMPLATES/prw-env.fish" >"$fish_dir/conf.d/pr-watch.fish"
    echo "fish loader installed: $fish_dir/conf.d/pr-watch.fish"
  fi

  # `--github` sets up GitHub only: a machine that pushes to GitHub alone has no
  # Atlassian account to give, and an empty answer used to abort before the
  # GitHub prompt. Bitbucket stays a separate `prw setup` run.
  if [ "$github" = 1 ] || [ "$claude" = 1 ]; then
    : # Bitbucket untouched: `--github` and `--claude` are their own steps, and a
      # GitHub-only machine has no Atlassian account. The placeholder means
      # "no Bitbucket token" to the daemon.
  elif [ "$rotate" = 1 ] || grep -q 'PASTE_YOUR_TOKEN_HERE' "$env_file"; then
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

  if [ "$github" = 1 ]; then setup_github_tokens "$env_file" "$interactive" "$rotate" "$rotate_n" "$remove_n" || return 1; fi

  if [ "$claude" = 1 ]; then
    if [ "$(type -t claude_install 2>/dev/null)" = "function" ]; then claude_install; else echo "claude adapter not available in this version" >&2; return 1; fi
  fi
  echo "Next: open a new shell, then run: prw doctor"
}

# setup_file_tokens ENV_FILE — the tokens the env file holds, one per line, as
# the daemon reads them, whatever this shell's environment says.
setup_file_tokens() {
  ( unset GITHUB_WATCH_TOKENS GITHUB_WATCH_TOKEN
    # shellcheck disable=SC1090
    [ -f "$1" ] && . "$1"
    github_tokens )
}

# setup_write_tokens ENV_FILE TOKENS — rewrite the GitHub line(s) of the env
# file as one GITHUB_WATCH_TOKENS list (0600). The single-token variable is
# folded into the list; the rest of the file is kept.
setup_write_tokens() {
  local env_file="$1" tokens="$2" joined
  joined="$(printf '%s\n' "$tokens" | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
  (
    umask 077
    {
      grep -v -e '^export GITHUB_WATCH_TOKEN=' -e '^export GITHUB_WATCH_TOKENS=' "$env_file"
      [ -n "$joined" ] && printf 'export GITHUB_WATCH_TOKENS="%s"\n' "$joined"
    } >"$env_file.tmp" && mv "$env_file.tmp" "$env_file"
  )
  chmod 600 "$env_file"
}

# setup_github_tokens ENV_FILE INTERACTIVE ROTATE ROTATE_N REMOVE_N — add a
# token to the list, or remove or replace one. Never prints a token.
setup_github_tokens() {
  local env_file="$1" interactive="$2" rotate="$3" rotate_n="$4" remove_n="$5" tokens count gtoken out="" i=0 t
  tokens="$(setup_file_tokens "$env_file")"
  count="$(printf '%s\n' "$tokens" | grep -c .)"

  if [ -n "$remove_n" ]; then
    if [ "$remove_n" -lt 1 ] || [ "$remove_n" -gt "$count" ]; then echo "refused: no token $remove_n ($count in the list)" >&2; return 1; fi
    while IFS= read -r t; do
      i=$((i + 1)); [ "$i" = "$remove_n" ] && continue
      out="$out$t
"
    done <<TOKENS
$tokens
TOKENS
    setup_write_tokens "$env_file" "$out"
    echo "GitHub token $remove_n removed ($((count - 1)) left); the list is in $env_file"
    echo "Also revoke it at https://github.com/settings/tokens — removing it here does not."
    return 0
  fi

  if [ "$rotate" = 1 ] && [ -z "$rotate_n" ]; then
    if [ "$count" = 1 ]; then rotate_n=1
    else echo "refused: $count tokens in the list: say which one to replace (prw setup --github --rotate N, numbers from --github --list)" >&2; return 1; fi
  fi
  if [ -n "$rotate_n" ] && { [ "$rotate_n" -lt 1 ] || [ "$rotate_n" -gt "$count" ]; }; then
    echo "refused: no token $rotate_n ($count in the list)" >&2; return 1
  fi

  echo "GitHub token, read-only: one fine-grained token per owner (user or organization), or one classic token with the repo scope for all."
  echo "  Fine-grained permissions: Pull requests, Checks, Commit statuses, Issues (read), Metadata — https://github.com/settings/personal-access-tokens"
  echo "  Each run adds a token to the list; prw uses, for each repository, the first token that can read it."
  if [ "$interactive" = 1 ]; then
    printf 'GitHub token (hidden): ' >&2; IFS= read -rs gtoken; echo >&2
  else
    IFS= read -r gtoken
  fi
  case "$gtoken" in *'"'*|*'$'*|*'`'*|*'\'*|*' '*|*,*) echo "refused: quote, dollar, backtick, backslash, space or comma in the input" >&2; return 1 ;; esac
  if [ -z "$gtoken" ]; then echo "refused: empty GitHub token" >&2; return 1; fi

  if [ -n "$rotate_n" ]; then
    while IFS= read -r t; do
      i=$((i + 1))
      if [ "$i" = "$rotate_n" ]; then out="$out$gtoken
"; else out="$out$t
"; fi
    done <<TOKENS
$tokens
TOKENS
    setup_write_tokens "$env_file" "$out"
    echo "GitHub token $rotate_n replaced in $env_file (token not shown)"
    return 0
  fi
  case "
$tokens
" in *"
$gtoken
"*) echo "GitHub token already in the list ($count tokens): nothing added"; return 0 ;; esac
  setup_write_tokens "$env_file" "$tokens
$gtoken"
  echo "GitHub token added to $env_file as number $((count + 1)) (token not shown; $((count + 1)) in the list)"
  echo "Check what it reaches: prw setup --github --list"
}

# plan_github_repos — OWNER/REPO of every GitHub repo under the code roots, one
# per line, unique. Reads the disk only (plan creates nothing).
plan_github_repos() {
  {
    local root git dir key
    while IFS= read -r root; do
      [ -n "$root" ] || continue
      while IFS= read -r git; do
        [ -n "$git" ] || continue
        dir="$(dirname "$git")"
        key="$(repo_from_remote "$dir" 2>/dev/null)"
        case "$key" in github:*) printf '%s\n' "${key#github:}" ;; esac
      done <<FINDS
$(find "$root" -maxdepth 4 \( -name node_modules -o -name worktrees -o -name .worktrees -o -name .cache -o -name .gomodcache \) -prune -o -name .git -print 2>/dev/null)
FINDS
    done <<ROOTS
$(plan_roots)
ROOTS
  } | sort -u
}

# github_matrix_summary MATRIX — "IDX KIND USER_RC OK TOTAL OWNERS" per token.
github_matrix_summary() {
  awk '{ i=$1; kind[i]=$2; urc[i]=$3; if (i>n) n=i
         if ($4 != "-") { tot[i]++; if ($5 == 0) { ok[i]++; split($4, a, "/"); o=a[1]
           if (!((i, o) in seen)) { seen[i, o]=1; owners[i]=owners[i] (owners[i]=="" ? "" : ",") o } } } }
       END { for (i=1; i<=n; i++) printf "%d %s %s %d %d %s\n", i, kind[i], urc[i], ok[i]+0, tot[i]+0, (owners[i]=="" ? "-" : owners[i]) }' "$1"
}

# github_matrix_unreadable MATRIX — the repos no token reads, one per line.
github_matrix_unreadable() {
  awk '$4 != "-" { seen[$4]=1; if ($5 == 0) ok[$4]=1 } END { for (r in seen) if (!(r in ok)) print r }' "$1" | sort
}

# setup_github_list — `prw setup --github --list`: how many tokens, and what
# each reaches among the repos under the code roots and the watched ones.
setup_github_list() {
  local env_file m repos n line i kind urc ok tot owners
  env_file="$(prw_env_file)"
  n="$(setup_file_tokens "$env_file" | grep -c .)"
  echo "$n GitHub token(s) in $env_file"
  [ "$n" = 0 ] && { echo "none yet: prw setup --github"; return 0; }
  m="$(mktemp)"; repos="$(mktemp)"
  { plan_github_repos; github_watched_repos; } | sort -u >"$repos"
  ( unset GITHUB_WATCH_TOKENS GITHUB_WATCH_TOKEN
    # shellcheck disable=SC1090
    . "$env_file"
    github_token_matrix "$repos" ) >"$m"
  while read -r i kind urc ok tot owners; do
    case "$urc" in
      0|14) echo "  $i  $kind  reads $ok of $tot known repos${owners:+ (owners: $owners)}" ;;
      10) echo "  $i  $kind  REJECTED by GitHub (401): replace it with prw setup --github --rotate $i" ;;
      *) echo "  $i  $kind  GitHub unreachable (code $urc)" ;;
    esac
  done <<SUMMARY
$(github_matrix_summary "$m")
SUMMARY
  while IFS= read -r line; do
    [ -n "$line" ] && echo "  no token reads github:$line"
  done <<UNREAD
$(github_matrix_unreadable "$m")
UNREAD
  rm -f "$m" "$repos"
}

cmd_doctor() {
  local quiet=0 fails=0 src out l env_file mode rc m wr i kind urc ok tot owners
  [ "${1:-}" = "--quiet" ] && quiet=1
  report() { # STATUS TEXT
    [ "$quiet" = 1 ] || printf '%s %s\n' "$1" "$2"
    [ "$1" = FAIL ] && fails=1
    return 0
  }

  if out="$(prw_require_deps)"; then report ok "deps (curl, jq, git)"
  else printf '%s\n' "$out" | while IFS= read -r l; do [ "$quiet" = 1 ] || echo "FAIL $l"; done; fails=1; fi

  src="file"
  [ -n "${BITBUCKET_WATCH_TOKEN:-}" ] && src="environment"
  if prw_load_credentials 2>/dev/null; then
    report ok "credential loaded ($src)"
    bb_get user >/dev/null 2>&1; rc=$?
    case "$rc" in
      0) report ok "credential accepted by Bitbucket" ;;
      10) report FAIL "credential rejected ($BB_HTTP_CODE)" ;;
      # A scoped token without an account scope gets 403 on /user, yet it
      # authenticated: a revoked or wrong token gets 401 (measured 2026-11-02).
      14) report ok "credential accepted by Bitbucket (scoped token)" ;;
      *) report FAIL "Bitbucket API unreachable (HTTP $BB_HTTP_CODE)" ;;
    esac
  elif [ -n "$(github_tokens)" ]; then
    report skip "no Bitbucket credential (GitHub only)"
  else
    report FAIL "credential missing: run prw setup"
  fi

  prw_source_credentials
  if [ -n "$(github_tokens)" ]; then
    m="$(mktemp)"; wr="$(mktemp)"
    github_watched_repos >"$wr"
    github_token_matrix "$wr" >"$m"
    while read -r i kind urc ok tot owners; do
      case "$urc" in
        0|14)
          if [ "$tot" = 0 ]; then report ok "GitHub token $i ($kind) accepted; no watched repository yet"
          else report ok "GitHub token $i ($kind) accepted; reads $ok of $tot watched repositories"; fi ;;
        10) report FAIL "GitHub token $i rejected (401): prw setup --github --rotate $i, or --remove $i" ;;
        *) report FAIL "GitHub API unreachable for token $i (code $urc)" ;;
      esac
    done <<SUMMARY
$(github_matrix_summary "$m")
SUMMARY
    # The actionable gap: a watched repository that no token reads.
    while IFS= read -r l; do
      [ -n "$l" ] && report FAIL "github:$l: no token can read it: prw setup --github with a token for owner ${l%%/*}"
    done <<UNREAD
$(github_matrix_unreadable "$m")
UNREAD
    rm -f "$m" "$wr"
  else
    report skip "GitHub not configured (prw setup --github)"
  fi

  env_file="$(prw_env_file)"
  if [ -f "$env_file" ]; then
    mode="$(file_mode "$env_file")"
    if [ "$mode" = 600 ]; then report ok "env file mode 600"; else report FAIL "env file mode $mode (want 600): chmod 600 $env_file"; fi
  fi

  if [ "$(type -t daemon_alive 2>/dev/null)" = "function" ]; then
    if daemon_alive; then report ok "daemon alive"; else report FAIL "daemon not running: prw daemon start"; fi
    # A live heartbeat is not a working watch: on 2026-11-02 the daemon beat
    # for two hours while every fetch of the one subscribed PR failed.
    out="$(daemon_health)"
    if [ -z "$out" ]; then report ok "subscriptions fetched"
    else
      while IFS= read -r l; do report FAIL "$l"; done <<EOF
$out
EOF
    fi
  else report skip "daemon check"; fi

  if [ "$(type -t claude_hooks_wired 2>/dev/null)" = "function" ]; then
    if claude_hooks_wired; then report ok "claude hooks"; else report skip "claude hooks not wired (prw setup --claude)"; fi
  else report skip "claude hooks check"; fi

  return "$fails"
}
