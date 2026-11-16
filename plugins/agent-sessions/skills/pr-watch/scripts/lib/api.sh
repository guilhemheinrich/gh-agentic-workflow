#!/usr/bin/env bash
# api.sh — read-only REST transport for both hosts. Only GET exists here.
# The request shape of each host lives in bitbucket.sh and github.sh.

BITBUCKET_API_BASE="${BITBUCKET_API_BASE:-https://api.bitbucket.org/2.0}"
GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com}"

# http_result CODE URL — the last response, for the daemon's log and doctor.
http_result() { HTTP_CODE="$1" HTTP_URL="$2"; export HTTP_CODE HTTP_URL; }

# bb_get PATH_OR_URL — print the response body on stdout.
# Returns 0 on 2xx, 10 on 401 (credential rejected, stderr "auth"), 14 on 403
# (credential valid but no access to that resource), 11 on 404, 12 on 429 that
# persists after one Retry-After wait, 13 on any other failure. Sets
# BB_HTTP_CODE, BB_HTTP_URL and HTTP_CODE, HTTP_URL when not run in a subshell.
# The credential travels in a curl config read from stdin (-K -), never in
# argv, so `ps` and logs never see it.
# -L: Bitbucket answers a PR diffstat with a 302 to the repository diffstat on
# the same host (measured 2026-11-02); curl keeps the credential on same-host
# redirects only.
bb_get() {
  local url="$1" body hdr code wait attempt=0
  case "$url" in http*) ;; *) url="$BITBUCKET_API_BASE/$url" ;; esac
  body="$(mktemp)" hdr="$(mktemp)"
  if [ -z "${BITBUCKET_WATCH_TOKEN:-}" ]; then
    rm -f "$body" "$hdr"; BB_HTTP_CODE=000 BB_HTTP_URL="$url"; http_result 000 "$url"; echo "auth" >&2; return 10
  fi
  while :; do
    code="$(printf 'user = "%s:%s"\n' "$BITBUCKET_WATCH_USER" "$BITBUCKET_WATCH_TOKEN" \
      | curl -sS -L --max-time 30 -K - -D "$hdr" -o "$body" -w '%{http_code}' "$url" 2>/dev/null)" || code=000
    if [ "$code" = 429 ] && [ "$attempt" -eq 0 ]; then
      attempt=1
      wait="$(tr -d '\r' <"$hdr" | awk -F': *' 'tolower($1)=="retry-after"{print $2}' | head -1)"
      case "$wait" in ''|*[!0-9]*) wait=30 ;; esac
      [ "$wait" -gt 60 ] && wait=60
      sleep "${PRW_RETRY_SLEEP:-$wait}"
      continue
    fi
    break
  done
  BB_HTTP_CODE="$code" BB_HTTP_URL="$url"; http_result "$code" "$url"
  case "$code" in
    2??) cat "$body"; rm -f "$body" "$hdr"; return 0 ;;
    401) echo "auth" >&2; rm -f "$body" "$hdr"; return 10 ;;
    403) rm -f "$body" "$hdr"; return 14 ;;
    404) rm -f "$body" "$hdr"; return 11 ;;
    429) rm -f "$body" "$hdr"; return 12 ;;
    *) rm -f "$body" "$hdr"; return 13 ;;
  esac
}

# gh_get_with TOKEN PATH_OR_URL — one GitHub REST call with one token. Same
# contract as bb_get. The token is a bearer header (classic `repo` token or
# fine-grained alike: GitHub sees no difference), sent through the stdin curl
# config, so it is never in argv. No -L: a redirect would be a host we did not
# ask for.
# Also sets GH_RATELIMITED (1 when the primary rate limit answered 403: the
# token is fine, the quota is spent, so another token must not be tried) and
# GH_TOKEN_KIND (classic | fine-grained | unknown).
gh_get_with() {
  local token="$1" url="$2" body hdr code wait attempt=0
  case "$url" in http*) ;; *) url="$GITHUB_API_BASE/$url" ;; esac
  body="$(mktemp)" hdr="$(mktemp)"
  GH_RATELIMITED=0 GH_TOKEN_KIND=unknown
  while :; do
    code="$(printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\nheader = "X-GitHub-Api-Version: 2022-11-28"\n' "$token" \
      | curl -sS --max-time 30 -K - -D "$hdr" -o "$body" -w '%{http_code}' "$url" 2>/dev/null)" || code=000
    if [ "$code" = 429 ] && [ "$attempt" -eq 0 ]; then
      attempt=1
      wait="$(tr -d '\r' <"$hdr" | awk -F': *' 'tolower($1)=="retry-after"{print $2}' | head -1)"
      case "$wait" in ''|*[!0-9]*) wait=30 ;; esac
      [ "$wait" -gt 60 ] && wait=60
      sleep "${PRW_RETRY_SLEEP:-$wait}"
      continue
    fi
    break
  done
  http_result "$code" "$url"
  # Classic tokens get an X-OAuth-Scopes header on every answer; fine-grained
  # ones never do. An error answer proves nothing: fall back to the prefix.
  case "$token" in ghp_*|gho_*) GH_TOKEN_KIND=classic ;; github_pat_*) GH_TOKEN_KIND=fine-grained ;; esac
  case "$code" in
    2??) if tr -d '\r' <"$hdr" | grep -qi '^x-oauth-scopes:'; then GH_TOKEN_KIND=classic; else GH_TOKEN_KIND=fine-grained; fi ;;
    403) if tr -d '\r' <"$hdr" | grep -qi '^x-ratelimit-remaining: *0'; then GH_RATELIMITED=1; code=429; fi ;;
  esac
  case "$code" in
    2??) cat "$body"; rm -f "$body" "$hdr"; return 0 ;;
    401) echo "auth" >&2; rm -f "$body" "$hdr"; return 10 ;;
    403) rm -f "$body" "$hdr"; return 14 ;;
    404) rm -f "$body" "$hdr"; return 11 ;;
    429) rm -f "$body" "$hdr"; return 12 ;;
    *) rm -f "$body" "$hdr"; return 13 ;;
  esac
}

# gh_get PATH_OR_URL — same contract as bb_get, for the GitHub REST API, with
# the token list (tokens.sh): one token is used as is, several are tried per
# repository and the working one is remembered, so a poll costs one request.
gh_get() {
  local url="$1" tokens repo tok rc saved_code saved_url
  case "$url" in http*) ;; *) url="$GITHUB_API_BASE/$url" ;; esac
  tokens="$(github_tokens)"
  if [ -z "$tokens" ]; then http_result 000 "$url"; echo "auth" >&2; return 10; fi
  repo="$(gh_repo_of_url "$url")"
  if [ -z "$repo" ] || [ "$(printf '%s\n' "$tokens" | wc -l | tr -d ' ')" = 1 ]; then
    tok="$(printf '%s\n' "$tokens" | head -1)"
    gh_get_with "$tok" "$url"; return $?
  fi

  # Several tokens. 1. The remembered one.
  tok="$(github_cached_token "$repo" "$tokens")"
  if [ -n "$tok" ]; then
    gh_get_with "$tok" "$url" 2>/dev/null; rc=$?
    case "$rc" in
      10|11|14)
        # The answer may be about the resource (a deleted PR), not the repo:
        # only a token that cannot read the repository any more is dropped.
        saved_code="$HTTP_CODE" saved_url="$HTTP_URL"
        if gh_get_with "$tok" "$GITHUB_API_BASE/repos/$repo" >/dev/null 2>&1; then
          http_result "$saved_code" "$saved_url"; github_return "$rc"; return $?
        fi
        github_cache_clear "$repo" ;;
      *) github_return "$rc"; return $? ;;
    esac
  fi
  # 2. Find the token that reads the repository (one request per token tried).
  gh_discover "$repo" "$tokens" || { rc=$?; github_return "$rc"; return $?; }
  gh_get_with "$GH_PICK" "$url"
}

# github_return RC — RC, with the "auth" word on stderr that code 10 carries.
github_return() { [ "$1" = 10 ] && echo "auth" >&2; return "$1"; }

# gh_repo_of_url URL — OWNER/REPO of a repos/ URL on the GitHub API host.
gh_repo_of_url() {
  local p="${1#"$GITHUB_API_BASE"/}"
  [ "$p" != "$1" ] || return 0
  case "$p" in
    repos/*/*) p="${p#repos/}"; printf '%s/%s\n' "${p%%/*}" "$(printf '%s' "${p#*/}" | sed 's#[/?].*##')" ;;
  esac
}

# gh_collect PATH EXTRACT OUT — every page of a GitHub list endpoint, one JSON
# value per line in OUT. EXTRACT is the jq path of the array in each page: '.'
# for a bare array, '.check_runs' for the check-runs envelope.
gh_collect() {
  local path="$1" extract="$2" out="$3" page=1 p n rc
  p="$(mktemp)"
  : >"$out"
  while :; do
    gh_get "$path?per_page=100&page=$page" >"$p" || { rc=$?; rm -f "$p"; return "$rc"; }
    jq -c "$extract[]?" "$p" >>"$out"
    n="$(jq "$extract | length" "$p")"
    [ "$n" -lt 100 ] && break
    page=$((page + 1))
  done
  rm -f "$p"
}
