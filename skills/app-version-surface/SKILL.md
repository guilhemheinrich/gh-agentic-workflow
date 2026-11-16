---
name: app-version-surface
description: >-
  Standardize how application components expose, transport, and display version
  metadata across the organization. Covers frontend, backend, worker, gateway,
  and embedded packages. Use when adding version display, configuring build
  metadata injection, creating version endpoints, or implementing version
  aggregation for multi-component applications.
tags:
  - common
  - versioning
---

# Application Version Surface

One stack-agnostic contract to expose, transport and display version metadata
for every component (frontend, backend, worker, gateway, embedded package).

## Contract

Each component serves or embeds one object validating against
[templates/version.schema.json](templates/version.schema.json). Mandatory:
`component`, `displayVersion`, `version` (SemVer), `gitCommit` (7+ chars),
`buildTime` (ISO-8601 UTC), `environment` (`local|dev|test|staging|production`).
Optional fields are listed in the schema.

- **Display format:** `<version>+<gitCommit>` (e.g. `2.4.1+5f2c9ab`), the SemVer
  build-metadata form. Use this exact string for Sentry `release`, log fields
  and APM correlation; `component` maps to the APM `service.name`.
- **Multi-component apps:** an aggregator (BFF or generated manifest) returns
  `{application, displayVersion, components[]}`, validated by
  [templates/aggregate.schema.json](templates/aggregate.schema.json).

## Ingestion

| Mode | Use for | How |
| --- | --- | --- |
| Build-time injection | SPAs, static bundles, desktop/mobile clients | CI injects version, commit, time, env; see [templates/build-args.snippet.md](templates/build-args.snippet.md) |
| Runtime endpoint | APIs, gateways, workers | `GET /version` (or a section of `/health`) serving the contract |
| Hybrid (default for web products) | Web products | Frontend self-version at build time; backends via endpoint |

## UI rules

- Level 1 (footer, About, profile menu): `Version 2.4.1+5f2c9ab`.
- Level 2 (support/technical panel): one line per component plus env and build time.
- Decoupled frontend and backend: show both, labelled with `component` names.
- Unreachable component: show `unavailable`; never a stale or invented string.

## Rules

- No hand-maintained version strings in source; the build produces them.
- No secrets or internal URLs in the payload or the panel.
- A version endpoint is public or behind the same auth as the app; never weaker
  than the app it describes unless explicitly decided.
- Do not ship only the commit hash, only the marketing version, or a single
  field mixing release version and deploy date.

Feed `semantic-release-js-ts-pipeline` outputs into the build so `version` and
`gitCommit` stay consistent with this contract.
