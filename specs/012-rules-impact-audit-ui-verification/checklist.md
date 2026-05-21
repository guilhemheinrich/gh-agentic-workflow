# Acceptance Checklist: Rules — Impact Audit (P7) + UI Verification

**Purpose**: Map every FR-001..FR-012 and SC-001..SC-005 from `spec.md` to its concrete verification evidence (file:line where the invariant landed, plus the `verify.sh` check that asserts it).
**Created**: 2026-05-21
**Feature**: [spec.md](./spec.md) · [plan.md](./plan.md) · [tasks.md](./tasks.md) · [verify.sh](./verify.sh)

> Sections pruned: Multi-tenant, File uploads, Migration — doc-only spec, no runtime, no tenant scoping, no schema change. Re-add manually if relevant.

## Pipeline state (auto-recorded)

- SPECIFY: SUCCESS — 12 FRs, 2 P1 stories
- CLARIFY: SKIPPED — 1 P2 marker only, deferred to Open Questions
- PLAN: α[Curie] core + β[Turing] research, both SUCCESS
- TASKS: SUCCESS — 15 tasks, 4 batches
- ANALYZE pre-tasks: Approved — 0 Critical/High, 1 Low, 1 Info
- ANALYZE tasks-delta: Approved — 12/12 FR coverage
- IMPLEMENT: complete — T004-T007 (Darwin), T008-T013 (Einstein), T014 (Galileo), T015 (inline)
- VERIFY: `verify.sh` PASS — all 12 acceptance checks satisfied
- REVIEW: Bohr Approved — 2 Low non-blocking, 0 Critical/High/Medium

## Spec — Functional Requirements

- [x] CHK001 FR-001 — P7 property entry numbered exactly P7, placed immediately after P6 in `5-spec-driven-dev.mdc`. Evidence: `rules/05-workflows-and-processes/5-spec-driven-dev.mdc:25-26` (P6 line 25, P7 line 26). (auto: verify.sh:30-32 — counts `^- \*\*P[1-7] \(` bullets == 7)
- [x] CHK002 FR-002 — P7 detail section follows the same four-part shape as P6 (Trigger, Required `tasks.md` template, Reviewer red flag, Failure mode prevented). Evidence: `rules/05-workflows-and-processes/5-spec-driven-dev.mdc:56-79` (heading line 56, Trigger 60-64, template 66-75, Reviewer red flag 77, Failure mode 79). (auto: verify.sh:34-35 — asserts `(P7)` heading present)
- [x] CHK003 FR-003 — P7 trigger covers signature changes (params added/removed/reordered/retyped, return type changed) AND observable behaviour changes. Evidence: `rules/05-workflows-and-processes/5-spec-driven-dev.mdc:60-64`. (manual: read of Trigger block; ANALYZE tasks-delta confirmed coverage)
- [x] CHK004 FR-004 — P7 `tasks.md` template mandates LSP "Find References" / `rg` / equivalent cross-codebase enumeration, plus per-call-site update-or-document discipline. Evidence: `rules/05-workflows-and-processes/5-spec-driven-dev.mdc:68-75`. (auto: verify.sh:37-38 — asserts `[impact-audit]` tag present)
- [x] CHK005 FR-005 — Anti-patterns block gains a bullet warning against signature/behaviour changes without a P7 audit task. Evidence: `rules/05-workflows-and-processes/5-spec-driven-dev.mdc:87`. (manual: read of Anti-patterns block; REVIEW Bohr Approved confirms bullet presence)
- [x] CHK006 FR-006 — `rules/07-quality-assurance/7-ui-verification.mdc` exists with valid YAML frontmatter containing `description`, `globs`, `alwaysApply: false`, `tags`. Evidence: `rules/07-quality-assurance/7-ui-verification.mdc:1-15` (description 2-7, globs 8, alwaysApply 9, tags 10-14). (auto: verify.sh:46-49 — counts 4 frontmatter keys in first 15 lines)
- [x] CHK007 FR-007 — `globs` narrows to frontend file types only, no catch-all (`**/*` or `**/*.ts`). Evidence: `rules/07-quality-assurance/7-ui-verification.mdc:8` — `'**/*.tsx,**/*.jsx,**/*.vue,**/*.svelte,**/*.html,**/*.css,**/*.scss'`. (auto: verify.sh:51-58 — rejects `**/*` and `**/*.ts` catch-all patterns)
- [x] CHK008 FR-008 — Body defines exactly two properties numbered P1 (visual diff) and P2 (interactive validation), each as a declarative invariant. Evidence: `rules/07-quality-assurance/7-ui-verification.mdc:25-26`. (auto: verify.sh:60-63 — counts `^- \*\*P[12] \(` bullets == 2)
- [x] CHK009 FR-009 — P1 requires before/after browser snapshot via Playwright MCP or equivalent, at implementation time, NOT part of the codified E2E suite. Evidence: `rules/07-quality-assurance/7-ui-verification.mdc:25`. (manual: read of P1 invariant; REVIEW Bohr Approved)
- [x] CHK010 FR-010 — P2 applies only when a new interactive element is introduced; requires real-browser click/exercise and asserting observable outcome against the spec. Evidence: `rules/07-quality-assurance/7-ui-verification.mdc:26` and `rules/07-quality-assurance/7-ui-verification.mdc:31-32` (conditional trigger). (manual: read of P2 invariant + Triggers block)
- [x] CHK011 FR-011 — No procedural step-by-step prose in `7-ui-verification.mdc`; how-to delegated to a future skill via `[NEEDS CLARIFICATION: priority=P2]` placeholder. Evidence: `rules/07-quality-assurance/7-ui-verification.mdc:37` (skill placeholder); whole file has zero ordered imperative blocks. (auto: verify.sh:65-68 — asserts zero `^[0-9]+\. ` ordered-list lines)
- [x] CHK012 FR-012 — Cross-references use relative paths matching `5-spec-driven-dev.mdc` convention. Evidence: `rules/07-quality-assurance/7-ui-verification.mdc:38` (`./7-testing.mdc`) and `rules/07-quality-assurance/7-ui-verification.mdc:39` (`../05-workflows-and-processes/5-spec-driven-dev.mdc`). (auto: verify.sh:70-75 — asserts both cross-ref strings present AND target files exist on disk)

## Spec — Success Criteria

- [x] CHK013 SC-001 — Reviewer can locate P7, its four-part detail section, and the new Anti-patterns bullet in `5-spec-driven-dev.mdc` in under 60 seconds. Evidence: P7 summary line at `rules/05-workflows-and-processes/5-spec-driven-dev.mdc:26`, detail heading at `:56`, Anti-patterns bullet at `:87` — three contiguous anchors, all visible in one scroll. (auto: verify.sh:30-38 — same anchors asserted by FR-001/FR-002/FR-004 checks)
- [x] CHK014 SC-002 — Frontmatter compliance verifiable by reading only the first 15 lines of `7-ui-verification.mdc`. Evidence: `rules/07-quality-assurance/7-ui-verification.mdc:1-15`. (auto: verify.sh:46-49 — `head -n 15 | rg -c '^(description|globs|alwaysApply|tags):' == 4`)
- [x] CHK015 SC-003 — Zero procedural step-by-step blocks (ordered lists of imperative agent actions) in `7-ui-verification.mdc`. Evidence: full-file read of `rules/07-quality-assurance/7-ui-verification.mdc`. (auto: verify.sh:65-68 — `rg -c '^[0-9]+\. '` returns 0)
- [x] CHK016 SC-004 — 100% of cross-references in the two produced/modified rules resolve as existing files. Evidence: `rules/05-workflows-and-processes/5-spec-driven-dev.mdc` (referencing `./5-spec-indexing.mdc`, `../07-quality-assurance/7-testing.mdc`) and `rules/07-quality-assurance/7-ui-verification.mdc:38-39` (referencing `./7-testing.mdc`, `../05-workflows-and-processes/5-spec-driven-dev.mdc`). (auto: verify.sh:70-75 — file-existence assertions on every relative target; verify.sh:77-80 also asserts both files indexed in `asset-registry.yml`)
- [ ] CHK017 SC-005 — A test spec that modifies an exported function's signature without a P7 audit task is flagged by a reviewer or rule-loading agent within the first review pass. Evidence: measured on the next TWO specs touching exported symbols after this rule ships. (deferred — empirical metric; cannot be auto-ticked at delivery time)

## Tasks — Implementation completeness

- [x] CHK018 All 15 tasks complete per IMPLEMENT pipeline state (T004-T007 Darwin, T008-T013 Einstein, T014 Galileo, T015 inline). (auto: pipeline-state IMPLEMENT line)
- [x] CHK019 Every FR is exercised by at least one verify.sh check or a manual ANALYZE finding. (auto: ANALYZE tasks-delta reported 12/12 FR coverage)
- [x] CHK020 Existing P1..P6 numbering preserved in `5-spec-driven-dev.mdc` (Out of Scope constraint from spec.md:98). Evidence: `rules/05-workflows-and-processes/5-spec-driven-dev.mdc:20-25` shows P1..P6 unchanged. (manual: REVIEW Bohr Approved confirmed P6 untouched, P1..P6 numbering preserved)

## Coverage

- [x] CHK021 12 FRs / 12 mapped to file:line evidence (FR-001..FR-012). (auto: ANALYZE tasks-delta 12/12)
- [x] CHK022 5 SCs / 4 auto-verifiable at delivery + 1 deferred empirical (SC-005). (manual: SC-005 is intentionally measured post-ship)
- [x] CHK023 Edge cases from spec.md:42-47 covered: rename-only → P6 not P7 (P6/P7 distinguishable by Trigger blocks at `:32-37` and `:60-64`); rename + signature change → both fire; backend-only spec → rule does not load (narrow globs at `7-ui-verification.mdc:8`); pure visual reflow → P1 yes, P2 no (explicit at `7-ui-verification.mdc:31-32`). (manual: read confirms all four edge cases addressed)

## Documentation

- [x] CHK024 `asset-registry.yml` indexes both deliverables with the `7-testing.mdc` shape. (auto: verify.sh:78-80 — asserts both filenames present in `asset-registry.yml`)
- [x] CHK025 No personal traces (`/Users/<name>/`, `$HOME`, username) in produced `.mdc` files. (auto: verify.sh:82-88 — asserts zero `/Users/.../` matches in both files)
- [x] CHK026 `verify.sh` is the canonical acceptance script and is committed under `specs/012-.../verify.sh`. Evidence: `specs/012-rules-impact-audit-ui-verification/verify.sh:1-90`.

## Open items (carried from spec.md `Open Questions`)

- [ ] CHK027 `[NEEDS CLARIFICATION: priority=P2]` — Exact slug of the future UI-verification skill (candidates: `ui-verification-mcp`, `browser-visual-diff`, `playwright-mcp-verification`). Placeholder currently lives at `rules/07-quality-assurance/7-ui-verification.mdc:37`. Resolve when the skill is authored.

## Sign-off

| Role | Name | Date | Decision |
|------|------|------|----------|
| Spec author | _to fill_ | _yyyy-mm-dd_ | _Approve / Request changes_ |
| Reviewer (rules library) | _to fill_ | _yyyy-mm-dd_ | _Approve / Request changes_ |
| Reviewer (downstream impact) | _to fill_ | _yyyy-mm-dd_ | _Approve / Request changes_ |

## Notes

- Check items off as completed: `[x]`
- All `(auto: ...)` annotations cite the precise script line range that asserts the invariant.
- CHK017 (SC-005) is intentionally left unticked — it is an empirical measure observed on the next two qualifying specs and cannot be verified at delivery time.
- CHK027 mirrors the lone open question from `spec.md`; closing it requires authoring the future skill, which is OUT OF SCOPE per `spec.md:88,95`.
