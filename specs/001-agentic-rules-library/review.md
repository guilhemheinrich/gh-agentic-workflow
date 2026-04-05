# Pre-Implementation Review

**Feature**: Agentic Rules Library  
**Artifacts reviewed**: `spec.md`, `plan.md`, `tasks.md`, `checklists/requirements.md`, `checklists/architecture-rules.md`, `research.md` (no `remediation.md`)  
**Review model**: Cross-model review (fleet Phase 7)  
**Generating model**: Primary session model (Phases 1–6)

## Summary

| Dimension | Verdict | Issues |
|-----------|---------|--------|
| Spec-Plan Alignment | **WARN** | FR-014 names `.md` / `architecture-overview.md` while plan/research standardize on `.mdc`; resolved by planned T014 but spec still divergent until then. |
| Plan-Tasks Completeness | **PASS** | Deliverables in plan (8× `.mdc`, constitution) map to T002–T010; polish T014–T016 covers doc alignment and quickstart. No automated test tasks — consistent with spec (“tests not requested”). |
| Dependency Ordering | **PASS** | Setup → constitution → parallel rule groups → overview T010 → US2/US3/US4 polish → cross-cutting; T010 correctly sequential after T003–T009. |
| Parallelization Correctness | **PASS** | Groups 1–3 split files without overlap; max 3 concurrent per group; T009 is single-file group 3 (valid). |
| Feasibility & Risk | **WARN** | Each rule file is content-heavy (examples + enforcement); risk of exceeding 500 lines mitigated by T012. FR-004 vs Rule 6 skill links (analyze I1) should be fixed in spec or task scope. |
| Standards Compliance | **WARN** | `.specify/memory/constitution.md` is still a placeholder template until T002; no conflict with future principles, but governance is not yet ratified. |
| Implementation Readiness | **WARN** | Most tasks name exact paths; T011 (“Review all eight… ensure Enforcement”) is subjective — acceptable as QA pass but could be tightened with a short checklist. |

**Overall**: **READY WITH WARNINGS**

## Findings

### Critical (FAIL — must fix before implementing)

None. No blocking FAIL dimensions.

### Warnings (WARN — recommend fixing, can proceed)

1. **Spec vs plan file extension** — Align `spec.md` FR-014 with `.mdc` and final filenames via **T014** before calling implementation “spec-complete.”
2. **FR-004 scope** — Either extend FR-004 to include Rule 6 skill reference requirements or adjust User Story 4 / task wording so Rule 6 is explicitly in scope (see analyze I1).
3. **Constitution placeholder** — **T002** must replace template `constitution.md` for FR-015; until then, standards compliance is provisional.
4. **T011 breadth** — Consider adding 1–3 bullet criteria for “Enforcement” (imports to flag, patterns) to reduce reviewer ambiguity.

### Observations (informational)

1. **T015** (`specify-rules.mdc` vs new rules) is a one-time consolidation decision; no spec FR, but valuable to avoid duplicate always-apply guidance.
2. **SC-003 / SC-005** remain qualitative; acceptable for a rules-library deliverable if Phase 9 verify uses manual/agent checks.

## Recommended Actions

- [ ] Complete **T014** to update FR-014 for `.mdc` and `architecture-overview.mdc` naming consistency.
- [ ] Resolve **FR-004** vs Rule 6 / **T008** skill link expectation in `spec.md` (one-line clarification or FR amendment).
- [ ] Execute **T002** early enough that Phase 9 verify can check constitution against rules.
- [ ] Optionally narrow **T011** with a mini-checklist (3–5 bullets) in `tasks.md` during implementation kickoff.
