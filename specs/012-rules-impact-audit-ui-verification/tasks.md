# Tasks: Rules — Impact Audit (P7) + UI Verification

**Input**: Design documents in `specs/012-rules-impact-audit-ui-verification/`
**Prerequisites**: `spec.md`, `plan.md`, `data-model.md`, `contracts/`

> **Doc-only spec.** This feature ships **zero runtime artifacts** — no code,
> no build, no test runner, no Docker image. Therefore the standard TDD
> "tests first" ordering does NOT apply. Tasks are ordered **verifications
> first, then writes**: the governing structural rule
> (`rules/00-architecture/0-rules-structure.mdc`) is loaded before any
> `.mdc` edit, and the shape of each `.mdc` file is verified via `rg` /
> `test` immediately after the write. No language toolchain is invoked,
> so the Docker-only rule does not apply here.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (touches a different file than other [P] tasks).
- **[Story]**: US1 = P7 added to `5-spec-driven-dev.mdc`; US2 = new `7-ui-verification.mdc`.
- **Touches:** field lists the exact file path(s) acted on — load-bearing for downstream batch planning.

---

## Phase 1: Foundations (Shared verifications, no story scope)

**Purpose**: Pre-flight static reads. No file writes. Establishes the
authoritative shape (frontmatter contract, P6 four-part pattern) that
both deliverables must mirror.

- [ ] **T001** Load the governing rules-structure rule and confirm the four mandatory frontmatter keys (`description`, `globs`, `alwaysApply`, `tags`) plus the "narrow globs" P2 invariant.
  - Touches: `rules/00-architecture/0-rules-structure.mdc` (read-only)
  - Pass criterion: reader can paraphrase P1 (one category per file), P2 (narrow globs), P3 (no framework-specific syntax in agnostic categories) without re-reading.

- [ ] **T002** [P] Load the existing P6 (rename-audit) block in `5-spec-driven-dev.mdc` as the canonical four-part template (Trigger / Required `tasks.md` template / Reviewer red flag / Failure mode this prevents).
  - Touches: `rules/05-workflows-and-processes/5-spec-driven-dev.mdc` (read-only)
  - Pass criterion: the four labelled sub-sections of P6 are identified by exact heading/label so P7 can mirror them verbatim in shape.

- [ ] **T003** [P] Load `7-testing.mdc` (sibling of the new UI rule) to confirm the H1/Properties/Enforcement skeleton already in use under `07-quality-assurance/`, so the new `7-ui-verification.mdc` reads as a sibling.
  - Touches: `rules/07-quality-assurance/7-testing.mdc` (read-only)
  - Pass criterion: skeleton (H1, Properties section, Enforcement section) is identified; deviations in the new file must be intentional and justified.

**Checkpoint**: The four-part P6 template and the frontmatter contract are explicit. Both deliverables can now proceed in parallel.

---

## Phase 2: User Story 1 — Add P7 (impact-audit) to `5-spec-driven-dev.mdc` (Priority: P1)

**Goal**: Extend the spec-driven-dev rule with property **P7 (impact-audit)** in the same four-part shape as P6, plus a matching Anti-patterns bullet. No other property is changed; P1..P6 numbering stays intact.

**Independent Test**: `rg -n '^- \*\*P7' rules/05-workflows-and-processes/5-spec-driven-dev.mdc` returns exactly 1 match; `rg -n '\(P7\)' rules/05-workflows-and-processes/5-spec-driven-dev.mdc` returns at least 1 detail-section heading; the Anti-patterns block mentions P7.

### Implementation for US1

- [x] **T004** [US1] Edit the "Properties" bullet list in `5-spec-driven-dev.mdc` to append one new bullet immediately after the existing P6 bullet: `**P7 (impact-audit)**:` followed by a one-line declarative summary covering signature/behaviour changes to exported symbols (FR-001, FR-003).
  - Touches: `rules/05-workflows-and-processes/5-spec-driven-dev.mdc`
  - Depends on: T001, T002
  - Pass criterion: exactly one new bullet inserted; P1..P6 bullets untouched; numbering is continuous (no gap, no duplicate).

- [x] **T005** [US1] Add the P7 detail section to `5-spec-driven-dev.mdc` immediately after the existing P6 detail section "Concept Rename / Semantic Redefinition Audit (P6)" and before the "Anti-patterns" H2. Heading: `## Exported-symbol Signature / Behaviour Audit (P7)`. Four labelled sub-sections, mirroring P6 verbatim in shape:
  - **Trigger** — bullets covering parameters added / removed / reordered / retyped, return type changed, AND observable behaviour changes under previously-defined inputs (FR-003).
  - **Required `tasks.md` template** — fenced ` ```markdown ` block containing a `[impact-audit]`-tagged task that mandates LSP "Find References", `rg`, or equivalent cross-codebase search, with an explicit "update each call site OR document why none applies" step (FR-004). Use the same `[impact-audit]` tag convention as P6's `[rename-audit]`.
  - **Reviewer red flag** — one paragraph naming the smoking-gun pattern (callers compiling because of lax typing / implicit any / structural duck-typing).
  - **Failure mode this prevents** — one paragraph describing silent caller breakage when a green build hides a signature-or-semantics drift.
  - Touches: `rules/05-workflows-and-processes/5-spec-driven-dev.mdc`
  - Depends on: T004
  - Pass criterion (FR-002): the four sub-section labels appear in the same order and use the same casing as in the P6 block.

- [x] **T006** [US1] Append one bullet to the existing "Anti-patterns" list in `5-spec-driven-dev.mdc`: warns against modifying an exported symbol's signature or observable behaviour without a P7 impact-audit task (FR-005). Mirrors the phrasing of the existing P6 anti-pattern bullet for symmetry.
  - Touches: `rules/05-workflows-and-processes/5-spec-driven-dev.mdc`
  - Depends on: T005
  - Pass criterion: exactly one new bullet appended; existing anti-pattern bullets untouched.

- [x] **T007** [US1] Verify the US1 file shape via `rg` (no writes):
  - `rg -n '^- \*\*P[1-7] \(' rules/05-workflows-and-processes/5-spec-driven-dev.mdc` → exactly 7 matches (P1..P7 properties bullets), continuous numbering, no duplicate.
  - `rg -n '\(P7\)' rules/05-workflows-and-processes/5-spec-driven-dev.mdc` → ≥ 1 match (detail-section heading).
  - `rg -n '\[impact-audit\]' rules/05-workflows-and-processes/5-spec-driven-dev.mdc` → ≥ 1 match (inside the fenced `tasks.md` template).
  - `rg -n 'P7' rules/05-workflows-and-processes/5-spec-driven-dev.mdc` → ≥ 3 matches (properties bullet + detail heading + anti-pattern bullet).
  - Touches: `rules/05-workflows-and-processes/5-spec-driven-dev.mdc` (read-only)
  - Depends on: T006

**Checkpoint US1**: `5-spec-driven-dev.mdc` carries a self-consistent P7 block; reviewer can locate it in < 60 seconds (SC-001). US1 is independently deliverable here — US2 work has not started.

---

## Phase 3: User Story 2 — Create `7-ui-verification.mdc` (Priority: P1)

**Goal**: Author the new declarative rule that encodes the UI dev-time verification invariant as two properties (P1 visual diff, P2 interactive validation). No procedural prose; how-to is deferred to a future skill.

**Independent Test**: `test -f rules/07-quality-assurance/7-ui-verification.mdc` succeeds; the first 15 lines contain `description`, `globs`, `alwaysApply: false`, `tags`; the body contains exactly two property bullets `**P1 (visual diff)**` and `**P2 (interactive validation)**`; no ordered procedural list of imperative agent actions appears in the body.

### Implementation for US2

- [x] **T008** [P] [US2] Create `rules/07-quality-assurance/7-ui-verification.mdc` with the YAML frontmatter block:
  - `description`: one paragraph stating the dev-time, in-browser visual + interactive verification invariant.
  - `globs`: narrow frontend-only list — `**/*.tsx,**/*.jsx,**/*.vue,**/*.svelte,**/*.html,**/*.css,**/*.scss` (FR-007). No `**/*` or `**/*.ts` catch-all.
  - `alwaysApply: false` (FR-006).
  - `tags`: `frontend`, `quality`, `verification`, `ui`.
  - Touches: `rules/07-quality-assurance/7-ui-verification.mdc` (CREATE)
  - Depends on: T001, T003
  - Pass criterion (FR-006, SC-002): the four frontmatter keys are present within the first 15 lines.
  - [P] rationale: different file than T004–T007 (`5-spec-driven-dev.mdc`); can run in parallel with US1's edits.

- [x] **T009** [US2] Add the body of `7-ui-verification.mdc` (after frontmatter): H1 `# UI dev-time verification`, then a `## Desired state` paragraph stating the one-sentence invariant, then a `## Properties` H2 containing exactly two declarative bullets:
  - `- **P1 (visual diff)**:` declarative MUST — before/after browser snapshot of the modified UI surface, via a browser MCP, at implementation time, not part of the codified E2E suite (FR-008, FR-009).
  - `- **P2 (interactive validation)**:` declarative MUST that fires CONDITIONALLY when the spec introduces a new interactive element (button, form control, link, menu, etc.) — requires clicking/exercising it in a real browser and asserting the observable outcome against the spec (FR-008, FR-010).
  - Touches: `rules/07-quality-assurance/7-ui-verification.mdc`
  - Depends on: T008
  - Pass criterion: exactly two property bullets in the Properties section; both phrased as declarative invariants (MUST / SHOULD), no imperative step-by-step prose.

- [x] **T010** [US2] Add the `## Triggers (when this rule's properties fire)` section to `7-ui-verification.mdc`, distinguishing P1 (always for any frontend file change) from P2 (only when a new interactive element is introduced). Explicitly covers the spec's edge case "pure visual reflow → P1 yes, P2 no" and notes that backend-only specs do not load this rule (narrow globs).
  - Touches: `rules/07-quality-assurance/7-ui-verification.mdc`
  - Depends on: T009
  - Pass criterion: the conditional trigger of P2 is explicit (edge case "pure visual reflow" addressed).

- [x] **T011** [US2] Add the `## Skill References` section to `7-ui-verification.mdc`:
  - A forward-reference placeholder for the future UI-verification skill, tagged `[NEEDS CLARIFICATION: priority=P2]` (FR-011) — slug TBD per spec Open Questions.
  - Relative link to `./7-testing.mdc` for the codified E2E suite (complementary, not a substitute).
  - Relative link to `../05-workflows-and-processes/5-spec-driven-dev.mdc` for the spec workflow that consumes this invariant (FR-012).
  - Touches: `rules/07-quality-assurance/7-ui-verification.mdc`
  - Depends on: T010
  - Pass criterion (FR-012): both relative links use the same relative-path convention already in `5-spec-driven-dev.mdc`; both targets exist on disk.

- [x] **T012** [US2] Add the `## Enforcement` section to `7-ui-verification.mdc`: a **Detect** bullet (frontend spec ships without a P1 visual-diff artifact; new interactive element ships without a P2 interaction trace) and a **Fix** bullet (reopen the spec's review checkpoint; run the forthcoming UI-verification skill against the modified surface).
  - Touches: `rules/07-quality-assurance/7-ui-verification.mdc`
  - Depends on: T011
  - Pass criterion: section present; phrased declaratively, not procedurally.

- [x] **T013** [US2] Verify the US2 file shape via `rg` / `test` (no writes):
  - `test -f rules/07-quality-assurance/7-ui-verification.mdc` → exit 0.
  - `rg -n '^(description|globs|alwaysApply|tags):' rules/07-quality-assurance/7-ui-verification.mdc` → 4 matches in the first 15 lines (SC-002).
  - `rg -n "globs:.*\*\*/\*'" rules/07-quality-assurance/7-ui-verification.mdc` → zero matches (no catch-all glob, FR-007).
  - `rg -n '^- \*\*P[12] \(' rules/07-quality-assurance/7-ui-verification.mdc` → exactly 2 matches (FR-008).
  - Manual read for ordered "1. do X, 2. do Y" recipe blocks (SC-003) → zero such blocks.
  - `test -f rules/07-quality-assurance/7-testing.mdc && test -f rules/05-workflows-and-processes/5-spec-driven-dev.mdc` → both pass (SC-004).
  - Touches: `rules/07-quality-assurance/7-ui-verification.mdc` (read-only)
  - Depends on: T012

**Checkpoint US2**: `7-ui-verification.mdc` exists, frontmatter compliant, exactly two declarative properties, zero procedural prose, all cross-refs resolve.

---

## Phase 4: Cross-cutting — Asset registry refresh and final integrity sweep

**Purpose**: Index the new rule in `asset-registry.yml` and run the cross-deliverable integrity checks that touch both files at once.

- [x] **T014** Append the `7-ui-verification.mdc` entry to `asset-registry.yml` under the rules block, immediately after the existing `rules/07-quality-assurance/7-testing.mdc` entry. Mirror the shape of the `7-testing.mdc` entry: `path`, `type: rule`, `tags` (`frontend`, `quality`, `verification`, `ui`), `description` (one-paragraph YAML folded-scalar). Do NOT modify any other registry entry.
  - Touches: `asset-registry.yml`
  - Depends on: T008 (file must exist first)
  - Pass criterion: exactly one new entry under the rules block; `rg -n '7-ui-verification.mdc' asset-registry.yml` → exactly 1 match; YAML still parses (no indentation drift relative to siblings).

- [x] **T015** Final integrity sweep across both deliverables (read-only `rg` / `test`):
  - `rg -n '^- \*\*P[1-7] \(' rules/05-workflows-and-processes/5-spec-driven-dev.mdc` → 7 matches, continuous.
  - `rg -n '^- \*\*P[12] \(' rules/07-quality-assurance/7-ui-verification.mdc` → 2 matches.
  - `rg -n '5-spec-driven-dev.mdc' rules/07-quality-assurance/7-ui-verification.mdc` → ≥ 1 match (cross-ref present, FR-012).
  - `rg -n '7-testing.mdc' rules/07-quality-assurance/7-ui-verification.mdc` → ≥ 1 match (cross-ref present, FR-012).
  - `rg -n '7-ui-verification.mdc' asset-registry.yml` → exactly 1 match (T014 landed).
  - Manual read of `7-ui-verification.mdc`: zero ordered "1. step / 2. step / 3. step" agent-action recipes (SC-003).
  - Touches: `rules/05-workflows-and-processes/5-spec-driven-dev.mdc`, `rules/07-quality-assurance/7-ui-verification.mdc`, `asset-registry.yml` (all read-only)
  - Depends on: T007, T013, T014

**Checkpoint Final**: Both rule edits land, asset registry is in sync, all cross-references resolve, no procedural prose has leaked into the UI rule. Spec is ready for review.

---

## Dependencies & Execution Order

### Phase dependencies

- **Phase 1 (Foundations)**: no dependency; can start immediately. Read-only.
- **Phase 2 (US1)**: requires T001, T002. Independent of Phase 3.
- **Phase 3 (US2)**: requires T001, T003. Independent of Phase 2.
- **Phase 4 (Cross-cutting)**: T014 requires T008 (file existence); T015 requires T007, T013, T014.

### Within each user story

- US1: T004 → T005 → T006 → T007 (strictly sequential — all four tasks touch the same file).
- US2: T008 → T009 → T010 → T011 → T012 → T013 (strictly sequential — all six tasks touch the same file).

### Parallel opportunities

- **T002 and T003** can run in parallel (different files, both read-only).
- **US1 (T004..T007) and US2 (T008..T013)** can run in parallel — they touch DIFFERENT files (`5-spec-driven-dev.mdc` vs `7-ui-verification.mdc`). T008 is explicitly marked `[P]` to call this out.
- All other tasks within a story are sequential because they touch the same `.mdc` file.

---

## Parallel example

```text
# Once Foundations (T001..T003) are done, two reviewers can split:
# Reviewer A — US1 sequential chain on rules/05-workflows-and-processes/5-spec-driven-dev.mdc
T004 → T005 → T006 → T007

# Reviewer B — US2 sequential chain on rules/07-quality-assurance/7-ui-verification.mdc
T008 → T009 → T010 → T011 → T012 → T013

# Then merge in the cross-cutting tail:
T014 → T015
```

---

## Notes

- This is a doc-only spec. No code, no test runner, no Docker, no language toolchain — by design.
- `[P]` strictly means "different file from other [P] tasks"; same-file edits are always sequential.
- Verification commands are `rg` and `test` only; they are static review aids, not part of any CI pipeline introduced by this spec.
- The `[NEEDS CLARIFICATION: priority=P2]` marker in T011 is the open question from `spec.md#Open Questions` — defer resolution to REVIEW; not a blocker.
- No personal traces (no absolute paths containing `/Users/<name>/`, no usernames, no `$HOME`) appear in the produced `.mdc` files or in `asset-registry.yml`.
