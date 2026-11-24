#!/bin/sh
# Runs INSIDE the toolbox container (alpine: dig, openssl, curl, jq). Called by
# ../tls-and-dns.sh after the authorization gate. Prints one JSON document on stdout.
#   tls-and-dns.inner.sh <host> <port> <mode: all|dns|tls> [resolver-ip] [takeover-probe 0|1]
set -eu

HOST="$1"; PORT="$2"; MODE="$3"; RESOLVER="${4:-}"; TAKEOVER_PROBE="${5:-0}"
AT=""; [ -n "$RESOLVER" ] && AT="@$RESOLVER"
W="$(mktemp -d)"

# CNAME targets on these suffixes belong to providers where a deleted resource name can
# sometimes be registered again by someone else. A dangling record pointing there is a
# takeover LEAD, never a proof: whether the name is claimable depends on the provider's
# current rules (reserved names, domain verification) and is settled with the owner.
TAKEOVER_SUFFIXES="s3.amazonaws.com s3-website cloudfront.net elasticbeanstalk.com github.io herokuapp.com herokudns.com azurewebsites.net cloudapp.net cloudapp.azure.com trafficmanager.net blob.core.windows.net azureedge.net azurefd.net fastly.net netlify.app pantheonsite.io surge.sh bitbucket.io ghost.io readme.io zendesk.com myshopify.com unbouncepages.com wpengine.com helpscoutdocs.com webflow.io fly.dev pages.dev"

lines() { jq -Rn '[inputs | select(length > 0)]'; }
# shellcheck disable=SC2086
# q <name> <TYPE>: rdata of the records of exactly that type. `dig +short` is not used:
# for an aliased name it prints the CNAME targets whatever the type asked.
q() {
  dig $AT +noall +answer +time=3 +tries=2 "$1" "$2" 2>/dev/null |
    awk -v t="$2" '$4 == t { for (i = 5; i <= NF; i++) printf "%s%s", $i, (i < NF ? " " : "\n") }' || true
}
# shellcheck disable=SC2086
rcode() { dig $AT +noall +comments +time=3 +tries=2 "$1" A 2>/dev/null | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -1; }

dns_json() {
  for t in A AAAA CNAME NS MX TXT CAA SOA; do
    q "$HOST" "$t" | lines >"$W/dns.$t"
  done

  # Follow the CNAME chain by hand so each hop is visible (max 10 hops).
  : >"$W/chain"
  cur="$HOST"; hops=0
  while [ "$hops" -lt 10 ]; do
    nxt="$(q "$cur" CNAME | head -1)"
    [ -n "$nxt" ] || break
    printf '%s\n' "$nxt" >>"$W/chain"
    cur="${nxt%.}"; hops=$((hops + 1))
  done
  final="$cur"
  final_rcode="$(rcode "$final")"
  final_has_addr=false
  if [ -n "$(q "$final" A)$(q "$final" AAAA)" ]; then final_has_addr=true; fi
  takeover_suffix=""
  if [ -s "$W/chain" ]; then
    for s in $TAKEOVER_SUFFIXES; do
      case "$final" in *"$s"*) takeover_suffix="$s"; break ;; esac
    done
  fi

  # Reverse DNS of each address: the PTR usually names the hosting provider.
  : >"$W/ptr.ndjson"
  for ip in $(q "$HOST" A | grep -E '^[0-9.]+$' || true); do
    jq -cn --arg ip "$ip" --arg ptr "$(dig $AT +noall +answer +time=3 +tries=1 -x "$ip" 2>/dev/null | awk '$4 == "PTR" {print $5; exit}')" \
      '{ip: $ip, ptr: (if $ptr == "" then null else $ptr end)}' >>"$W/ptr.ndjson"
  done

  # CAA is inherited: climb the tree until a record set is found.
  caa_at=""; d="$HOST"
  while [ -n "$d" ] && [ "$d" != "${d#*.}" ]; do
    if [ -n "$(q "$d" CAA)" ]; then caa_at="$d"; q "$d" CAA | lines >"$W/dns.CAA"; break; fi
    d="${d#*.}"
  done

  # Wildcard providers (S3, CloudFront, GitHub Pages...) always resolve, so a dead
  # resource shows only in the HTTP answer. That is one request to the authorized host:
  # sent only with --takeover-probe, never in a DNS-only (passive) run by default.
  takeover_fp=""; takeover_checked=false
  if [ "$TAKEOVER_PROBE" = "1" ] && [ -n "$takeover_suffix" ] && [ "$final_has_addr" = "true" ]; then
    takeover_checked=true
    takeover_fp="$(curl -s --max-time 10 "http://$HOST/" 2>/dev/null | head -c 4096 | grep -Eo -m1 \
      "NoSuchBucket|The specified bucket does not exist|There isn't a GitHub Pages site here|No such app|Fastly error: unknown domain|404 Web Site not found|project not found|Repository not found|The request could not be satisfied|Domain is not configured" || true)"
  fi

  q "_dmarc.$HOST" TXT | lines >"$W/dmarc"

  jq -n \
    --slurpfile a "$W/dns.A" --slurpfile aaaa "$W/dns.AAAA" --slurpfile cname "$W/dns.CNAME" \
    --slurpfile ns "$W/dns.NS" --slurpfile mx "$W/dns.MX" --slurpfile txt "$W/dns.TXT" \
    --slurpfile caa "$W/dns.CAA" --slurpfile soa "$W/dns.SOA" --slurpfile dmarc "$W/dmarc" \
    --slurpfile ptr "$W/ptr.ndjson" --rawfile chain "$W/chain" \
    --arg final "$final" --arg final_rcode "$final_rcode" --argjson final_has_addr "$final_has_addr" \
    --arg takeover_suffix "$takeover_suffix" --arg takeover_fp "$takeover_fp" --argjson takeover_checked "$takeover_checked" --arg caa_at "$caa_at" --arg host_rcode "$(rcode "$HOST")" '
    ($chain | split("\n") | map(select(length > 0))) as $hops
    | { rcode: $host_rcode,
        a: ($a[0] | map(select(test("^[0-9.]+$")))), aaaa: ($aaaa[0] | map(select(test(":")))),
        ns: $ns[0], mx: $mx[0], soa: $soa[0], txt: $txt[0],
        cname_chain: $hops,
        cname_final: (if ($hops | length) > 0 then $final else null end),
        dangling: (($hops | length) > 0 and ($final_has_addr | not)),
        dangling_detail: (if ($hops | length) > 0 and ($final_has_addr | not)
          then "CNAME chain ends at \($final), which resolves to nothing (status \($final_rcode))" else null end),
        takeover_candidate: (($hops | length) > 0 and $takeover_suffix != "" and (($final_has_addr | not) or $takeover_fp != "")),
        takeover_http_checked: $takeover_checked,
        takeover_http_fingerprint: (if $takeover_fp == "" then null else $takeover_fp end),
        third_party_suffix: (if $takeover_suffix == "" then null else $takeover_suffix end),
        round_robin: ((($a[0] | map(select(test("^[0-9.]+$"))) | length) > 1)),
        ptr: $ptr,
        caa: {records: $caa[0], found_at: (if $caa_at == "" then null else $caa_at end)},
        email: { spf: ($txt[0] | map(select(test("v=spf1"))) | .[0] // null),
                 dmarc: ($dmarc[0] | map(select(test("v=DMARC1"))) | .[0] // null) } }'
}

# try_proto <openssl flag> : "accepted" | "rejected" | "untestable"
try_proto() {
  out="$(echo | timeout 12 openssl s_client -connect "$HOST:$PORT" -servername "$HOST" "-$1" \
    -cipher 'ALL:@SECLEVEL=0' 2>&1 || true)"
  if printf '%s' "$out" | grep -Eq 'unknown option|Option unknown|no protocols available'; then echo untestable
  elif printf '%s' "$out" | grep -Eq '^New, TLSv|Cipher is [A-Z0-9_-]+' && ! printf '%s' "$out" | grep -q 'Cipher is (NONE)'; then echo accepted
  else echo rejected; fi
}

tls_json() {
  if ! echo | timeout 12 openssl s_client -connect "$HOST:$PORT" -servername "$HOST" \
      -showcerts -status -alpn h2,http/1.1 >"$W/s_client" 2>"$W/s_client.err"; then
    if ! grep -q 'BEGIN CERTIFICATE' "$W/s_client"; then
      jq -n --arg e "$(head -c 400 "$W/s_client.err")" --arg hp "$HOST:$PORT" '{endpoint: $hp, error: $e}'
      return
    fi
  fi
  # First certificate of the chain = the leaf.
  awk '/BEGIN CERTIFICATE/{n++} n==1{print} /END CERTIFICATE/&&n==1{exit}' "$W/s_client" >"$W/leaf.pem"
  x() { openssl x509 -in "$W/leaf.pem" -noout "$@" 2>/dev/null || true; }
  expired=false; within14=false; within30=false
  openssl x509 -in "$W/leaf.pem" -noout -checkend 0 >/dev/null 2>&1 || expired=true
  openssl x509 -in "$W/leaf.pem" -noout -checkend 1209600 >/dev/null 2>&1 || within14=true
  openssl x509 -in "$W/leaf.pem" -noout -checkend 2592000 >/dev/null 2>&1 || within30=true

  # Last certificate sent: self-issued means the server also sends its root (useless bytes).
  nchain="$(grep -c 'BEGIN CERTIFICATE' "$W/s_client" || true)"
  awk -v n="$nchain" '/BEGIN CERTIFICATE/{c++} c==n{print}' "$W/s_client" >"$W/last.pem"
  root_sent=false
  last_subject="$(openssl x509 -in "$W/last.pem" -noout -subject 2>/dev/null | sed 's/^subject= *//')"
  last_issuer="$(openssl x509 -in "$W/last.pem" -noout -issuer 2>/dev/null | sed 's/^issuer= *//')"
  if [ "$nchain" -gt 1 ] && [ -n "$last_subject" ] && [ "$last_subject" = "$last_issuer" ]; then root_sent=true; fi

  p10="$(try_proto tls1)"; p11="$(try_proto tls1_1)"; p12="$(try_proto tls1_2)"; p13="$(try_proto tls1_3)"
  hsts="$(curl -skI --max-time 10 "https://$HOST:$PORT/" 2>/dev/null | tr -d '\r' | sed -n 's/^[Ss]trict-[Tt]ransport-[Ss]ecurity: *//p' | head -1)"

  jq -n \
    --arg hp "$HOST:$PORT" \
    --arg subject "$(x -subject | sed 's/^subject= *//')" \
    --arg issuer "$(x -issuer | sed 's/^issuer= *//')" \
    --arg not_before "$(x -startdate | sed 's/^notBefore=//')" \
    --arg not_after "$(x -enddate | sed 's/^notAfter=//')" \
    --arg san "$(x -ext subjectAltName | sed '1d' | tr -d '\n' | sed 's/^ *//')" \
    --arg key "$(x -text | sed -n 's/^ *Public-Key: *(\(.*\))/\1/p' | head -1)" \
    --arg sigalg "$(x -text | sed -n 's/^ *Signature Algorithm: *//p' | head -1)" \
    --arg fp "$(x -fingerprint -sha256 | sed 's/^.*=//')" \
    --arg verify "$(sed -n 's/^ *Verify return code: *//p' "$W/s_client" | head -1)" \
    --arg negotiated "$(sed -n 's/^New, \(TLSv[0-9.]*\), Cipher is \(.*\)$/\1 \2/p' "$W/s_client" | head -1)" \
    --arg alpn "$(sed -n 's/^ALPN protocol: *//p' "$W/s_client" | head -1)" \
    --arg ocsp "$(grep -m1 -E 'OCSP response: no response sent|OCSP Response Status:' "$W/s_client" | sed 's/^ *//' || true)" \
    --arg hsts "$hsts" \
    --argjson chain "$(grep -c 'BEGIN CERTIFICATE' "$W/s_client" || true)" \
    --argjson root_sent "$root_sent" --argjson expired "$expired" --argjson within14 "$within14" --argjson within30 "$within30" \
    --arg p10 "$p10" --arg p11 "$p11" --arg p12 "$p12" --arg p13 "$p13" '
    { endpoint: $hp,
      protocols: {"TLSv1.0": $p10, "TLSv1.1": $p11, "TLSv1.2": $p12, "TLSv1.3": $p13},
      legacy_protocol_accepted: ($p10 == "accepted" or $p11 == "accepted"),
      tls13_supported: ($p13 == "accepted"),
      negotiated: $negotiated,
      alpn: (if $alpn == "" then null else $alpn end),
      certificate: {
        subject: $subject, issuer: $issuer, self_signed: ($subject == $issuer),
        san: $san, not_before: $not_before, not_after: $not_after,
        expired: $expired, expires_within_14_days: $within14, expires_within_30_days: $within30,
        key: $key, signature_algorithm: $sigalg, sha256_fingerprint: $fp,
        chain_certificates_sent: $chain, root_sent: $root_sent,
        verify: $verify, trusted: ($verify | startswith("0 ")) },
      ocsp_stapling: (if $ocsp == "" then "unknown" elif ($ocsp | test("no response sent")) then "absent" else $ocsp end),
      hsts: (if $hsts == "" then null else $hsts end) }'
}

echo null >"$W/dns.json"; echo null >"$W/tls.json"
if [ "$MODE" = "all" ] || [ "$MODE" = "dns" ]; then dns_json >"$W/dns.json"; fi
if [ "$MODE" = "all" ] || [ "$MODE" = "tls" ]; then tls_json >"$W/tls.json"; fi

jq -n --arg host "$HOST" --arg probed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg tools "$(dig -v 2>&1 | head -1); $(openssl version)" \
  --slurpfile dns "$W/dns.json" --slurpfile tls "$W/tls.json" \
  '{host: $host, probed_at: $probed_at, tools: $tools, dns: $dns[0], tls: $tls[0]}'
