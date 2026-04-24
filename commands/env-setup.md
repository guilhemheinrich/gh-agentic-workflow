---
name: env-setup
description: >-
  Manage dual-mode environment files (Hub vs hubless/standalone). Generates
  .env.example, .env.hub.example (committed templates) and .env.hub,
  .env.hubless (local ready-to-use presets). Audits .gitignore and detects the
  current .env mode.
tags:
  - docker
  - hub
---

# `/env-setup` — Dual-Mode Environment Manager

This command manages the **Hub / hubless** environment duality for projects that can run either standalone (S2S static secrets) or embedded in the **Modelo Hub** (JWKS RS256 JWT + session bridge).

## Usage

```
/env-setup
/env-setup audit
/env-setup detect
```

---

## Concepts

A project that supports both Hub-embedded and standalone modes needs **4 env files**:

| File | Committed | Purpose |
|------|-----------|---------|
| `.env.example` | Yes | Template for **standalone/hubless** mode — safe defaults, no real secrets |
| `.env.hub.example` | Yes | Template for **Hub-embedded** mode — safe defaults, `change-me` placeholders |
| `.env.hubless` | No | **Ready-to-use** local preset for hubless mode — copy to `.env` |
| `.env.hub` | No | **Ready-to-use** local preset for Hub mode — copy to `.env` |

The `.env` file itself is **never committed** — it is always a copy of either `.env.hub` or `.env.hubless`.

### Switching modes

```bash
# Switch to hubless:
cp .env.hubless .env

# Switch to Hub:
cp .env.hub .env
```

---

## Execution Pipeline

```
┌────────────┐   ┌─────────────┐   ┌──────────────┐   ┌────────────┐   ┌──────────┐
│  Step 1    │──▶│   Step 2    │──▶│    Step 3    │──▶│   Step 4   │──▶│  Step 5  │
│ Codebase   │   │  Detect     │   │  .gitignore  │   │ Generate   │   │  Report  │
│ Analysis   │   │  Current    │   │  Audit       │   │ Files      │   │          │
└────────────┘   └─────────────┘   └──────────────┘   └────────────┘   └──────────┘
```

---

## Step 1: Codebase Analysis

### 1.1 Identify the project type

Determine what kind of project this is by scanning:

- `compose.yml` / `docker-compose.yml` — service topology, networks
- `Makefile` — available targets
- `package.json` / `go.mod` — language and framework
- Any existing `.env*` files

### 1.2 Discover Hub integration patterns

Search the codebase for Hub-related mechanisms:

| What to find | Search patterns |
|---|---|
| **Hub feature flag** | `HUB_ENABLED`, `VITE_HUB_MODE`, `HUB_BASE_URL` |
| **S2S auth middleware** | `S2SAuth`, `APIKeyAuth`, `X-API-Key`, `Bearer`, `S2S_API_KEY_SECRET` |
| **JWKS / JWT verification** | `JWKS`, `HUB_SERVICE_AUTH_ISSUER`, `HUB_SERVICE_AUTH_JWKS_URL`, `RS256` |
| **Hub session bridge** | `/api/hub/bootstrap`, `HubSessionPort`, `IntrospectSession` |
| **Hub client/adapter** | `hub.Client`, `HUB_AUTH_INTERNAL_URL`, `HUB_AUTH_API_URL` |
| **Cookie domain** | `JWT_COOKIE_DOMAIN`, `JWT_COOKIE_SECURE` |
| **Frontend mode** | `VITE_HUB_URL`, `VITE_HUB_BASE_URL`, `VITE_HUB_MODE` |

### 1.3 Discover cross-project S2S contracts

Search for variables that must be **aligned between projects**:

| Pattern | What it means |
|---|---|
| `BROKER_API_KEY` ↔ `APP_API_KEY` | API key shared between caller and target |
| `BROKER_S2S_API_KEY` ↔ `S2S_API_KEY_SECRET` | S2S Bearer token shared between caller and target |
| `BROKER_BASE_URL` | URL of the target service on the Docker network |
| `BROKER_SLUG` / `APP_SLUG` | App identity for JWT audience matching |

### 1.4 Build the variable matrix

For each environment variable found, classify it:

| Variable | Hub value | Hubless value | Shared with | Notes |
|---|---|---|---|---|
| *example:* `APP_API_KEY` | `change-me` (Hub-generated) | `dev-local-broker-key` | Bill-e `BROKER_API_KEY` | Must match cross-project |

---

## Step 2: Detect Current Mode

Read the current `.env` file (if it exists) and determine if it corresponds to Hub or hubless mode.

### Detection heuristics

**Hub mode indicators:**
- `HUB_ENABLED=true`
- `HUB_BASE_URL` is non-empty and points to a real Hub URL (e.g. `https://hub.modelo.dev`)
- `HUB_SERVICE_AUTH_ISSUER` is non-empty
- `HUB_AUTH_INTERNAL_URL` is non-empty (e.g. `http://auth-api:3000`)
- `VITE_HUB_MODE=auto` or `VITE_HUB_MODE=embedded`
- `JWT_COOKIE_SECURE=true`
- `JWT_COOKIE_DOMAIN` is set (e.g. `.modelo.dev`)

**Hubless mode indicators:**
- `HUB_ENABLED=false` or absent
- `HUB_BASE_URL` is empty
- `HUB_SERVICE_AUTH_ISSUER` is empty
- `VITE_HUB_MODE=standalone`
- `JWT_COOKIE_SECURE=false`
- `JWT_COOKIE_DOMAIN` is empty
- `CORS_ALLOWED_ORIGINS` points to `localhost`

### Output

Report the detected mode:

```
Current .env mode: HUB
  Evidence:
    - HUB_ENABLED=true
    - HUB_BASE_URL=https://hub.modelo.dev
    - HUB_SERVICE_AUTH_ISSUER=https://auth.modelo.dev/api/auth
```

**IF ambiguous** (mixed signals — some Hub indicators, some hubless), **ASK the user**:

> L'état actuel du `.env` est ambigu. Certaines variables indiquent le mode Hub, d'autres le mode standalone.
> Quel mode souhaitez-vous configurer ?
> - **Hub** (SSO, JWKS, session bridge)
> - **Hubless** (standalone, S2S statiques)

---

## Step 3: .gitignore Audit

### 3.1 Expected pattern

The `.gitignore` must:

1. **Ignore** `.env` (the active file)
2. **Ignore** `.env.*` (catch-all for local presets)
3. **Whitelist** `.env.example` (committed template — standalone)
4. **Whitelist** `.env.hub.example` (committed template — Hub)

Correct pattern:

```gitignore
.env
.env.*
!.env.example
!.env.hub.example
```

### 3.2 Verification

Read the `.gitignore` and check:

| Check | Expected | Fix |
|---|---|---|
| `.env` is ignored | Line `.env` exists | Add `.env` |
| `.env.*` is ignored | Line `.env.*` exists | Add `.env.*` |
| `.env.example` is whitelisted | Line `!.env.example` exists **after** `.env.*` | Add `!.env.example` after `.env.*` |
| `.env.hub.example` is whitelisted | Line `!.env.hub.example` exists **after** `.env.*` | Add `!.env.hub.example` after `.env.*` |
| `.env.hub` is **NOT** whitelisted | No `!.env.hub` line | Remove if present (contains real secrets) |
| `.env.hubless` is **NOT** whitelisted | No `!.env.hubless` line | Remove if present (contains real secrets) |

### 3.3 Edge case: existing `.env.local` or other patterns

If the project already uses `.env.local`, `.env.development`, etc., **preserve** those patterns. Only add the Hub/hubless lines if missing.

**IF fixes are needed**, apply them and report:

```
.gitignore audit:
  ✅ .env is ignored
  ✅ .env.* is ignored
  ⚠️  Added: !.env.hub.example
  ✅ .env.example is whitelisted
  ✅ .env.hub and .env.hubless are NOT whitelisted (correct — they contain secrets)
```

---

## Step 4: Generate Files

### 4.1 File generation strategy

For each of the 4 files, determine whether it needs to be **created**, **updated**, or is **already correct**:

| File | Source | Strategy |
|---|---|---|
| `.env.example` | Codebase analysis (Step 1) | Hubless template — all Hub vars empty, S2S keys as dev defaults |
| `.env.hub.example` | Codebase analysis (Step 1) | Hub template — Hub vars with placeholder URLs, `change-me` for generated keys |
| `.env.hubless` | Current `.env` + hubless overrides | Ready-to-use — real dev secrets, Hub disabled |
| `.env.hub` | Current `.env` + hub overrides | Ready-to-use — real dev secrets, Hub enabled |

### 4.2 Template rules

**Both `.env.example` and `.env.hub.example`** (committed):
- **NO real secrets** — use `change-me`, empty strings, or documented placeholders
- **NO API keys** — use empty or `change-me`
- Include **clear header comments** explaining the mode and prerequisites
- Include **cross-project alignment documentation** (which var matches which in the other project)
- Follow the **exact same variable order** as the current `.env`
- Use **section separators** with `# ---` or `# ===` to group related variables

**Both `.env.hubless` and `.env.hub`** (local, not committed):
- **MAY contain real dev secrets** (local tokens, staging API keys)
- Must be **immediately usable** via `cp .env.hubless .env` — no editing needed
- Include the **header comment** explaining the mode and quick-start steps
- **Pre-align S2S keys** with the partner project's matching preset

### 4.3 Hubless-specific rules

In the hubless file (`.env.example` and `.env.hubless`):

- All `HUB_*` variables → **empty**
- `HUB_ENABLED` → `false` (if the variable exists)
- `HUB_SERVICE_AUTH_ISSUER` → **empty** (disables JWKS)
- `HUB_SERVICE_AUTH_JWKS_URL` → **empty**
- `VITE_HUB_URL` / `VITE_HUB_BASE_URL` → **empty**
- `VITE_HUB_MODE` → `standalone` (if the variable exists)
- `JWT_COOKIE_SECURE` → `false` (if the variable exists)
- `JWT_COOKIE_DOMAIN` → **empty** (if the variable exists)
- `CORS_ALLOWED_ORIGINS` → `http://localhost:<port>` (if the variable exists)
- S2S keys → deterministic dev values (e.g. `dev-local-broker-key`, `dev-local-s2s-secret`)

### 4.4 Hub-specific rules

In the Hub file (`.env.hub.example` and `.env.hub`):

- `HUB_ENABLED` → `true` (if the variable exists)
- `HUB_BASE_URL` → `https://hub.modelo.dev`
- `HUB_SERVICE_AUTH_ISSUER` → `https://auth.modelo.dev/api/auth` (or project-specific)
- `HUB_SERVICE_AUTH_JWKS_URL` → `http://auth-api:3000/api/auth/.well-known/jwks.json` (or project-specific)
- `VITE_HUB_URL` / `VITE_HUB_BASE_URL` → `https://hub.modelo.dev`
- `VITE_HUB_MODE` → `auto` (if the variable exists)
- `JWT_COOKIE_SECURE` → `true` (if the variable exists)
- `JWT_COOKIE_DOMAIN` → `.modelo.dev` (if the variable exists)
- `CORS_ALLOWED_ORIGINS` → `https://<app-slug>.modelo.dev` (if the variable exists)
- `APP_API_KEY` → `change-me` in `.example`, real Hub-generated key in `.env.hub`

### 4.5 Cross-project key alignment

When generating files, document and enforce the S2S key alignment contract:

```
# S2S keys — MUST match across projects:
#   This project          ↔  Partner project
#   APP_API_KEY           ↔  BROKER_API_KEY
#   S2S_API_KEY_SECRET    ↔  BROKER_S2S_API_KEY
```

Use **identical default values** in the hubless presets of both projects so they work together out-of-the-box.

---

## Step 5: Report

Produce a summary:

```markdown
## /env-setup Report

### Detected Mode
Current .env: [Hub / Hubless / Not found / Ambiguous]

### .gitignore Audit
| Check | Status |
|---|---|
| .env ignored | ✅ |
| .env.* ignored | ✅ |
| .env.example whitelisted | ✅ |
| .env.hub.example whitelisted | ✅ / ⚠️ Fixed |

### Files Generated
| File | Status | Action |
|---|---|---|
| .env.example | Created / Updated / Already correct | Committed template (hubless) |
| .env.hub.example | Created / Updated / Already correct | Committed template (Hub) |
| .env.hubless | Created / Updated / Already correct | Local preset (hubless) |
| .env.hub | Created / Updated / Already correct | Local preset (Hub) |

### Cross-Project Alignment
| This project | Partner project | Hubless value | Hub value |
|---|---|---|---|
| APP_API_KEY | BROKER_API_KEY | dev-local-broker-key | change-me |
| S2S_API_KEY_SECRET | BROKER_S2S_API_KEY | dev-local-s2s-secret | change-me |

### Quick Start
```bash
# Hubless mode:
cp .env.hubless .env && make up

# Hub mode:
cp .env.hub .env && make up-build
```
```

---

## Critical Rules

- **NEVER commit real secrets** — `.env.example` and `.env.hub.example` contain only placeholders
- **ALWAYS preserve existing variable ordering** — do not reorder variables when updating files
- **ALWAYS include header comments** explaining the mode, prerequisites, and quick-start
- **ALWAYS document the cross-project key contract** in both `.example` files
- **ALWAYS verify `.gitignore`** before generating files
- **IF `.env` does not exist**, create both `.env.hubless` and `.env.hub` from the `.example` templates enriched with any real dev values found in the codebase (e.g. existing `.env.hub.example`)
- **IF the current `.env` mode is ambiguous**, ASK the user before proceeding
- **Run ALL commands via Docker** if the project uses Docker — NEVER on the host
- **Follow `.cursor/rules/`** and `AGENTS.md` for project conventions
