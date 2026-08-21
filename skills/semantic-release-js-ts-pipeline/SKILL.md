---
name: semantic-release-js-ts-pipeline
description: >-
  Standardize release automation for JavaScript/TypeScript projects using
  semantic-release. Covers version calculation, Git tags, release notes, npm
  publishing policy, and CI/CD governance. Treats OIDC trusted publishing as the
  default npm authentication, and documents the failure modes of a broken release (EOTP,
  E403, ENONPMTOKEN, a branch frozen by a skip-CI release commit). Use when
  setting up automated releases, configuring semantic-release plugins, choosing
  between a trusted publisher and an NPM_TOKEN, defining branch strategies, or
  integrating release versions with application metadata.
tags:
  - ci-cd
  - git
  - npm
  - versioning
---

# semantic-release — JavaScript/TypeScript Release Pipeline

## Overview

This skill describes a **standard pipeline** for JavaScript and TypeScript projects using [semantic-release](https://semantic-release.gitbook.io/) to:

- **Calculate versions** from [Conventional Commits](https://www.conventionalcommits.org/) (via the default Angular-style rules used by semantic-release)
- **Generate release notes** for the forge (GitHub, GitLab, etc.)
- **Create Git tags** that represent released versions
- **Optionally publish** to npm when the artifact is a package, not only a deployed application

It covers **three project types**:

1. **Applications** — deployed (container, static host, server); typically **no npm publish**. Releases are tags + forge notes; version for runtime comes from the tag / build injection (see [Version surfacing integration](#version-surfacing-integration)).
2. **npm packages** — libraries or CLIs published to a registry; semantic-release updates `package.json` and runs `@semantic-release/npm` (or equivalent).
3. **Monorepos** — multiple packages or apps in one repo; semantic-release is **one release line per repo by default**; advanced setups need extra tooling (see [Monorepo considerations](#monorepo-considerations)).

---

## Commit convention mapping

semantic-release’s default analyzer follows **Angular Commit Message Conventions**, aligned with **Conventional Commits** (`type(scope): subject`).

| Commit signal | Typical version bump |
| --- | --- |
| `feat:` | **minor** |
| `fix:` | **patch** |
| `perf:` | **patch** |
| `feat!:` or **BREAKING CHANGE:** in the footer | **major** |
| `docs:`, `chore:`, `refactor:`, `style:`, `test:`, `ci:`, `build:` | **no release** (by default — no version bump from these alone) |

Custom rules are possible via `@semantic-release/commit-analyzer` options; the table reflects the **default** preset.

---

## Plugin recommendation matrix

| Tier | Plugins | When to use |
| --- | --- | --- |
| **Minimum viable** (always required) | `@semantic-release/commit-analyzer`, `@semantic-release/release-notes-generator` | Every setup: analyze commits and generate notes. |
| **Standard application** (deployed app, no npm publish) | Minimum viable + `@semantic-release/github` **or** `@semantic-release/gitlab` | Create releases on the forge; no registry publish. |
| **Standard npm package** (published to registry) | Minimum viable + `@semantic-release/npm` + forge plugin (`@semantic-release/github` or GitLab) | Version bump in `package.json`, publish tarball, release on forge. |
| **Opt-in only** | `@semantic-release/changelog` (writes `CHANGELOG.md`), `@semantic-release/git` (commits release artifacts) | Only when there is an **explicit** requirement to maintain a committed changelog or commit release files. |

**Important:** The official `@semantic-release/changelog` and `@semantic-release/git` documentation warns that **committing release-generated files** often adds **unnecessary merge friction and complexity**. Prefer forge-only release notes unless the team explicitly needs a file in the repository.

---

## Reference configurations

### Case 1 — Application (no npm publish)

```json
{
  "branches": ["main"],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    "@semantic-release/github"
  ]
}
```

### Case 2 — npm package

```json
{
  "branches": ["main"],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    "@semantic-release/npm",
    "@semantic-release/github"
  ]
}
```

### Case 3 — Application with opt-in `CHANGELOG` (only if explicitly required)

```json
{
  "branches": ["main"],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    ["@semantic-release/changelog", { "changelogFile": "CHANGELOG.md" }],
    "@semantic-release/npm",
    ["@semantic-release/git", {
      "assets": ["CHANGELOG.md", "package.json"],
      "message": "chore(release): ${nextRelease.version} [skip ci]"
    }],
    "@semantic-release/github"
  ]
}
```

### Multi-branch (pre-releases)

```json
{
  "branches": [
    "main",
    { "name": "next", "prerelease": true },
    { "name": "beta", "prerelease": true }
  ]
}
```

Adjust plugin lists per case (e.g. omit `@semantic-release/npm` for pure applications).

---

## CI pipeline architecture

### On pull request (dry-run)

```bash
npx semantic-release --dry-run
```

Projects **projected** next version and release type **without** creating tags or publishing. Use this on PR workflows to surface impact early.

### On merge to a release branch (actual release)

```bash
npx semantic-release
```

Performs the full pipeline: version calculation, tag, release notes, optional npm publish.

### npm authentication — prefer trusted publishing (OIDC) over a token

For packages published to **registry.npmjs.org**, authenticate the release job with
**OIDC trusted publishing**. The CI job proves its identity to npm and receives a
short-lived publish token; no `NPM_TOKEN` secret exists, so nothing expires, leaks
or has to be rotated. Reach for a token only when the registry does not support
trusted publishing (a self-hosted Verdaccio, Artifactory, GitHub Packages).

**Mechanism.** `@semantic-release/npm` asks the CI provider for an id-token scoped
to `npm:registry.npmjs.org`, POSTs it to
`https://registry.npmjs.org/-/npm/v1/oidc/token/exchange/package/<package-name>`,
and publishes with the token it gets back. It tries this **before** any token auth
and falls back to `NPM_TOKEN` when the exchange fails — so a misconfigured trusted
publisher surfaces as `ENONPMTOKEN`, not as an OIDC error.

**Hard requirements** (all four, or the exchange is refused):

| Requirement | Value |
| --- | --- |
| Plugin | `@semantic-release/npm` **≥ 13**, shipped by `semantic-release` **≥ 25** (engines `^22.14.0 \|\| >= 24.10.0`) |
| npm CLI | **≥ 11.5.1** — `node:24` carries 11.17.0; **`node:22` still carries 10.9.8**, so Node 22 needs an explicit npm upgrade |
| Job permission | `id-token: write` |
| Registry-side | a trusted publisher declared on the package |

**Declaring the publisher** (npmjs → package → *Settings* → *Trusted Publisher*).
The available providers are **GitHub Actions**, **GitLab CI/CD** and **CircleCI**.
For GitHub Actions:

| Field | Value |
| --- | --- |
| Organization or user | the GitHub org or user |
| Repository | the repository name |
| Workflow filename | the **filename only**, extension included — `release.yml`, never `.github/workflows/release.yml` |
| Environment name | leave empty unless the job declares an `environment:` |
| Allowed actions | `npm publish` |

**Order of operations matters.** Declare the publisher **before** merging the
workflow change. A release that runs first fails at publish, and — when
`@semantic-release/git` is configured — leaves the branch frozen (see
[Failure modes](#failure-modes)).

**Workflow shape.** Do not set `registry-url`, `scope` or `NODE_AUTH_TOKEN` on
`setup-node`: the `.npmrc` auth line it writes only competes with OIDC. Do not pass
`--provenance` or `NPM_CONFIG_PROVENANCE` either — trusted publishing attests by
default.

```yaml
permissions:
  contents: write
  issues: write
  pull-requests: write
  id-token: write        # required: OIDC token exchange + provenance

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/setup-node@v4
        with:
          node-version: "24"   # npm >= 11.5.1; no registry-url, no NODE_AUTH_TOKEN
      - run: npm ci
      - run: npx semantic-release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

Confirm success in the log — these three lines, in order:

```
Verifying OIDC context for publishing from GitHub Actions
OIDC token exchange with the npm registry succeeded
Publishing version <x.y.z> to npm registry on dist-tag latest
```

**After the first green publish**, delete the now-unused `NPM_TOKEN` secret and set
the package to *Require two-factor authentication and disallow tokens*.

**Two properties that bite later.** The **workflow filename is part of the trust
identity** — renaming `release.yml` breaks publishing silently. And the exchange is
**per package**, so every new package under the same scope needs its own publisher.


### Required CI environment

| Secret / condition | Purpose |
| --- | --- |
| `GITHUB_TOKEN` or `GITLAB_TOKEN` (or CI equivalents) | Authenticate to the forge to create releases and often to push tags |
| `NPM_TOKEN` | Only when publishing to a registry that has **no** trusted publishing — see [npm authentication](#npm-authentication--prefer-trusted-publishing-oidc-over-a-token). On registry.npmjs.org, prefer OIDC and set no secret at all |
| `id-token: write` permission | Required for OIDC trusted publishing and for provenance |
| **Git history** | **Not** a shallow clone for full commit analysis, **or** ensure tags and relevant commits are fetched (`fetch-depth: 0` in GitHub Actions is common) |

### Example: GitHub Actions (release job)

```yaml
release:
  runs-on: ubuntu-latest
  if: github.ref == 'refs/heads/main'
  steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0
    - uses: actions/setup-node@v4
      with:
        node-version: 20
    - run: npm ci
    - run: npx semantic-release
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

The snippet above is the token-free minimum for a **deployed app** (forge release only).
When using `@semantic-release/npm` against registry.npmjs.org, add `id-token: write`
and bump `node-version` to `24` instead of adding a secret — see
[npm authentication](#npm-authentication--prefer-trusted-publishing-oidc-over-a-token).
Add `NPM_TOKEN` to `env` only for a registry without trusted publishing.

In repositories that require **all Node/npm commands to run inside Docker**, execute the same steps in a job that uses the project’s Node image and runs `npx semantic-release` there instead of on the default runner’s bare Node install.

---

## Branch governance

| Branch | Role |
| --- | --- |
| `main` | Stable production releases (typical default) |
| `next` (optional) | Pre-release channel when configured with `prerelease: true` |
| `beta` (optional) | Beta pre-release channel when configured |

**Rules:**

- **Release only** when CI runs `semantic-release` on **branches explicitly listed** in `branches` (e.g. `main`, `next`, `beta`).
- Use **`--dry-run` on every PR** (or on integration branches) to catch version impact and commit-message issues before merge.
- **Do not** rely on implicit “any branch” behavior: undeclared branches may be ignored or misconfigured; keep config and documentation aligned.

---

## Version surfacing integration

After semantic-release **creates a Git tag** (e.g. `v1.2.3`), CI can **read that tag** (or the version string semantic-release outputs) and **inject it into the build** as application metadata.

- The **Git tag** (or the version computed for that tag) is the **single source of truth** for “what is released” for **deployed applications**.
- **Populate** `version` and `displayVersion` (and related fields) per the [**app-version-surface**](../app-version-surface/SKILL.md) skill so runtime and ops see a consistent contract.
- For **npm packages**, `package.json` **version** is updated by semantic-release and **is** authoritative for the registry; for **container-only or bundle-only apps**, do **not** treat `package.json#version` as the sole runtime source of truth — prefer the **tag-driven** build version.

**Cross-reference:** [app-version-surface](../app-version-surface/SKILL.md).

---

## Dry-run strategy

- Run `npx semantic-release --dry-run` on **PRs** to preview the **next version** and **release notes** without side effects.
- Use it to **validate Conventional Commits** before merge (wrong types or missing `BREAKING CHANGE` when needed).
- In CI, dry-run can **fail** a PR if policy requires a releasable commit when the analyzer would produce **no** release (team-specific; implement with script + exit codes if needed).

---

## Rollback strategy

- semantic-release **does not** provide a one-click “rollback release” in the tool.
- **Git / application:** Revert the offending commit, merge the revert; a new **`fix:`**-style history typically yields a **new patch release** (or adjust process if you must not release).
- **npm packages:** `npm unpublish` is **time-limited** (e.g. 72 hours for many cases — check current npm policy); prefer **`npm deprecate`** for bad versions that must stay on the registry.
- **Tags:** Deleting remote tags is possible but **generally discouraged** (confuses consumers and CI); prefer forward-fix releases.

---

## Implementation checklist

- [ ] Conventional commits enforced (commitlint or equivalent)
- [ ] `.releaserc.json` (or `release` in `package.json`) created with the correct **project type** (app vs package vs opt-in changelog/git)
- [ ] CI: **dry-run** on PR, **full release** on merge to `main` (or other configured release branches)
- [ ] Secrets: `GITHUB_TOKEN` / `GITLAB_TOKEN`. On registry.npmjs.org, **no npm secret** — use trusted publishing
- [ ] Publishing to npmjs: trusted publisher declared on the package **before** the workflow change merges, `id-token: write` on the job, `semantic-release` >= 25, Node 24
- [ ] Git checkout in CI is **not shallow** (`fetch-depth: 0` or equivalent) and tags are available
- [ ] Branch strategy **documented** and matches `branches` in config
- [ ] Version surfacing planned with [**app-version-surface**](../app-version-surface/SKILL.md) for `version` / `displayVersion`
- [ ] Team **onboarded** on commit message rules and release expectations

---

## Failure modes

Each row below was observed on a real pipeline. The error code is the fastest
discriminator — read it before changing anything.

| Symptom | Cause | Fix |
| --- | --- | --- |
| `npm error code EOTP` — *requires a one-time password* | The npm account enforces 2FA on writes and the token in use does not bypass it. A classic **Publish** token never bypasses it; a classic **Automation** or a **Granular** token does. Independently, a package set to `mfa=publish` refuses **even an Automation token** | Move to [trusted publishing](#npm-authentication--prefer-trusted-publishing-oidc-over-a-token). Staying on tokens means `npm access set mfa=automation <pkg>` **and** an Automation or Granular token |
| `npm error code ENONPMTOKEN` on a job with no secret | The OIDC exchange was refused, and the plugin fell back to token auth | Check the publisher's **workflow filename** and repository on npmjs, and that `id-token: write` is declared |
| `npm error code E403 You cannot publish over the previously published versions` | A publish step ran when no release was due. `semantic-release` exits **0** when it decides not to release, so a step gated on its exit status still fires and republishes the unchanged version | Let `@semantic-release/npm` own the publish (`npmPublish: true`). Never bolt a separate `npm publish` step onto the job |
| `npm error code EUSAGE` on provenance | Provenance cannot be attested for a restricted package | `publishConfig.access: "public"`, or drop provenance |
| **The branch is frozen: no run fires at all** | `@semantic-release/git` runs in `prepare`, so the `chore(release): x.y.z [skip ci]` commit and the tag are pushed **before** `publish`. When publishing fails, the branch head carries the CI-skip marker and no push event can retry — and `semantic-release` never re-publishes a version it already tagged | Push an empty commit with a **releasable** type (`fix:`); a `chore:` commit triggers the workflow and then publishes nothing while reporting success. The stuck version number is lost — accept the gap |

**One trap worth its own line:** the forge scans the **whole** commit message for the
CI-skip marker, body included. Quoting that marker while *explaining* this failure
suppresses the very run you are trying to trigger. Name it, never reproduce it.

---

## Anti-patterns

- Running semantic-release **without** enforcing Conventional Commits (unpredictable or missing releases).
- **Requiring** a committed `CHANGELOG.md` on every project (forge release notes are often enough).
- Using `@semantic-release/git` to auto-commit **without** a clear product or compliance need.
- **Mixing** “npm package” and “deployed app only” strategies (e.g. publishing to npm when nothing consumes the package).
- Using **`package.json#version` alone** as runtime truth for **deployed apps** (use **Git tag** / build injection).
- **Publishing to npm** from a repo that only ships a **container or static bundle** with no package consumers.
- Running **full** `semantic-release` on **every** branch instead of only **configured** release branches.
- Storing a long-lived `NPM_TOKEN` when the registry supports **trusted publishing** (a secret that expires silently and can leak, replacing one that cannot).
- Bolting a **separate `npm publish` step** onto the release job next to `semantic-release`, gated on its step outcome — see `E403` in [Failure modes](#failure-modes).
- Passing `--provenance` **and** using trusted publishing (redundant: the attestation is automatic).

---

## Monorepo considerations

- **Default behavior:** semantic-release is **per-repository** (one version line, one tag stream unless you use advanced patterns).
- **Monorepos** often need:
  - **[multi-semantic-release](https://github.com/dhoulb/multi-semantic-release)** or similar, **or**
  - **Per-workspace** release scripts and careful branch/tag naming, **or**
  - **Orchestrators** (Turborepo, Nx) combined with a clear “which package releases when” policy.
- **Trade-offs:** Independent versioning per package adds operational overhead; a single version for the whole repo is simpler but couples all packages.
- **Do not over-promise** a one-size-fits-all monorepo setup: document the chosen tool and its limitations explicitly.

---

## Related skills

- [**app-version-surface**](../app-version-surface/SKILL.md) — Standard contract for `version`, `displayVersion`, and related metadata that should consume the version **produced** by this pipeline (e.g. from the Git tag or build-time injection).
