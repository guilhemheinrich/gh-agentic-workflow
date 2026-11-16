#!/bin/sh
# Host launcher: builds the apiconv image when its sources change, then runs one command in it.
#
#   apiconv.sh convert <bundle-dir> <identity-file-name> <identity-env-name>
#   apiconv.sh verify  <bundle-dir> <identity-file-name> <identity-env-name>
#   apiconv.sh bundle  <bundle-dir> <identity-file-name> <identity-env-name> [<plan-file>]
#       convert + static verify + (with a plan) runtime check; reports land in <bundle-dir>/.apiconv/
#
# <bundle-dir> holds an `insomnia/` folder of Insomnia v4 exports, one of them the identity file.
# Postman and Bruno output is written to <bundle-dir>/postman and <bundle-dir>/bruno.
# APICONV_LABEL, when set, prefixes the Postman environment names.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
usage() { sed -n '4,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 4 ] || usage
CMD=$1; DIR=$(cd "$2" && pwd); ID=$3; ENVN=$4; PLAN=${5:-}

# Tag the image by the hash of its inputs, so an edit rebuilds it and nothing else does.
TAG=apiconv:$(cat "$HERE/Dockerfile" "$HERE/package-lock.json" "$HERE/apiconv.mjs" \
  "$HERE/bundle.sh" "$HERE/runtime-check.sh" "$HERE"/schemas/* | shasum | cut -c1-12)
docker image inspect "$TAG" >/dev/null 2>&1 || docker build -q -t "$TAG" "$HERE" >/dev/null
run() { docker run --rm -e APICONV_LABEL -v "$DIR:/work" "$@"; }

case $CMD in
  bundle)
    [ $# -le 5 ] || usage
    mkdir -p "$DIR/.apiconv"
    if [ -n "$PLAN" ]; then
      PLAN=$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")
      run -v "$PLAN:/plan.txt:ro" "$TAG" ./bundle.sh /work "$ID" "$ENVN" /work/.apiconv/report /plan.txt
    else
      run "$TAG" ./bundle.sh /work "$ID" "$ENVN" /work/.apiconv/report
    fi
    tail -1 "$DIR/.apiconv/report.verify.txt"
    grep -q '^verify-exit=0$' "$DIR/.apiconv/report.verify.txt" || exit 1
    [ -n "$PLAN" ] || { cat "$DIR/.apiconv/report.runtime.txt"; exit 0; }
    grep -c '^SAME' "$DIR/.apiconv/report.runtime.txt" | sed 's/^/runtime SAME: /'
    ! grep -q '^DIFF' "$DIR/.apiconv/report.runtime.txt" ;;
  convert|verify)
    [ $# -eq 4 ] || usage
    run "$TAG" node apiconv.mjs "$CMD" /work/insomnia "/work/insomnia/$ID" "$ENVN" /work ;;
  *) echo "unknown command: $CMD" >&2; exit 2 ;;
esac
