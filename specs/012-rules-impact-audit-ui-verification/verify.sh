#!/usr/bin/env bash
# verify.sh — acceptance script for spec 012 (rules impact-audit + UI verification)
#
# Doc-only spec: every check is a static read against the produced .mdc / .yml files.
# Each check maps to an FR or SC from spec.md. Exit non-zero on first failure.
#
# Run from repo root: bash specs/012-rules-impact-audit-ui-verification/verify.sh
set -euo pipefail

repo_root() {
  git rev-parse --show-toplevel
}
cd "$(repo_root)"

fail() {
  printf >&2 "FAIL: %s\n" "$*"
  exit 1
}

ok() {
  printf "PASS: %s\n" "$*"
}

# --- US1 / FR-001..FR-005 — P7 added to 5-spec-driven-dev.mdc ---
SDD=rules/05-workflows-and-processes/5-spec-driven-dev.mdc

[[ -f "$SDD" ]] || fail "target file missing: $SDD"
ok "[$SDD] exists"

count=$(rg -c '^- \*\*P[1-7] \(' "$SDD" || true)
[[ "$count" == "7" ]] || fail "FR-001/SC-001: expected 7 P-property bullets in $SDD, got $count"
ok "FR-001 — P1..P7 properties present (count=7)"

rg -q '\(P7\)' "$SDD" || fail "FR-002: P7 detail-section heading missing"
ok "FR-002 — P7 detail section heading present"

rg -q '\[impact-audit\]' "$SDD" || fail "FR-004: [impact-audit] task tag missing from tasks.md template"
ok "FR-004 — [impact-audit] tag present"

# --- US2 / FR-006..FR-012 — 7-ui-verification.mdc ---
UI=rules/07-quality-assurance/7-ui-verification.mdc

[[ -f "$UI" ]] || fail "target file missing: $UI"
ok "[$UI] exists"

# FR-006 + SC-002 — four frontmatter keys within first 15 lines
keys=$(head -n 15 "$UI" | rg -c '^(description|globs|alwaysApply|tags):' || true)
[[ "$keys" == "4" ]] || fail "FR-006/SC-002: expected 4 frontmatter keys in first 15 lines, got $keys"
ok "FR-006/SC-002 — 4 frontmatter keys in first 15 lines"

# FR-007 — narrow globs, no catch-all
if rg -q "globs:.*\\*\\*/\\*'" "$UI"; then
  fail "FR-007: catch-all glob detected in $UI"
fi
if rg -q "globs:.*\\*\\*/\\*\\.ts'" "$UI"; then
  fail "FR-007: '**/*.ts' catch-all (would match backends) detected"
fi
ok "FR-007 — globs are narrow (no **/* or **/*.ts catch-all)"

# FR-008 — exactly two properties
pcount=$(rg -c '^- \*\*P[12] \(' "$UI" || true)
[[ "$pcount" == "2" ]] || fail "FR-008: expected exactly 2 P-property bullets, got $pcount"
ok "FR-008 — exactly two property bullets"

# FR-011 + SC-003 — zero ordered imperative recipe blocks
recipes=$(rg -c '^[0-9]+\. ' "$UI" || true)
[[ "$recipes" == "0" || -z "$recipes" ]] || fail "FR-011/SC-003: $recipes ordered list lines suggest procedural recipe in $UI"
ok "FR-011/SC-003 — no procedural ordered lists"

# FR-012 — relative cross-refs present and resolve
rg -q '5-spec-driven-dev.mdc' "$UI" || fail "FR-012: cross-ref to 5-spec-driven-dev.mdc missing"
rg -q '7-testing.mdc' "$UI" || fail "FR-012: cross-ref to 7-testing.mdc missing"
[[ -f rules/05-workflows-and-processes/5-spec-driven-dev.mdc ]] || fail "FR-012: cross-ref target 5-spec-driven-dev.mdc does not exist"
[[ -f rules/07-quality-assurance/7-testing.mdc ]] || fail "FR-012: cross-ref target 7-testing.mdc does not exist"
ok "FR-012 — cross-refs present and resolve"

# --- Cross-cutting / SC-004 — asset registry indexes both files ---
rg -q '5-spec-driven-dev.mdc' asset-registry.yml || fail "SC-004: 5-spec-driven-dev.mdc missing from asset-registry.yml"
rg -q '7-ui-verification.mdc' asset-registry.yml || fail "SC-004: 7-ui-verification.mdc missing from asset-registry.yml"
ok "SC-004 — both deliverables indexed in asset-registry.yml"

# --- No personal traces in produced files ---
for f in "$SDD" "$UI"; do
  if rg -q '/Users/[A-Za-z0-9._-]+/' "$f"; then
    fail "personal-trace leak in $f"
  fi
done
ok "no personal traces in produced .mdc files"

printf "\nALL CHECKS PASSED\n"
