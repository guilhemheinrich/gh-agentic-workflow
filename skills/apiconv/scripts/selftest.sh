#!/bin/sh
# Self-test on the synthetic fixture, through the Docker launcher (no host Node needed):
#   1. convert + verify pass;
#   2. a second conversion is byte-identical to the first (diff -r);
#   3. a hand-edited Postman URL and a hand-edited .bru header each make verify fail.
# Usage: selftest.sh [<work-dir>]   (default: a fresh mktemp directory)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
W=${1:-$(mktemp -d)}; mkdir -p "$W"
A=$W/run-a; B=$W/run-b; M=$W/mutated
rm -rf "$A" "$B" "$M"
for d in "$A" "$B"; do mkdir -p "$d" && cp -R "$HERE/fixtures/demo/insomnia" "$d/"; done
ID=00-identity-demo.insomnia.json; ENVN=demo

echo "== 1. convert + verify"
"$HERE/apiconv.sh" convert "$A" "$ID" "$ENVN"
"$HERE/apiconv.sh" verify "$A" "$ID" "$ENVN"

echo "== 2. determinism"
"$HERE/apiconv.sh" convert "$B" "$ID" "$ENVN"
diff -r "$A/postman" "$B/postman" && diff -r "$A/bruno" "$B/bruno" && echo "diff -r: no difference"

echo "== 3. mutations must fail verify"
fails=0
mutate() { # <label> <file-relative-to-bundle> <sed-expression>
  rm -rf "$M"; cp -R "$A" "$M"
  sed -i.bak "$3" "$M/$2" && rm "$M/$2.bak"
  if cmp -s "$A/$2" "$M/$2"; then echo "mutation $1 did not change $2"; exit 1; fi
  set +e; out=$("$HERE/apiconv.sh" verify "$M" "$ID" "$ENVN" 2>&1); rc=$?; set -e
  printf '%s\n' "$out" | grep '^FAIL' || true
  if [ "$rc" -eq 0 ]; then echo "mutation $1: verify exit 0 — NOT detected"; fails=$((fails + 1)); else echo "mutation $1: verify exit $rc — detected"; fi
}
mutate postman-url-path postman/01-demo-items.postman_collection.json 's|"raw": "{{items_url}}"|"raw": "{{items_url}}/v2"|'
mutate postman-url-query postman/01-demo-items.postman_collection.json 's|"raw": "{{items_url}}?limit=10&q=widget"|"raw": "{{items_url}}?limit=11\&q=widget"|'
mutate bruno-header bruno/01-demo-items/03-3-read-item-with-trace.bru 's|X-Request-Id:|X-Trace-Id:|'
[ "$fails" -eq 0 ] && echo "selftest passed ($W)"
