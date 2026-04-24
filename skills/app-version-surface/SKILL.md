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

## Overview

This skill defines a **uniform way to expose, transport, and display version information** for all application components in the organization. It applies to **frontend web** apps, **backend/API** services, **workers and jobs**, **gateways and BFFs**, and **embedded or shared packages**. The contract is **stack-agnostic**: the same shape and display rules work regardless of language, framework, or hosting model. Use it whenever you add version to the UI, wire build-time metadata, add `/version` endpoints, or aggregate versions across a distributed app.

---

## Canonical Version Contract

A single **component** (one deployable or independently versioned unit) is represented in JSON with the following shape.

```json
{
  "component": "frontend-web",
  "displayVersion": "2.4.1+5f2c9ab",
  "version": "2.4.1",
  "gitCommit": "5f2c9ab",
  "buildTime": "2026-04-22T09:14:00Z",
  "environment": "production"
}
```

### Mandatory fields

| Field            | Description |
|------------------|-------------|
| `component`      | Stable identifier for the component (e.g. `frontend-web`, `backend-api`, `worker-billing`). |
| `displayVersion` | Standard display format: `<version>+<gitCommit>`. |
| `version`        | SemVer human-readable version (e.g. `2.4.1`). |
| `gitCommit`      | Short Git hash (7+ characters). |
| `buildTime`      | ISO-8601 UTC timestamp of the build. |
| `environment`    | Deployment environment: `local`, `dev`, `test`, `staging`, or `production`. |

### Optional fields

| Field               | Description |
|---------------------|-------------|
| `releaseTag`        | e.g. `v2.4.1` |
| `repository`        | Repository identifier (org/repo or internal ID). |
| `branch`            | Source branch of the build. |
| `deploymentId`      | Deployment or release identifier. |
| `apiCompatibility`  | API contract version, if applicable. |
| `statusEndpoint`    | URL to fetch version from a remote component (for aggregation or linking). |

---

## Display Format Standard

The **canonical display format** is:

```text
<version>+<gitCommit>
```

**Example:** `2.4.1+5f2c9ab`

This follows the **SemVer** convention of separating the prerelease/core version from **build metadata** after `+`, which is widely understood and tool-friendly. It is **readable** (humans see the product version first), **precise** (the commit disambiguates builds), **stable across stacks** (no framework-specific string), and **correlatable** with logs, Sentry, and distributed traces that tag releases or commits the same way.

---

## UI Display Rules

### Level 1 — User-Visible

Show in a **footer**, **profile menu**, **About** page, or **admin login** screen, using this pattern:

```text
Version 2.4.1+5f2c9ab
```

### Level 2 — Technical Information Panel

In a dedicated **technical** or **support** view, list each component and environment:

```text
Frontend : 2.4.1+5f2c9ab
Backend  : 3.12.0+9d14e21
Worker   : 1.7.4+ab91cd2
Env      : production
Built at : 2026-04-22T09:14:00Z
```

### Surface rules

- **End users:** Show at least the version of the **visible** component (usually the client they interact with).
- **Distributed systems:** If multiple runtimes are **operated separately**, also show versions for those dependencies the user or support may need to reason about.
- **Decoupled frontend and backend:** Show **both** (and align labels with `component` names).
- **Unreachable component:** Use **`unavailable`** (or equivalent explicit placeholder) **instead of** inventing, caching stale, or misleading version strings.

---

## Ingestion Modes

### A. Build-Time Injection

**Version and commit are fixed when the artifact is built.** The pipeline or bundler injects `version`, `gitCommit`, `buildTime`, and `environment` (and optionally more) into environment variables, generated config, or a small generated module.

**Use for:** front-end SPAs, static bundles, packaged desktop or mobile clients, and any asset without a long-lived process serving metadata.

**Typical wiring:** `VITE_*` / `REACT_APP_*` / `NEXT_PUBLIC_*` style public env, Webpack/Vite/Metro **define** plugins, `import.meta.env`, or a `version.json` emitted by CI and copied into the build output. Values must come from the **build**, not from guessing in the browser.

### B. Runtime Endpoint Exposure

**The process reads its embedded or mounted metadata and serves it over HTTP (or gRPC) on a technical route.** Callers (including a BFF or ops dashboard) fetch the canonical JSON at runtime.

**Use for:** APIs, BFFs/gateways, workers with an admin or metrics port, and any long-running service where **what is running** must match the **live** process.

**Typical paths:** `/version`, `/health` (version subsection), `/metadata`, `/info`. The response should match the **Canonical Version Contract** (single component) or a documented subset plus link to the full object.

### C. Hybrid (Recommended Default for Web Products)

- **Front end:** build-time injection so the shell always shows a version even if the API is down.
- **Back end (and other services):** runtime endpoint for truth of what is deployed.

The UI may **merge** build-time self-version with **fetched** backend/worker versions for Level 2 panels, with clear handling when fetches fail.

---

## Aggregated Version Contract

For **multi-component** applications, an aggregator (BFF, portal API, or static manifest generator) can expose a single object that names the app and lists each component in canonical form.

```json
{
  "application": "customer-portal",
  "displayVersion": "2.4.1+5f2c9ab",
  "components": [
    { "component": "frontend-web", "displayVersion": "2.4.1+5f2c9ab", "version": "2.4.1", "gitCommit": "5f2c9ab", "buildTime": "2026-04-22T09:14:00Z", "environment": "production" },
    { "component": "backend-api", "displayVersion": "3.12.0+9d14e21", "version": "3.12.0", "gitCommit": "9d14e21", "buildTime": "2026-04-22T09:10:00Z", "environment": "production" }
  ]
}
```

- **`application`:** Product or application name (stable string).
- **`displayVersion`:** Often the **primary** user-facing or release-driving component’s `displayVersion`, or a product-level convention documented per app.
- **`components`:** One full canonical object per component; `displayVersion` in each child must follow `<version>+<gitCommit>`.

---

## Implementation Checklist (for Application Projects)

- [ ] **CI pipeline** injects Git metadata (`GIT_COMMIT`, tag, or short SHA) and version source (e.g. from `package.json` or release tool) for every build.
- [ ] **Build** generates a version file, env, or code constants consumed by the app (no hand-maintained version strings in source).
- [ ] **Backend (and similar services)** exposes a version/metadata endpoint with the canonical JSON (or a strict subset) for each component.
- [ ] **Frontend** reads build-injected metadata for its own `displayVersion` and, where applicable, fetches other components.
- [ ] **UI** implements Level 1 (and Level 2 if needed) with correct labels and `unavailable` for failed fetches.
- [ ] **Aggregation** endpoint or manifest is implemented if the product has multiple runtimes, unless a single static catalog is the agreed model.
- [ ] **Observability** (Sentry release, logging fields, APM `service.name`) is aligned with `displayVersion` and `component` as in this skill.

---

## Security and Observability Checklist

- **Do not** put internal-only URLs, secrets, or infrastructure details into version JSON or the version UI.
- **Access:** Expose read-only version metadata **without authentication** if that matches product policy, **or** behind the **same** auth as the app — avoid a weaker public version endpoint for a protected app unless explicitly decided.
- **Sentry (and similar):** `release` (or equivalent) should use the same **`displayVersion`** string (`<version>+<gitCommit>`) for releases and source maps.
- **Logs:** Structured logs should include at least `component` and `gitCommit` (and usually `version`) for correlation.
- **APM and tracing:** Service identifiers should **map to** the canonical `component` name so traces match version surfaces and dashboards.

---

## Anti-Patterns

| Anti-pattern | Why it is wrong |
|--------------|-----------------|
| **Only the Git hash** in the UI | Not human-readable; hard to match to a marketed release. |
| **Only a marketing version** (no commit) | Not correlatable to a specific build; duplicate versions across commits. |
| **Mixing release version and deploy date in one field** | Ambiguous semantics; breaks parsing and comparison. |
| **Computing “version” only in the client** without build/runtime source of truth | Easy to fake or drift; not trustworthy for support. |
| **Secrets or internal URLs in the version panel or JSON** | Expands attack surface and trains users to copy sensitive data. |

---

## Related Skills

- **`semantic-release-js-ts-pipeline`** — Automates version number calculation, tagging, and changelog generation; **feed** its outputs into the build and endpoints described here so `version` and `gitCommit` stay consistent with this contract.
