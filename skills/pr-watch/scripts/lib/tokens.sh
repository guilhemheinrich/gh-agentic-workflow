#!/usr/bin/env bash
# tokens.sh — the list of GitHub tokens and the per-repository choice among them.
#
# A fine-grained token covers one resource owner, so a machine whose repos
# belong to several owners needs several tokens; a classic `repo` token covers
# them all alone. The two kinds are used the same way (same header, same calls):
# the list may hold either, mixed.
#
#   GITHUB_WATCH_TOKENS  tokens separated by whitespace or commas
#   GITHUB_WATCH_TOKEN   one more token (the original variable, still read)
#
# For each OWNER/REPO the first token that reads it is remembered in
# $STATE/github-tokens/, as a hash of the token (never the token). With one
# token there is nothing to choose: no cache, no extra request.

# github_tokens — the tokens, deduplicated, in order, one per line. Nothing
# when none is set. The placeholder of a fresh env file is not a token.
github_tokens() {
  local raw t seen="
" arr
  raw="$(printf '%s %s' "${GITHUB_WATCH_TOKENS:-}" "${GITHUB_WATCH_TOKEN:-}" | tr ',\n\t' '   ')"
  set -f
  # shellcheck disable=SC2206
  arr=($raw)
  set +f
  for t in ${arr[@]+"${arr[@]}"}; do
    [ "$t" = "PASTE_YOUR_TOKEN_HERE" ] && continue
    case "$seen" in *"
$t
"*) continue ;; esac
    seen="$seen$t
"
    printf '%s\n' "$t"
  done
}

# github_hash — the first 12 hex digits of the SHA-256 of stdin.
github_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -c1-12
}

# github_token_id TOKEN — what names a token in the cache and in the output.
github_token_id() { printf '%s' "$1" | github_hash; }

# --- the remembered choice --------------------------------------------------
# A cache file holds either "ok TOKEN_ID" or, when no token read the repo,
# "none LIST_ID EPOCH HTTP CODE": the repo is not asked again for
# PRW_GITHUB_NEGATIVE_TTL seconds (600) unless the token list changes.
# PRW_NO_TOKEN_CACHE=1 turns the cache off (plan: read-only).

github_cache_file() {
  printf '%s/github-tokens/%s\n' "$(prw_state_path)" "$(printf '%s' "$1" | tr 'A-Z' 'a-z' | LC_ALL=C sed 's/[^a-z0-9._-]/__/g')"
}

github_cache_clear() {
  [ "${PRW_NO_TOKEN_CACHE:-0}" = 1 ] && return 0
  rm -f "$(github_cache_file "$1")"
}

github_cache_write() { # REPO TEXT
  local f
  [ "${PRW_NO_TOKEN_CACHE:-0}" = 1 ] && return 0
  f="$(github_cache_file "$1")"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  printf '%s\n' "$2" >"$f.tmp" && mv "$f.tmp" "$f"
}

# github_cached_token REPO TOKENS — the remembered token of REPO, if it is
# still in the list. Prints nothing otherwise.
github_cached_token() {
  local f line t id
  [ "${PRW_NO_TOKEN_CACHE:-0}" = 1 ] && return 0
  f="$(github_cache_file "$1")"
  [ -f "$f" ] || return 0
  line="$(cat "$f")"
  case "$line" in
    "ok "*)
      id="${line#ok }"
      while IFS= read -r t; do
        [ "$(github_token_id "$t")" = "$id" ] && { printf '%s\n' "$t"; return 0; }
      done <<TOKENS
$2
TOKENS
      ;;
  esac
  return 0
}

# gh_discover REPO TOKENS — find the token that reads REPO, in list order, by
# asking for the repository itself. On success sets GH_PICK and remembers it.
# On failure returns the code to report (11/14 over 10: a bad token is not the
# repository's answer) and, when every token answered, remembers that for a
# while so the next polls do not ask N tokens again. A rate limit or a network
# error decides nothing: returned as is, nothing remembered.
gh_discover() {
  local repo="$1" tokens="$2" tok rc best=10 line list_id now ttl f
  ttl="${PRW_GITHUB_NEGATIVE_TTL:-600}"
  list_id="$(printf '%s\n' "$tokens" | github_hash)"
  f="$(github_cache_file "$repo")"
  if [ "${PRW_NO_TOKEN_CACHE:-0}" != 1 ] && [ -f "$f" ]; then
    line="$(cat "$f")"
    case "$line" in
      "none $list_id "*)
        set -- $line
        now="$(prw_now)"
        if [ $((now - $3)) -lt "$ttl" ]; then
          http_result "$4" "$GITHUB_API_BASE/repos/$repo"
          return "$5"
        fi ;;
    esac
  fi
  while IFS= read -r tok; do
    gh_get_with "$tok" "$GITHUB_API_BASE/repos/$repo" >/dev/null 2>&1; rc=$?
    case "$rc" in
      0) GH_PICK="$tok"; github_cache_write "$repo" "ok $(github_token_id "$tok")"; return 0 ;;
      11|14) [ "$best" = 10 ] && best="$rc" ;;
      10) ;;
      *) return "$rc" ;;
    esac
  done <<TOKENS
$tokens
TOKENS
  github_cache_write "$repo" "none $list_id $(prw_now) ${HTTP_CODE:-000} $best"
  return "$best"
}

# gh_repo_readable REPO — 0 when some token reads REPO. No cache, no output.
gh_repo_readable() {
  local tokens
  tokens="$(github_tokens)"
  [ -n "$tokens" ] || return 10
  PRW_NO_TOKEN_CACHE=1 gh_discover "$1" "$tokens"
}

# github_watched_repos — the GitHub repos the subscriptions follow, one per line.
github_watched_repos() {
  store_subscriptions_jq -r '[.[] | select(.status != "closed") | .repo | select(startswith("github:")) | sub("^github:"; "")] | unique[]' 2>/dev/null
}

# github_token_matrix REPOS_FILE — one line per token and repo, "IDX KIND CODE
# REPO RC" ("-" for no repo): CODE is what GET /user answered, RC what the
# repository answered. Tokens never leave this function.
github_token_matrix() {
  local reposf="$1" tok i=0 rc kind urc repo
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    i=$((i + 1))
    gh_get_with "$tok" user >/dev/null 2>&1; urc=$?
    kind="$GH_TOKEN_KIND"
    if [ -s "$reposf" ]; then
      while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        gh_get_with "$tok" "repos/$repo" >/dev/null 2>&1; rc=$?
        printf '%s %s %s %s %s\n' "$i" "$kind" "$urc" "$repo" "$rc"
      done <"$reposf"
    else
      printf '%s %s %s - -\n' "$i" "$kind" "$urc"
    fi
  done <<TOKENS
$(github_tokens)
TOKENS
}
