# Research: Rules — Impact Audit (P7) + UI Verification

**Spec**: [spec.md](./spec.md)
**Scope**: research (Phase 0 — inventory of governing rules and adjacent rules, decisions on placement, shape, and globs)
**Date**: 2026-05-21

This spec ships rule content only (two `.mdc` files). There is no runtime, no dependency to pin, no library to look up. "Research" here means **proving that the two produced files do not collide with, contradict, or duplicate any existing rule**, and that the chosen folder + glob + content-shape decisions match the governing taxonomy.

---

## Inventory of touched / adjacent rules

| Rule | Globs | Role for this spec | Collision risk |
|------|-------|--------------------|----------------|
| `rules/00-architecture/0-rules-structure.mdc` | `rules/**/*.mdc` | **Governing rule** — defines folder taxonomy, frontmatter keys, naming pattern, and the "describe invariants, not procedure" content shape. Both produced files MUST conform. | None — produced files mirror its constraints (see "Conformance check" below). |
| `rules/05-workflows-and-processes/5-spec-driven-dev.mdc` | `specs/**/*,fixes/**/*` | **Target of additive extension**: gains property P7 and a P7 detail section in the same shape as P6 (Trigger / Required `tasks.md` template / Reviewer red flag / Failure mode this prevents). Globs unchanged. | None — additive only; existing P1..P6 numbering preserved (FR per spec). |
| `rules/05-workflows-and-processes/5-spec-indexing.mdc` | (separate indexing rule) | Sibling under same folder, unrelated content (indexation). | None — different concern. |
| `rules/07-quality-assurance/7-testing.mdc` | `**/*_test.go,**/*.test.ts,**/*.spec.ts,**/__tests__/**,**/test/**,**/tests/**` | **Sibling of new file** under `07-quality-assurance/`. Covers agnostic testing principles (TDD, pyramid, AAA, naming, boundaries). | **Verified non-overlap** — `7-testing.mdc` globs match *test source files*; the new `7-ui-verification.mdc` globs will match *frontend source files*. The two sets are disjoint. Content scope is also disjoint: `7-testing` is about codified automated tests; `7-ui-verification` is about dev-time, in-browser manual/agent verification (explicitly NOT part of the codified E2E suite, per FR-009). |
| `rules/03-frameworks-and-libraries/3-vitest-conventions.mdc` | `**/*.test.ts,**/*.spec.ts,**/__tests__/**/*.ts,**/vitest.config.ts,**/vitest.config.*.ts` | Mentions Playwright tangentially in its "Skill References" (`E2E and Playwright: use the project's E2E skill or CI documentation when present`). | **Verified non-overlap** — vitest globs are TypeScript test files; new file's globs will be `*.tsx`, `*.jsx`, `*.vue`, `*.svelte`, `*.html`, `*.css`, `*.scss`. No overlap on `.test.ts` since that extension is excluded from the new file's globs by design. |
| `skills/e2e-spec-writing/SKILL.md` | n/a (skill) | Procedural sibling that explains *how to write* E2E spec deliverables. The new rule's invariant lives one level above — at the dev-time verification gate before any codified E2E exists. | None — different layer. The new rule MAY cross-link to this skill from its "Skill References" section as a related-but-distinct procedural resource. |
| `skills/web-analysis/SKILL.md` | n/a (skill) | Bundles browser tooling (Lighthouse, pa11y, axe-core CLI, html-validate) via Docker. Not a browser-MCP skill, but **the closest existing browser-automation surface** in the repo. Worth noting in the new rule's "Skill References" as the current entry point for any browser-tool work, until the future `*-ui-verification-mcp` skill ships. | None — referenced as adjacent, not as the operational skill for P1/P2. |

### Conformance check against `0-rules-structure.mdc`

| Constraint from governing rule | Decision for `5-spec-driven-dev.mdc` (modify) | Decision for `7-ui-verification.mdc` (create) |
|---|---|---|
| Lives in exactly one category folder (P1) | Already in `05-workflows-and-processes/`; unchanged | `07-quality-assurance/` — confirmed by taxonomy table (07 = "Testing, quality gates (principles may be agnostic)") |
| Naming `{N}-{kebab-slug}.mdc` | Unchanged | `7-ui-verification.mdc` — slots after `7-testing.mdc` inside `07-quality-assurance/` |
| Frontmatter has `description`, `globs`, `alwaysApply`, `tags` | Unchanged | Will be present (see data-model.md) |
| Globs narrow enough to load only when relevant (P2) | Unchanged | **Highest-risk decision — see next section** |
| Content describes invariants, not procedure (content shape) | P7 detail section mirrors the existing P6 *declarative* shape (no numbered "first do X, then Y") | Body holds exactly two numbered properties P1 / P2, each phrased as a declarative MUST/SHOULD invariant; how-to deferred to a future skill (FR-011) |
| Examples in agnostic categories use pseudo-code or Go (P3) | No new code examples added by P7 (template snippet in markdown is a `tasks.md` line, not source code) | No source-code examples; rule body is pure prose invariants |

Both produced files pass the governing rule.

---

## Highest-risk decision: glob narrowness of `7-ui-verification.mdc`

Per spec **FR-007**, the new rule's `globs` field MUST narrow to frontend file types only and MUST NOT contain catch-alls. This is the single decision that determines whether the rule behaves as designed (load on frontend specs, stay invisible on backend-only specs) or pollutes every spec with a non-applicable invariant.

### Options weighed

| Option | Glob | Trade-off |
|---|---|---|
| **A — narrow** (chosen) | `**/*.tsx,**/*.jsx,**/*.vue,**/*.svelte,**/*.html,**/*.css,**/*.scss` | Matches the four frontend component formats currently in scope across downstream projects (React/TSX, React/JSX, Vue SFC, Svelte) plus raw markup/styles. Backend-only TypeScript (`*.ts` without JSX) does NOT match, which is the goal. Aligned with `Assumptions` block of `spec.md`. |
| B — include `**/*.ts` | `**/*.ts,**/*.tsx,...` | Rejected: pulls in every backend TypeScript file (Node/Hono routes, domain code, vitest fixtures). Would re-introduce the noise the rule is designed to prevent. Violates FR-007 explicitly. |
| C — path-scoped | `apps/web/**/*,packages/ui/**/*` | Rejected: too project-specific. The rule lives in a shared library consumed by multiple downstream repos with different folder conventions. Extension-based matching is the portable choice. |
| D — include `**/*.md` (storybook stories, MDX) | `...,**/*.md,**/*.mdx` | Rejected for v1: docs/markdown changes that touch UI copy are already covered by P6 (rename-audit) when they rename a label. Adding `*.md` would cause the rule to load on spec edits themselves (specs are markdown), which is pathological. May be revisited if MDX-based component stories appear in scope (per spec `Assumptions`, additional extensions can be appended later without changing intent). |

**Decision**: Option A. Comma-separated extension list, no path prefix, no catch-all.

### Verification approach (post-merge, manual)

1. Open a backend-only spec folder (any spec where every file is `*.ts` / `*.go` / `*.md`). Confirm `7-ui-verification.mdc` is NOT loaded by the agent/editor's rule-loader.
2. Open a frontend spec folder containing at least one `*.tsx` or `*.vue`. Confirm `7-ui-verification.mdc` IS loaded.
3. SC-004 covers the cross-reference integrity (all relative links resolve).

---

## Shape mirroring: P7 ↔ P6

The P7 detail section in `5-spec-driven-dev.mdc` MUST follow the same four-part shape as the existing P6 "Concept Rename / Semantic Redefinition Audit (P6)" section. The mirror is:

| P6 section heading | P7 section heading (target) |
|---|---|
| Trigger | Trigger |
| Required `tasks.md` template | Required `tasks.md` template |
| Reviewer red flag | Reviewer red flag |
| Failure mode this prevents | Failure mode this prevents |

The Properties list line for P7 follows the same one-line declarative pattern as P6's:

```
- **P7 (impact-audit)**: When a spec changes the signature or observable behaviour of an exported function, method, or class, `tasks.md` MUST include an explicit cross-codebase call-site audit task before implementation begins.
```

The `tasks.md` template tag convention is `[impact-audit]`, mirroring P6's `[rename-audit]` — per spec `Assumptions`, this keeps existing `tasks.md` parsers/tooling unchanged.

Distinguishability from P6 (per spec edge case): P6 fires on **rename without behaviour change**; P7 fires on **signature or behaviour change** (which may or may not also be a rename). When both fire, both tasks are required.

---

## Forward references and open questions

- **Future skill slug** for the operational how-to of `7-ui-verification.mdc` P1/P2 is open (`[NEEDS CLARIFICATION: priority=P2]` in `spec.md`, line 106). Candidates: `ui-verification-mcp`, `browser-visual-diff`, `playwright-mcp-verification`. The new rule MUST link to a placeholder path until the slug is decided; the link target itself is the bikeshed and does not block this spec.
- The `web-analysis` skill is **not** the operational skill for P1/P2 (it focuses on Lighthouse/pa11y/axe-core/html-validate audits, not interactive browser MCP). It MAY be referenced as an adjacent skill in the new rule's "Skill References" section, but the placeholder for the future MCP-based skill remains the canonical forward reference.

---

## Summary of decisions

1. `rules/05-workflows-and-processes/5-spec-driven-dev.mdc` is extended additively with property P7 and a P7 detail section that mirrors P6's four-part shape exactly. No existing content changes. Anti-patterns block gains one bullet.
2. `rules/07-quality-assurance/7-ui-verification.mdc` is created with narrow frontend-only globs (Option A above), `alwaysApply: false`, and a body of exactly two declarative properties P1 (visual diff) and P2 (interactive validation). No procedural prose; how-to deferred to a future skill referenced by placeholder.
3. No contradiction with any existing rule. Glob non-overlap with `7-testing.mdc` and `3-vitest-conventions.mdc` verified by extension-set disjointness.
4. No new dependency, no API surface, no contract. See `contracts/README.md`.
