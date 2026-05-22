# Tasks: Asset Registry Classification (category × bundles × tags)

> Strict format: `- [ ] TXXX [P?] [USX?] Description with file path`.
> `[P]` = parallelizable (different files, no ordering dep). `[USx]` = belongs to user story x.

---

## Phase 1: Setup

**Purpose**: Stage the workspace; no asset edits yet.

- [ ] T001 Verify clean baseline — run `git status` from repo root; ensure no untracked changes outside `specs/013-asset-registry-classification/`.
- [ ] T002 Read the current `asset-registry.yml` and `asset-registry.schema.json` end-to-end to confirm the asset list matches `data-model.md §6`. If a path drifted since the spec was written, flag it in the PR description; do NOT silently invent entries.

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Land the new schema and prove it with positive/negative fixtures **before** touching `asset-registry.yml`. Migrating against an unverified schema would re-create silent drift.

- [ ] T010 [US2] Add `$defs.category` enum in `asset-registry.schema.json` with the 10 values from `data-model.md §2`.
- [ ] T011 [US1] Add `$defs.bundle` enum in `asset-registry.schema.json` with the single v1 value `common`.
- [ ] T012 [US3] Replace `$defs.tag` enum in `asset-registry.schema.json` with the cleaned vocabulary from `data-model.md §4.1` (~42 tags). Remove `architecture`, `quality`, `workflow`, `meta`, `rules`, `domain`, `backend`, `infrastructure`, `devops`, `common`, `ddd`, `hexagonal`, `vertical-slices`, `purity`, `indexing`; add `frontend`, `sql`, `keycloak`.
- [ ] T013 [US2] In `asset-registry.schema.json`, add `category` (required, `$ref: #/$defs/category`) to `assetEntry.properties` and to `assetEntry.required`.
- [ ] T014 [US1] In `asset-registry.schema.json`, add optional `bundles` (`type: array`, `items: { $ref: #/$defs/bundle }`, `uniqueItems: true`, `minItems: 1`) on `assetEntry.properties`.
- [ ] T015 [US3] In `asset-registry.schema.json`, change `assetEntry.required` so `tags` is **optional** (drop from required), but keep `uniqueItems: true` and `minItems: 1` on its schema (`data-model.md §1`).
- [ ] T016 [US2] In `asset-registry.schema.json`, add an `allOf` block on `assetEntry` with 10 `if/then` clauses enforcing the folder→category mapping for `rules/NN-…/` paths (`data-model.md §5`).
- [ ] T017 [P] [US4] In `asset-registry.schema.json`, add a root-level `x-bundle-descriptions` object (with `common` only) and `x-category-descriptions` object (with all 10 entries). Update `required` at root.
- [ ] T018 [P] [US3] In `asset-registry.schema.json`, rewrite `x-tag-descriptions` block: drop placeholders starting with `[NEW]`, drop removed tags, add real one-line descriptions for added tags (`frontend`, `sql`, `keycloak`). Sync the `required` list inside `x-tag-descriptions` with the new tag set.
- [ ] T019 Keep `additionalProperties: false` at root, on `assetEntry`, on `x-*-descriptions`. Verify with a quick read after edits.

**Checkpoint**: schema compiles cleanly with ajv against the two positive fixtures, and rejects every negative fixture (see Phase 3 below). Do NOT proceed to Phase 4 until this passes.

## Phase 3: Validation harness (gated on Phase 2)

**Purpose**: Prove the schema before any migration.

- [ ] T020 [US2] Run the positive fixture check: validate `specs/013-asset-registry-classification/contracts/fixtures/valid-minimal.yml` and `valid-full.yml` with the Docker ajv command from `quickstart.md §1`. Both MUST validate (exit 0).
- [ ] T021 [US2] Run the negative fixture loop from `quickstart.md §2`. Each of the 9 `invalid-*.yml` files MUST be rejected (exit ≠ 0). Capture the ajv error message per fixture in the PR description.
- [ ] T022 If a fixture passes when it should fail (or vice-versa), fix the schema (not the fixture) and re-run T020+T021 until they all behave as expected. Re-loop until green.

## Phase 4 — User Story 1: Bootstrap by bundle (Priority: P1) — MVP

**Goal**: `bundles: [common]` works as a starter selector.
**Independent Test**: `yq '.assets[] | select(.bundles[]? == "common") | .path' asset-registry.yml` returns exactly the 20 paths in `data-model.md §3.1`.

- [ ] T030 [US1] In `asset-registry.yml`, bump `version` to `2.0.0`.
- [ ] T031 [US1] In `asset-registry.yml`, add `x-bundle-descriptions: { common: "Stack-agnostic minimum-viable starter set for any project" }` near the top, beside `x-tag-descriptions`.
- [ ] T032 [US1] Add `bundles: [common]` to the **6 rule assets** listed in `data-model.md §3.1` (Rules sub-table) inside `asset-registry.yml`.
- [ ] T033 [US1] Add `bundles: [common]` to the **9 skill assets** listed in `data-model.md §3.1` (Skills sub-table).
- [ ] T034 [US1] Add `bundles: [common]` to the **3 command assets** listed in `data-model.md §3.1` (Commands sub-table).
- [ ] T035 [US1] Add `bundles: [common]` to the **2 agent assets** listed in `data-model.md §3.1` (Agents sub-table).
- [ ] T036 [US1] Verify exact membership: `yq '[.assets[] | select(.bundles[]? == "common")] | length'` returns `20`.

**Checkpoint**: User Story 1 fully functional and testable.

## Phase 5 — User Story 2: Navigate by category (Priority: P1)

**Goal**: every asset has the right `category`.
**Independent Test**: `yq '.assets[] | select(has("category") | not)'` returns empty.

- [ ] T040 [US2] In `asset-registry.yml`, add `x-category-descriptions: { … }` near the top with all 10 entries from `data-model.md §2`.
- [ ] T041 [P] [US2] Add `category: architecture` to every `rules/00-architecture/*.mdc` entry (5 entries; see §6.5 of data-model).
- [ ] T042 [P] [US2] Add `category: standards` to every `rules/01-standards/*.mdc` entry (2 entries).
- [ ] T043 [P] [US2] Add `category: programming-languages` to every `rules/02-programming-languages/*.mdc` entry (4 entries).
- [ ] T044 [P] [US2] Add `category: frameworks-and-libraries` to every `rules/03-frameworks-and-libraries/*.mdc` entry (6 entries).
- [ ] T045 [P] [US2] Add `category: tools-and-configurations` to every `rules/04-tools-and-configurations/*.mdc` entry (3 entries).
- [ ] T046 [P] [US2] Add `category: workflows-and-processes` to every `rules/05-workflows-and-processes/*.mdc` entry (2 entries).
- [ ] T047 [P] [US2] Add `category: quality-assurance` to every `rules/07-quality-assurance/*.mdc` entry (2 entries).
- [ ] T048 [US2] Add `category` to every `.cursor/rules/*.mdc` entry per `data-model.md §6.4` (3 entries).
- [ ] T049 [US2] Add `category` to every skill entry per `data-model.md §6.1` (covers `skills/*` and `.agents/skills/*` — ~51 entries).
- [ ] T050 [US2] Add `category` to every command entry per `data-model.md §6.2` (~35 entries).
- [ ] T051 [US2] Add `category` to every agent entry per `data-model.md §6.3` (~12 entries).
- [ ] T052 [US2] Run `quickstart.md §7` (`yq` folder⇒category check). Output MUST be empty.
- [ ] T053 [US2] Run `yq '.assets[] | select(has("category") | not) | .path' asset-registry.yml`. Output MUST be empty.

**Checkpoint**: User Story 2 fully functional and testable.

## Phase 6 — User Story 3: Filter by tag (Priority: P2)

**Goal**: tag vocabulary is small, deliberate, no `common`, no category-duplicates.

- [ ] T060 [US3] Rewrite the `x-tag-descriptions` block at the top of `asset-registry.yml` per `data-model.md §4.1` + §4.3 (drop removed tags, drop `[NEW] …` placeholders, add `frontend`, `sql`, `keycloak`). Sync with the schema's `x-tag-descriptions.required`.
- [ ] T061 [US3] For every asset in `asset-registry.yml`, rewrite its `tags[]` per the per-asset tables in `data-model.md §6`. Drop the field entirely if the cleaned list is empty (now allowed).
- [ ] T062 [US3] Run `yq '.assets[] | select(.tags[]? == "common") | .path' asset-registry.yml`. Output MUST be empty (SC-003).
- [ ] T063 [US3] Run the used-vs-declared tag diff from `quickstart.md §5` / `contracts/audit-queries.md §Q5`. The two sets MUST be equal.
- [ ] T064 [US3] Run `jq '."$defs".tag.enum | length' asset-registry.schema.json`. MUST be ≤ 45.
- [ ] T065 [US3] Run `yq '.["x-tag-descriptions"] | to_entries | map(select(.value | test("\\[NEW\\]"))) | length' asset-registry.yml`. MUST be `0` (SC-008).

**Checkpoint**: User Story 3 fully functional and testable.

## Phase 7 — User Story 4: VS Code autocomplete (Priority: P2)

- [ ] T070 [US4] Confirm `# yaml-language-server: $schema=./asset-registry.schema.json` is still line 1 of `asset-registry.yml` after the migration.
- [ ] T071 [US4] Open `asset-registry.yml` in VS Code with the YAML extension; verify autocomplete proposes the 10 categories on `category:`, the bundle `common` on `bundles:`, and the cleaned tag list on `tags:`. Document the result (one screenshot or a short note) in the PR description.

## Phase 8 — Cross-cutting verification (gates merge)

- [ ] T080 Run the full validation from `quickstart.md §1` against the migrated `asset-registry.yml`. MUST exit 0.
- [ ] T081 Re-run the negative-fixture loop (`quickstart.md §2`). All 9 fixtures MUST still be rejected.
- [ ] T082 Run `quickstart.md §3` (assets per category report) and capture the output in the PR description. Spot-check 5 random entries against `data-model.md §6`.
- [ ] T083 Run `quickstart.md §4` (bundle membership report). `common` count MUST equal `20`.
- [ ] T084 Run `quickstart.md §8` (asset count before/after). The two integers MUST be **equal** (NFR-004).
- [ ] T085 Run two consecutive invocations of `quickstart.md §3` and diff their outputs → MUST be byte-identical (SC-009).
- [ ] T086 [rename-audit] Cross-codebase audit of every reference to the OLD meaning of `tags: [common]`:
  - `rg -n "common" asset-registry.yml` MUST not appear inside any `tags:` list (only inside `bundles:` or `x-bundle-descriptions:`).
  - `rg -n "tags:.*common" asset-registry.yml` MUST be empty.
  - Comments in `asset-registry.yml`, the README (if any references the registry), and other specs under `specs/` that mention `tag common` MUST be updated to "bundle common" or marked as historical.
  - Acceptance: zero remaining matches outside `specs/013-asset-registry-classification/` historical references and the prompt.
- [ ] T087 [impact-audit] Cross-codebase impact audit of any consumer that reads `asset-registry.yml`:
  - `rg -nF "asset-registry"` from the repo root — enumerate every reader (docs, scripts, agents, other registries).
  - For each hit, confirm it does NOT depend on `tags` being required or on `common` being a tag. If it does, update the consumer to read `category` / `bundles` instead, OR document explicitly why no change is needed.
  - Tests/scripts asserting the OLD shape — REWRITE to assert the new shape.
  - Acceptance: zero uncovered consumers; every consumer either updated or explicitly documented as unaffected.

## Phase 9: Polish & Cross-Cutting

- [ ] T090 [P] Update `specs/013-asset-registry-classification/stats.md` end-of-session entry (date, model, file count, status).
- [ ] T091 [P] Re-read `spec.md §Success Criteria` and tick each SC against the actual results, capturing the measured value (e.g. "SC-007: tag enum went from 60 → 42 = 30% reduction ✅").
- [ ] T092 If any SC failed, open a follow-up task in the same `tasks.md` rather than silently relaxing the criterion.

---

## Dependency Graph

```text
Phase 1 (Setup)
   └─> Phase 2 (Foundational: schema)
          └─> Phase 3 (Validation harness — gate)
                 └─> Phase 4 (US1: bundles)  ─┐
                       Phase 5 (US2: category)─┤
                       Phase 6 (US3: tags)    ─┼─> Phase 8 (Verification gate)
                       Phase 7 (US4: VS Code) ─┘         └─> Phase 9 (Polish)
```

Phases 4, 5, 6 each MUTATE `asset-registry.yml`; they are **sequential** (same file). Tasks T041–T047 inside Phase 5 are `[P]` only because they touch disjoint entries inside the same file, but the implementer SHOULD merge them into one editing pass to avoid YAML merge friction.

## Summary

- Total tasks: 60
- By priority: P1 = 17 (Phases 4 + 5), P2 = 12 (Phases 6 + 7), Foundational + Verification = 31.
- Estimated effort (senior dev, manual): ~1.5 person-days.
- Single deliverable: a clean `asset-registry.{yml,schema.json}` pair + 11 fixtures + this spec set.
