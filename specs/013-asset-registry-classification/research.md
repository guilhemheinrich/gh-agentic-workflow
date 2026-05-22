# Research — Asset Registry Classification

## 1 — Why three axes instead of one richer tag system

### Observed pathology

The current registry treats `tags[]` as the universal axis. Across ~120 assets and ~60 declared tags we see:

| Tag class                      | Examples                                                                | Problem                                                                                  |
| ------------------------------ | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Bootstrap intent (preset)      | `common`                                                                | Means "install this on every project"; semantically a preset, not a topic.               |
| Folder-mirror (navigation)     | `architecture`, `workflow`, `rules`, `meta`, `quality`                  | Duplicate of the `rules/00-…09-*/` folder name; primary navigation, not a search facet.  |
| Technology (true tag)          | `docker`, `typescript`, `nestjs`, `prisma`                              | Genuine search facet — keep as `tags`.                                                   |
| Concern (true tag)             | `testing`, `security`, `documentation`, `validation`                    | Genuine fine-grained search facet — keep.                                                |
| Single-use placeholder         | `[NEW] purity`, `[NEW] vertical-slices`, `[NEW] ddd`, `[NEW] hexagonal` | Tag invented for one asset; not search-useful.                                           |
| Orphan in YAML (not in schema) | `web-analysis`, `performance`, `accessibility`, `seo`, `ui`, `frontend` | Tag used in `asset-registry.yml` but absent from `$defs.tag.enum` — silent validation failure. |

### Decision

Split the axes:

- `category` → navigation (the answer to "where does this asset live in the mental tree?").
- `bundles` → bootstrap selectors (the answer to "what minimum set do I install?").
- `tags`    → fine-grained technical/domain labels (the answer to "what stack does this assume?").

This mirrors how teams already think about the assets when bootstrapping a project: first they want a *bucket*, then a *starter pack*, then *technology-specific* extras.

### Alternative considered — keep one axis, add tag namespaces

E.g. encode prefixes: `cat:tools-and-configurations`, `bundle:common`, `tech:docker`. Rejected:

- Hard to validate cleanly (the enum becomes a regex zoo).
- VS Code autocomplete becomes noisier, not helpful.
- The category vs bundle distinction must be enforced *structurally*, not by string convention, to prevent the same drift recurring.

### Alternative considered — drop `bundles` from v1, only `category` + `tags`

Rejected because the headline pain in the user request is "bootstrap a project". Without a named preset, the maintainer has to enumerate categories *and* tags to recreate "common", and the user would re-implement the very concept we are eliminating.

---

## 2 — Why `category` mirrors `rules/00-…09-*/`

`rules/` already encodes a curated 10-bucket taxonomy that has survived several feature waves. Adopting it as the registry's primary axis:

1. Removes the cognitive overhead of maintaining two taxonomies in parallel.
2. Makes the `rules/NN-folder → category` constraint *trivial to verify* (a single mapping table, expressible as JSON Schema `if/then/properties` per prefix).
3. Reuses existing maintainer intuition: when someone adds a new rule under `rules/04-tools-and-configurations/`, the category is mechanically obvious.

For non-rule assets (skills, commands, agents), the same 10 buckets are wide enough that *every* current asset fits without inventing new ones. The per-asset assignments are documented in `data-model.md`.

---

## 3 — Why `bundles` is an enum, not a free list

Free strings would re-create today's drift. Enum-validated bundle names make:

- VS Code autocomplete useful on the `bundles:` line.
- Negative validation reject typos (`bundles: [comon]`).
- The bundle catalog discoverable by reading the schema's `$defs.bundle.enum`.

v1 declares **only** `common`. Future bundles (`frontend`, `backend`, `nestjs-stack`, `vue-stack`, `hub-app`) are documented as candidates in section 6 below but not introduced until the demand is concrete (avoids the "one-item category" anti-pattern).

---

## 4 — Tag-vocabulary cleanup methodology

Process (deterministic, repeatable):

1. **Inventory used tags**: `yq '.assets[].tags[]?' asset-registry.yml | sort -u`.
2. **Inventory declared tags**: `jq -r '."$defs".tag.enum[]' asset-registry.schema.json | sort -u`.
3. **Symmetric difference** → split into:
   - **Orphans** (used, not declared) → either declare or substitute per the table in `data-model.md`.
   - **Unused** (declared, never used) → drop unless explicitly reserved with a `# reserved:` comment.
4. **Reclassify**: every tag whose meaning belongs to `category` (architecture, quality, …) or `bundles` (common) is removed from `$defs.tag.enum`.
5. **Merge near-duplicates** per the substitution table in `data-model.md` (e.g. `verification` → `testing`, `ui` → `frontend`).

The result is a vocabulary of ~40 tags vs today's 60 — a ≥25 % reduction (SC-007).

---

## 5 — Why YAML stays the storage format

| Option                       | Pros                                                | Cons                                                                        | Verdict                |
| ---------------------------- | --------------------------------------------------- | --------------------------------------------------------------------------- | ---------------------- |
| Stay on YAML                 | Human-editable, comment support, in-place schema directive, VS Code autocomplete already wired. | Whitespace-sensitive, harder for some shell pipelines.                       | **Chosen.**            |
| Switch to JSON               | One less conversion step for ajv.                   | Loses comments (we use them for `# reserved:` tags), loses readability.      | Rejected.              |
| Switch to TOML               | Comment-friendly, less indentation-sensitive.       | Worse fit for nested arrays of objects; VS Code schema integration weaker.   | Rejected.              |
| Generate YAML from a DSL     | Single source of truth, custom validation.          | Adds a code generator and a runtime; defeats "human-editable" requirement.   | Rejected.              |

---

## 6 — Candidate bundles (NOT introduced in v1)

Documented here so the design doesn't surprise the next maintainer who needs them. Each is a *hypothesis* awaiting a concrete need before being declared.

| Candidate bundle | Hypothetical scope                                                                                  | Pre-flight question                                                  |
| ---------------- | --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `frontend`       | Web Components / UI verification / CSS / Lit / Astro assets.                                        | Are there ≥ 3 distinct frontend bootstrap projects that need this?   |
| `backend`        | NestJS architecture, hexagonal/DDD rules, fp-ts skills, npm private registry.                       | Is there a recurring backend-only template?                          |
| `nest-stack`     | The `backend` set restricted to the NestJS opinionated stack.                                       | Distinct enough from `backend` to justify a separate bundle?         |
| `vue-stack`      | Nuxt / nuxt-ui / Vue skills.                                                                        | Same as above.                                                       |
| `hub-app`        | Hub registration, Hub documentation, Keycloak, common Hub plumbing.                                 | Will Hub apps reuse a shared bootstrap?                              |
| `e2e-only`       | Playwright / e2e-spec-writing / Cypress-style assets.                                               | Useful as an add-on bundle on top of `common`?                       |
| `versioning`     | semantic-release pipeline, app-version-surface, commit hygiene.                                     | Tightly coupled trio; might justify a bundle once a second project adopts. |

**Decision rule**: do not declare a bundle until at least one downstream project would clearly install it as a unit. Otherwise re-create today's drift in a new form.

---

## 7 — Validation runtime — ajv vs alternatives

| Option                              | Verdict                                                                                                                                  |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `ajv-cli` (Node, Draft 2020-12)     | **Chosen.** Fast, mature, ships JSON-pointer error messages, runs in a one-shot `node:22-alpine` container without local install.        |
| `check-jsonschema` (Python)         | Mature but its Draft 2020-12 support lagged behind ajv historically; ajv is closer to the canonical reference.                           |
| Hand-rolled validator in TypeScript | Adds runtime code and a build step; redundant with ajv.                                                                                  |
| VS Code "Save → validate"           | Already there for editing, but cannot serve as the gate; we need a CI-grade exit code.                                                   |

---

## 8 — Risks and mitigations

| Risk                                                                                                            | Mitigation                                                                                                                       |
| --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Migration accidentally drops an asset.                                                                          | NFR-004 forbids it. Sanity check: `yq '.assets | length'` before vs after MUST match.                                            |
| A maintainer reintroduces `common` as a tag after the migration.                                                | Schema removes `common` from `$defs.tag.enum`; ajv rejects on validation.                                                        |
| A category becomes ambiguous (e.g. a hub skill that is "domain" and "framework").                               | Spec rule: pick *primary intent*, surface the secondary aspect via `tags`. Documented in `data-model.md`.                        |
| Tag enum keeps growing back.                                                                                    | Audit query (FR-018) flags every tag with a single use; review monthly (out of scope for this spec, but the query is provided).  |
| VS Code autocomplete fails because the `$schema` header is lost.                                                | The first task explicitly preserves line 1.                                                                                      |
| Ajv refuses Draft 2020-12 features (e.g. `prefixItems`).                                                        | Schema sticks to widely-supported features (`enum`, `if/then`, `additionalProperties`, `$ref`, `$defs`, `uniqueItems`).          |
| Conditional folder→category constraint becomes hard to read.                                                    | Expressed as a single `allOf` with one `if/then` block per prefix; documented in `contracts/README.md`.                          |
