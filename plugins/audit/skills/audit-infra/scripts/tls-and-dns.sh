#!/usr/bin/env bash
# tls-and-dns.sh: DNS and TLS posture of one host, as JSON (dig + openssl, in Docker).
# DNS: A/AAAA/NS/MX/TXT/CAA/SOA, CNAME chain hop by hop, dangling CNAME and takeover
# candidates, PTR of each address, SPF/DMARC. TLS: protocol versions accepted
# (1.0 to 1.3), negotiated cipher, ALPN, certificate (issuer, SAN, expiry, key, trust),
# OCSP stapling, HSTS. --deep adds a full testssl.sh run (several minutes, noisier).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/authz.sh
. "$SCRIPT_DIR/lib/authz.sh"

TESTSSL_IMAGE="${AUDIT_INFRA_TESTSSL_IMAGE:-drwetter/testssl.sh:3.2}"

usage() {
  cat <<'USAGE'
Usage: tls-and-dns.sh --i-am-authorized <host> [options] <host>

Required:
  --i-am-authorized HOST   Exact target host. Asserts that you own it or are
                           allowed to test it. Without it the script refuses (exit 77).
Options:
  --port PORT              TLS port (default 443)
  --dns-only               DNS section only (queries go to resolvers, not to the host)
  --takeover-probe         With the DNS section: when the CNAME chain ends on a
                           third-party provider that still resolves, send ONE plain
                           HTTP GET to the authorized host itself and look for the
                           provider's "no such resource" page (light tier, not passive)
  --tls-only               TLS section only (about 6 handshakes to the host)
  --deep DIR               Also run testssl.sh and write DIR/testssl.json (hundreds of
                           handshakes; ACTIVE tier: also needs --active-scans-agreed HOST)
  --active-scans-agreed HOST  Exact host again. Asserts that the owner agreed to
                           active scans of it, in a stated time window.
  --resolver IP            Ask this DNS server instead of the container's default
                           (an authoritative server, or a lab resolver)
  --docker-network NAME    Join this Docker network (to reach a local lab)
  --out FILE               Write the JSON report to FILE instead of stdout
  -h, --help               Show this help

Example:
  tls-and-dns.sh --i-am-authorized shop.example.com shop.example.com
USAGE
}

AUTHORIZED=""; ACTIVE=""; TAKEOVER=0; PORT=443; MODE=all; DEEP=""; NETWORK=""; OUT=""; HOST=""; RESOLVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --i-am-authorized) AUTHORIZED="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --active-scans-agreed) ACTIVE="${2:-}"; shift 2 ;;
    --takeover-probe) TAKEOVER=1; shift ;;
    --dns-only) MODE=dns; shift ;;
    --tls-only) MODE=tls; shift ;;
    --deep) DEEP="${2:-}"; shift 2 ;;
    --resolver) RESOLVER="${2:-}"; shift 2 ;;
    --docker-network) NETWORK="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) HOST="$1"; shift ;;
  esac
done

[ -n "$HOST" ] || { usage >&2; exit 1; }
case "$PORT" in ''|*[!0-9]*) die "--port must be an integer" ;; esac
HOST="$(url_host "$HOST")"

authz_gate "$HOST" "$AUTHORIZED" "tls-and-dns.sh"
if [ -n "$DEEP" ]; then
  authz_gate_active "$HOST" "$ACTIVE" "tls-and-dns.sh" "--deep (testssl.sh)"
fi
need_docker
ensure_toolbox "$SCRIPT_DIR"

NET_ARGS=()
[ -n "$NETWORK" ] && NET_ARGS=(--network "$NETWORK")

run() {
  docker run --rm ${NET_ARGS[@]+"${NET_ARGS[@]}"} \
    -v "$SCRIPT_DIR/lib:/audit-lib:ro" \
    "$AUDIT_INFRA_TOOLBOX" sh /audit-lib/tls-and-dns.inner.sh "$HOST" "$PORT" "$MODE" "$RESOLVER" "$TAKEOVER"
}

if [ -n "$OUT" ]; then
  run >"$OUT" || die "collection failed"
  printf 'audit-infra: report written to %s\n' "$OUT" >&2
else
  run
fi

if [ -n "$DEEP" ]; then
  mkdir -p "$DEEP" || die "cannot create $DEEP"
  DEEP_ABS="$(abs_path "$DEEP")"
  rm -f "$DEEP_ABS/testssl.json"
  printf 'audit-infra: running %s against %s:%s (several minutes)\n' "$TESTSSL_IMAGE" "$HOST" "$PORT" >&2
  docker run --rm ${NET_ARGS[@]+"${NET_ARGS[@]}"} --user "$(id -u):$(id -g)" -v "$DEEP_ABS:/out" "$TESTSSL_IMAGE" \
    --quiet --color 0 --warnings off --jsonfile-pretty /out/testssl.json "$HOST:$PORT" >"$DEEP_ABS/testssl.log" 2>&1
  printf 'audit-infra: testssl exit=%s, report %s/testssl.json, log %s/testssl.log\n' "$?" "$DEEP_ABS" "$DEEP_ABS" >&2
fi
