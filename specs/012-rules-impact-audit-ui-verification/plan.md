# Implementation Plan: Rules — Impact Audit (P7) + UI Verification

**Branch**: `012-rules-impact-audit-ui-verification` | **Date**: 2026-05-21 | **Spec**: [./spec.md](./spec.md)
**Input**: Feature specification at `specs/012-rules-impact-audit-ui-verification/spec.md`

## Summary

Ship two declarative rule edits in the `rules/` library, with **zero** runtime, build, or test surface:

1. **Modify** `rules/05-workflows-and-processes/5-spec-driven-dev.mdc` — add property **P7 (impact-audit)** in the same four-part shape as the existing P6 (rename-audit), plus a matching Anti-patterns bullet.
2. **Create** `rules/07-quality-assurance/7-ui-verification.mdc` — a new rule with narrow frontend-only globs declaring two invariants: **P1 (visual diff)** and **P2 (interactive validation)**. The how-to is deferred to a future skill; the rule encodes the invariant only.

Approach is purely textual editing of `.mdc` files against the conventions in [`rules/00-architecture/0-rules-structure.mdc`](../../rules/00-architecture/0-rules-structure.mdc). Verification is grep/`rg`-based static review — there is nothing to compile, build, or run.

## Technical Context

**Language/Version**: N/A — Markdown + YAML frontmatter (`.mdc`).
**Primary Dependencies**: None. Editing this repo's own rule files.
**Storage**: Git-versioned text files under `rules/`.
**Testing**: No automated test suite. Verification = `rg`/grep checks + manual reviewer pass against [`0-rules-structure.mdc`](../../rules/00-architecture/0-rules-structure.mdc) properties P1..P3.
**Target Platform**: Repo content consumed by Cursor / Claude Code rule loaders via glob matching.
**Project Type**: Meta-repository (rules + skills + agents + commands library). No application runtime, no frontend, no backend, no Docker target.
**Performance Goals**: N/A.
**Constraints**: English-only artifacts; no personal traces in produced files; no procedural prose inside the rule body (procedural how-to belongs in skills per [`0-rules-structure.mdc`](../../rules/00-architecture/0-rules-structure.mdc) §"Content shape").
**Scale/Scope**: 2 files touched (1 modified, 1 created). Both files expected to stay under ~120 lines each.

## Constitution Check

This repo has no `.specify/memory/constitution.md`. The de-facto constitution for this spec is the rules-structure rule itself plus standing Septeo discipline:

| Principle | Source | Compliance |
|-----------|--------|------------|
| English-only artifacts | Septeo standing rule | PASS — both produced files English. |
| No personal traces (absolute paths, usernames, `$HOME`) | Septeo standing rule | PASS — only repo-relative paths used. |
| P1 (one category per file) | `0-rules-structure.mdc` | PASS — P7 stays inside `05-workflows-and-processes/`; UI rule lives in `07-quality-assurance/`. |
| P2 (narrow globs) | `0-rules-structure.mdc` | PASS — UI rule globs narrow to frontend extensions only; no `**/*` catch-all. |
| P3 (no framework-specific syntax in agnostic categories) | `0-rules-structure.mdc` | PASS — UI rule body stays declarative, references no specific framework syntax. |
| No procedural prose inside rules | `0-rules-structure.mdc` §"Content shape" | PASS — UI rule defers how-to to a future skill placeholder (FR-011). |

**Constitution waivers**: none required.

## Project Structure

### Documentation (this feature)

```text
specs/012-rules-impact-audit-ui-verification/
├── plan.md              # This file
├── spec.md              # Already authored
├── quickstart.md        # Phase 1 output (this dispatch)
└── tasks.md             # Phase 2 output (later dispatch)
```

No `research.md`, `data-model.md`, or `contracts/` apply here — no dependency choice, no data entities beyond the conceptual "rule file" already captured in `spec.md#Key Entities`, no API surface.

### Source files touched

```text
rules/
├── 05-workflows-and-processes/
│   └── 5-spec-driven-dev.mdc          # MODIFY: add P7 property + detail section + anti-pattern bullet
└── 07-quality-assurance/
    ├── 7-testing.mdc                  # (sibling — referenced, NOT modified)
    └── 7-ui-verification.mdc          # CREATE: new rule, two properties (P1, P2)
```

**Structure Decision**: Two co-located edits, each scoped to its category folder per `0-rules-structure.mdc` P1. No new folders. No file moves. No renames. No asset-registry move (additive file only — see "Side-effect: asset registry" below).

## Approach

### Edit 1 — `5-spec-driven-dev.mdc`: add P7

Three additive insertions into the existing file. Numbering P1..P6 stays untouched (spec §"Out of Scope"). All insertions mirror the existing P6 prose style so reviewers can read by analogy.

1. **Properties list** (one new bullet, right after P6): one-line declarative summary of P7 (impact-audit). Mirrors the P6 bullet shape: bold tag + parenthetical short name + colon + invariant statement.
2. **Detail section** (new H2 after the existing P6 detail section, before "Anti-patterns"): heading `## Exported-symbol Signature / Behaviour Audit (P7)`. Body has the same four labelled sub-sections as P6:
   - **Trigger** — bullet list covering signature changes (parameters added/removed/reordered/retyped, return type changed) AND observable behaviour changes (FR-003).
   - **Required `tasks.md` template** — fenced ` ```markdown ` block with a `[impact-audit]`-tagged task that mandates LSP "Find References", `rg`, or equivalent cross-codebase search, plus an explicit "update each call site OR document why none applies" step (FR-004). Same `[impact-audit]` tag convention as P6's `[rename-audit]` per spec §Assumptions.
   - **Reviewer red flag** — one paragraph naming the smoking-gun pattern (e.g. callers compiling because of lax typing or implicit any).
   - **Failure mode this prevents** — one paragraph describing the silent-caller-breakage scenario.
3. **Anti-patterns** (one new bullet appended to the existing list): "Modifying an exported symbol's signature or observable behaviour without a P7 impact-audit task" (FR-005).

### Edit 2 — `7-ui-verification.mdc`: create new file

Single new file, ~80–120 lines. Skeleton:

```text
---
description: >-
  Dev-time, in-browser visual and interactive verification invariant for any
  spec that ships a frontend change. Pairs with codified E2E, does not replace it.
globs: '**/*.tsx,**/*.jsx,**/*.vue,**/*.svelte,**/*.html,**/*.css,**/*.scss'
alwaysApply: false
tags:
  - frontend
  - quality
  - verification
  - ui
---

# UI dev-time verification

## Desired state
<one paragraph stating the invariant: every frontend spec gets a real-browser visual + interactive check before merge, via a browser MCP>

## Properties

- **P1 (visual diff)**: <declarative MUST — before/after browser snapshot at the modification site, via a browser MCP, at implementation time, not part of the codified E2E suite> (FR-009)
- **P2 (interactive validation)**: <declarative MUST that fires CONDITIONALLY when the spec introduces a new interactive element — button, form control, link, menu — requiring click/exercise in a real browser with assertion of the observable outcome against the spec> (FR-010)

## Triggers (when this rule's properties fire)

<short table or bullet list distinguishing P1 (always for frontend changes) from P2 (only when new interactive elements introduced) — addresses Edge Case "pure visual reflow"; addresses Edge Case "backend-only spec" by being silent thanks to narrow globs>

## Skill References

- [NEEDS CLARIFICATION: priority=P2] Future `skills/<ui-verification-slug>/SKILL.md` will encode the how-to (MCP choice, selector strategy, snapshot storage). Until decided, this rule states the invariant only.
- [7-testing.mdc](./7-testing.mdc) for the codified E2E suite — complementary, not a substitute.
- [5-spec-driven-dev.mdc](../05-workflows-and-processes/5-spec-driven-dev.mdc) for the spec workflow that consumes this invariant.

## Enforcement

- **Detect**: frontend spec ships without a P1 visual diff artifact; new interactive element ships without a P2 interaction trace.
- **Fix**: reopen the spec's review checkpoint; run the (forthcoming) UI-verification skill against the modified surface.
```

The body MUST stay declarative — no numbered "step 1, step 2" recipe (FR-011, SC-003).

### Verification approach (post-edit, before commit)

Run these `rg` / file-existence checks from the repo root. They are static review aids — no runtime, no Docker.

| Check | Command (pseudo — run in shell) | Pass criterion |
|-------|---------------------------------|----------------|
| P7 bullet present | `rg -n '^\- \*\*P7' rules/05-workflows-and-processes/5-spec-driven-dev.mdc` | exactly 1 match |
| P7 detail heading present | `rg -n '^## .*P7\)' rules/05-workflows-and-processes/5-spec-driven-dev.mdc` | exactly 1 match |
| Anti-pattern bullet added | `rg -n 'P7' rules/05-workflows-and-processes/5-spec-driven-dev.mdc` | ≥ 3 matches (properties list + detail + anti-pattern) |
| New file exists | `test -f rules/07-quality-assurance/7-ui-verification.mdc` | exit 0 |
| Frontmatter shape | `rg -n '^(description|globs|alwaysApply|tags):' rules/07-quality-assurance/7-ui-verification.mdc` | 4 matches in first 15 lines (SC-002) |
| Globs are narrow | `rg -n "globs:.*\\*\\*/\\*'" rules/07-quality-assurance/7-ui-verification.mdc` | zero matches (no catch-all) |
| Exactly two properties | `rg -n '^\- \*\*P[12] \(' rules/07-quality-assurance/7-ui-verification.mdc` | exactly 2 matches |
| No procedural prose | manual read for ordered "1. do X, 2. do Y, 3. do Z" recipe blocks | zero such blocks (SC-003) |
| Cross-refs resolve | `test -f rules/07-quality-assurance/7-testing.mdc && test -f rules/05-workflows-and-processes/5-spec-driven-dev.mdc` | both pass (SC-004) |
| Property numbering continuity | sequential read of P1..P7 in `5-spec-driven-dev.mdc` | no gap, no duplicate |

All commands run as `rg` / `test` against the repo. No language toolchain, no Docker image, no compile step — the Docker-only rule does not apply because no language tool is invoked.

### Side-effect: asset registry

`asset-registry.yml` at the repo root catalogues rules and skills. Adding `7-ui-verification.mdc` is an **additive** change. Two options:

1. Re-run whatever registry-refresh skill exists in this repo (deferred to TASKS phase to decide if any).
2. Append the new rule entry by hand, mirroring an existing entry shape.

Plan does not pick the option — it flags the choice for the TASKS dispatch. Either way the work is small and additive.

## Complexity Tracking

No constitution violation. No complexity tracking row required.

## Out-of-scope confirmation (echoed from spec)

- No new skill file created.
- No `AGENTS.md` edit.
- No code, no test, no automation.
- No change to any other rule.
- No renumbering of existing P1..P6 in `5-spec-driven-dev.mdc`.
