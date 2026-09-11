#!/usr/bin/env bash
# with-env.sh — load the test-target environment, then exec a command.
#
#   bash tests/env/with-env.sh [--confirm-prod] [--live] <env> -- <command> [args...]
#   bash tests/env/with-env.sh staging -- npx playwright test --project api
#   bash tests/env/with-env.sh --confirm-prod prod -- npx playwright test --grep @prod-safe
#
# Precedence, highest first:
#   1. the caller's environment (shell, CI secret store, `make VAR=…`)
#   2. tests/env/.env.<env>.secret   (gitignored)
#   3. tests/env/.env.<env>          (committed)
#
# Run flags (PROD_CONFIRM, TEST_LIVE) are NOT variables: they are the flags
# above. Any PROD_CONFIRM / TEST_LIVE found in the environment or in a file is
# discarded, so a shell profile or a .secret file cannot open the prod lock.
# The Makefile turns `make … PROD_CONFIRM=1` into --confirm-prod only when the
# assignment came from the make command line ($(origin) check).
#
# Runners then read plain environment variables (process.env, os.Getenv,
# __ENV) — no dotenv library anywhere downstream. bash 3.2 compatible.
set -euo pipefail

usage() {
  echo "usage: with-env.sh [--confirm-prod] [--live] <env> -- <command> [args...]" >&2
  exit 1
}

confirm_prod=0
live=0
while [ $# -gt 0 ]; do
  case "$1" in
    --confirm-prod) confirm_prod=1; shift ;;
    --live) live=1; shift ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || usage
env_name="$1"; shift
[ "${1:-}" = "--" ] && shift
[ $# -ge 1 ] || usage

# Lowercase letters, digits and dashes only. `Prod` would open .env.prod on a
# case-insensitive filesystem (macOS default) and dodge the string compare.
case "$env_name" in
  *[!a-z0-9-]*|"") echo "with-env: environment name must match [a-z0-9-]+, got '$env_name'" >&2; exit 2 ;;
esac

env_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="$env_dir/.env.$env_name"

if [ ! -f "$env_file" ]; then
  known="$( (cd "$env_dir" && ls .env.* 2>/dev/null | grep -v '\.secret' | sed 's/^\.env\.//' | tr '\n' ' ') || true)"
  echo "with-env: no $env_file — known environments: ${known:-none}" >&2
  exit 2
fi

# The files are sourced by bash, so they are checked first against the strict
# grammar the Node and Go loaders implement: KEY=VALUE, blank lines, full-line
# comments, single- or double-quoted values, no $ ` \ or shell metacharacter,
# no inline comment, no `export`. A file that needs more is not an env file.
env_grammar='^[[:space:]]*(#.*)?$|^[A-Za-z_][A-Za-z0-9_]*=("[^"$`\\]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]"'"'"'$`\\;&|<>()#]*)[[:space:]]*$'
check_grammar() {
  local bad
  if grep -q "$(printf '\r')" "$1"; then
    echo "with-env: $1 has CRLF line endings; bash would keep the \\r inside every value. Convert to LF." >&2
    exit 2
  fi
  bad="$(grep -nvE "$env_grammar" "$1" || true)"
  if [ -n "$bad" ]; then
    echo "with-env: $1 is not a plain KEY=VALUE file (no \$, backticks, inline comments or shell syntax):" >&2
    echo "$bad" | sed 's/^/  line /' >&2
    exit 2
  fi
}
check_grammar "$env_file"
[ -f "$env_file.secret" ] && check_grammar "$env_file.secret"

# Snapshot the caller's exported variables so they win over file values.
# `export -p` re-evaluates cleanly and needs no associative arrays (bash 3.2).
caller_env="$(export -p)"

set -a
# shellcheck disable=SC1090
. "$env_file"
if [ -f "$env_file.secret" ]; then
  # shellcheck disable=SC1090
  . "$env_file.secret"
fi
set +a

eval "$caller_env"
export TEST_ENV="$env_name"

# Run flags come from this script's options and nowhere else. The marker
# tells the in-runner fallbacks (env.ts, testenv.go) that the flags were set
# here; without it they discard PROD_CONFIRM / TEST_LIVE, so a bare IDE run
# cannot inherit them from a shell profile.
unset PROD_CONFIRM TEST_LIVE
export TEST_ENV_LOADER=with-env
[ "$confirm_prod" = 1 ] && export PROD_CONFIRM=1
[ "$live" = 1 ] && export TEST_LIVE=1

if [ "$env_name" = "prod" ] && [ "$confirm_prod" != 1 ]; then
  echo "with-env: refusing TEST_ENV=prod without --confirm-prod (make … ENV=prod PROD_CONFIRM=1)" >&2
  exit 2
fi

# A non-prod run must not reach a prod host through a caller override:
#   E2E_BASE_URL=https://app.example.com make test-e2e ENV=local
# would otherwise run the full local suite against prod with no lock.
if [ "$env_name" != "prod" ] && [ -f "$env_dir/.env.prod" ]; then
  prod_hosts="$(sed -n 's#^[A-Za-z0-9_]*_BASE_URL=["'"'"']*[A-Za-z][A-Za-z0-9+.-]*://\([^/?"'"'"']*\).*#\1#p' "$env_dir/.env.prod" | sed 's/^.*@//; s/:.*$//')"
  for var in $(env | sed -n 's#^\([A-Za-z0-9_]*_BASE_URL\)=.*#\1#p'); do
    host="$(printf '%s' "${!var}" | sed -n 's#^[A-Za-z][A-Za-z0-9+.-]*://\([^/?]*\).*#\1#p')"
    host="${host##*@}"   # drop userinfo: https://x@api.example.com is still api.example.com
    host="${host%%:*}"   # drop the port
    for prod_host in $prod_hosts; do
      if [ -n "$host" ] && [ "$host" = "$prod_host" ]; then
        echo "with-env: $var=${!var} points at a host declared in .env.prod while TEST_ENV=$env_name — run with ENV=prod PROD_CONFIRM=1 or drop the override" >&2
        exit 2
      fi
    done
  done
fi

# One line of provenance, never a secret. Add variables here, never passwords.
echo "with-env: TEST_ENV=$TEST_ENV E2E_BASE_URL=${E2E_BASE_URL:-<unset>} API_BASE_URL=${API_BASE_URL:-<unset>}${PROD_CONFIRM:+ PROD_CONFIRM=1}${TEST_LIVE:+ TEST_LIVE=1}" >&2

exec "$@"
