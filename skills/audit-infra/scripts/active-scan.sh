#!/usr/bin/env bash
# active-scan.sh: the only supported way to run nmap or nuclei in this skill.
# Both are ACTIVE scans (hundreds to thousands of probes), so both gates apply:
#   --i-am-authorized <host>       the operator owns the host or may test it
#   --active-scans-agreed <host>   the owner agreed to active scans of it, in a time window
# Never run the nmap or nuclei image by hand against a remote host: that skips the gates.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/authz.sh
. "$SCRIPT_DIR/lib/authz.sh"

NMAP_IMAGE="${AUDIT_INFRA_NMAP_IMAGE:-instrumentisto/nmap:7.98-r2}"
NUCLEI_IMAGE="${AUDIT_INFRA_NUCLEI_IMAGE:-projectdiscovery/nuclei:v3.11.1}"
NUCLEI_VOLUME="${AUDIT_INFRA_NUCLEI_TEMPLATES:-audit-infra-nuclei-templates}"
# Detection templates only. Tags are OR-ed by nuclei, so every class that sends an
# attack payload, a login attempt or an out-of-band callback is excluded by name.
NUCLEI_TAGS="exposure,misconfig,tech"
NUCLEI_EXCLUDE="dos,fuzz,intrusive,bruteforce,default-login,cve,rce,sqli,xss,ssrf,lfi,takeover,oast,injection,file-upload,auth-bypass,bypass,headless,code"
# Whole directories of exploit-shaped templates are excluded too: on template set v10.5.2
# the tag filter alone still let in 53 templates of http/vulnerabilities (auth bypass,
# file download, user creation). Tags and paths are community metadata, not a guarantee.
NUCLEI_EXCLUDE_PATHS="http/vulnerabilities/,http/cves/,http/cnvd/,http/iot/,http/default-logins/,http/fuzzing/"

usage() {
  cat <<'USAGE'
Usage: active-scan.sh --i-am-authorized <host> --active-scans-agreed <host> [options] nmap <host>
       active-scan.sh --i-am-authorized <host> --active-scans-agreed <host> [options] nuclei <url>

Required (both, same exact host as the target; refusal is exit 77):
  --i-am-authorized HOST       You own the host or may test it.
  --active-scans-agreed HOST   The owner agreed to active scans of it, in a stated window.
Options:
  --out DIR                Output directory (default ./out): nmap.xml or nuclei.txt
  --ports LIST             nmap: scan this list (e.g. 22,443,5432) instead of the top 1000
  --ipv6                   nmap: scan the host's IPv6 address (-6)
  --docker-network NAME    Join this Docker network (to reach a local lab)
  -h, --help               Show this help

Volume: nmap = 1000 TCP ports at 50 probes/s at most (connect scan, first address only),
        then service detection (-sV) on each open port, which --max-rate does not cap.
        nuclei = several thousand HTTP requests at 20 requests/s at most.
Do not target an address that belongs to a CDN, a PaaS or a cloud load balancer.
USAGE
}

AUTHORIZED=""; ACTIVE=""; OUT="out"; PORTS=""; IPV6=0; NETWORK=""; TOOL=""; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --i-am-authorized) AUTHORIZED="${2:-}"; shift 2 ;;
    --active-scans-agreed) ACTIVE="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --ports) PORTS="${2:-}"; shift 2 ;;
    --ipv6) IPV6=1; shift ;;
    --docker-network) NETWORK="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) if [ -z "$TOOL" ]; then TOOL="$1"; else TARGET="$1"; fi; shift ;;
  esac
done

[ -n "$TOOL" ] && [ -n "$TARGET" ] || { usage >&2; exit 1; }
case "$TOOL" in nmap|nuclei) : ;; *) die "unknown scan '$TOOL' (nmap or nuclei)" ;; esac
case "$PORTS" in *[!0-9,-]*) die "--ports takes digits, commas and dashes only" ;; esac
HOST="$(url_host "$TARGET")"

authz_gate "$HOST" "$AUTHORIZED" "active-scan.sh"
authz_gate_active "$HOST" "$ACTIVE" "active-scan.sh" "$TOOL"
need_docker

mkdir -p "$OUT" || die "cannot create $OUT"
OUT_ABS="$(abs_path "$OUT")"
NET_ARGS=()
[ -n "$NETWORK" ] && NET_ARGS=(--network "$NETWORK")

if [ "$TOOL" = "nmap" ]; then
  PORT_ARGS=(--top-ports 1000)
  [ -n "$PORTS" ] && PORT_ARGS=(-p "$PORTS")
  V6_ARGS=()
  [ "$IPV6" = "1" ] && V6_ARGS=(-6)
  docker run --rm ${NET_ARGS[@]+"${NET_ARGS[@]}"} "$NMAP_IMAGE" \
    -Pn -sT -sV -T3 --max-rate 50 "${PORT_ARGS[@]}" ${V6_ARGS[@]+"${V6_ARGS[@]}"} -oX - "$HOST" >"$OUT_ABS/nmap.xml"
  rc=$?
  printf 'audit-infra: nmap exit=%s, report %s/nmap.xml\n' "$rc" "$OUT_ABS" >&2
  exit "$rc"
fi

case "$TARGET" in http://*|https://*) : ;; *) die "nuclei needs an http:// or https:// URL" ;; esac
docker run --rm ${NET_ARGS[@]+"${NET_ARGS[@]}"} -v "$NUCLEI_VOLUME:/root/nuclei-templates" "$NUCLEI_IMAGE" \
  -u "$TARGET" -pt http -tags "$NUCLEI_TAGS" -exclude-tags "$NUCLEI_EXCLUDE" \
  -exclude-templates "$NUCLEI_EXCLUDE_PATHS" -severity info,low,medium,high \
  -rate-limit 20 -concurrency 5 -no-interactsh -no-color -silent -stats-json -stats-interval 60 \
  >"$OUT_ABS/nuclei.txt" 2>"$OUT_ABS/nuclei.log"
rc=$?
printf 'audit-infra: nuclei exit=%s, matches %s/nuclei.txt, log and request counters %s/nuclei.log\n' "$rc" "$OUT_ABS" "$OUT_ABS" >&2
exit "$rc"
