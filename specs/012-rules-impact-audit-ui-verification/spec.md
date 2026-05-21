# Feature Specification: Rules — Impact Audit (P7) + UI Verification

**Feature Branch**: `012-rules-impact-audit-ui-verification`
**Created**: 2026-05-21
**Status**: Draft
**Input**: Hardening the rules library so that (a) signature/behaviour changes to exported functions trigger a codified cross-codebase impact audit, and (b) any frontend change carries a dev-time, in-browser visual + interactive verification invariant.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — P7 impact-audit added to the spec-driven-dev rule (Priority: P1)

A spec author drafts a spec that changes the signature or observable behaviour of an exported function, method, or class. Reading `../05-workflows-and-processes/5-spec-driven-dev.mdc`, they encounter a new property **P7 (impact-audit)** in the same shape as the existing **P6 (rename-audit)**: Trigger, Required `tasks.md` template, Reviewer red flag, Failure mode prevented. The author adds the required cross-codebase call-site sweep task to `tasks.md` before implementation begins.

**Why this priority**: Without this rule extension, "modify-an-exported-symbol" specs continue to ship with silent caller breakage; this is the single highest-value invariant the spec captures.

**Independent Test**: Read `rules/05-workflows-and-processes/5-spec-driven-dev.mdc` standalone. Verify P7 exists, mirrors P6's four-part shape, and references its trigger and `tasks.md` template — no other artifact in the repo needs to change for this story to deliver value.

**Acceptance Scenarios**:

1. **Given** the updated `5-spec-driven-dev.mdc`, **When** a reader scans the "Properties" list, **Then** an entry numbered **P7 (impact-audit)** appears immediately after P6 with a one-line declarative summary.
2. **Given** the updated rule, **When** a reader looks for the detailed section, **Then** a dedicated heading (analogous to "Concept Rename / Semantic Redefinition Audit (P6)") provides Trigger, Required `tasks.md` template, Reviewer red flag, and Failure mode this prevents.
3. **Given** the updated rule, **When** a reader inspects the Anti-patterns block, **Then** a bullet warns against modifying an exported symbol's signature/behaviour without a P7 audit task.

---

### User Story 2 — New rule `7-ui-verification.mdc` for in-browser dev-time verification (Priority: P1)

A spec author drafts a spec that ships a frontend change (new component, modified component, new interactive element). Their editor or agent loads `rules/07-quality-assurance/7-ui-verification.mdc` because the spec touches frontend file types. The rule states the invariant in two sub-properties: **P1 (visual diff)** requires a before/after browser snapshot at the modification site, and **P2 (interactive validation)** requires clicking any newly added interactive element in a real browser and confirming the observable outcome matches the spec. The how-to (which MCP, which selector strategy) is deferred to a future skill — the rule only encodes the invariant.

**Why this priority**: Pairs with P7 on the implementation side. Without this rule, UI regressions ship despite a green codified E2E suite because the codified suite does not exercise the agent's intent at the moment of authoring.

**Independent Test**: Read `rules/07-quality-assurance/7-ui-verification.mdc` standalone. Verify it has valid frontmatter, narrow frontend-only globs, two numbered properties P1 and P2, no procedural step-by-step prose, and relative links to related rules.

**Acceptance Scenarios**:

1. **Given** the new rule file, **When** a reader inspects the frontmatter, **Then** `description`, `globs`, `alwaysApply`, and `tags` are present, `globs` lists frontend file extensions only, and `alwaysApply` is `false`.
2. **Given** the new rule file, **When** a reader scans the body, **Then** exactly two properties appear, numbered **P1 (visual diff)** and **P2 (interactive validation)**, each phrased as an invariant (declarative MUST/SHOULD), not as a numbered procedure.
3. **Given** the new rule file, **When** a reader follows the cross-references, **Then** links to `../05-workflows-and-processes/5-spec-driven-dev.mdc` and `./7-testing.mdc` resolve via repo-relative paths.

---

### Edge Cases

- A spec changes an exported function's name only (no signature/behaviour change): falls under P6 (rename-audit), NOT P7 — the two properties MUST be distinguishable from their triggers alone.
- A spec changes the signature AND renames the symbol: both P6 and P7 triggers fire and `tasks.md` MUST carry both audit tasks.
- A spec touches only backend files: `7-ui-verification.mdc` MUST NOT load (globs narrow enough that it is invisible to backend-only specs).
- A frontend spec adds zero new interactive elements (pure visual reflow): P1 applies, P2 does not — the rule MUST make the conditional trigger of P2 explicit.

## Requirements *(mandatory)*

### Functional Requirements

These FRs are invariants on the produced `.mdc` files (not on runtime behaviour, since this spec ships rule content only).

- **FR-001**: The file `rules/05-workflows-and-processes/5-spec-driven-dev.mdc` MUST contain a property entry numbered exactly **P7** in its "Properties" list, placed immediately after the existing P6.
- **FR-002**: The P7 detailed section MUST follow the same four-part shape as P6: **Trigger**, **Required `tasks.md` template**, **Reviewer red flag**, **Failure mode this prevents**.
- **FR-003**: The P7 trigger MUST cover signature changes (parameters added/removed/reordered/retyped, return type changed) AND observable behaviour changes (semantics under previously-defined inputs) of an exported function, method, or class.
- **FR-004**: The P7 `tasks.md` template MUST mandate enumerating call sites via LSP "Find References", `rg`, or an equivalent cross-codebase search, and MUST require updating each call site (or explicitly documenting why none is needed).
- **FR-005**: The "Anti-patterns" block of `5-spec-driven-dev.mdc` MUST gain a bullet warning against signature/behaviour changes without a P7 audit task.
- **FR-006**: A new file MUST exist at `rules/07-quality-assurance/7-ui-verification.mdc` with valid YAML frontmatter containing `description`, `globs`, `alwaysApply: false`, and `tags`.
- **FR-007**: The `globs` field of `7-ui-verification.mdc` MUST narrow to frontend file types only (e.g. `**/*.tsx,**/*.jsx,**/*.vue,**/*.svelte,**/*.html,**/*.css,**/*.scss`) and MUST NOT contain catch-all patterns such as `**/*` or `**/*.ts`.
- **FR-008**: The body of `7-ui-verification.mdc` MUST define exactly two properties numbered **P1 (visual diff)** and **P2 (interactive validation)**, each stated as a declarative invariant.
- **FR-009**: P1 (visual diff) MUST require a before-state and an after-state browser snapshot of the modified UI surface, captured via a browser MCP (Playwright MCP or equivalent), at implementation time and not as part of the codified E2E suite.
- **FR-010**: P2 (interactive validation) MUST apply only when a spec introduces a new interactive element (button, form control, link, menu, etc.) and MUST require clicking/exercising it in a real browser and asserting the observable outcome against the spec.
- **FR-011**: `7-ui-verification.mdc` MUST NOT contain procedural step-by-step prose (no numbered "first do X, then Y" recipe); the how-to MUST be delegated to a future skill and the rule MUST link to that skill placeholder via a relative path or a `[NEEDS CLARIFICATION: priority=P2]` marker if the skill slug is not yet decided.
- **FR-012**: All cross-references between the produced rules and existing rules (`5-spec-driven-dev.mdc`, `7-testing.mdc`, `../00-architecture/0-rules-structure.mdc`) MUST use relative paths matching the convention already in use in `5-spec-driven-dev.mdc`.

### Key Entities

- **Rule file (`.mdc`)**: A versioned text artifact under `rules/{NN-category}/` with mandatory YAML frontmatter and a declarative body describing invariants. Two such files are produced or modified by this spec.
- **Property**: A numbered entry inside a rule (`P1`..`PN`) stating one invariant. Numbering is continuous within a single rule and additive across versions (a new property gets the next free number, existing properties keep their numbers).
- **Trigger**: A condition stated in a rule property that determines when the property's required action becomes mandatory for a given spec.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A reviewer reading `5-spec-driven-dev.mdc` standalone can locate property P7, its four-part detail section, and the new Anti-patterns bullet in under 60 seconds without consulting this spec.
- **SC-002**: A linter or human checker can confirm `7-ui-verification.mdc` frontmatter compliance (4 required keys, narrow globs) by reading only the first 15 lines of the file.
- **SC-003**: Zero procedural step-by-step blocks (defined as ordered lists of imperative agent actions) appear in `7-ui-verification.mdc`; verified by a manual read of the produced file.
- **SC-004**: 100% of cross-references in the two produced/modified rules resolve as existing files when checked against the repository tree (no broken relative links).
- **SC-005**: A test specification that modifies an exported function's signature without a P7 audit task is flagged by a reviewer (or rule-loading agent) within the first review pass — measured on the next two specs that touch exported symbols after this rule ships.

## Assumptions

- The repository convention is `{N}-{kebab-slug}.mdc` per `../00-architecture/0-rules-structure.mdc`; the new file is therefore named `7-ui-verification.mdc` to slot after the existing `7-testing.mdc` inside `07-quality-assurance/`.
- "Frontend file types" for the narrow globs cover the stacks currently represented across downstream projects (React/TSX, Vue, Svelte, plain HTML/CSS/SCSS); additional extensions can be appended later without changing the rule's intent.
- The future skill that operationalises P1/P2 of `7-ui-verification.mdc` will live under `skills/<name>/SKILL.md` and is OUT OF SCOPE for this spec — only a forward-reference placeholder is required.
- The P7 audit task uses the same `[impact-audit]` tag convention that P6 uses (`[rename-audit]`), so existing `tasks.md` tooling/parsers do not need to learn a new format.
- Downstream consumers of this rules library load `.mdc` files via glob-matching; therefore narrowing globs is the only mechanism preventing `7-ui-verification.mdc` from loading on backend-only specs.

## Out of Scope

- No edit to the root `AGENTS.md`.
- No new skill file (`skills/<name>/SKILL.md`) is created by this spec.
- No code, no E2E test suite, no automation script.
- No change to any rule other than `5-spec-driven-dev.mdc` (additive) and the new `7-ui-verification.mdc` (created).
- No change to existing property numbering in `5-spec-driven-dev.mdc` (P1..P6 stay as-is).

## Roadmap alignment

`[unaligned]` — no active `ROADMAP.md` milestone targets the rules library hardening track; this spec is opportunistic agent-stack maintenance.

## Open Questions

- **[NEEDS CLARIFICATION: priority=P2]** Exact slug of the future skill that operationalises `7-ui-verification.mdc` (candidates: `ui-verification-mcp`, `browser-visual-diff`, `playwright-mcp-verification`). Defaults to a forward-reference placeholder in the rule's "Skill References" section until decided.
