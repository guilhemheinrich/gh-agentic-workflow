#!/usr/bin/env bash
# cli.test.sh — dispatcher, version, state dir and dependency check.
. "$(dirname "$0")/lib.sh"

out="$("$PRW" --version 2>&1)"
check "--version prints prw 0.1.0" '[ "$out" = "prw 0.1.0" ]' "$out"

out="$("$PRW" nope 2>&1)"; rc=$?
check "unknown command exits 64" '[ "$rc" = 64 ]' "rc=$rc"
check "unknown command names it" '[ "$out" = "prw: unknown command '"'"'nope'"'"'" ]' "$out"

dir="$(bash -c ". '$SKILL_DIR/scripts/lib/config.sh'; prw_state_dir")"
check "state dir is the spaced PRW_STATE_DIR" '[ "$dir" = "$PRW_STATE_DIR" ]' "$dir"
check "state dir is created" '[ -d "$PRW_STATE_DIR" ]'

mkdir -p "$WORK/nojq"
for tool in bash sed cat curl git date mkdir; do
  p="$(command -v "$tool")" && ln -sf "$p" "$WORK/nojq/$tool"
done
out="$(PATH="$WORK/nojq" bash -c ". '$SKILL_DIR/scripts/lib/config.sh'; prw_require_deps")"; rc=$?
check "missing jq is reported" '[ "$out" = "missing: jq" ] && [ "$rc" = 1 ]' "rc=$rc out=$out"

out="$(bash -c ". '$SKILL_DIR/scripts/lib/config.sh'; prw_require_deps")"; rc=$?
check "deps present returns 0 silently" '[ -z "$out" ] && [ "$rc" = 0 ]' "rc=$rc out=$out"

summary
