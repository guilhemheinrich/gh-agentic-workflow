# Implementation Plan: Asset Registry Classification

**Branch**: `feature/013-asset-registry-classification` | **Date**: 2026-05-22 | **Spec**: [./spec.md](./spec.md)

## Summary

Refactor the project-root `asset-registry.yml` and `asset-registry.schema.json` to introduce a **three-axis classification** for every asset:

1. `category` — **required, single, enum of 10**, mirrors `rules/00-…09-*/`.
2. `bundles` — **optional, array, enum** (v1: only `common`), bootstrap presets.
3. `tags` — **optional, array, cleaned enum (~40)**, fine-grained technical / domain search.

Migrate the existing ~120 entries with **zero asset added or removed**: only the classification axes change. Bump the registry to `version: 2.0.0`. Ship a Dockerised Ajv 2020-12 validation step and a deterministic audit script.

## Technical Context

| Aspect                 | Decision                                                                                                                                                  |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **File format**        | YAML 1.2 (preserved) for the registry, JSON Schema Draft 2020-12 for the schema.                                                                          |
| **Editor integration** | `# yaml-language-server: $schema=./asset-registry.schema.json` header (kept on line 1).                                                                   |
| **Validation runtime** | `ajv-cli` (Draft 2020-12) via `node:22-alpine` Docker image — no host install required.                                                                   |
| **Audit runtime**      | `mikefarah/yq:4` + `ghcr.io/jqlang/jq:latest` + `rg` (already-present `ripgrep` Docker image) — pure CLI, no scripts.                                     |
| **Project type**       | Single-file refactor (`asset-registry.yml` + `asset-registry.schema.json`) + Docker-only audit/validation glue. No new app, no new package, no migration code beyond the YAML edit. |
| **Testing**            | **JSON Schema negative fixtures** under `specs/013-asset-registry-classification/contracts/fixtures/` covering each rejection rule (FR-008). |
| **Target platform**    | Anything that can run Docker on `linux/amd64`/`arm64`.                                                                                                    |

## Architecture Decision (high level)

This is not an application change; it is a **vocabulary and schema refactor** with one large data migration. The architecture is intentionally minimal:

```text
asset-registry.yml              ← single source of truth (data)
asset-registry.schema.json      ← contract enforcer
specs/013-.../contracts/        ← positive + negative validation fixtures
specs/013-.../quickstart.md     ← Docker one-liners for validate + audit
```

No script is added to the repo's runtime; all checks are reproducible Docker commands documented in `quickstart.md` and invokable from CI when desired.

## Technology Stack

| Component                | Technology                              | Rationale                                                                                                |
| ------------------------ | --------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Registry format          | YAML 1.2                                | Already in use; human-editable; VS Code YAML extension support.                                          |
| Schema language          | JSON Schema Draft 2020-12               | Already in use; supports `if/then`, `unevaluatedProperties`, `$defs`, conditional category-by-prefix.    |
| Validator                | Ajv 8 (Draft 2020-12) via `ajv-cli`     | De-facto standard; Dockerable; supports JSON-pointer error reporting.                                    |
| YAML→JSON transformer    | `yq` (mikefarah)                        | Stable, single-binary, Dockerable.                                                                       |
| Tag-usage audit          | `yq` + `jq` + `rg`                      | Deterministic, no language runtime needed on host.                                                       |
| CI integration (future)  | Bitbucket Pipelines step (out of scope) | Validate-on-PR can be added later by referencing the same Docker one-liners.                             |

## Project Structure

```text
.
├── asset-registry.yml                 # MUTATED — new category, bundles, cleaned tags
├── asset-registry.schema.json         # MUTATED — new $defs.category, $defs.bundle, cleaned $defs.tag, conditional folder→category rules
└── specs/
    └── 013-asset-registry-classification/
        ├── prompt.md
        ├── spec.md
        ├── plan.md                    # this file
        ├── research.md
        ├── data-model.md
        ├── quickstart.md
        ├── tasks.md
        ├── stats.md
        └── contracts/
            ├── README.md
            ├── fixtures/
            │   ├── valid-minimal.yml
            │   ├── valid-full.yml
            │   ├── invalid-missing-category.yml
            │   ├── invalid-unknown-category.yml
            │   ├── invalid-array-category.yml
            │   ├── invalid-unknown-bundle.yml
            │   ├── invalid-unknown-tag.yml
            │   ├── invalid-duplicate-tag.yml
            │   ├── invalid-common-as-tag.yml
            │   ├── invalid-extra-property.yml
            │   └── invalid-folder-category-mismatch.yml
            └── audit-queries.md      # canonical yq/jq one-liners used by quickstart.md
```

## Implementation Strategy

### Phase 1 — Schema redesign (no migration yet)

Edit `asset-registry.schema.json`:

1. Add `$defs.category` enum (10 values from data-model.md).
2. Add `$defs.bundle` enum (v1: `[common]`) and an `x-bundle-descriptions` block.
3. Add `x-category-descriptions` block to the registry root.
4. Replace `$defs.tag.enum` with the **cleaned** list from data-model.md (drop `architecture`, `quality`, `workflow`, `meta`, `rules`, `domain`, `backend`, `infrastructure`, `devops`, `common`, plus any `[NEW]` placeholders that became unused; add `sql`, `frontend`, `keycloak` if needed per data-model.md).
5. On `assetEntry`:
   - Add `category` (required, `$ref: $defs/category`).
   - Add `bundles` (optional, array of `$ref: $defs/bundle`, `uniqueItems: true`, `minItems: 1`).
   - Loosen `tags` to optional but keep `minItems: 1` and `uniqueItems: true` when present.
   - Add conditional `allOf` blocks expressing the rules/NN-folder → category constraint (FR-005). One `if/then` per folder prefix. Falls back to the migration for non-rule assets.
6. Update `x-tag-descriptions` required list to match the cleaned enum.
7. Keep `additionalProperties: false` everywhere (FR-006).

**Validation gate**: hand-craft a 1-asset YAML covering each new property → ajv accepts; one fixture per negative case → ajv rejects with the expected JSON-pointer error.

### Phase 2 — Registry migration

Edit `asset-registry.yml`:

1. Bump `version` to `2.0.0`.
2. Replace `x-tag-descriptions` content per the cleaned vocabulary; add `x-bundle-descriptions: { common: "Minimum starter set for any project" }` and `x-category-descriptions: { … }`.
3. For each existing entry (in current YAML order):
   - Assign `category` per the folder→category mapping (rules) or per the per-asset table in `data-model.md` (skills, commands, agents).
   - If the asset is in the documented common starter set, add `bundles: [common]`.
   - Rewrite `tags[]`:
     - Strip any tag now removed (`architecture`, `quality`, `workflow`, `meta`, `rules`, `domain`, `backend`, `infrastructure`, `devops`, `common`, …).
     - Replace orphan tags (`web-analysis`, `performance`, `accessibility`, `seo`, `frontend`, `verification`, `ui`) with the substitutions from `data-model.md`.
     - Drop the field entirely if the surviving list is empty (now allowed).
4. Re-sort the file by `(category, path)` to make the new structure visible at a glance (optional but recommended; documented in `quickstart.md`).

### Phase 3 — Validation and audit

1. Convert YAML → JSON via `yq -o=json` (Docker).
2. Validate JSON against the new schema via `ajv-cli` (Docker).
3. Run the three audit queries (`audit-queries.md`) and check:
   - Every asset has `category`.
   - No `common` inside `tags`.
   - Bundle `common` matches the documented starter set count.
   - Used tags ⊆ declared tags (modulo `# reserved:` comments).

Each negative fixture under `contracts/fixtures/invalid-*.yml` MUST fail ajv with a specific message — these are the "tests" of this refactor.

### Phase 4 — Documentation

1. `quickstart.md` — Docker one-liners for every check.
2. `contracts/README.md` — what each fixture proves.
3. Update top-level `README.md` (if one exists at root) with a "How to read the registry" section — out of scope if no README is present; otherwise minimal pointer paragraph only.

## Dependencies

External (Docker images, pulled at validation time):

- `mikefarah/yq:4`
- `node:22-alpine` (one-shot `npx ajv-cli@5`)
- `ghcr.io/jqlang/jq:latest` (optional, only for human-friendly audit)
- `pipelinecomponents/ripgrep:latest` (or any image carrying `rg`)

Internal: none beyond the two registry files.

## Out of Scope (re-stated)

- No CLI tool, no install pipeline, no runtime code change.
- No localisation of descriptions.
- No automatic disk-existence check for `path`.
- Bundles other than `common` are documented as candidates only.
