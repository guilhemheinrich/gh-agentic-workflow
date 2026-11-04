#!/bin/sh
# Inside the apiconv image: convert, verify (static) and, given a plan, runtime-check one bundle.
# Usage: bundle.sh <bundle-dir> <identity-file-name> <identity-env-name> <report-prefix> [<plan-file>]
set -u
D=$1; ID=$2; ENVN=$3; R=$4; PLAN=${5:-}
node apiconv.mjs convert "$D/insomnia" "$D/insomnia/$ID" "$ENVN" "$D" > /dev/null || exit 1
node apiconv.mjs verify "$D/insomnia" "$D/insomnia/$ID" "$ENVN" "$D" > "$R.verify.txt" 2>&1
echo "verify-exit=$?" >> "$R.verify.txt"
if [ -n "$PLAN" ]; then
  ./runtime-check.sh "$D" "$R.rt" "$PLAN" "$ENVN" > "$R.runtime.txt" 2>&1 || true
else
  echo "runtime check skipped: no plan file" > "$R.runtime.txt"
fi
