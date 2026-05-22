# Data Model — Asset Registry Classification

## 1 — Entities

### `AssetRegistry`

```text
{
  version: string                          # SemVer, "2.0.0" after this spec
  x-category-descriptions: object          # category -> human description
  x-bundle-descriptions: object            # bundle   -> human description
  x-tag-descriptions: object               # tag      -> human description
  assets: AssetEntry[]                     # ordered, hand-editable
}
```

### `AssetEntry`

```text
{
  path: string                             # repo-relative path (file or directory)
  type: "skill" | "command" | "rule" | "agent" | "hook"
  category: Category                       # REQUIRED, single, enum
  bundles?: Bundle[]                       # optional, uniqueItems, items in enum
  tags?: Tag[]                             # optional, uniqueItems, minItems:1 if present
  description?: string                     # free text, multi-line allowed
}
```

`additionalProperties: false` — unknown fields rejected (FR-006).

---

## 2 — `Category` enum (10 values, fixed)

Aligned 1:1 with `rules/00-…09-*/` folder names (FR-002).

| #   | Category                  | rules/-folder              | Meaning                                                                           |
| --- | ------------------------- | -------------------------- | --------------------------------------------------------------------------------- |
| 00  | `architecture`            | `00-architecture`          | Cross-cutting architectural invariants: hexagonal/DDD, monorepo, vertical slices, Makefile structure. |
| 01  | `standards`               | `01-standards`             | Project-wide coding/documentation standards (pure domain, indexing-friendly docs). |
| 02  | `programming-languages`   | `02-programming-languages` | Language-level rules and skills (TypeScript, Python, FP-TS conventions).          |
| 03  | `frameworks-and-libraries`| `03-frameworks-and-libraries`| Framework- or library-scoped rules and skills (NestJS, Lit, Vitest, Nuxt, React…). |
| 04  | `tools-and-configurations`| `04-tools-and-configurations`| Tooling and configuration: Docker, Git, npm, semantic commits, Bitbucket, k8s.    |
| 05  | `workflows-and-processes` | `05-workflows-and-processes`| Process and workflow rules (spec-driven dev, indexing, release workflows).        |
| 06  | `templates-and-models`    | `06-templates-and-models`  | Reusable templates and reference models.                                          |
| 07  | `quality-assurance`       | `07-quality-assurance`     | Testing, verification, accessibility, performance, security audits, UI verification. |
| 08  | `domain-specific`         | `08-domain-specific-rules` | Business-domain-bound rules (Hub, Keycloak, real-estate, …).                      |
| 09  | `other`                   | `09-other`                 | Anything that genuinely does not fit above (escape hatch; use sparingly).         |

**Constraint** (FR-005): for every asset whose `path` starts with `rules/NN-…/`, `category` MUST equal the row above. The schema expresses this as `allOf: [{ if: { properties: { path: { pattern: "^rules/04-" } } }, then: { properties: { category: { const: "tools-and-configurations" } } } }, …]`, one block per prefix.

---

## 3 — `Bundle` enum (v1: one value)

| Bundle  | Meaning                                                                                                         |
| ------- | --------------------------------------------------------------------------------------------------------------- |
| `common`| Stack-agnostic minimum starter set: install on virtually any project (Docker / Make / Git / Spec-driven / Testing / Documentation). |

`x-bundle-descriptions.common` = `"Stack-agnostic minimum-viable starter set for any project"`.

Future bundles are **candidates only** — see `research.md §6`. Do not declare them until ≥ 1 downstream project would install them as a unit.

### 3.1 — `common` bundle membership (authoritative list)

The migration MUST assign `bundles: [common]` to **exactly these assets**, and to no others.

#### Rules

| Path                                                            | Category                  | Why in `common`                                          |
| --------------------------------------------------------------- | ------------------------- | -------------------------------------------------------- |
| `rules/00-architecture/0-makefile-structure.mdc`                | `architecture`            | Docker-first execution invariant; applies everywhere.    |
| `rules/01-standards/1-code-documentation-for-indexing.mdc`      | `standards`               | Docs invariant for embedding-friendly code.              |
| `rules/04-tools-and-configurations/4-semantic-commits.mdc`      | `tools-and-configurations`| Commit hygiene for any project.                          |
| `rules/05-workflows-and-processes/5-spec-driven-dev.mdc`        | `workflows-and-processes` | Project-wide spec workflow.                              |
| `rules/05-workflows-and-processes/5-spec-indexing.mdc`          | `workflows-and-processes` | Companion to spec-driven-dev.                            |
| `rules/07-quality-assurance/7-testing.mdc`                      | `quality-assurance`       | Agnostic testing principles (TDD, pyramid, AAA).         |

#### Skills

| Path                                | Category                  | Why in `common`                                                   |
| ----------------------------------- | ------------------------- | ----------------------------------------------------------------- |
| `skills/dockerfile-multi-stage/`    | `tools-and-configurations`| Docker is treated as common per repo conventions.                 |
| `skills/multi-stage-dockerfile/`    | `tools-and-configurations`| Same. (Note: kept while the dedup decision is out of scope.)      |
| `skills/docker-expert/`             | `tools-and-configurations`| Generic Docker knowledge.                                          |
| `skills/makefile-conventions/`      | `architecture`            | Make patterns; pairs with the Makefile rule.                       |
| `skills/git-commit/`                | `tools-and-configurations`| Conventional commits; pairs with semantic-commits rule.            |
| `skills/documentation-writer/`      | `standards`               | Diátaxis documentation expert; useful on every project.            |
| `skills/find-skills/`               | `other`                   | Skill discovery; useful on every project.                          |
| `skills/systematic-debugging/`      | `quality-assurance`       | Multi-layer investigation methodology.                             |
| `skills/spec-reindex/`              | `workflows-and-processes` | Spec maintenance.                                                  |

#### Commands

| Path                                | Category                  | Why in `common`                                                   |
| ----------------------------------- | ------------------------- | ----------------------------------------------------------------- |
| `commands/commit.md`                | `tools-and-configurations`| Smart commit; pairs with the rule.                                |
| `commands/push.md`                  | `tools-and-configurations`| Routine git push helper.                                          |
| `commands/merge.md`                 | `tools-and-configurations`| Routine git merge helper.                                         |

#### Agents

| Path                                | Category                  | Why in `common`                                                   |
| ----------------------------------- | ------------------------- | ----------------------------------------------------------------- |
| `agents/dependency-updater.md`      | `tools-and-configurations`| Dependency hygiene; runs on virtually any project.                |
| `agents/gitter.md`                  | `tools-and-configurations`| Generic Git workflow agent.                                       |

**Total** common bundle: **6 rules + 9 skills + 3 commands + 2 agents = 20 assets** (SC-004 target: exact match).

Every asset currently carrying `tags: [common]` that is NOT in the table above LOSES the marker (notably `skills/hub-app-registration/`, `skills/sql-migration-guidelines/`, `skills/app-version-surface/`, `.agents/skills/*`, etc.) — those are stack-specific and don't belong in a stack-agnostic minimum.

---

## 4 — `Tag` enum (cleaned, ~40 values)

Tags are **technical or domain labels** only. Anything that means "navigation" or "preset" is forbidden.

### 4.1 — Kept

| Class               | Tags                                                                                                                     |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Languages           | `typescript`, `python`                                                                                                   |
| Functional core     | `fp-ts`                                                                                                                  |
| Frameworks / UI     | `nestjs`, `react`, `vue`, `nuxt`, `lit`, `web-components`, `astro`, `starlight`                                          |
| Persistence / data  | `prisma`, `sql`                                                                                                          |
| Domain themes       | `hub`, `keycloak`, `sentry`, `sonarqube`, `kubernetes`, `cursor`, `spec-kit`, `scraping`                                 |
| Tools               | `docker`, `docker-compose`, `git`, `github`, `bitbucket`, `make`, `npm`, `eslint`, `vitest`, `playwright`, `shell`       |
| Concerns            | `testing`, `e2e`, `tdd`, `validation`, `security`, `auth`, `debugging`, `refactoring`, `documentation`, `versioning`, `ci-cd`, `monorepo`, `css`, `frontend` |

**Count**: 42 tags (≤ 45 target, ≥ 25 % reduction from 60 → SC-007 satisfied).

### 4.2 — Removed (with reason)

| Removed tag         | Reason                                                                                  | What to do for the assets that used it                                                   |
| ------------------- | --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `common`            | Becomes a **bundle**.                                                                    | Move to `bundles: [common]` only if in the §3.1 table; otherwise drop.                  |
| `architecture`      | Becomes a **category**.                                                                 | Drop from `tags`; ensure `category` is set.                                              |
| `quality`           | Becomes a **category** (`quality-assurance`).                                            | Drop from `tags`; ensure `category: quality-assurance`.                                  |
| `workflow`          | Becomes a **category** (`workflows-and-processes`).                                      | Drop; ensure correct category.                                                           |
| `meta`              | Pseudo-tag; "rules about rules" is a category-level idea, not a tag.                     | Drop; ensure `category: architecture` or `other`.                                        |
| `rules`             | Same as above.                                                                          | Drop.                                                                                    |
| `domain`            | Becomes a **category** (`domain-specific`).                                              | Drop; ensure `category: domain-specific` if appropriate.                                 |
| `backend`           | Too coarse to be a tag; navigation handled by category.                                  | Drop; rely on framework tags (`nestjs`, `fp-ts`).                                        |
| `infrastructure`    | Overlaps with `kubernetes`, `docker`, `ci-cd`.                                           | Drop; keep the precise tool tag.                                                         |
| `devops`            | Same as above.                                                                          | Drop; keep precise tool tag.                                                             |
| `ddd`               | Single-use; the rule itself is enough scoped by category.                                | Drop.                                                                                    |
| `hexagonal`         | Single-use; same as above.                                                              | Drop.                                                                                    |
| `vertical-slices`   | Single-use; same.                                                                       | Drop.                                                                                    |
| `purity`            | Single-use; same.                                                                       | Drop.                                                                                    |
| `indexing`          | Single-use; the asset description already covers it.                                     | Drop.                                                                                    |

### 4.3 — Orphan tags (used in YAML, never declared)

| Orphan tag       | Substitution                                                                                       |
| ---------------- | -------------------------------------------------------------------------------------------------- |
| `web-analysis`   | Drop; replace with `[testing, security]` for `skills/web-analysis/` and set `category: quality-assurance`. |
| `performance`    | Drop; covered by `quality-assurance` category + skill description.                                  |
| `accessibility`  | Same.                                                                                              |
| `seo`            | Same.                                                                                              |
| `frontend`       | **Declare** as a tag (broadly useful for selecting UI assets).                                     |
| `verification`   | Drop; replace with `testing` on the offending assets.                                              |
| `ui`             | Drop; covered by `frontend` tag.                                                                   |
| `sql`            | **Declare** as a tag (used by `skills/sql-migration-guidelines/`).                                 |

### 4.4 — Tag descriptions

All `x-tag-descriptions` entries that currently start with `[NEW]` are placeholders inherited from a previous spec; the migration MUST replace them with a real one-line description or drop the tag entirely. Final descriptions live next to the schema in `$defs.tag` and are mirrored in `x-tag-descriptions` (see Phase 2 of `plan.md`).

---

## 5 — Folder → category mapping (rule assets, conditional schema constraint)

| Path prefix                                  | Required `category`        |
| -------------------------------------------- | -------------------------- |
| `rules/00-architecture/`                     | `architecture`             |
| `rules/01-standards/`                        | `standards`                |
| `rules/02-programming-languages/`            | `programming-languages`    |
| `rules/03-frameworks-and-libraries/`         | `frameworks-and-libraries` |
| `rules/04-tools-and-configurations/`         | `tools-and-configurations` |
| `rules/05-workflows-and-processes/`          | `workflows-and-processes`  |
| `rules/06-templates-and-models/`             | `templates-and-models`     |
| `rules/07-quality-assurance/`                | `quality-assurance`        |
| `rules/08-domain-specific-rules/`            | `domain-specific`          |
| `rules/09-other/`                            | `other`                    |
| `.cursor/rules/*` and `rules/*.mdc` at root  | Pick by intent; no auto-mapping (escape via `category`); rare. |

Also covers all `.cursor/rules/*.mdc` "pointer" assets — they are categorised by intent (typically `architecture` since they map to the rules tree) and the schema does NOT enforce the prefix rule for them.

---

## 6 — Non-rule asset → category mapping (skills, commands, agents)

Authoritative reference for the migration; the implementer applies this table verbatim. Path forms shown without trailing slashes for brevity.

### 6.1 — Skills

| Path                                                | Category                    | Tags (cleaned)                                       | In `common`? |
| --------------------------------------------------- | --------------------------- | ---------------------------------------------------- | :----------: |
| `skills/app-version-surface/`                       | `quality-assurance`         | `versioning`                                         |              |
| `skills/compose-env-ports/`                         | `tools-and-configurations`  | `docker`, `docker-compose`, `shell`                  |              |
| `skills/docker-compose-orchestration/`              | `tools-and-configurations`  | `docker`, `docker-compose`                           |              |
| `skills/docker-containerization/`                   | `tools-and-configurations`  | `docker`, `ci-cd`, `security`                        |              |
| `skills/docker-expert/`                             | `tools-and-configurations`  | `docker`                                             |     ✅       |
| `skills/docker-hotreload-volume/`                   | `tools-and-configurations`  | `docker`, `typescript`                               |              |
| `skills/dockerfile-dev-prod/`                       | `tools-and-configurations`  | `docker`, `ci-cd`                                    |              |
| `skills/dockerfile-multi-stage/`                    | `tools-and-configurations`  | `docker`                                             |     ✅       |
| `skills/documentation-writer/`                      | `standards`                 | `documentation`                                      |     ✅       |
| `skills/e2e-playwright/`                            | `quality-assurance`         | `docker`, `e2e`, `testing`, `playwright`             |              |
| `skills/e2e-spec-writing/`                          | `quality-assurance`         | `documentation`, `e2e`, `spec-kit`, `testing`       |              |
| `skills/eslint-solid-nestjs/`                       | `frameworks-and-libraries`  | `eslint`, `monorepo`, `nestjs`, `typescript`         |              |
| `skills/find-skills/`                               | `other`                     | `cursor`                                             |     ✅       |
| `skills/fluid-architecture-scroll-mastery/`         | `frameworks-and-libraries`  | `css`, `vue`, `web-components`, `frontend`           |              |
| `skills/fp-ts-async-practical/`                     | `programming-languages`     | `fp-ts`, `typescript`                                |              |
| `skills/fp-ts-backend/`                             | `programming-languages`     | `fp-ts`, `typescript`                                |              |
| `skills/fp-ts-errors/`                              | `programming-languages`     | `fp-ts`, `typescript`                                |              |
| `skills/fp-ts-pragmatic/`                           | `programming-languages`     | `fp-ts`, `typescript`                                |              |
| `skills/fp-ts-validation/`                          | `programming-languages`     | `fp-ts`, `typescript`, `validation`                  |              |
| `skills/gh-cli/`                                    | `tools-and-configurations`  | `git`, `github`, `shell`                             |              |
| `skills/git-commit/`                                | `tools-and-configurations`  | `git`                                                |     ✅       |
| `skills/hub-app-registration/`                      | `domain-specific`           | `auth`, `docker`, `hub`                              |              |
| `skills/hub-documentation/`                         | `domain-specific`           | `documentation`, `hub`                               |              |
| `skills/jsdoc-typescript-docs/`                     | `programming-languages`     | `documentation`, `typescript`                        |              |
| `skills/k8s-troubleshoot/`                          | `tools-and-configurations`  | `docker`, `kubernetes`                               |              |
| `skills/lit-web-components/`                        | `frameworks-and-libraries`  | `lit`, `web-components`, `frontend`                  |              |
| `skills/makefile-conventions/`                      | `architecture`              | `docker`, `make`, `monorepo`                         |     ✅       |
| `skills/mcp-chatbot-client/`                        | `frameworks-and-libraries`  | `documentation`, `nestjs`, `python`, `react`, `security`, `spec-kit`, `typescript` |              |
| `skills/mcp-server-backend/`                        | `frameworks-and-libraries`  | `documentation`, `nestjs`, `python`, `spec-kit`, `typescript`, `security` |              |
| `skills/multi-stage-dockerfile/`                    | `tools-and-configurations`  | `docker`, `ci-cd`                                    |     ✅       |
| `skills/npm-private-registry/`                      | `tools-and-configurations`  | `ci-cd`, `docker`, `monorepo`, `npm`                 |              |
| `skills/nuxt-ui/`                                   | `frameworks-and-libraries`  | `css`, `nuxt`, `vue`, `frontend`                     |              |
| `skills/nuxt/`                                      | `frameworks-and-libraries`  | `nuxt`, `vue`                                        |              |
| `skills/scroll-mastery/`                            | `frameworks-and-libraries`  | `css`, `web-components`, `frontend`                  |              |
| `skills/semantic-release-js-ts-pipeline/`           | `tools-and-configurations`  | `ci-cd`, `git`, `npm`, `versioning`                  |              |
| `skills/sentry-fix-issues/`                         | `quality-assurance`         | `debugging`, `sentry`                                |              |
| `skills/septeo-keycloak-user-register/`             | `domain-specific`           | `auth`, `keycloak`, `security`                       |              |
| `skills/sonarqube-config/`                          | `quality-assurance`         | `ci-cd`, `sonarqube`, `testing`                      |              |
| `skills/spec-reindex/`                              | `workflows-and-processes`   | `spec-kit`                                           |     ✅       |
| `skills/sql-migration-guidelines/`                  | `tools-and-configurations`  | `sql`                                                |              |
| `skills/systematic-debugging/`                      | `quality-assurance`         | `debugging`                                          |     ✅       |
| `skills/wc-live-demos-starlight/`                   | `frameworks-and-libraries`  | `astro`, `documentation`, `starlight`, `web-components`, `frontend` |              |
| `.agents/skills/documentation-writer/`              | `standards`                 | `documentation`                                      |              |
| `.agents/skills/gh-cli/`                            | `tools-and-configurations`  | `git`, `github`, `shell`                             |              |
| `.agents/skills/git-commit/`                        | `tools-and-configurations`  | `git`                                                |              |
| `.agents/skills/k8s-troubleshoot/`                  | `tools-and-configurations`  | `docker`, `kubernetes`                               |              |
| `.agents/skills/speckit-git-commit/`                | `workflows-and-processes`   | `git`, `spec-kit`                                    |              |
| `.agents/skills/speckit-git-feature/`               | `workflows-and-processes`   | `git`, `spec-kit`                                    |              |
| `.agents/skills/speckit-git-initialize/`            | `workflows-and-processes`   | `git`, `spec-kit`                                    |              |
| `.agents/skills/speckit-git-remote/`                | `workflows-and-processes`   | `git`, `github`                                      |              |
| `.agents/skills/speckit-git-validate/`              | `workflows-and-processes`   | `git`, `spec-kit`                                    |              |
| `.agents/skills/web-analysis/SKILL.md`              | `quality-assurance`         | `docker`, `security`, `testing`                      |              |

### 6.2 — Commands

| Path                                                | Category                    | Tags (cleaned)                                       | In `common`? |
| --------------------------------------------------- | --------------------------- | ---------------------------------------------------- | :----------: |
| `commands/commit.md`                                | `tools-and-configurations`  | `git`                                                |     ✅       |
| `commands/env-setup.md`                             | `tools-and-configurations`  | `docker`, `hub`                                      |              |
| `commands/improve.md`                               | `quality-assurance`         | `refactoring`, `sonarqube`                           |              |
| `commands/k8s-troubleshoot.md`                      | `tools-and-configurations`  | `docker`, `kubernetes`                               |              |
| `commands/merge.md`                                 | `tools-and-configurations`  | `git`                                                |     ✅       |
| `commands/pre-kubify.md`                            | `tools-and-configurations`  | `docker`, `kubernetes`                               |              |
| `commands/push.md`                                  | `tools-and-configurations`  | `git`                                                |     ✅       |
| `commands/scrape-site.md`                           | `other`                     | `playwright`, `scraping`                             |              |
| `commands/spec-release-and-versioning.md`           | `tools-and-configurations`  | `ci-cd`, `versioning`                                |              |
| `commands/specify-mcp-backend.md`                   | `templates-and-models`      | `documentation`, `nestjs`, `security`, `spec-kit`   |              |
| `commands/specify-mcp-chatbot.md`                   | `templates-and-models`      | `documentation`, `react`, `security`, `spec-kit`, `typescript` |              |
| `commands/specify-qa.md`                            | `quality-assurance`         | `e2e`, `spec-kit`, `testing`                         |              |
| `commands/spt.md`                                   | `workflows-and-processes`   | `cursor`, `spec-kit`                                 |              |
| `.cursor/commands/k8s-troubleshoot.md`              | `tools-and-configurations`  | `docker`, `kubernetes`                               |              |
| `.cursor/commands/speckit.analyze.md`               | `workflows-and-processes`   | `cursor`, `spec-kit`                                 |              |
| `.cursor/commands/speckit.checklist.md`             | `workflows-and-processes`   | `cursor`, `spec-kit`                                 |              |
| `.cursor/commands/speckit.clarify.md`               | `workflows-and-processes`   | `cursor`, `spec-kit`                                 |              |
| `.cursor/commands/speckit.constitution.md`          | `workflows-and-processes`   | `cursor`, `spec-kit`                                 |              |
| `.cursor/commands/speckit.fleet.review.md`          | `workflows-and-processes`   | `cursor`, `spec-kit`                                 |              |
| `.cursor/commands/speckit.fleet.run.md`             | `workflows-and-processes`   | `ci-cd`, `cursor`, `spec-kit`                        |              |
| `.cursor/commands/speckit.implement.md`             | `workflows-and-processes`   | `cursor`, `spec-kit`                                 |              |
| `.cursor/commands/speckit.plan.md`                  | `workflows-and-processes`   | `cursor`, `spec-kit`                                 |              |
| `.cursor/commands/speckit.specify.md`               | `workflows-and-processes`   | `cursor`, `spec-kit`                                 |              |
| `.cursor/commands/speckit.tasks.md`                 | `workflows-and-processes`   | `cursor`, `spec-kit`                                 |              |
| `.cursor/commands/speckit.taskstoissues.md`         | `workflows-and-processes`   | `cursor`, `github`, `spec-kit`                       |              |
| `.cursor/commands/speckit.verify.run.md`            | `workflows-and-processes`   | `cursor`, `spec-kit`, `testing`                      |              |
| `.cursor/commands/spt.md`                           | `workflows-and-processes`   | `cursor`, `spec-kit`                                 |              |
| `.specify/extensions/fleet/commands/fleet.md`       | `workflows-and-processes`   | `spec-kit`                                           |              |
| `.specify/extensions/fleet/commands/review.md`      | `workflows-and-processes`   | `spec-kit`                                           |              |
| `.specify/extensions/git/commands/speckit.git.commit.md`     | `workflows-and-processes` | `git`, `spec-kit`                                  |              |
| `.specify/extensions/git/commands/speckit.git.feature.md`    | `workflows-and-processes` | `git`, `spec-kit`                                  |              |
| `.specify/extensions/git/commands/speckit.git.initialize.md` | `workflows-and-processes` | `git`, `spec-kit`                                  |              |
| `.specify/extensions/git/commands/speckit.git.remote.md`     | `workflows-and-processes` | `git`, `github`                                    |              |
| `.specify/extensions/git/commands/speckit.git.validate.md`   | `workflows-and-processes` | `git`, `spec-kit`                                  |              |
| `.specify/extensions/verify/commands/verify.md`              | `workflows-and-processes` | `spec-kit`, `testing`                              |              |

### 6.3 — Agents

| Path                                                | Category                    | Tags (cleaned)                                       | In `common`? |
| --------------------------------------------------- | --------------------------- | ---------------------------------------------------- | :----------: |
| `agents/archivist.md`                               | `workflows-and-processes`   | `documentation`, `spec-kit`                          |              |
| `agents/cartographer.md`                            | `workflows-and-processes`   | `spec-kit`                                           |              |
| `agents/debugger.md`                                | `quality-assurance`         | `debugging`, `spec-kit`                              |              |
| `agents/dependency-updater.md`                      | `tools-and-configurations`  | `npm`                                                |     ✅       |
| `agents/gitter.md`                                  | `tools-and-configurations`  | `git`, `github`                                      |     ✅       |
| `agents/implementer.md`                             | `workflows-and-processes`   | `spec-kit`                                           |              |
| `agents/orchestrator.md`                            | `workflows-and-processes`   | `git`, `spec-kit`                                    |              |
| `agents/qa-tester.md`                               | `quality-assurance`         | `e2e`, `spec-kit`, `testing`                         |              |
| `agents/reviewer.md`                                | `quality-assurance`         | `spec-kit`                                           |              |
| `agents/scraper.md`                                 | `other`                     | `playwright`, `scraping`                             |              |
| `agents/specifier.md`                               | `workflows-and-processes`   | `spec-kit`                                           |              |
| `agents/tester.md`                                  | `quality-assurance`         | `spec-kit`, `testing`                                |              |

### 6.4 — `.cursor/rules/*.mdc` pointers (rule type, no folder prefix)

| Path                                                | Category                    | Tags (cleaned)                                       |
| --------------------------------------------------- | --------------------------- | ---------------------------------------------------- |
| `.cursor/rules/0-rules-structure.mdc`               | `architecture`              | `cursor`                                             |
| `.cursor/rules/4-specify-rules.mdc`                 | `workflows-and-processes`   | `cursor`, `spec-kit`                                 |
| `.cursor/rules/specify-rules.mdc`                   | `workflows-and-processes`   | `cursor`, `spec-kit`                                 |

(These do not fall under `rules/NN-…/`, so the schema's conditional folder rule does not apply.)

### 6.5 — `rules/NN-…/` rule entries (folder rule applies)

The category is **mechanically derived** from the folder name (§5). The cleaned tags are documented in the migration; the implementer applies §4 substitutions:

| Path                                                          | Category                    | Tags (cleaned)                                          |
| ------------------------------------------------------------- | --------------------------- | ------------------------------------------------------- |
| `rules/00-architecture/0-hexagonal-ddd.mdc`                   | `architecture`              | (drop `architecture`, `ddd`, `hexagonal` → empty; omit `tags` entirely) |
| `rules/00-architecture/0-makefile-structure.mdc`              | `architecture`              | `docker`, `make`                                        |
| `rules/00-architecture/0-monorepo.mdc`                        | `architecture`              | `monorepo`                                              |
| `rules/00-architecture/0-rules-structure.mdc`                 | `architecture`              | `cursor`                                                |
| `rules/00-architecture/0-vertical-slices.mdc`                 | `architecture`              | (drop `architecture`, `vertical-slices` → empty; omit)  |
| `rules/01-standards/1-code-documentation-for-indexing.mdc`    | `standards`                 | `documentation`                                         |
| `rules/01-standards/1-pure-domain.mdc`                        | `standards`                 | (drop `architecture`, `domain`, `purity` → empty; omit) |
| `rules/02-programming-languages/2-anti-currying.mdc`          | `programming-languages`     | `fp-ts`, `typescript`                                   |
| `rules/02-programming-languages/2-explicit-typing.mdc`        | `programming-languages`     | `typescript`                                            |
| `rules/02-programming-languages/2-pure-domain.mdc`            | `programming-languages`     | `fp-ts`, `nestjs`, `typescript`                         |
| `rules/02-programming-languages/2-semantic-jsdoc.mdc`         | `programming-languages`     | `documentation`, `typescript`                           |
| `rules/03-frameworks-and-libraries/3-flat-orchestration.mdc`  | `frameworks-and-libraries`  | `nestjs`, `typescript`                                  |
| `rules/03-frameworks-and-libraries/3-lit.mdc`                 | `frameworks-and-libraries`  | `lit`, `web-components`, `frontend`                     |
| `rules/03-frameworks-and-libraries/3-module-isolation.mdc`    | `frameworks-and-libraries`  | `nestjs`                                                |
| `rules/03-frameworks-and-libraries/3-nestjs-architecture.mdc` | `frameworks-and-libraries`  | `fp-ts`, `nestjs`, `typescript`                         |
| `rules/03-frameworks-and-libraries/3-typed-boundaries.mdc`    | `frameworks-and-libraries`  | `nestjs`, `typescript`, `validation`                    |
| `rules/03-frameworks-and-libraries/3-vitest-conventions.mdc`  | `frameworks-and-libraries`  | `testing`, `typescript`, `vitest`                       |
| `rules/03-frameworks-and-libraries/3-wc-live-demos-in-starlight.mdc` | `frameworks-and-libraries` | `astro`, `documentation`, `starlight`, `web-components`, `frontend` |
| `rules/04-tools-and-configurations/4-npm-private-registry.mdc`| `tools-and-configurations`  | `docker`, `monorepo`, `npm`, `security`                 |
| `rules/04-tools-and-configurations/4-semantic-commits.mdc`    | `tools-and-configurations`  | `git`                                                   |
| `rules/04-tools-and-configurations/4-specify-rules.mdc`       | `tools-and-configurations`  | `cursor`, `spec-kit`                                    |
| `rules/05-workflows-and-processes/5-spec-driven-dev.mdc`      | `workflows-and-processes`   | `spec-kit`                                              |
| `rules/05-workflows-and-processes/5-spec-indexing.mdc`        | `workflows-and-processes`   | `spec-kit`                                              |
| `rules/07-quality-assurance/7-testing.mdc`                    | `quality-assurance`         | `tdd`, `testing`                                        |
| `rules/07-quality-assurance/7-ui-verification.mdc`            | `quality-assurance`         | `frontend`, `testing`                                   |

---

## 7 — Migration invariants (auto-checkable)

| Invariant                                                                     | Check (Docker one-liner — see `quickstart.md`)                                                          |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Asset count unchanged.                                                        | `yq '.assets | length'` before vs after (NFR-004).                                                       |
| Every asset has a `category`.                                                 | `yq '.assets[] | select(has("category") | not)'` returns empty.                                          |
| Every `rules/NN-…/` asset has the correct folder-mapped category.             | Per-prefix `yq` queries (see `audit-queries.md`).                                                       |
| `common` never appears as a tag.                                              | `yq '.assets[] | select(.tags[]? == "common")'` returns empty.                                          |
| Common-bundle membership matches §3.1 (count = 20).                           | `yq '[.assets[] | select(.bundles[]? == "common")] | length'` = 20.                                     |
| Used tags ⊆ declared tags.                                                    | Compare `yq '.assets[].tags[]?' | sort -u` with `jq -r '."$defs".tag.enum[]' | sort -u`.                |
| Declared tags - used tags = `# reserved:` set (currently empty).              | Same diff, opposite direction.                                                                          |
| `$defs.tag.enum` size ≤ 45.                                                   | `jq '."$defs".tag.enum | length'` ≤ 45.                                                                  |
| Ajv accepts the migrated YAML.                                                | `npx ajv-cli@5 validate -s asset-registry.schema.json -d <(yq -o=json .)`.                              |
| Ajv rejects every negative fixture.                                           | Run the same command against each `contracts/fixtures/invalid-*.yml`; exit code MUST be ≠ 0 each time.  |
