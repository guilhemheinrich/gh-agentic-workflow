#!/usr/bin/env bash
# leads.sh - run a checklist "lead" search without putting a credential in
# the transcript.
#
# Default output: file:line only. Open the lines you need with -c.
# -c (context): the line too, with every quoted literal emptied to "...",
#    comments dropped (// and /* after a space or at line start, # at line
#    start or after a space), user:password@ in URLs, the value after a
#    credential-like name and ":" or "=", and any bare run of 20+
#    letters/digits holding both, replaced by <redacted>. Literals are emptied
#    whatever their length: a short secret passed positionally
#    (createHmac("sha256", "hunter2")) is not recognisable, so nothing is kept.
# Skipped files: .env*, *.env, keys and certificates, source maps, minified
# files, lockfiles, node_modules, .git, dist, build, vendor, .venv, coverage.
# Search those with `grep -l` (file names only) or list-secret-names.sh.
#
# Usage: leads.sh [-i] [-c] PATTERN [DIR ...]   (PATTERN is a grep -E regex)
# Exit codes: 0 = matches, 1 = none, 2 = error. Runs itself in Docker (grep, awk).
set -euo pipefail

ci=(); ctx=0
while [ $# -gt 0 ]; do
  case "$1" in -i) ci=(-i); shift ;; -c) ctx=1; shift ;; *) break ;; esac
done
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: leads.sh [-i] [-c] PATTERN [DIR ...]" >&2
  exit 2
fi
pat="$1"; shift
[ $# -gt 0 ] || set -- .

# Run inside a container, not on the host: the checkout is mounted read-only
# at its own path, with no network, so a symlink pointing outside it (to
# ~/.aws/credentials, say) dangles instead of being read.
if [ "${AUDIT_IN_DOCKER:-}" != 1 ]; then
  command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 2; }
  for a in "$@"; do
    case "$a" in /*) a2="$a" ;; *) a2="$PWD/$a" ;; esac
    case "$a2/" in *"/../"*) echo "path with ..: $a" >&2; exit 2 ;; "$PWD"/*) ;; *) echo "run from the repository root; path outside it: $a" >&2; exit 2 ;; esac
  done
  exec docker run --rm --network none -e AUDIT_IN_DOCKER=1 -v "$PWD":"$PWD":ro -w "$PWD" \
    -v "$(cd "$(dirname "$0")" && pwd)":/skill-scripts:ro "${PYTHON_IMAGE:-python:3.12-slim}" \
    bash /skill-scripts/leads.sh ${ci[@]+"${ci[@]}"} $([ "$ctx" -eq 0 ] || echo -c) "$pat" "$@"
fi

grep -rnIE ${ci[@]+"${ci[@]}"} \
  --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist --exclude-dir=build \
  --exclude-dir=vendor --exclude-dir=.venv --exclude-dir=coverage \
  --exclude='.env*' --exclude='*.env' --exclude='*.pem' --exclude='*.key' --exclude='*.p12' \
  --exclude='*.pfx' --exclude='*.map' --exclude='*.min.js' --exclude='*.lock' \
  --exclude='package-lock.json' --exclude='pnpm-lock.yaml' \
  -e "$pat" "$@" | awk -v ctx="$ctx" '
function longtok(s,   out, t) {   # bare tokens: 20+ chars, letter and digit
  out = ""
  while (match(s, /[A-Za-z0-9+\/=_-]+/)) {
    t = substr(s, RSTART, RLENGTH)
    if (RLENGTH >= 20 && t ~ /[0-9]/ && t ~ /[A-Za-z]/) t = "<redacted>"
    out = out substr(s, 1, RSTART - 1) t
    s = substr(s, RSTART + RLENGTH)
  }
  return out s
}
function literals(s, q,   out, rest, j, lit) {   # quoted: content emptied
  out = ""
  while ((j = index(s, q)) > 0) {
    rest = substr(s, j + 1)
    if (index(rest, q) == 0) break
    lit = substr(rest, 1, index(rest, q) - 1)
    if (length(lit) > 0) lit = "..."
    out = out substr(s, 1, j) lit q
    s = substr(rest, index(rest, q) + 1)
  }
  return out s
}
function nocomment(b) {
  if (match(b, /(^|[ \t])(\/\/|\/\*|#)/)) b = substr(b, 1, RSTART - 1)
  return b
}
function redact(b,   lc, m, k, out) {
  b = literals(b, "\""); b = literals(b, "\047"); b = literals(b, "`")
  b = nocomment(b)
  out = ""
  while (match(b, /:\/\/[^\/@ \t"\047]+@/)) { out = out substr(b, 1, RSTART - 1) "://<redacted>@"; b = substr(b, RSTART + RLENGTH) }
  b = out b
  lc = tolower(b)
  if (match(lc, /(secret|passw|pwd|token|api_?key|apikey|private_?key|credential|authorization|bearer|dsn|connection_?string)[a-z0-9_"\047]*[ \t]*[:=]/)) {
    m = substr(lc, RSTART, RLENGTH); k = RSTART
    match(m, /[:=]/)
    b = substr(b, 1, k + RSTART - 1) " <redacted>"
  }
  return longtok(b)
}
{
  p = index($0, ":"); rest = substr($0, p + 1); q = index(rest, ":")
  if (ctx != 1) { print substr($0, 1, p + q - 1); next }
  print substr($0, 1, p + q) " " redact(substr(rest, q + 1))
}'
