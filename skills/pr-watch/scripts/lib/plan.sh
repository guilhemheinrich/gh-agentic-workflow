#!/usr/bin/env bash
# plan.sh — `prw plan` and `prw migrate`: the two steps that turn this skill
# into an instance on one machine.
#
#   plan     read-only. Looks at the machine and says what an instance needs.
#   migrate  moves a legacy `bitbucket-pr-watch` instance onto the generic
#            names, one confirmed step at a time.
#
# Nothing here writes a secret, and plan never creates a directory.

# plan_roots — the code roots to scan, one per line: PRW_CODE_ROOTS
# (colon-separated), else ~/code and ~/lab.
plan_roots() {
  local roots="${PRW_CODE_ROOTS:-$HOME/code:$HOME/lab}" r
  while [ -n "$roots" ]; do
    r="${roots%%:*}"
    case "$roots" in *:*) roots="${roots#*:}" ;; *) roots="" ;; esac
    [ -d "$r" ] && printf '%s\n' "$r"
  done
}

# plan_hosts — "bitbucket N github N other N": the hosts the repositories under
# the code roots push to. Worktrees and dependency folders are skipped.
plan_hosts() {
  local root git dir key bb=0 gh=0 other=0 url
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    while IFS= read -r git; do
      [ -n "$git" ] || continue # an empty scan must not read the repository of the cwd
      dir="$(dirname "$git")"
      key="$(repo_from_remote "$dir" 2>/dev/null)"
      if [ -n "$key" ]; then
        case "$(provider_of "$key")" in github) gh=$((gh + 1)) ;; *) bb=$((bb + 1)) ;; esac
      else
        url="$(git -C "$dir" remote get-url origin 2>/dev/null)"
        [ -n "$url" ] && other=$((other + 1))
      fi
    done <<EOF
$(find "$root" -maxdepth 4 \( -name node_modules -o -name worktrees -o -name .worktrees -o -name .cache -o -name .gomodcache \) -prune -o -name .git -print 2>/dev/null)
EOF
  done <<EOF
$(plan_roots)
EOF
  printf 'bitbucket %s github %s other %s\n' "$bb" "$gh" "$other"
}

# plan_token_state HOST — ok | missing. Presence only: a token is never printed.
plan_token_state() {
  case "$1" in
    github)
      [ -n "$(github_tokens)" ] && echo ok || echo missing ;;
    *)
      [ -n "${BITBUCKET_WATCH_USER:-}" ] && [ -n "${BITBUCKET_WATCH_TOKEN:-}" ] \
        && [ "$BITBUCKET_WATCH_TOKEN" != "PASTE_YOUR_TOKEN_HERE" ] && echo ok || echo missing ;;
  esac
}

# plan_bitbucket_mcp — the Claude config file that declares a Bitbucket MCP
# server, or nothing.
plan_bitbucket_mcp() {
  local f
  for f in "$HOME/.claude.json" "$(claude_settings)" "$(claude_desktop_dir)/claude_desktop_config.json"; do
    [ -f "$f" ] || continue
    if jq -e '[(.mcpServers // {}) | keys[] | test("bitbucket"; "i")] | any' "$f" >/dev/null 2>&1; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 0
}

# legacy_* — where a pre-rename `bitbucket-pr-watch` instance lives.
legacy_state() { printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/bitbucket-pr-watch"; }
legacy_env() { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/bitbucket-pr-watch/env"; }
legacy_plist() { printf '%s\n' "$HOME/Library/LaunchAgents/com.bitbucket-pr-watch.daemon.plist"; }
legacy_label() { printf '%s\n' "com.bitbucket-pr-watch.daemon"; }

# legacy_hooks_present — legacy hook scripts or settings entries exist.
legacy_hooks_present() {
  local settings
  ls "$(claude_hooks_dir)"/bitbucket-pr-watch-*.sh >/dev/null 2>&1 && return 0
  settings="$(claude_settings)"
  [ -f "$settings" ] && grep -q 'bitbucket-pr-watch-' "$settings" 2>/dev/null
}

# plan_legacy — one line per leftover of the legacy instance, nothing if none.
plan_legacy() {
  local d settings
  for d in "$HOME/.agents/skills/bitbucket-pr-watch" "$HOME/.claude/skills/bitbucket-pr-watch"; do
    [ -d "$d" ] && echo "skill copy $d"
  done
  [ -f "$(legacy_plist)" ] && echo "launchd agent $(legacy_label)"
  [ -d "$(legacy_state)" ] && echo "state $(legacy_state)"
  [ -f "$(legacy_env)" ] && echo "credential file $(legacy_env)"
  ls "$(claude_hooks_dir)"/bitbucket-pr-watch-*.sh >/dev/null 2>&1 && echo "hook scripts in $(claude_hooks_dir)"
  settings="$(claude_settings)"
  if [ -f "$settings" ] && jq -e '[.. | .command? // empty | select(type == "string" and test("bitbucket-pr-watch-"))] | length > 0' "$settings" >/dev/null 2>&1; then
    echo "hook entries in $settings"
  fi
  return 0
}

# plan_owners TOKEN_STATE — the GitHub owners found under the code roots, and
# whether some token reads their repositories. Sets ownerless (owners with no
# readable repo). With tokens, one read-only request per repo and token tried,
# and no cache written: plan creates nothing.
plan_owners() {
  local repos owner count good rc repo
  repos="$(plan_github_repos)"
  [ -n "$repos" ] || return 0
  echo "owners    GitHub owners under the code roots:"
  while IFS= read -r owner; do
    [ -n "$owner" ] || continue
    count=0 good=0
    while IFS= read -r repo; do
      case "$repo" in "$owner"/*) ;; *) continue ;; esac
      count=$((count + 1))
      if [ "$1" = ok ]; then gh_repo_readable "$repo" >/dev/null 2>&1 && good=$((good + 1)); fi
    done <<REPOS
$repos
REPOS
    if [ "$1" != ok ]; then echo "            $owner  $count repos · no token"; ownerless="$ownerless${ownerless:+, }$owner"
    elif [ "$good" = 0 ]; then echo "            $owner  $count repos · NO WORKING TOKEN"; ownerless="$ownerless${ownerless:+, }$owner"
    elif [ "$good" -lt "$count" ]; then echo "            $owner  $count repos · $good readable (prw doctor names the others)"
    else echo "            $owner  $count repos · all readable"; fi
  done <<OWNERS
$(printf '%s\n' "$repos" | sed 's#/.*##' | sort -u)
OWNERS
}

cmd_plan() {
  local hosts bb gh bbn ghn mcp legacy state next=0 daemon ownerless=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --roots) PRW_CODE_ROOTS="$2"; shift ;;
      --github) ;; # kept for old callers: the GitHub step is listed by default now
      *) echo "prw plan: unknown option $1" >&2; return 64 ;;
    esac
    shift
  done
  prw_source_credentials
  hosts="$(plan_hosts)"
  set -- $hosts
  bb="$2"; gh="$4"
  bbn="$(plan_token_state bitbucket)"; ghn="$(plan_token_state github)"

  echo "prw plan — what this machine needs (read-only, nothing is changed)"
  if prw_in_checkout; then echo "runs from ${PRW_SELF:-?} — a git checkout: install first, nothing below may be applied from here"
  else echo "runs from ${PRW_SELF:-?}"; fi
  echo "hosts     bitbucket $bb · github $gh · other $6"
  echo "tokens    bitbucket $bbn · github $ghn"
  ownerless=""
  if [ "$gh" -gt 0 ]; then plan_owners "$ghn"; fi
  if [ "$(uname -s)" = Darwin ] && command -v launchctl >/dev/null 2>&1; then
    daemon="launchd"
  else
    daemon="none (run: prw daemon run)"
  fi
  echo "daemon    $daemon"
  mcp="$(plan_bitbucket_mcp)"
  if [ -n "$mcp" ]; then echo "comments  Bitbucket MCP declared in $mcp; GitHub through Bash (gh)"
  else echo "comments  no Bitbucket MCP declared; GitHub through Bash (gh)"; fi

  legacy="$(plan_legacy)"
  state="$(prw_state_path)"
  if [ -n "$legacy" ]; then
    echo "instance  legacy bitbucket-pr-watch found:"
    printf '%s\n' "$legacy" | sed 's/^/            - /'
  elif [ -d "$state" ]; then echo "instance  current ($state)"
  else echo "instance  none yet"; fi

  if [ "$gh" -gt 0 ]; then
    echo "github    $gh repositories: the native monitor fixes (Desktop: ccd_pr set_monitor auto_fix on each PR: CI failures,"
    echo "          conflicts, review comments); pr-watch informs (green CI, approvals, change requests, merges, post-merge build)"
  fi
  echo "next"
  if prw_in_checkout; then next=$((next + 1)); echo "  $next. bash install.sh   (from the repository), then re-run ~/.agents/skills/pr-watch/scripts/prw plan"; fi
  [ -n "$legacy" ] && { next=$((next + 1)); echo "  $next. prw migrate"; }
  if [ "$bb" -gt 0 ] && [ "$bbn" = missing ]; then next=$((next + 1)); echo "  $next. prw setup           (Bitbucket: $bb repositories)"; fi
  if [ "$gh" -gt 0 ] && [ "$ghn" = missing ]; then next=$((next + 1)); echo "  $next. prw setup --github  (GitHub: $gh repositories)"
  elif [ -n "$ownerless" ]; then next=$((next + 1)); echo "  $next. prw setup --github  (add a token for: $ownerless)"; fi
  if [ -z "$legacy" ] && ! claude_hooks_wired; then next=$((next + 1)); echo "  $next. prw setup --claude"; fi
  if [ -z "$legacy" ] && [ "$daemon" = launchd ] && ! daemon_alive; then next=$((next + 1)); echo "  $next. prw daemon start"; fi
  next=$((next + 1)); echo "  $next. prw doctor"
}

# migrate_confirm TEXT — y on PRW_ASSUME_YES or an interactive yes.
migrate_confirm() {
  local answer
  echo "$1"
  if [ "${PRW_ASSUME_YES:-0}" = 1 ]; then return 0; fi
  printf 'Apply? [y/N] ' >&2; IFS= read -r answer || answer=n
  case "$answer" in y|Y|yes) return 0 ;; *) echo "skipped"; return 1 ;; esac
}

cmd_migrate() {
  local d f new_state new_env rc settings
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) PRW_ASSUME_YES=1 ;;
      *) echo "prw migrate: unknown option $1" >&2; return 64 ;;
    esac
    shift
  done
  if [ -z "$(plan_legacy)" ]; then echo "no legacy bitbucket-pr-watch instance found"; return 0; fi
  prw_require_installed || return 1

  # 1. The legacy daemon must stop before its state moves.
  if [ -f "$(legacy_plist)" ] && migrate_confirm "1. stop the legacy launchd agent $(legacy_label) and remove its plist"; then
    command -v launchctl >/dev/null 2>&1 && launchctl bootout "gui/$(id -u)/$(legacy_label)" 2>/dev/null
    rm -f "$(legacy_plist)"
  fi

  # 2. State: subscriptions and snapshots keep their meaning (a Bitbucket repo key is unchanged).
  new_state="$(prw_state_path)"
  if [ -d "$(legacy_state)" ] && [ ! -e "$new_state" ] \
    && migrate_confirm "2. move $(legacy_state) to $new_state (running waits end with exit 3; the session re-arms them)"; then
    mkdir -p "$(dirname "$new_state")" && mv "$(legacy_state)" "$new_state"
    rm -f "$new_state/daemon.pid" "$new_state/daemon.started" "$new_state/heartbeat"
  elif [ -d "$(legacy_state)" ] && [ -e "$new_state" ]; then
    echo "2. $new_state already exists: legacy state left in place, merge it by hand"
  fi

  # 3. Credential file and the shell lines that source it.
  new_env="$(prw_env_file)"
  if [ -f "$(legacy_env)" ] && [ ! -e "$new_env" ] \
    && migrate_confirm "3. move the credential file to $new_env and re-point the shell startup files"; then
    mkdir -p "$(dirname "$new_env")" && mv "$(legacy_env)" "$new_env" && chmod 600 "$new_env"
    for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshenv"; do
      [ -f "$f" ] && grep -q 'bitbucket-pr-watch' "$f" && { grep -v 'bitbucket-pr-watch' "$f" >"$f.tmp"; cat "$f.tmp" >"$f"; rm -f "$f.tmp"; }
    done
    rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/bitbucket-pr-watch.fish"
    cmd_setup --non-interactive </dev/null >/dev/null
  fi

  # 4. Hooks: the legacy entries and scripts go, the generic ones come in.
  settings="$(claude_settings)"
  if legacy_hooks_present \
    && migrate_confirm "4. replace the legacy Claude hooks by the generic ones"; then
    if [ -f "$settings" ]; then
      jq 'if has("hooks") then
            .hooks |= (with_entries(.value |= map(select(any(.hooks[]?; (.command? // "") | test("bitbucket-pr-watch-")) | not)))
                       | with_entries(select(.value | length > 0)))
          else . end' "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
    fi
    rm -f "$(claude_hooks_dir)"/bitbucket-pr-watch-*.sh
    PRW_ASSUME_YES=1 claude_install >/dev/null
  fi

  # 5. The stale installed copy: two skills for one watcher would both trigger.
  for d in "$HOME/.agents/skills/bitbucket-pr-watch" "$HOME/.claude/skills/bitbucket-pr-watch"; do
    [ -d "$d" ] || continue
    case "$PRW_SELF" in "$d"/*) echo "5. $d is the copy running now: remove it by hand once prw runs from the new skill"; continue ;; esac
    migrate_confirm "5. remove the stale skill copy $d" && rm -rf "$d"
  done

  # 6. The generic daemon.
  if migrate_confirm "6. start the generic daemon"; then daemon_start || true; fi
  echo "Next: prw doctor"
}
