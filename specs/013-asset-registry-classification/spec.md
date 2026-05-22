# Feature Specification: Asset Registry Classification (category × bundles × tags)

**Feature Branch**: `013-asset-registry-classification`
**Created**: 2026-05-22
**Status**: Draft
**Input**: Refactor `asset-registry.yml` and its JSON Schema to introduce a 3-axis classification (`category`, `bundles`, `tags`) so that bootstrapping a project from the registry becomes obvious instead of tag-archaeology.

---

## Context

The repository hosts AI assets of three primary kinds:

- **Skill** — describes HOW to do something.
- **Command** — describes an OBJECTIVE to achieve.
- **Rule** — describes a STRUCTURE / STATE to respect.
- (Plus secondary types already present: `agent`, `hook`.)

The current `asset-registry.yml` (~120 entries, `version: 1.0.0`) leans almost exclusively on a single `tags` axis. This produces three pathologies:

1. **Mixed semantics at one level**: `common` (a bootstrap preset), `architecture` (a topic), `docker` (a tool), `quality` (a concern), and `typescript` (a language) all live in the same `tags[]` array, so the reader cannot tell *what* a tag is for.
2. **Granularity drift**: the schema currently declares **~60 tags**; many are single-use (`purity`, `vertical-slices`, `domain`, `ddd`, `hexagonal`, `indexing`, `meta`, `starlight`, …) and several are flat duplicates of a folder name. Worse, the YAML uses tags that are **not declared in the schema** at all (`web-analysis`, `performance`, `accessibility`, `seo`, `frontend`, `verification`, `ui`) — meaning either the schema is silently ignored or validation has never been enforced end-to-end.
3. **No bootstrap path**: a newcomer wanting "the minimum sane set for any project" must grep `common` across `tags[]` and discover, after the fact, that the intent of `common` is a *preset* and not a *theme*.

The folder tree under `rules/` already encodes a clean taxonomy (`00-architecture`, `01-standards`, … `09-other`) that the registry does **not** mirror. This spec aligns the registry with that taxonomy and separates the three concerns.

---

## User Scenarios & Testing (mandatory)

### User Story 1 — Bootstrap a new project from a named bundle (Priority: P1)

As a developer onboarding a new project, I want to install a curated **starter set** of rules, skills, and commands without reading every entry, so that I get a sane default in one selector.

**Why this priority**: This is the headline pain. Today a newcomer has to read the entire registry and reverse-engineer what `common` means; tomorrow they read one line: `bundle: common`.

**Independent Test**: Run a YAML query (`yq '.assets[] | select(.bundles[]? == "common") | .path'`) → returns the documented minimum-viable starter set defined in `data-model.md`; no asset outside that set is returned.

**Acceptance Scenarios**:

1. **Given** the new `asset-registry.yml` with `bundles` declared, **When** I select `bundles: [common]`, **Then** I get the documented common starter set (Docker, Makefile, semantic commits, spec-driven workflow, testing principles, documentation writer skill, git skill — see data-model.md).
2. **Given** I pick a bundle name not declared in the schema, **When** the registry is validated, **Then** validation fails with a clear "unknown bundle" error.
3. **Given** I read any asset entry, **When** I look for `common`, **Then** it is **only** under `bundles[]` and **never** under `tags[]`.

---

### User Story 2 — Navigate the registry by category (Priority: P1)

As a maintainer adding a new asset, I want to put it in one obvious top-level bucket, so I do not have to invent yet another tag.

**Why this priority**: `category` becomes the single navigation axis; tags become optional fine-grained search. Without this, the duplicate-tag drift restarts.

**Independent Test**: Run `yq '.assets[] | select(.category == "tools-and-configurations") | .path'` → returns every Docker/Make/Git/Bitbucket/etc. asset; no rule under `rules/04-*/` is missing.

**Acceptance Scenarios**:

1. **Given** the new schema, **When** I list assets with `category == "frameworks-and-libraries"`, **Then** I get all NestJS / Lit / Vitest / Web-Components rules and skills, with **zero** misclassifications.
2. **Given** any rule under `rules/XX-name/`, **When** I read its registry entry, **Then** `category` matches the folder mapping (XX → name) defined in data-model.md.
3. **Given** an asset entry omits `category`, **When** the registry is validated, **Then** validation fails with a "missing category" error.
4. **Given** an entry declares two categories or an unknown category, **When** the registry is validated, **Then** validation fails.

---

### User Story 3 — Filter by precise technical tag (Priority: P2)

As an agent assembling context for a specific stack, I want to filter by a small, deliberate set of technical tags (e.g. `docker`, `typescript`, `nestjs`) without those tags overlapping with categories or bundles.

**Why this priority**: Tags remain useful, but only as the *third* axis. The cleanup is what makes them trustworthy.

**Independent Test**: Run `yq '.assets[] | select(.tags[]? == "nestjs") | .path'` → returns NestJS-specific assets only; verify count is consistent before/after migration (no NestJS asset lost).

**Acceptance Scenarios**:

1. **Given** the cleaned tag vocabulary, **When** I read `$defs.tag.enum` in the schema, **Then** the list contains **no** entries that duplicate a category (`architecture`, `quality`, `workflow`, `meta`, `rules`) and **no** `common`.
2. **Given** the cleaned vocabulary, **When** I diff "used tags" vs "declared tags", **Then** the two sets are equal except for tags explicitly documented as "reserved for upcoming assets".
3. **Given** I tag an asset with a string not in the enum, **When** I validate, **Then** validation fails with "unknown tag".

---

### User Story 4 — Editing the registry stays human-friendly in VS Code (Priority: P2)

As a maintainer, I want VS Code (with the YAML extension and the `$schema` comment) to autocomplete `category`, `bundles`, and `tags`, and to flag mistakes inline, so I do not have to run a CLI to find typos.

**Why this priority**: Hardening validation without ergonomic feedback would push maintainers to bypass the schema, recreating today's drift.

**Independent Test**: Open `asset-registry.yml` in VS Code with the YAML extension installed → autocomplete proposes the 10 categories on `category:`, the declared bundles on `bundles:`, and the cleaned tag vocabulary on `tags:`.

**Acceptance Scenarios**:

1. **Given** the `# yaml-language-server: $schema=...` directive is preserved, **When** I open the file in VS Code, **Then** autocomplete works for the three classification fields.
2. **Given** I introduce an unknown property at the asset level (e.g. `categories: [...]` plural), **When** I save, **Then** the YAML extension highlights it as invalid (because `additionalProperties: false`).

---

## Edge Cases

- **Asset whose category is ambiguous between two folders** (e.g. a skill that is "testing × tooling" or "frontend × architecture"). Resolution: the maintainer picks the category that best reflects the asset's *primary intent*; ambiguity is handled with `tags`, never with multiple categories.
- **Asset that is part of multiple bundles** (e.g. a Docker rule that belongs to both `common` and a future `backend` bundle). Supported: `bundles[]` is a list. Out of scope for v1: only `common` is declared.
- **A tag becomes single-use after migration**. Acceptable only if it is a precise technical label (`prisma`, `sentry`, `keycloak`). It is *not* acceptable for a label that means "navigation" — those become categories or are dropped.
- **A schema-declared tag is unused** after migration. Allowed only with an inline comment justifying the reservation; otherwise it must be removed from the enum.
- **A path referenced in the registry no longer exists on disk**. Out of scope for v1 schema validation (handled by a separate audit tool, kept as a known gap in `assumptions`).
- **`common` collision**: the legacy `common` tag MUST be removed from the schema's tag enum to forbid accidental reintroduction; bundle and tag namespaces are independent enums.

---

## Requirements (mandatory)

### Functional Requirements

- **FR-001**: The system MUST extend `asset-registry.schema.json` to add two new asset-level properties: `category` (single string, required, enum) and `bundles` (array of strings, optional, items from a declared enum, unique).
- **FR-002**: The `category` enum MUST be exactly the ten values: `architecture`, `standards`, `programming-languages`, `frameworks-and-libraries`, `tools-and-configurations`, `workflows-and-processes`, `templates-and-models`, `quality-assurance`, `domain-specific`, `other` (aligned with the `rules/00-…09-*/` folder layout).
- **FR-003**: The `bundles` enum MUST declare `common` in v1; the schema MUST be designed to accept future additions without breaking changes (open enum mechanism via `$defs.bundle`).
- **FR-004**: The schema MUST forbid `common` from appearing inside `tags[]` (either by removing it from the tag enum, or by an explicit `not` constraint).
- **FR-005**: For every asset whose `path` starts with `rules/NN-folder/`, `category` MUST equal the canonical category derived from the folder name (folder→category mapping documented in `data-model.md`); the schema MUST express this constraint where possible (per-prefix `if/then` blocks), and the migration MUST guarantee it for the rest.
- **FR-006**: The schema MUST keep `additionalProperties: false` at the asset entry level so that unknown fields (e.g. `categories` plural typo) are rejected.
- **FR-007**: The schema MUST reject duplicate values inside `tags[]` and inside `bundles[]` (`uniqueItems: true` on both).
- **FR-008**: The schema MUST reject unknown values inside `category`, `bundles[]`, and `tags[]` with messages that name the offending value.
- **FR-009**: The registry MUST remain a single YAML file at the repo root, editable by hand, with a `# yaml-language-server: $schema=./asset-registry.schema.json` directive on line 1 (preserved from today).
- **FR-010**: The `version` field at the top of the YAML MUST be bumped to a new MAJOR (`2.0.0`) reflecting the breaking schema change (new required `category` field).
- **FR-011**: The migration MUST assign a `category` to every existing asset; **zero** assets may be left without one.
- **FR-012**: The migration MUST tag with `bundles: [common]` exactly the assets explicitly identified as the **minimum-viable starter set** in `data-model.md` (no other asset may carry `bundles: [common]` after migration).
- **FR-013**: The migration MUST clean the tag vocabulary:
  - Remove tags that are now categories: `architecture`, `quality`, `workflow`, `meta`, `rules`, `domain`, `backend`, `infrastructure`, `devops` (categorise them as `category` or `bundles` or drop entirely if redundant).
  - Remove `common` from the tag enum entirely.
  - Drop tags that became zero-use after the migration (or, if intentionally reserved, document them in a `# reserved:` comment block in the YAML AND keep them in `$defs.tag.enum`).
  - Merge near-duplicates following the table in `data-model.md` (e.g. `verification` → `testing` if appropriate, `ui` + `frontend` → `frontend` or dropped).
- **FR-014**: The migration MUST register every tag actually used in `asset-registry.yml` inside the schema's `$defs.tag.enum`. After migration, the symmetric difference between *used tags* and *declared tags* MUST be empty (modulo documented reservations).
- **FR-015**: The `x-tag-descriptions` block in both the YAML and the schema MUST be updated to match the final tag vocabulary (no entry whose value starts with `[NEW]` placeholder may survive).
- **FR-016**: The schema MUST keep the existing `path`, `type`, `description?` fields with their current semantics; `tags` becomes **optional** (it is no longer the primary axis), but if present MUST have `minItems: 1` and pass enum validation.
- **FR-017**: A validation procedure MUST exist and be runnable from the repo root via a documented Dockerised command (Ajv 2020-12 or equivalent), with exit code ≠ 0 on any violation. The command MUST be reproducible without local Node install.
- **FR-018**: A reverse audit procedure MUST exist (and be documented in `quickstart.md`) that produces three deterministic reports:
  1. Assets per category (one line per asset, sorted by category then path).
  2. Asset-count per bundle.
  3. Tag usage histogram with orphan / unused tags flagged.

### Non-Functional Requirements

- **NFR-001**: The YAML MUST remain plain text, hand-editable, and renderable without preprocessing.
- **NFR-002**: The schema MUST stay compatible with JSON Schema Draft 2020-12 and the VS Code YAML extension.
- **NFR-003**: The validation command MUST complete in under 5 seconds on the existing ~120-asset registry.
- **NFR-004**: The migration MUST be a **pure transformation** of the existing YAML: no asset added, none removed, none renamed. Only the classification axes (`category`, `bundles`, `tags`) and the schema change.

---

## Key Entities

- **AssetEntry**: `{ path: string, type: AssetType, category: Category, bundles?: Bundle[], tags?: Tag[], description?: string }`.
- **AssetType**: enum `skill | command | rule | agent | hook` (unchanged).
- **Category**: enum of 10 values mirroring the `rules/00-…09-*/` taxonomy. **Required, single, no plural form, no array.**
- **Bundle**: enum (v1: `common`); optional list per asset.
- **Tag**: cleaned enum; optional list per asset; technical / domain labels only.
- **AssetRegistry**: `{ version: string, x-tag-descriptions: object, x-bundle-descriptions: object, x-category-descriptions: object, assets: AssetEntry[] }`.

---

## Success Criteria (mandatory, measurable, tech-agnostic)

- **SC-001**: 100 % of asset entries have a `category` value belonging to the declared enum. Measurement: a one-line `yq` query reports zero offenders.
- **SC-002**: 100 % of assets under `rules/NN-folder/` have a `category` equal to the documented folder→category mapping. Measurement: deterministic mapping script reports zero mismatches.
- **SC-003**: The string `common` appears **zero** times inside any `tags[]` array across the whole YAML. Measurement: `rg -F "- common"` scoped to tag blocks returns nothing.
- **SC-004**: The minimum-viable starter set documented in `data-model.md` is exactly the set of assets carrying `bundles: [common]`; size matches expected count ±0.
- **SC-005**: The symmetric difference between "tags used in `asset-registry.yml`" and "tags declared in `$defs.tag.enum`" is **empty** (except for entries explicitly marked `# reserved:` in the schema and in `x-tag-descriptions`).
- **SC-006**: The validation command (FR-017) exits 0 against the migrated registry and exits ≠ 0 against each of the negative fixtures (unknown category, unknown bundle, unknown tag, duplicate tag, `common` used as a tag, missing `category`, `category` as an array, unknown extra property).
- **SC-007**: The number of declared tags decreases by at least 25 % vs the current 60-tag enum (target: ≤ 45 tags). Measurement: `len($defs.tag.enum)` before vs after.
- **SC-008**: No tag in `$defs.tag.enum` has a description that still starts with the `[NEW]` placeholder.
- **SC-009**: The three reports of FR-018 are reproducible and stable: running the audit twice in a row produces byte-identical output.
- **SC-010**: A maintainer can add a new asset entry in VS Code and obtain autocomplete on `category`, `bundles`, and `tags` from the schema (manual verification documented in `quickstart.md`).

---

## Assumptions

- The taxonomy alignment with `rules/00-…09-*/` is treated as authoritative for the `category` axis; if the folder tree is ever renamed, the schema MUST be updated in the same change.
- v1 only declares the `common` bundle. Bundle names like `frontend`, `backend`, `nest-stack`, `vue-stack`, `hub-app` are **candidates** documented in `research.md` but explicitly out of scope.
- v1 keeps `tags` optional. An asset MAY have zero tags if `category` is sufficient for discovery. This is a deliberate softening of the v1 `minItems: 1` constraint, traded against the cleanup objective.
- v1 does not introduce a separate CLI; validation and audit run through documented Dockerised one-liners. A standalone tool is a follow-up spec.
- The audit and migration scripts may use `yq`, `ajv-cli`, and `rg`, all runnable via Docker images (no host install required) per the repo's Docker-first convention.

---

## Out of Scope

- A CLI/TUI to browse the registry.
- Programmatic bundle composition (e.g. `bundles: [common, +frontend, -docker]` set algebra).
- Auto-installation of assets into a target project (this spec only fixes the *classification*, not the *install pipeline*).
- Asset-existence validation (path on disk).
- Migrating user-level / plugin-cache asset registries (only `asset-registry.yml` at repo root).
- Localisation of `x-*-descriptions` (kept in current French/English mix; not changed by this spec).
