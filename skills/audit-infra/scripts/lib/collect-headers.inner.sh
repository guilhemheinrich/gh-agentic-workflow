#!/bin/sh
# Runs INSIDE the toolbox container (alpine: curl, jq). Called by ../collect-headers.sh,
# which has already enforced the authorization gate. Prints one JSON document on stdout.
#   collect-headers.inner.sh <url> <requests> <delay-seconds> <insecure 0|1> <probe-endpoints 0|1>
set -eu

URL="$1"; N="$2"; DELAY="$3"; INSECURE="$4"; PROBE="$5"
LIB="$(dirname "$0")"
W="$(mktemp -d)"
UA="audit-infra/1.0 (authorized infrastructure audit)"
K=""; [ "$INSECURE" = "1" ] && K="-k"
# curl >= 7.83 serialises every write-out variable and every response header itself.
FMT='{"meta":%{json},"headers":%{header_json}}'

SCHEME="${URL%%://*}"
REST="${URL#*://}"
AUTHORITY="${REST%%/*}"
ORIGIN="$SCHEME://$AUTHORITY"

# one <body-file> <curl args...> : one request on a NEW connection, one JSON line.
one() {
  body="$1"; shift
  # shellcheck disable=SC2086
  if out="$(curl -sS $K -A "$UA" --max-time 15 -o "$body" -w "$FMT" "$@" 2>"$W/err")"; then
    printf '%s\n' "$out"
  else
    jq -cn --rawfile e "$W/err" '{error: ($e | gsub("\n$"; ""))}'
  fi
}

# 1. N independent requests: a fresh TCP/TLS connection each, so a load balancer re-balances.
i=0
: >"$W/samples.ndjson"
while [ "$i" -lt "$N" ]; do
  one /dev/null "$URL" >>"$W/samples.ndjson"
  i=$((i + 1))
  [ "$i" -lt "$N" ] && sleep "$DELAY"
done
jq -s . "$W/samples.ndjson" >"$W/samples.json"

# 2. Affinity probe: replay with the cookies of the first answer. If the backend-specific
#    headers stop varying, the balancer pins a client to a backend (sticky sessions).
COOKIES="$(jq -r '[.[] | select(.error | not)][0].headers["set-cookie"] // [] | map(split(";")[0]) | join("; ")' "$W/samples.json")"
: >"$W/sticky.ndjson"
if [ -n "$COOKIES" ]; then
  i=0
  while [ "$i" -lt "$N" ]; do
    one /dev/null -H "Cookie: $COOKIES" "$URL" >>"$W/sticky.ndjson"
    i=$((i + 1))
    [ "$i" -lt "$N" ] && sleep "$DELAY"
  done
fi
jq -s . "$W/sticky.ndjson" >"$W/sticky.json"

# 3. CORS probe: does the server reflect an arbitrary origin?
one /dev/null -H "Origin: https://audit-infra.invalid" "$URL" >"$W/cors.json"

# 4. Error-page probe: a path that cannot exist; the 404 often comes from another layer.
one "$W/nf.body" "$ORIGIN/audit-infra-$(date +%s)-does-not-exist" >"$W/notfound.json"
head -c 600 "$W/nf.body" 2>/dev/null >"$W/nf.head" || : >"$W/nf.head"

# 5. Plain-HTTP probe (only when the target is https on the default port).
echo null >"$W/http.json"
if [ "$SCHEME" = "https" ]; then
  case "$AUTHORITY" in
    *:*) : ;;
    *) one /dev/null "http://$AUTHORITY/" >"$W/http.json" ;;
  esac
fi

# 6. Optional: well-known admin/debug endpoints, signature-checked (active tier).
: >"$W/endpoints.ndjson"
if [ "$PROBE" = "1" ]; then
  grep -v '^#' "$LIB/endpoints.tsv" | while IFS="$(printf '\t')" read -r method path severity signature what; do
    [ -n "$path" ] || continue
    if [ "$method" = "POST" ]; then
      r="$(one "$W/ep.body" -X POST -H 'Content-Type: application/json' \
        --data '{"query":"{__schema{queryType{name}}}"}' "$ORIGIN$path")"
    else
      r="$(one "$W/ep.body" "$ORIGIN$path")"
    fi
    matched=false
    if head -c 65536 "$W/ep.body" 2>/dev/null | grep -Eq -- "$signature"; then matched=true; fi
    printf '%s' "$r" | jq -c --arg m "$method" --arg p "$path" --arg s "$severity" --arg w "$what" \
      --argjson matched "$matched" '
        {method: $m, path: $p, severity: $s,
         status: (.meta.http_code // null),
         bytes: (.meta.size_download // null),
         content_type: (.headers["content-type"][0] // null),
         signature_matched: $matched,
         exposed: ($matched and (.meta.http_code == 200)),
         what: $w, error: (.error // null)}' >>"$W/endpoints.ndjson"
    : >"$W/ep.body"
    sleep "$DELAY"
  done
fi
jq -s . "$W/endpoints.ndjson" >"$W/endpoints.json"

jq -n \
  --arg url "$URL" \
  --arg probed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg curl_version "$(curl --version | head -1)" \
  --slurpfile samples "$W/samples.json" \
  --slurpfile sticky "$W/sticky.json" \
  --slurpfile cors "$W/cors.json" \
  --slurpfile notfound "$W/notfound.json" \
  --slurpfile http "$W/http.json" \
  --slurpfile endpoints "$W/endpoints.json" \
  --rawfile nfbody "$W/nf.head" \
  -f "$LIB/analyze-headers.jq"
