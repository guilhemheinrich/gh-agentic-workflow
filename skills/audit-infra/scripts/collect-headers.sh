#!/usr/bin/env bash
# collect-headers.sh: black-box HTTP collector for an infrastructure audit.
# Sends N requests on fresh connections (curl, in Docker) and prints one JSON report:
# CDN/WAF/LB/proxy layers inferred from headers, load-balancer detection, cookie affinity,
# security headers, cookies, CORS, http->https redirect, error-page leakage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/authz.sh
. "$SCRIPT_DIR/lib/authz.sh"

usage() {
  cat <<'USAGE'
Usage: collect-headers.sh --i-am-authorized <host> [options] <url>

Required:
  --i-am-authorized HOST   Exact host of <url>. Asserts that you own it or are
                           allowed to test it. Without it the script refuses (exit 77).
Options:
  --requests N             Requests on fresh connections (default 10, max 50)
  --delay SECONDS          Pause between requests (default 0.3)
  --probe-endpoints        Also request the well-known admin/debug paths of
                           lib/endpoints.tsv (24 more requests; ACTIVE tier: also
                           needs --active-scans-agreed HOST)
  --active-scans-agreed HOST  Exact host again. Asserts that the owner agreed to
                           active scans of it, in a stated time window.
  --insecure               Accept an invalid certificate (lab / self-signed only)
  --docker-network NAME    Join this Docker network (to reach a local lab)
  --out FILE               Write the JSON report to FILE instead of stdout
  -h, --help               Show this help

Volume: 2N + 3 requests (N = 10 -> 23), plus 24 with --probe-endpoints.
Example:
  collect-headers.sh --i-am-authorized shop.example.com https://shop.example.com/
USAGE
}

AUTHORIZED=""; ACTIVE=""; N=10; DELAY=0.3; PROBE=0; INSECURE=0; NETWORK=""; OUT=""; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --i-am-authorized) AUTHORIZED="${2:-}"; shift 2 ;;
    --active-scans-agreed) ACTIVE="${2:-}"; shift 2 ;;
    --requests) N="${2:-}"; shift 2 ;;
    --delay) DELAY="${2:-}"; shift 2 ;;
    --probe-endpoints) PROBE=1; shift ;;
    --insecure) INSECURE=1; shift ;;
    --docker-network) NETWORK="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) URL="$1"; shift ;;
  esac
done

[ -n "$URL" ] || { usage >&2; exit 1; }
case "$URL" in http://*|https://*) : ;; *) die "the target must be an http:// or https:// URL" ;; esac
case "$N" in ''|*[!0-9]*) die "--requests must be an integer" ;; esac
[ "$N" -ge 2 ] && [ "$N" -le 50 ] || die "--requests must be between 2 and 50"
case "$DELAY" in ''|*[!0-9.]*) die "--delay must be a number of seconds" ;; esac

authz_gate "$(url_host "$URL")" "$AUTHORIZED" "collect-headers.sh"
if [ "$PROBE" = "1" ]; then
  authz_gate_active "$(url_host "$URL")" "$ACTIVE" "collect-headers.sh" "--probe-endpoints"
fi
need_docker
ensure_toolbox "$SCRIPT_DIR"

NET_ARGS=()
[ -n "$NETWORK" ] && NET_ARGS=(--network "$NETWORK")

run() {
  docker run --rm ${NET_ARGS[@]+"${NET_ARGS[@]}"} \
    -v "$SCRIPT_DIR/lib:/audit-lib:ro" \
    "$AUDIT_INFRA_TOOLBOX" sh /audit-lib/collect-headers.inner.sh "$URL" "$N" "$DELAY" "$INSECURE" "$PROBE"
}

if [ -n "$OUT" ]; then
  run >"$OUT" || die "collection failed"
  printf 'audit-infra: report written to %s\n' "$OUT" >&2
else
  run
fi
