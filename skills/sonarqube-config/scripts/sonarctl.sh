#!/usr/bin/env bash
# sonarctl.sh — bind a repository to a SonarQube (Community Build) project once,
# then scan it and read the result, from one file at the repository root.
#
#   sonarctl.sh doctor              check the machine-level and project-level setup
#   sonarctl.sh bind [options]      create project + analysis token, write .sonar-config
#       --key K --name N --visibility public|private (default public: on a
#       single-owner Community Build, public lets the analysis token read its
#       own results) --main-branch B --expires YYYY-MM-DD --force
#   sonarctl.sh scan [-- scanner args]
#                                   run the Dockerized scanner, wait for the quality
#                                   gate, print gate + open issues
#   sonarctl.sh status              quality gate + open issues without scanning
#
# Machine level — user environment, declared once by templates/sonar-env.{sh,fish}:
#   SONAR_HOST_URL      https://sonarqube.example.com
#   SONAR_ADMIN_TOKEN   USER_TOKEN (squ_…) of an account holding "Create Projects"
#                       (provisioning) permission. Read by `bind` and `doctor` only.
#
# Project level — .sonar-config at the repository root, written by `bind`:
#   SONAR_HOST_URL      same instance
#   SONAR_PROJECT_KEY   the SonarQube project key
#   SONAR_TOKEN         PROJECT_ANALYSIS_TOKEN (sqp_…) scoped to that one project
# Plain KEY=VALUE lines, no quotes, mode 0600, ignored through ~/.gitignore_global
# (a Community Build instance has one owner, so the binding is personal, not repo
# content). `scan` and `status` read only this file: they never need the admin token.
#
# Dependencies: bash, curl, jq, git, docker (scan only).
set -euo pipefail

VERSION="1.0.0"
CONFIG_NAME=".sonar-config"
SCANNER_IMAGE="${SONAR_SCANNER_IMAGE:-sonarsource/sonar-scanner-cli:latest}"
ENV_FILE="${SONAR_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/sonarqube/admin.env}"

# ── output ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_FAIL=""; C_DIM=""; C_OFF=""
fi
FAILS=0; WARNS=0
ok()   { printf '%s  ok   %s%s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s  warn %s%s\n' "$C_WARN" "$C_OFF" "$*"; WARNS=$((WARNS + 1)); }
fail() { printf '%s  FAIL %s%s\n' "$C_FAIL" "$C_OFF" "$*"; FAILS=$((FAILS + 1)); }
info() { printf '%s  ·    %s%s\n' "$C_DIM" "$C_OFF" "$*"; }
die()  { printf 'sonarctl: %s\n' "$*" >&2; exit "${2:-1}"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# ── HTTP ────────────────────────────────────────────────────────────────────
# api <token> <method> <path> [curl args…]  → body on stdout, HTTP status via api_status.
# Callers run api inside $(...), so the status crosses the subshell through a file.
STATUS_FILE=$(mktemp)
trap 'rm -f "$STATUS_FILE"' EXIT
api_status() { cat "$STATUS_FILE" 2>/dev/null || printf 000; }
api() {
  local tok=$1 method=$2 path=$3 out
  shift 3
  if ! out=$(curl -sS -m 30 -u "$tok:" -X "$method" "$@" -w $'\n%{http_code}' "$HOST/api/$path" 2>&1); then
    printf 000 >"$STATUS_FILE"
    printf '%s' "$out"
    return 1
  fi
  printf '%s' "${out##*$'\n'}" >"$STATUS_FILE"
  printf '%s' "${out%$'\n'*}"
}
api_ok() { local s; s=$(api_status); [ "$s" -ge 200 ] && [ "$s" -lt 300 ]; }
api_errors() { jq -r '[.errors[]?.msg] | join("; ")' 2>/dev/null <<<"$1" || printf '%s' "$1"; }

# ── config files ────────────────────────────────────────────────────────────
repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

# Strict dotenv reader: KEY=VALUE lines only, no quotes, no expansion. The same
# file is consumed verbatim by `docker run --env-file`, which also takes values
# literally — a quoted value would reach the scanner with its quotes.
read_config() {
  local file=$1 line key val
  P_HOST=""; P_KEY=""; P_TOKEN=""; P_BAD=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}; val=${line#*=}
    case "$key" in
      SONAR_HOST_URL)    P_HOST=$val ;;
      SONAR_PROJECT_KEY) P_KEY=$val ;;
      SONAR_TOKEN)       P_TOKEN=$val ;;
      *) P_BAD="$P_BAD $key" ;;
    esac
    case "$val" in *\"*|*\'*) P_BAD="$P_BAD $key(quoted)" ;; esac
  done <"$file"
}

require_admin() {
  HOST=${SONAR_HOST_URL:-}
  [ -n "$HOST" ] || die "SONAR_HOST_URL is not set — run templates/sonar-env.sh (or .fish), then open a new shell"
  [ -n "${SONAR_ADMIN_TOKEN:-}" ] || die "SONAR_ADMIN_TOKEN is not set — see templates/sonar-env.sh"
  HOST=${HOST%/}
}

require_project() {
  ROOT=$(repo_root)
  CONFIG="$ROOT/$CONFIG_NAME"
  [ -f "$CONFIG" ] || die "$CONFIG_NAME not found in $ROOT — run: sonarctl.sh bind"
  read_config "$CONFIG"
  [ -n "$P_HOST" ] && [ -n "$P_KEY" ] && [ -n "$P_TOKEN" ] || die "$CONFIG_NAME is incomplete (needs SONAR_HOST_URL, SONAR_PROJECT_KEY, SONAR_TOKEN) — run: sonarctl.sh bind --force"
  [ -z "$P_BAD" ] || die "$CONFIG_NAME has unexpected or quoted keys:$P_BAD"
  HOST=${P_HOST%/}
}

# Token used for READS (gate, issues, task). An analysis token can browse a public
# project only; on a private one the machine-level admin token is required.
read_token() {
  if [ -n "${SONAR_ADMIN_TOKEN:-}" ] && [ "${SONAR_HOST_URL:-}" != "" ] && [ "${SONAR_HOST_URL%/}" = "$HOST" ]; then printf %s "$SONAR_ADMIN_TOKEN"; else printf %s "$P_TOKEN"; fi
}
read_token_name() { [ "$(read_token)" = "${SONAR_ADMIN_TOKEN:-}" ] && printf admin || printf project; }

# ── gitignore (user level) ──────────────────────────────────────────────────
excludes_file() { git config --global core.excludesFile 2>/dev/null || true; }
excludes_has_config() {
  local f; f=$(excludes_file)
  [ -n "$f" ] && [ -f "${f/#\~/$HOME}" ] && grep -qxF "$CONFIG_NAME" "${f/#\~/$HOME}"
}
ensure_excluded() {
  local f; f=$(excludes_file)
  if [ -z "$f" ]; then
    f="$HOME/.gitignore_global"
    git config --global core.excludesFile "$f"
    info "set core.excludesFile = $f"
  fi
  f=${f/#\~/$HOME}
  touch "$f"
  if ! grep -qxF "$CONFIG_NAME" "$f"; then
    if grep -qx '# SonarQube artifacts' "$f"; then
      # Slot it under the existing block so the file keeps one Sonar section.
      awk -v line="$CONFIG_NAME" '{print} /^# SonarQube artifacts$/ && !done {print line; done=1}' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    else
      printf '\n# SonarQube artifacts\n# .sonar-config is the personal binding to a Community Build instance — never repo content.\n%s\n' "$CONFIG_NAME" >>"$f"
    fi
    info "added $CONFIG_NAME to $f"
  fi
}

# ── doctor ──────────────────────────────────────────────────────────────────
cmd_doctor() {
  printf 'sonarctl %s — doctor\n\nmachine\n' "$VERSION"
  local t body login perms
  for t in curl jq git; do command -v "$t" >/dev/null 2>&1 && ok "$t: $(command -v "$t")" || fail "$t: not found"; done
  if command -v docker >/dev/null 2>&1; then
    if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then ok "docker: daemon $(docker version --format '{{.Server.Version}}')"; else warn "docker: installed, daemon not reachable (scan needs it)"; fi
  else warn "docker: not found (scan needs it)"; fi

  if [ -f "$ENV_FILE" ]; then
    local mode; mode=$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE")
    [ "$mode" = "600" ] && ok "env file: $ENV_FILE (0600)" || warn "env file: $ENV_FILE has mode $mode — expected 600 (chmod 600 '$ENV_FILE')"
  else
    warn "env file: $ENV_FILE not found — run templates/sonar-env.sh or sonar-env.fish"
  fi

  HOST=${SONAR_HOST_URL:-}
  if [ -z "$HOST" ]; then
    fail "SONAR_HOST_URL: not set in this shell (a GUI-launched agent runs zsh -c and reads only ~/.zshenv — re-run templates/sonar-env.sh, SKILL.md §3)"
  else
    HOST=${HOST%/}
    case "$HOST" in https://*) ok "SONAR_HOST_URL: $HOST" ;; http://*) warn "SONAR_HOST_URL: $HOST is plain http — the token travels in clear" ;; *) fail "SONAR_HOST_URL: '$HOST' is not a URL" ;; esac
    if body=$(curl -sS -m 15 "$HOST/api/server/version" 2>&1); then ok "server: SonarQube $body"; else fail "server: unreachable — $body"; fi
  fi

  if [ -z "${SONAR_ADMIN_TOKEN:-}" ]; then
    fail "SONAR_ADMIN_TOKEN: not set (bind needs it; scan does not)"
  elif [ -n "$HOST" ]; then
    case "$SONAR_ADMIN_TOKEN" in squ_*) ;; sqp_*|sqa_*) warn "SONAR_ADMIN_TOKEN: starts with ${SONAR_ADMIN_TOKEN:0:4} — that is an analysis token, not a user token; bind will fail" ;; esac
    body=$(api "$SONAR_ADMIN_TOKEN" GET authentication/validate) || true
    if [ "$(jq -r '.valid' <<<"$body" 2>/dev/null)" = "true" ]; then
      body=$(api "$SONAR_ADMIN_TOKEN" GET users/current) || true
      login=$(jq -r '.login // "?"' <<<"$body"); perms=$(jq -r '[.permissions.global[]?] | join(",")' <<<"$body")
      ok "SONAR_ADMIN_TOKEN: valid — user '$login', global permissions: ${perms:-none}"
      case ",$perms," in *,provisioning,*|*,admin,*) ;; *) fail "SONAR_ADMIN_TOKEN: '$login' lacks 'provisioning' (Create Projects) — bind cannot create projects" ;; esac
    else
      fail "SONAR_ADMIN_TOKEN: rejected by $HOST (HTTP $(api_status))"
    fi
  fi

  local exf; exf=$(excludes_file)
  if [ -z "$exf" ]; then fail "git core.excludesFile: unset — bind will set ~/.gitignore_global; or run: git config --global core.excludesFile ~/.gitignore_global"
  elif excludes_has_config; then ok "git core.excludesFile: $exf lists $CONFIG_NAME"
  else fail "git core.excludesFile: $exf does not list $CONFIG_NAME — bind adds it, or append the line yourself"; fi

  local mcp=""
  [ -f ./.mcp.json ] && jq -e '.mcpServers.sonarqube' ./.mcp.json >/dev/null 2>&1 && mcp="./.mcp.json"
  [ -z "$mcp" ] && [ -f "$HOME/.claude.json" ] && jq -e '.mcpServers.sonarqube' "$HOME/.claude.json" >/dev/null 2>&1 && mcp="~/.claude.json"
  [ -n "$mcp" ] && ok "sonarqube MCP: configured in $mcp (issue reading through MCP tools)" || info "sonarqube MCP: not configured here — sonarctl.sh status covers issue reading through the Web API"

  printf '\nproject (%s)\n' "$(repo_root)"
  ROOT=$(repo_root); CONFIG="$ROOT/$CONFIG_NAME"
  if [ ! -f "$CONFIG" ]; then
    info "$CONFIG_NAME: absent — this repository is not bound (sonarctl.sh bind)"
  else
    read_config "$CONFIG"
    local mode; mode=$(stat -f '%Lp' "$CONFIG" 2>/dev/null || stat -c '%a' "$CONFIG")
    [ "$mode" = "600" ] && ok "$CONFIG_NAME: present (0600)" || warn "$CONFIG_NAME: mode $mode — chmod 600 '$CONFIG'"
    [ -n "$P_HOST" ] && [ -n "$P_KEY" ] && [ -n "$P_TOKEN" ] && ok "$CONFIG_NAME: SONAR_HOST_URL, SONAR_PROJECT_KEY=$P_KEY, SONAR_TOKEN present" || fail "$CONFIG_NAME: incomplete — bind --force"
    [ -z "$P_BAD" ] || fail "$CONFIG_NAME: unexpected or quoted keys:$P_BAD (docker --env-file takes quotes literally)"
    [ -n "$HOST" ] && [ -n "$P_HOST" ] && [ "${P_HOST%/}" != "$HOST" ] && warn "$CONFIG_NAME: host ${P_HOST%/} differs from SONAR_HOST_URL $HOST"
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      if git -C "$ROOT" ls-files --error-unmatch "$CONFIG_NAME" >/dev/null 2>&1; then
        fail "$CONFIG_NAME: TRACKED BY GIT — the token is in history. git rm --cached $CONFIG_NAME, then revoke and rebind (bind --force)"
      elif git -C "$ROOT" check-ignore -q "$CONFIG_NAME"; then ok "$CONFIG_NAME: ignored by git"
      else fail "$CONFIG_NAME: NOT ignored by git — a 'git add -A' would commit the token"; fi
    fi
    if [ -n "$P_HOST" ] && [ -n "$P_TOKEN" ]; then
      HOST=${P_HOST%/}
      body=$(api "$P_TOKEN" GET authentication/validate) || true
      [ "$(jq -r '.valid' <<<"$body" 2>/dev/null)" = "true" ] && ok "SONAR_TOKEN: accepted by $HOST" || fail "SONAR_TOKEN: rejected by $HOST (HTTP $(api_status)) — revoked? bind --force"
      body=$(api "$(read_token)" GET "components/show?component=$P_KEY") || true
      if api_ok; then ok "project '$P_KEY': exists — $HOST/dashboard?id=$P_KEY (reads use the $(read_token_name) token)"
      elif [ "$(api_status)" = "403" ] && [ "$(read_token_name)" = "project" ]; then warn "project '$P_KEY': private — the analysis token can scan it but not read results; set SONAR_ADMIN_TOKEN (or use the MCP) for status"
      else fail "project '$P_KEY': HTTP $(api_status) — $(api_errors "$body")"; fi
    fi
    if [ -f "$ROOT/sonar-project.properties" ]; then
      if grep -qE '^\s*sonar\.(host\.url|token|login|projectKey)\s*=' "$ROOT/sonar-project.properties"; then
        warn "sonar-project.properties: hardcodes host/token/projectKey — those belong to $CONFIG_NAME only"
      else ok "sonar-project.properties: present, scope-only"; fi
    else info "sonar-project.properties: absent — the scanner will analyse the whole tree (see SKILL.md §6)"; fi
  fi
  if [ -f "$ROOT/.env" ] && grep -qE '^SONAR_(TOKEN|PROJECT_KEY)=' "$ROOT/.env"; then
    warn ".env: carries SONAR_* keys from the pre-1.0 contract — bind writes $CONFIG_NAME; remove them from .env afterwards"
  fi

  printf '\n%d failure(s), %d warning(s)\n' "$FAILS" "$WARNS"
  [ "$FAILS" -eq 0 ]
}

# ── bind ────────────────────────────────────────────────────────────────────
default_key() {
  local url base
  url=$(git remote get-url origin 2>/dev/null || true)
  if [ -n "$url" ]; then base=${url%/}; base=${base%.git}; base=${base##*/}; base=${base##*:}; else base=$(basename "$(repo_root)"); fi
  printf '%s' "$base" | tr -c 'A-Za-z0-9_.:-\n' '-' | tr -d '\n'
}

cmd_bind() {
  need curl; need jq; need git
  local key="" name="" visibility="public" main_branch="" expires="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --key) key=$2; shift 2 ;;
      --name) name=$2; shift 2 ;;
      --visibility) visibility=$2; shift 2 ;;
      --main-branch) main_branch=$2; shift 2 ;;
      --expires) expires=$2; shift 2 ;;
      --force) force=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "bind: unknown option $1" ;;
    esac
  done
  require_admin
  ROOT=$(repo_root); CONFIG="$ROOT/$CONFIG_NAME"
  [ -n "$key" ] || key=$(default_key)
  [ -n "$name" ] || name=$key
  case "$key" in *[!A-Za-z0-9_.:-]*|'') die "project key '$key' — allowed: letters, digits, _ . : -" ;; esac
  case "$key" in *[A-Za-z]*) ;; *) die "project key '$key' must contain at least one letter" ;; esac

  printf 'bind %s → %s\n' "$key" "$HOST"
  ensure_excluded

  local body
  body=$(api "$SONAR_ADMIN_TOKEN" GET authentication/validate) || true
  [ "$(jq -r '.valid' <<<"$body" 2>/dev/null)" = "true" ] || die "SONAR_ADMIN_TOKEN rejected by $HOST (HTTP $(api_status))"
  local login; login=$(api "$SONAR_ADMIN_TOKEN" GET users/current | jq -r '.login')

  if [ -f "$CONFIG" ] && [ "$force" -eq 0 ]; then
    read_config "$CONFIG"
    if [ "$P_KEY" = "$key" ] && [ "${P_HOST%/}" = "$HOST" ] && [ -n "$P_TOKEN" ]; then
      body=$(api "$P_TOKEN" GET authentication/validate) || true
      if [ "$(jq -r '.valid' <<<"$body" 2>/dev/null)" = "true" ]; then
        ok "already bound to '$key' with a valid token — nothing to do (use --force to regenerate)"
        return 0
      fi
      warn "existing $CONFIG_NAME token is rejected — regenerating"
    else
      die "$CONFIG_NAME already binds '${P_KEY:-?}' on '${P_HOST:-?}' — pass --force to rebind to '$key'"
    fi
  fi

  # 1. project
  body=$(api "$SONAR_ADMIN_TOKEN" GET "projects/search?projects=$key") || die "projects/search failed: $body"
  api_ok || die "projects/search: HTTP $(api_status) — $(api_errors "$body") (the token needs the 'Create Projects' permission)"
  if [ "$(jq -r '.paging.total' <<<"$body")" = "0" ]; then
    local args=(--data-urlencode "project=$key" --data-urlencode "name=$name" --data-urlencode "visibility=$visibility")
    [ -n "$main_branch" ] && args+=(--data-urlencode "mainBranch=$main_branch")
    body=$(api "$SONAR_ADMIN_TOKEN" POST projects/create "${args[@]}") || die "projects/create failed: $body"
    api_ok || die "projects/create: HTTP $(api_status) — $(api_errors "$body")"
    ok "project created: $key ($visibility)"
  else
    ok "project exists: $key"
  fi

  # 2. token — one per project, named like the SonarQube UI does. A token value is
  #    readable only at generation, so a rebind revokes and regenerates.
  local tname="Analyze \"$key\""
  body=$(api "$SONAR_ADMIN_TOKEN" GET user_tokens/search) || die "user_tokens/search failed: $body"
  if jq -e --arg n "$tname" '.userTokens[] | select(.name == $n)' <<<"$body" >/dev/null; then
    body=$(api "$SONAR_ADMIN_TOKEN" POST user_tokens/revoke --data-urlencode "name=$tname") || die "user_tokens/revoke failed: $body"
    api_ok || die "user_tokens/revoke: HTTP $(api_status) — $(api_errors "$body")"
    info "revoked previous token '$tname' (its value cannot be re-read)"
  fi
  local args=(--data-urlencode "name=$tname" --data-urlencode "type=PROJECT_ANALYSIS_TOKEN" --data-urlencode "projectKey=$key")
  [ -n "$expires" ] && args+=(--data-urlencode "expirationDate=$expires")
  body=$(api "$SONAR_ADMIN_TOKEN" POST user_tokens/generate "${args[@]}") || die "user_tokens/generate failed: $body"
  api_ok || die "user_tokens/generate: HTTP $(api_status) — $(api_errors "$body")"
  local token; token=$(jq -r '.token' <<<"$body")
  [ -n "$token" ] && [ "$token" != "null" ] || die "user_tokens/generate returned no token"
  ok "token generated: '$tname' (PROJECT_ANALYSIS_TOKEN, owner $login${expires:+, expires $expires})"

  # 3. .sonar-config — plain KEY=VALUE, docker --env-file compatible, 0600, atomic.
  local tmp; tmp=$(mktemp "$ROOT/.sonar-config.XXXXXX")
  (
    umask 077
    printf '# SonarQube binding written by sonarctl.sh bind on %s — personal, never committed.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'SONAR_HOST_URL=%s\nSONAR_PROJECT_KEY=%s\nSONAR_TOKEN=%s\n' "$HOST" "$key" "$token"
  ) >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$CONFIG"
  ok "wrote $CONFIG (0600)"

  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "$ROOT" ls-files --error-unmatch "$CONFIG_NAME" >/dev/null 2>&1; then
      fail "$CONFIG_NAME is TRACKED — git rm --cached $CONFIG_NAME and rebind with --force after the removal is pushed"
    elif git -C "$ROOT" check-ignore -q "$CONFIG_NAME"; then ok "$CONFIG_NAME is ignored by git"
    else fail "$CONFIG_NAME is NOT ignored — check $(excludes_file)"; fi
  fi
  [ -f "$ROOT/sonar-project.properties" ] || info "no sonar-project.properties — add one to scope sources, tests and exclusions (SKILL.md §6)"
  printf '\nnext: sonarctl.sh scan        dashboard: %s/dashboard?id=%s\n' "$HOST" "$key"
  [ "$FAILS" -eq 0 ]
}

# ── result reading (scan + status) ──────────────────────────────────────────
print_gate() { # $1 = qualitygates/project_status body
  local st; st=$(jq -r '.projectStatus.status' <<<"$1")
  case "$st" in OK) ok "quality gate: OK" ;; NONE) info "quality gate: none computed yet" ;; *) fail "quality gate: $st" ;; esac
  jq -r '.projectStatus.conditions[]? | select(.status != "OK") | "       \(.metricKey) = \(.actualValue) (\(.comparator) \(.errorThreshold))"' <<<"$1"
}

print_issues() { # uses HOST, P_TOKEN, P_KEY, TOP
  local body total
  body=$(api "$(read_token)" GET "issues/search?componentKeys=$P_KEY&resolved=false&ps=1&facets=severities,types") || { warn "issues/search failed: $body"; return; }
  api_ok || { warn "issues/search: HTTP $(api_status) — $(api_errors "$body")${SONAR_ADMIN_TOKEN:+}"; [ "$(api_status)" = "403" ] && info "private project: reads need SONAR_ADMIN_TOKEN in the environment, or the sonarqube MCP"; return; }
  total=$(jq -r '.total' <<<"$body")
  printf '\nopen issues: %s\n' "$total"
  jq -r '.facets[] | "  \(.property): " + ([.values[] | select(.count > 0) | "\(.val)=\(.count)"] | join("  "))' <<<"$body"
  [ "$total" = "0" ] && return
  body=$(api "$(read_token)" GET "issues/search?componentKeys=$P_KEY&resolved=false&ps=$TOP&s=SEVERITY&asc=false") || return
  printf '\ntop %s by severity (file:line  severity  rule  message)\n' "$TOP"
  jq -r --arg k "$P_KEY:" '.issues[] | "  \(.component | ltrimstr($k)):\(.line // 0)  \(.severity)  \(.rule)  \(.message)"' <<<"$body"
  printf '\nfull list: MCP search_sonar_issues_in_projects (projectKey %s) or %s/project/issues?id=%s&resolved=false\n' "$P_KEY" "$HOST" "$P_KEY"
}

cmd_status() {
  need curl; need jq
  TOP=20
  while [ $# -gt 0 ]; do case "$1" in --top) TOP=$2; shift 2 ;; -h|--help) usage; return 0 ;; *) die "status: unknown option $1" ;; esac; done
  require_project
  printf 'status %s @ %s\n' "$P_KEY" "$HOST"
  local body; body=$(api "$(read_token)" GET "qualitygates/project_status?projectKey=$P_KEY") || die "project_status failed: $body"
  api_ok || die "project_status: HTTP $(api_status) — $(api_errors "$body")"
  print_gate "$body"
  print_issues
  [ "$FAILS" -eq 0 ]
}

cmd_scan() {
  need curl; need jq; need docker
  TOP=20; local wait=1 gate_timeout="${SONAR_GATE_TIMEOUT:-300}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --top) TOP=$2; shift 2 ;;
      --no-wait) wait=0; shift ;;
      --) shift; break ;;
      -h|--help) usage; return 0 ;;
      -D*) break ;;
      *) die "scan: unknown option $1 (scanner flags go after --)" ;;
    esac
  done
  require_project
  cd "$ROOT"
  printf 'scan %s → %s  (image %s)\n' "$P_KEY" "$HOST" "$SCANNER_IMAGE"
  mkdir -p "$HOME/.sonar/cache" "$ROOT/.scannerwork"
  local extra=() rc=0
  [ "$wait" -eq 1 ] && extra+=("-Dsonar.qualitygate.wait=true" "-Dsonar.qualitygate.timeout=$gate_timeout")
  # The official image reads SONAR_HOST_URL and SONAR_TOKEN from its environment;
  # the project key travels as a -D flag. /usr/src is the image's base dir, and the
  # working directory is pinned inside the mount (the image defaults to /tmp) so
  # report-task.txt survives the container and yields the analysis id.
  docker run --rm \
    -e "SONAR_HOST_URL=$HOST" -e "SONAR_TOKEN=$P_TOKEN" \
    ${SONAR_SCANNER_OPTS:+-e "SONAR_SCANNER_OPTS=$SONAR_SCANNER_OPTS"} \
    -v "$ROOT:/usr/src" -v "$HOME/.sonar/cache:/opt/sonar-scanner/.sonar/cache" \
    "$SCANNER_IMAGE" "-Dsonar.projectKey=$P_KEY" "-Dsonar.working.directory=/usr/src/.scannerwork" ${extra[@]+"${extra[@]}"} "$@" || rc=$?
  printf '\n'
  [ "$rc" -eq 0 ] && ok "scanner finished" || warn "scanner exit code $rc (a failed quality gate also exits non-zero when waiting)"

  local report="$ROOT/.scannerwork/report-task.txt" task_id="" analysis_id="" body status
  if [ -f "$report" ]; then
    task_id=$(sed -n 's/^ceTaskId=//p' "$report")
    if [ -n "$task_id" ]; then
      local i=0
      while :; do
        body=$(api "$(read_token)" GET "ce/task?id=$task_id") || break
        status=$(jq -r '.task.status' <<<"$body")
        case "$status" in
          SUCCESS) analysis_id=$(jq -r '.task.analysisId' <<<"$body"); ok "analysis task: SUCCESS ($task_id)"; break ;;
          FAILED|CANCELED) fail "analysis task: $status — $(jq -r '.task.errorMessage // "no message"' <<<"$body")"; break ;;
          *) i=$((i + 1)); [ "$i" -gt 60 ] && { warn "analysis task still $status after 5 min — check $HOST/project/background_tasks?id=$P_KEY"; break; }; sleep 5 ;;
        esac
      done
    fi
  else
    warn "no .scannerwork/report-task.txt — the scanner did not reach the server"
  fi
  if [ -n "$analysis_id" ]; then
    body=$(api "$(read_token)" GET "qualitygates/project_status?analysisId=$analysis_id") && api_ok && print_gate "$body"
  else
    body=$(api "$(read_token)" GET "qualitygates/project_status?projectKey=$P_KEY") && api_ok && print_gate "$body"
  fi
  print_issues
  printf '\ndashboard: %s/dashboard?id=%s\n' "$HOST" "$P_KEY"
  [ "$FAILS" -eq 0 ] && [ "$rc" -eq 0 ]
}

# ── main ────────────────────────────────────────────────────────────────────
case "${1:-}" in
  doctor) shift; cmd_doctor "$@" ;;
  bind)   shift; cmd_bind "$@" ;;
  scan)   shift; cmd_scan "$@" ;;
  status) shift; cmd_status "$@" ;;
  --version) printf 'sonarctl %s\n' "$VERSION" ;;
  -h|--help|'') usage; [ -n "${1:-}" ] || exit 2 ;;
  *) die "unknown command '$1' — doctor | bind | scan | status" 2 ;;
esac
