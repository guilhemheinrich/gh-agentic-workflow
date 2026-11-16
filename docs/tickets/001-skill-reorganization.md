# Ticket 001 — Reorganize skills into thematic plugins before the first publication

Status: proposed (not started). Owner decision needed on the open questions at the end.

## Why now

`scripts/build-plugins.mjs` currently turns each registry `category` into one
plugin (11 plugins today). Categories were never designed as product
boundaries, so the split is uneven (`tools-and-configurations` holds 18 skills,
`other` holds 0 skills and 2 non-skill assets) and 10 cross-plugin reference
links exist. Plugin names become part of every skill's public name
(`<plugin>:<skill>`). Renaming after the first publication breaks every
installed user, so the taxonomy has to be settled **before** the first release.

## Findings (86 skills, measured on `main` at abab37f)

### 1. Near-duplicate clusters that should become one skill

| Cluster | Skills (lines) | Proposal |
|---|---|---|
| fp-ts | `fp-ts-pragmatic` (605), `fp-ts-errors` (863), `fp-ts-validation` (907), `fp-ts-async-practical` (960), `fp-ts-backend` (1332) — 4,667 lines | One `fp-ts` skill: short `SKILL.md` (when to use what) + `references/{pragmatic,errors,validation,async,backend}.md`. |
| Dockerfile | `dockerfile-multi-stage` (49), `multi-stage-dockerfile` (300), `dockerfile-dev-prod` (260), `docker-containerization` (102), `docker-expert` (425) | One `dockerfile` skill; keep `docker-hotreload-volume` separate (a distinct pattern). |
| Code documentation | `jsdoc-typescript-docs`, `docstring-python-docs`, `godoc-go-docs`, `phpdoc-php-docs`, `rustdoc-rust-docs` (+ `documentation-writer`, Diátaxis) | One `code-documentation` skill with one reference file per language; `documentation-writer` stays as the structure/method skill. |
| Scroll layout | `scroll-mastery` (54), `fluid-architecture-scroll-mastery` (56) | One skill. |
| "Show what changed" | `eza-file-overview` (377), `change-projection` (350) | Check overlap; likely merge or make one reference the other. |
| Adversarial review transport | `cursor-adversarial-review` (657), `openrouter-adversarial-review` (731), `adversarial-review-convergence` (363) | Keep three (different transports + a method) but group in one plugin and cross-link. |

Note on fp-ts: the library the owner could not name is **fp-ts** (pure
functions, `Either`, `TaskEither`, `pipe`). Before investing in the merge,
check whether fp-ts is still the right target or whether its successor in the
Effect ecosystem should be covered instead.

### 2. Oversized skills (progressive-disclosure problem)

`docker-compose-orchestration` (2,239 lines), `gh-cli` (2,194), `hub-app-registration`
(1,313), `linear-tracker` (1,018). A skill body is loaded in full when it
triggers; move reference material to `references/` and keep `SKILL.md` under
roughly 300 lines.

### 3. Candidates to drop, rework or move out of the public marketplace

- **Spec-kit leftovers.** Spec-kit was removed from this repo, but 49 references
  to `/specify`, `/plan`, `/tasks`, `/speckit.*` remain (all listed in the
  builder's `externalReferences`). Skills that only make sense with spec-kit:
  `spec-reindex`, `e2e-spec-writing`, `notion-spec-sync`, `mcp-server-backend`,
  `mcp-chatbot-client` (spec generators). Decide: drop, or rewrite without
  spec-kit.
- **Organization-specific (Septeo / Modelo Hub).** `hub-app-registration`,
  `hub-documentation`, `septeo-keycloak-user-register`,
  `model-tenant-agency-user-db`, `app-version-surface` (check). These are of no
  use to outside users and may expose internal details: put them in a separate
  private plugin/marketplace, or do not publish.
- **Visual one-offs.** `cursor-dot-glow`, `text-clip-cloud-word`,
  `wc-live-demos-starlight`, `javascript-resizable-panel`: narrow, demo-style
  skills. Keep only if actually reused; otherwise drop or group in one
  `frontend-effects` plugin.
- **Third-party tool wrappers of doubtful value.** `ai-igniter-setup`, `lsp-mcp`
  (its MCP server failed to connect in this session): confirm they are used.
- **Broken metadata.** `hub-documentation` and `scroll-mastery` show no usable
  `description` when parsed; fix, since the description is what triggers a skill.
- `other` category: 0 skills — remove it.

### 4. Proposed thematic plugins

Replace the 11 category plugins by themes (final names to be confirmed):

| Plugin | Contents (after merges) |
|---|---|
| `agent-sessions` | pilot-session, session-meta, session-title, conversation-focus, pr-watch, grievances, linear-tracker, self-improving-skills, plain-explanation, ai-usage-tracking |
| `review-and-projection` | cursor-/openrouter-adversarial-review, adversarial-review-convergence, change-projection, data-projection, eza-file-overview |
| `agent-tooling` | find-skills, claude-plugin-release, static-validation-hooks, lsp-mcp, eslint-solid-nestjs |
| `typescript-fp` | fp-ts (merged) |
| `docker-and-k8s` | dockerfile (merged), docker-compose-orchestration, compose-env-ports, docker-hotreload-volume, k8s-troubleshoot |
| `git-and-delivery` | git-commit, git-activity-report, gh-cli, bitbucket-pipelines, devops-pipeline-design, semantic-release-js-ts-pipeline, integration-branch-discipline, makefile-conventions, sonarqube-config, npm-private-registry |
| `testing-and-debugging` | e2e-playwright, playwright-auth-factory, test-env-targeting, systematic-debugging, web-analysis, sentry-fix-issues |
| `backend-and-data` | sql-migration-guidelines, drizzle-pg-boss, s3-backend-proxy, authorization-models, philosophy-data-first, project-philosophy, openapi-client-generator, apiconv |
| `frontend` | nuxt, nuxt-ui, lit-web-components, scroll (merged) |
| `code-documentation` | code-documentation (merged), documentation-writer |
| `modelo-internal` (private) | hub-*, septeo-*, model-tenant-agency-user-db |

Agents and commands (`agents/`, `commands/`, 14 + 15 files) need the same
assignment; the orchestrator/implementer/tester/reviewer/debugger agents belong
together (likely `agent-sessions` or their own `orchestration` plugin).

## Scope

1. Decide the open questions below.
2. Add an explicit grouping field (or a mapping table) to the registry so the
   plugin split is no longer tied to `category`; update
   `asset-registry.schema.json`, `scripts/plugin-builder/`, and keep the
   registry in sync (AGENTS.md rule).
3. Execute the merges (fp-ts, dockerfile, code-documentation, scroll) — one
   child session per merge, each in its own branch.
4. Apply the drops/moves decided in question 2.
5. Split oversized skills into `SKILL.md` + `references/`.
6. Rebuild; require zero unresolved references, a stable two-run output and
   `claude plugin validate dist --strict`.

Out of scope: CI, versioning, the publication itself (next ticket).

## Done when

- The builder emits the agreed plugin set; no empty plugin; no plugin below
  3 assets unless justified.
- Cross-plugin references are explicit and minimal (target: fewer than today's 10).
- The registry, schema and builder tests pass; two builds are byte-identical.
- The plugin and skill names are frozen and listed in the README as the
  public naming contract.

## Opus review of usefulness (2026-11-16, five read-only reviewers, all 85 skills)

Criterion: does the skill add something a current frontier model does not
already do well, or is it noise?

Proposed DROP (noise, stale, or misleading):
`ai-igniter-setup` (config keys largely invented vs the upstream README),
`self-improving-skills` (survey of third-party repos, no script),
`git-commit`, `gh-cli` (keep ~10 lines of non-interactive gotchas in a rule),
`bitbucket-pipelines` (invalid YAML, outdated images), `openapi-client-generator`,
`systematic-debugging`, `nuxt` (generated docs dump, context7 is fresher),
`scroll-mastery` and `fluid-architecture-scroll-mastery` (duplicates; keep a
3-line note in `lit-web-components`), `javascript-resizable-panel`,
`hub-documentation` (file map of a private checkout).

Proposed MERGE: five fp-ts skills into one conventions-only `fp-ts` (~100
lines, Effect for greenfield); five per-language doc skills into one
`code-documentation`; `multi-stage-dockerfile` + `dockerfile-dev-prod` into
`dockerfile` (the other three Dockerfile skills are noise);
`eza-file-overview` into `change-projection` (keep `git-impacted.sh --md`);
`project-philosophy` into `philosophy-data-first`; `mcp-server-backend` +
`mcp-chatbot-client` into one; `npm-private-registry` into its rule (fix the
token-in-ARG/ENV issue first).

Proposed TRIM (valuable core buried in noise): `docker-compose-orchestration`
(keep the ~60-line secrets rule), `k8s-troubleshoot`, `e2e-playwright`,
`web-analysis`, `lit-web-components`, `hub-app-registration`,
`session-title`, `conversation-focus`, `linear-tracker` (split into
`references/`), `openrouter-adversarial-review`, `plain-explanation`,
`documentation-writer`, `find-skills` (trigger too broad; installs third-party
code with `-y`), `lsp-mcp` (Claude Code has a native LSP tool), `devops-pipeline-design`,
`s3-backend-proxy`, `authorization-models`.

Spec-kit dependent (conflict with the owner decision to keep them): `spec-reindex`,
`e2e-spec-writing`, `notion-spec-sync` rely on the `specs/NNN-*` layout or the
removed `/speckit.*` commands; `change-projection`, `data-projection`,
`session-title` and `linear-tracker` depend on spec-kit `tasks.md` flows in part.

Public-repo hygiene to fix before publishing: internal hosts incl. production
and a real-looking PBKDF2 hash in `septeo-keycloak-user-register`; internal
container/package names in `hub-app-registration`; a person's name in `pr-watch`
(SKILL.md, example, test); internal company names in `k8s-troubleshoot`,
`test-env-targeting`, `multi-stage-dockerfile`, `semantic-release-js-ts-pipeline`,
`makefile-conventions`, `sonarqube-config`, `linear-tracker` refs, `grievances`,
`claude-plugin-release`, pilot-session worked example; French bodies in
`makefile-conventions`, `s3-backend-proxy`; two skills without a `name`
field and one duplicate `name`; stale facts (bitnami/kubectl:latest, gh 2.85.0,
Compose `version:` keys, ESLint `unstable_ts_config`).

## Decisions (owner, 2026-11-16)

1. Repository is public; it must contain no sensitive information. The
   organization-specific skills stay (plugin `modelo-internal`) but need a
   sensitive-content check before publication.
2. Spec-kit dependent skills are kept, isolated in their own plugin `speckit`
   (a 12th plugin, added to the 11 accepted names), with a README/description
   stating they follow the spec-kit philosophy and need spec-kit installed.
3. Cover the Effect successor next to fp-ts: new `effect` skill in `typescript-fp`.
4. "Visual one-offs" are the demo-style frontend skills; keep them, grouped in `frontend`.
5. The 11 proposed plugin names are accepted.

## Open questions for the owner (answered above, kept for history)

1. Is the repository public? If so, the organization-specific skills must not
   ship in the public marketplace.
2. Drop or rewrite the spec-kit dependent skills?
3. Keep fp-ts as the target, or cover its Effect successor?
4. Which visual one-off skills are still used?
5. Accept the proposed theme names, or prefer fewer, larger plugins?
