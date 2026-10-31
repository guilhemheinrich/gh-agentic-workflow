#!/usr/bin/env bash
# api.sh — read-only Bitbucket Cloud REST calls. Only GET exists here.

BBW_API_BASE="${BBW_API_BASE:-https://api.bitbucket.org/2.0}"

# bb_get PATH_OR_URL — print the response body on stdout.
# Returns 0 on 2xx, 10 on 401 (credential rejected, stderr "auth"), 14 on 403
# (credential valid but no access to that resource), 11 on 404, 12 on 429 that
# persists after one Retry-After wait, 13 on any other failure. Sets
# BB_HTTP_CODE when not run in a subshell. The credential travels in a curl
# config read from stdin (-K -), never in argv, so `ps` and logs never see it.
bb_get() {
  local url="$1" body hdr code wait attempt=0
  case "$url" in http*) ;; *) url="$BBW_API_BASE/$url" ;; esac
  body="$(mktemp)" hdr="$(mktemp)"
  while :; do
    code="$(printf 'user = "%s:%s"\n' "$BITBUCKET_WATCH_USER" "$BITBUCKET_WATCH_TOKEN" \
      | curl -sS --max-time 30 -K - -D "$hdr" -o "$body" -w '%{http_code}' "$url" 2>/dev/null)" || code=000
    if [ "$code" = 429 ] && [ "$attempt" -eq 0 ]; then
      attempt=1
      wait="$(tr -d '\r' <"$hdr" | awk -F': *' 'tolower($1)=="retry-after"{print $2}' | head -1)"
      case "$wait" in ''|*[!0-9]*) wait=30 ;; esac
      [ "$wait" -gt 60 ] && wait=60
      sleep "${BBW_RETRY_SLEEP:-$wait}"
      continue
    fi
    break
  done
  BB_HTTP_CODE="$code"
  case "$code" in
    2??) cat "$body"; rm -f "$body" "$hdr"; return 0 ;;
    401) echo "auth" >&2; rm -f "$body" "$hdr"; return 10 ;;
    403) rm -f "$body" "$hdr"; return 14 ;;
    404) rm -f "$body" "$hdr"; return 11 ;;
    429) rm -f "$body" "$hdr"; return 12 ;;
    *) rm -f "$body" "$hdr"; return 13 ;;
  esac
}
