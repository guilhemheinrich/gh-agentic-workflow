# Data Model: Rules — Impact Audit (P7) + UI Verification

**Spec**: [spec.md](./spec.md)
**Scope**: research (Phase 1 — entity shapes for the artifacts produced by this spec)
**Date**: 2026-05-21

This spec produces text artifacts (`.mdc` rule files) governed by `rules/00-architecture/0-rules-structure.mdc`. There is no database, no API entity, no domain model in the runtime sense. The single relevant entity is the `.mdc` file itself.

---

## Entity: `RuleFile`

A versioned text artifact under `rules/{NN-category}/` describing invariants enforced on a scoped set of files.

### Frontmatter (YAML, required)

| Field | Type | Required | Constraint | Source of truth |
|---|---|---|---|---|
| `description` | string (single-paragraph, may use YAML `>-` block scalar for wrapping) | yes | Short, declarative summary of the desired state the rule enforces. Imperative-free for the rule's *own* statement (the body uses MUST/SHOULD). | `0-rules-structure.mdc` — Frontmatter section |
| `globs` | string (single glob OR comma-separated list of globs) | yes | Non-empty. Narrowed to the file set the rule applies to. Architecture-tier rules may use wide patterns; language/framework/UI rules MUST narrow by extension or path. | `0-rules-structure.mdc` — P2 |
| `alwaysApply` | boolean | yes | `true` only for repo-wide meta rules; `false` for all scoped rules. Both files produced by this spec set `alwaysApply: false`. | `0-rules-structure.mdc` — Frontmatter section |
| `tags` | list of short string labels | yes | Used for registry and search. Lowercase kebab-case is the existing convention across the rules tree. | `0-rules-structure.mdc` — Frontmatter section |

### Body (Markdown)

| Section | Type | Required | Constraint |
|---|---|---|---|
| H1 title | heading | yes | Single H1 matching the rule's subject. |
| `## Desired state` (or equivalent opening section) | prose | yes | One short paragraph stating the desired end-state in declarative voice. |
| `## Properties` | numbered list | yes | Items keyed `P1`, `P2`, … `PN`. Numbering is continuous within a single rule and additive across versions: a new property gets the next free number; existing properties keep their numbers (per spec — see Out of Scope, line 98). |
| Property detail sections (optional, per property) | prose subsections | conditional | When a property warrants more than a one-line statement, a dedicated H2 section can expand it. The four-part shape used by P6 in `5-spec-driven-dev.mdc` (Trigger / Required `tasks.md` template / Reviewer red flag / Failure mode this prevents) is the canonical template for audit-flavored properties and MUST be reused by P7 of the same file. |
| `## Anti-patterns` | bullet list | recommended | Negative examples and forbidden practices. |
| `## Skill References` | bullet list of relative links | conditional | Required when the rule defers a how-to to a skill. Each link uses a repo-relative path. |
| `## Enforcement` | two-bullet block (Detect / Fix) | recommended | Pairs each invariant with a detection heuristic and a fix recipe. |

### Invariants on the entity

1. **Single-folder placement** — a `RuleFile` lives in exactly one category folder under `rules/`; if its content spans categories it MUST be split into two `RuleFile`s. (`0-rules-structure.mdc` P1)
2. **Narrow globs** — `globs` MUST match only the files for which the rule is relevant. The narrower, the better (P2 of governing rule).
3. **Declarative body** — the body describes *invariants*, *constraints*, and *properties*. Procedural step-by-step content belongs in a skill and is linked from the rule, not inlined. (Content shape clause of governing rule)
4. **Stable property numbering** — within a single `RuleFile`, property numbers are append-only across revisions. Renumbering an existing property is forbidden because external references (`P6`, `P7`, etc.) become stale.
5. **Relative links** — cross-references between rules use repo-relative paths (e.g. `../05-workflows-and-processes/5-spec-driven-dev.mdc`), never absolute paths, never URLs.

### Mapping to artifacts produced by this spec

| Artifact path | Operation | New property numbers (within that file) | Notes |
|---|---|---|---|
| `rules/05-workflows-and-processes/5-spec-driven-dev.mdc` | modify (additive) | Adds `P7` (impact-audit). P1..P6 unchanged. | Gains one Properties-list entry, one detailed H2 section mirroring P6's four-part shape, one Anti-patterns bullet. |
| `rules/07-quality-assurance/7-ui-verification.mdc` | create | Defines `P1` (visual diff) and `P2` (interactive validation). | First revision; both properties phrased as declarative invariants, no procedural prose. |

No other `RuleFile` is created or modified.

---

## Non-entities (intentionally absent)

- **Database tables**: none. This spec ships text artifacts.
- **API surfaces**: none. See `contracts/README.md`.
- **Runtime configuration**: none.
- **Migration**: none — the additive change to `5-spec-driven-dev.mdc` does not renumber any existing property, so no consumer of the rule needs to update references.
