---
name: semantic-release-js-ts-pipeline
description: >-
  Release automation for JavaScript/TypeScript projects with semantic-release.
  Treats OIDC trusted publishing as the default npm authentication and documents
  the failure modes of a broken release (EOTP, E403, ENONPMTOKEN, a branch frozen
  by a skip-CI release commit), plus the mandatory 90-day granular-token rotation
  and how to script it. Ships a .releaserc.json and a GitHub Actions release job.
  Use when setting up automated releases, choosing between a trusted publisher
  and an NPM_TOKEN, or debugging a failed npm publish.
tags:
  - ci-cd
  - git
  - npm
  - versioning
---

# semantic-release for JS/TS

Generic semantic-release usage (Conventional Commits mapping, plugin lists, dry-run) is assumed known. This skill keeps the npm-publishing facts and failure modes that are easy to get wrong.

## Templates

- [`templates/.releaserc.json`](templates/.releaserc.json): npm package (analyzer, notes, npm, GitHub; `next` as prerelease channel). For a deployed app drop `@semantic-release/npm`.
- [`templates/release.yml`](templates/release.yml): GitHub Actions job (dry-run on PR, release on push, OIDC, `fetch-depth: 0`).

Policy: prefer forge release notes. Use `@semantic-release/changelog` and `@semantic-release/git` (which commit release files) only on explicit need; they add merge friction and cause the frozen-branch failure below. For deployed apps the Git tag is the version source of truth (see [app-version-surface](../app-version-surface/SKILL.md)), not `package.json#version`. Monorepos: semantic-release is one release line per repo; use multi-semantic-release or per-workspace scripts and document the limits.

## npm authentication: prefer trusted publishing (OIDC)

On registry.npmjs.org, authenticate with OIDC: no `NPM_TOKEN`, nothing to rotate or leak. Use tokens only for registries without trusted publishing (self-hosted, GitHub Packages).

`@semantic-release/npm` requests an id-token for `npm:registry.npmjs.org`, exchanges it at `https://registry.npmjs.org/-/npm/v1/oidc/token/exchange/package/<package-name>`, and publishes with the result. It tries this before token auth and falls back to `NPM_TOKEN`, so a misconfigured publisher surfaces as `ENONPMTOKEN`, not as an OIDC error.

All four are required:

| Requirement | Value |
| --- | --- |
| Plugin | `@semantic-release/npm` >= 13, shipped by `semantic-release` >= 25 (engines `^22.14.0 \|\| >= 24.10.0`) |
| npm CLI | >= 11.5.1. `node:24` carries 11.17.0; `node:22` still carries 10.9.8 and needs an explicit npm upgrade |
| Job permission | `id-token: write` |
| Registry side | trusted publisher declared on the package |

Declare it in npmjs: package, Settings, Trusted Publisher (providers: GitHub Actions, GitLab CI/CD, CircleCI; Bitbucket Pipelines is absent). GitHub fields: organization/user, repository, workflow filename only (`release.yml`, not the path), environment empty unless the job declares `environment:`, allowed action `npm publish`.

- Declare the publisher before merging the workflow, or the first release fails at publish (and may freeze the branch).
- Do not set `registry-url`, `scope` or `NODE_AUTH_TOKEN` on `setup-node`, and do not pass `--provenance`: the attestation is automatic.
- Success log, in order: `Verifying OIDC context for publishing from GitHub Actions`, `OIDC token exchange with the npm registry succeeded`, `Publishing version <x.y.z> to npm registry on dist-tag latest`.
- After the first green publish, delete `NPM_TOKEN` and set the package to "Require two-factor authentication and disallow tokens".
- The workflow filename is part of the trust identity (renaming breaks publishing silently) and the exchange is per package (each new package needs its own publisher).

## Token rotation (only when you cannot use OIDC)

- 2025-12-09: all classic tokens were permanently revoked. Granular write tokens are capped at 90 days (default often 7).
- Granular tokens enforce 2FA unless "Bypass 2FA" was ticked at creation; it cannot be added later. Without it every publish fails with `EOTP`; recreate the token.
- `npm token create` (npm >= 11) key flags: `--name`, `--expires <days>` (<= 90 for write), `--packages <pkg>` or `--scopes <scope>` (prefer one package), `--packages-and-scopes-permission read-write`, `--orgs-permission no-access`, `--bypass-2fa`, optional `--cidr`.
- Creation needs the account password and an OTP: rotation cannot be fully unattended.

Scripts (both honour `NPM_BIN`, e.g. `export NPM_BIN="docker run --rm -v $HOME/.npmrc:/root/.npmrc:ro node:24 npm"`):

- [`scripts/npm-token-audit.sh`](scripts/npm-token-audit.sh): rotation queue, soonest expiry first, exits `3` when a token expires within `--warn-days` (default 14). `npm token list` has no expiry column (verified on npm 11.17.0 and 12.0.2), so it reads `--json` and probes for `expires`, `expires_at`, `expiresAt`, `expiration`, `expiry`; `--raw-keys` shows the real payload fields.
- [`scripts/rotate-npm-publish-token.sh`](scripts/rotate-npm-publish-token.sh): `./scripts/rotate-npm-publish-token.sh --package @org/pkg --verify-publish . --revoke <old-id>`. Refuses `--expires` > 90, always passes `--bypass-2fa`, verifies with `whoami` and an optional `publish --dry-run`, revokes the old token only after verification; the token is the only stdout line on success. `--dry-run` prints the command.

## Failure modes

| Symptom | Cause | Fix |
| --- | --- | --- |
| `EOTP` | token does not bypass 2FA, or package set to `mfa=publish` | trusted publishing; else recreate with Bypass 2FA and `npm access set mfa=automation <pkg>` |
| `E401` / `ENEEDAUTH` about every 90 days | granular token expired | trusted publishing, or rotate |
| `ENONPMTOKEN` on a job with no secret | OIDC exchange refused, fell back to token | check publisher workflow filename and repo on npmjs, and `id-token: write` |
| `E403 cannot publish over the previously published versions` | a separate `npm publish` step ran although no release was due (`semantic-release` exits 0 when nothing is releasable) | let `@semantic-release/npm` own publishing; never add a separate `npm publish` step |
| `EUSAGE` on provenance | provenance on a restricted package | `publishConfig.access: "public"` or drop provenance |
| Branch frozen, no run fires | `@semantic-release/git` pushes the `chore(release): x.y.z` skip-CI commit and tag in `prepare`, before `publish`; if publish fails, no push event can retry and the version is never re-published | push an empty commit with a releasable type (`fix:`); a `chore:` commit runs the workflow and publishes nothing. The stuck version number is lost |

The forge scans the whole commit message (body included) for the CI-skip marker: never reproduce it while explaining this failure, or you suppress the run you want.

## Rollback

No rollback command. Revert and merge for a new patch release; for npm prefer `npm deprecate` (unpublish is time-limited, about 72 hours); avoid deleting remote tags.
