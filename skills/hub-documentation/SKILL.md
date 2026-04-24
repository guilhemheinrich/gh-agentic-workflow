---
tags:
  - architecture
  - documentation
  - hub
---
# Skill: Modelo Hub Documentation

> **When to use**: Whenever you need to understand the Modelo Hub platform — its architecture, integration contracts, onboarding process, session model, or operational setup. Use this skill for both high-level architectural questions and fine-grained implementation details.

## Instructions

This skill is a **knowledge map** of the Modelo Hub documentation. It provides:

1. A **global overview** of how the Hub works (architecture, auth flow, services, deployment).
2. **Fine-grained references** to specific docs for targeted questions.

When answering a question about the Hub, first consult the relevant section below, then read the referenced file(s) for full details. All paths are relative to `~/code/modelo-hub/`.

---

## 1. Global Overview

### What is the Modelo Hub?

The Modelo Hub is a **unified platform federating real estate applications** under `*.modelo.fr` (production) / `*.modelo.dev` (local). It provides:

- **Single Sign-On (SSO)** via Keycloak (groupe Septeo, OIDC PKCE)
- **App catalog and launch** — users browse apps and launch them via redirect
- **Shared navigation chrome** — `<modelo-hub-chrome>` web component
- **Entitlements and subscriptions** — plan-based access control
- **Feature flags** — per-session flag evaluation
- **Inter-app delegation** — App1 calls App2 on behalf of a user via RFC 8693 token exchange
- **Event Bus** — Redis Streams for cross-app entity synchronization

### Core Tech Stack

| Layer | Technology |
|---|---|
| Language | TypeScript 5.9 |
| Backend | Hono (Node.js 24 LTS) |
| Frontend | React 19.2 + Vite 7 |
| Database | PostgreSQL 18 + Prisma 7 |
| Sessions | Redis 8.6 |
| IdP | Keycloak groupe Septeo (OIDC PKCE, external) |
| Reverse proxy | Traefik 3.6 |
| Package manager | Bun 1.3 |
| Monorepo | Turborepo 2.8 |
| Architecture | DDD Hexagonal (ports/adapters) |

The Hub enforces an **integration contract**, not a tech stack — downstream apps can use any technology.

### Monorepo Structure

```
modelo-hub/
├── apps/
│   ├── auth-api/          # BFF — OIDC auth, sessions, SSO
│   ├── app-registry/      # App registry + Traefik HTTP provider
│   ├── entitlements/      # Plans, subscriptions, access rights
│   ├── feature-flags/     # Feature flag evaluation and admin
│   └── hub-shell/         # React 19 SPA — navigation, catalog
├── packages/
│   ├── hub-contracts/     # Port interfaces (IAuthProvider, etc.)
│   ├── hub-events/        # Event Bus (Redis Streams)
│   └── hub-ui/            # Design tokens, UI components
├── docs/                  # Developer documentation
├── specs/                 # SpecKit specifications per feature
├── .docker/               # Dockerfiles, Traefik config
├── helm/                  # Kubernetes Helm charts
├── compose.yml            # Docker Compose — single entry point
├── turbo.json             # Turborepo pipelines
└── Makefile               # All dev commands (never run node/bun on host)
```

### Auth Flow (High Level)

1. User opens `https://hub.modelo.dev` → Hub Shell loads
2. User clicks "Login" → redirected to Septeo Keycloak (OIDC PKCE)
3. After login → `session_hub` cookie set, user sees app catalog
4. User clicks an app tile → `GET /api/auth/authorize?target_slug={slug}&redirect_url=...`
5. `auth-api` validates Hub session, checks entitlements, creates `session_{slug}` cookie
6. Browser redirected to `https://{slug}.modelo.dev` with cookies set
7. App backend reads `session_{slug}`, calls introspect, creates local session

### Service Dependency Map

```
Browser → Traefik → hub-shell (UI)
                  → auth-api (BFF auth, SSO, sessions) → Keycloak (external)
                  → app-registry (app catalog, Traefik config)
                  → entitlements (plans, subscriptions)
                  → feature-flags (flag evaluation)
                  → [downstream apps on *.modelo.dev]

auth-api → PostgreSQL, Redis
auth-api → entitlements (access resolution)
auth-api → feature-flags (flag checks)
app-registry → PostgreSQL, Redis
entitlements → PostgreSQL, Redis
feature-flags → PostgreSQL, Redis
```

---

## 2. Documentation Map — Quick Reference

### README (Project Root)

| Topic | File |
|---|---|
| Full project overview, tech stack, getting started, monorepo structure, make commands, K8s deployment | `README.md` |

**Read `README.md` for**: setup instructions, `make` commands, local URLs, test credentials, port conflicts, WSL2 setup, Kubernetes deployment pipeline, Helm chart structure.

---

### Docs Index

| Topic | File |
|---|---|
| Documentation table of contents | `docs/README.md` |

---

### Integration — Onboarding

| Topic | File | Key Content |
|---|---|---|
| **Quickstart** — is the Hub ready for downstream dev? | `docs/integration/onboarding/quickstart.md` | Onboarding-critical services checklist, automated + manual verification steps, ready/not-ready verdict rules |
| **Provider Contract** — what the Hub team must deliver | `docs/integration/onboarding/downstream-app-onboarding-contract.md` | Required Hub outputs per app (slug, apiKey, entitlements), admin capability matrix (registry, entitlements, auth, flags), routing/launch contract, session introspection contract, token exchange contract, entitlement patterns |

---

### Integration — Canonical Contracts

These are the **sole references** for integration. Older spec documents are superseded.

| Topic | File | Key Content |
|---|---|---|
| **Frontend Contract v2** | `docs/integration/contracts/frontend-contract-v2.md` | App launch via redirect (not iframe), Hub context detection (hostname), `<modelo-hub-chrome>` quick start, events (`hub-chrome:logout`, `hub-chrome:theme`, `hub-chrome:locale`, `hub-chrome:org-changed`), BroadcastChannel `modelo-hub`, Vite/Webpack config, Docker `extra_hosts`, standalone fallback, integration checklist |
| **Backend Contract v2** | `docs/integration/contracts/backend-contract-v2.md` | SSO bootstrap flow (cookie → introspect → local session), session introspection endpoint (`POST /api/auth/session/introspect`) with full request/response/error reference, inter-app token exchange (`POST /api/auth/token-exchange`) with RFC 8693, compatibility bridge endpoints (`/api/hub/bootstrap`, `/api/hub/me`, `/api/hub/logout`, `/api/hub/health`), required headers (`X-API-Key`, `X-Correlation-Id`), cookie reference table, local mapping hooks, historical URL coexistence, integration checklist |
| **Hub Chrome Contract** | `docs/integration/contracts/hub-chrome-contract.md` | `<modelo-hub-chrome>` web component: loading, attributes (`app-name`, `hub-url`, `user-name`, `org-label`), events (`hub-chrome:logout`), Shadow DOM rendering, brand alignment (Modelo palette), responsive behavior, versioning policy, `hub-embed-tokens.css` token stylesheet for embedded apps, workspace semantic tokens, dark theme support, checklist |
| **Entity Model Contract** | `docs/integration/contracts/entity-model-contract.md` | `HubUser` nucleus schema, Event Bus integration (`user.created`, `user.updated`, `user.roles_updated`) |
| **Integration Type Decision** | `docs/integration/contracts/integration-type-decision.md` | `integrationType` field is **informational only** — all apps launch via redirect regardless. Decision rationale, upgrade path for future iframe/federation support |

---

### Integration — Existing App Compatibility Playbook

For apps that **already have their own auth, sessions, and user model**. Based on lessons from the Raggit pilot.

| Topic | File | Key Content |
|---|---|---|
| **Pre-Onboarding Checklist** | `docs/integration/playbook/pre-onboarding-checklist.md` | 10-section assessment (auth model, guards, 401 handling, logout, user identity, frontend arch, multi-tenancy, domain/proxy, CI/CD, inter-app). Effort scoring matrix (Low/Medium/High). Blocking incompatibilities table. |
| **Session Coexistence Guide** | `docs/integration/playbook/session-coexistence-guide.md` | Three patterns: **A) Dual-Cookie** (recommended, Raggit uses this), **B) Session Takeover**, **C) Proxy Session**. Decision tree. Auth guard dual-mode pattern. Cookie naming strategy. Session lifetime reconciliation. Edge cases (token-based coexistence, SSR). |
| **Frontend Bootstrap Guide** | `docs/integration/playbook/frontend-bootstrap-guide.md` | Startup sequencing: Hub context detection → bridge bootstrap → auth check → tenant init → render. 401 interceptor handling (3 options: context-aware, bypass flag, error code). State management coordination. Framework-specific examples (React, Vue, Angular). Troubleshooting table. |
| **User Mapping Guide** | `docs/integration/playbook/user-mapping-guide.md` | Hub-owned vs App-owned boundary table. Four strategies: **1) Strict Email Match** (Raggit), **2) Auto-Provision**, **3) Match + On-Demand Provision**, **4) Custom Mapping**. Decision tree. Organization mapping patterns. Role projection patterns. Error handling summary (fail-closed). |
| **Logout Flow Guide** | `docs/integration/playbook/logout-flow-guide.md` | Three logout triggers (app UI, hub-chrome, Hub direct). Complete 3-step sequence: clear bridge → clear native → redirect to Hub. Frontend + backend implementation. Edge cases (Hub-side logout, session expiry, concurrent tabs). Sequence diagram. |
| **Infrastructure Prerequisites** | `docs/integration/playbook/infrastructure-prerequisites.md` | Docker networking (`extra_hosts`), CSP configuration, build tool config (Vite/Webpack/Angular), `@septeo-immo/*` package installation (`NPM_TOKEN`), DNS/TLS (`*.modelo.dev`, mkcert), CORS, required environment variables (`HUB_AUTH_URL`, `HUB_API_KEY`, `HUB_APP_SLUG`). |
| **Inter-App Delegation Guide** | `docs/integration/playbook/inter-app-delegation-guide.md` | Anti-pattern (cookie propagation). Delegated token flow sequence diagram. Token exchange request/response. Token validation (App2 side): signature, expiry, audience, issuer. JWKS caching. Fail-closed error matrix. Implementation examples (TypeScript). |
| **Modelo Manifest Guide** | `docs/integration/playbook/modelo-manifest-guide.md` | `modelo.manifest.json` schema (slug, name, version, hubBridge endpoints, sessionCoexistence, userMappingStrategy). Examples for existing app and greenfield app. Registry alignment verification. Slug format regex. |
| **Integration Completion Checklist** | `docs/integration/playbook/integration-completion-checklist.md` | **45-item** post-integration verification across 10 sections: bootstrap, session, user context, logout, health, manifest, hub chrome, error behavior, infrastructure, cross-cutting. Scoring and verdict (45/45 = complete, <40 = significant gaps). |
| **Raggit Reference Implementation** | `docs/integration/playbook/raggit-reference-implementation.md` | First real integration case study. 9 adaptations annotated: bridge module, auth guard extension, cookie strategy, user mapping (strict email), frontend bootstrap sequencing, 401 interceptor neutralization, hub chrome, Docker networking, API base URL. Known gaps. Lessons learned (bridge = 20% effort, coexistence = 80%). |

---

### Platform Operations

| Topic | File | Key Content |
|---|---|---|
| **Kubernetes Infra Sizing** | `docs/kubernetes-infra-sizing-report.md` | Workload inventory with CPU/memory requests/limits per service. Mermaid architecture diagram. Cluster sizing proposals (Core vs Full). HPA autoscaling baselines. Storage recommendations (PostgreSQL 200Gi, Redis 20Gi). Platform requirements (K8s 1.29+, cert-manager, metrics). Infra request checklist. |
| **Staging Secrets** | `docs/staging-secrets.md` | Secret generation commands. Keycloak variables (PKCE, no client secret). Per-service secrets (auth-api, entitlements, feature-flags). Shared key relationships diagram. DevOps name → env var mapping. |
| **Future Documentation Platform** | `docs/FUTURE-DOCUMENTATION-PLATFORM.md` | Design constraints for future doc platform: auth/access control, per-app namespace, vectorized search with language segmentation, multi-language support. `septeo-rag` investigation notes. |

---

## 3. Key Concepts Quick Reference

### Session Model (BFF)

- **No bearer tokens in browser** — steady-state auth uses HttpOnly cookies
- `session_hub` — Hub shell session (set by auth-api login callback)
- `session_{slug}` — Per-app session (set by auth-api authorize flow)
- `csrf_token_{slug}` — CSRF protection (readable by JS)
- All cookies: `Secure`, `SameSite=Lax`, `Domain=.modelo.dev`

### Introspection Endpoint

```
POST https://auth.modelo.dev/api/auth/session/introspect
Headers: X-API-Key, Content-Type: application/json
Body: { "session_id": "<value from session_{slug} cookie>" }
Response: { data: { userId, orgId, appSlug, user, roles, isAdmin, entitlements, flags, ... } }
```

### Token Exchange Endpoint

```
POST https://auth.modelo.dev/api/auth/token-exchange
Headers: X-API-Key, Content-Type: application/json
Body: { "subject_token": "<access token>", "target_audience": "<target-app-slug>" }
Response: { data: { accessToken, expiresIn } }
```

### Entitlement Pattern

```
app:{slug}:access          — required for every app
app:{slug}:{feature}       — optional app-specific features
```

### Hub Chrome

```html
<script src="https://hub.modelo.dev/hub-chrome.js" defer></script>
<modelo-hub-chrome app-name="My App" hub-url="https://hub.modelo.dev"
  user-name="Jane Doe" org-label="Acme Corp"></modelo-hub-chrome>
```

Events: `hub-chrome:logout`, `hub-chrome:theme`, `hub-chrome:locale`, `hub-chrome:org-changed`

### Entity Model (Event Bus)

- Stream: `modelo-hub`
- Events: `user.created`, `user.updated`, `user.roles_updated`
- Payload: `HubUser { id, email, firstName?, lastName?, active, createdAt, updatedAt }`

---

## 4. Decision Trees

### Which session coexistence pattern?

```
App needs standalone mode?
  ├─ No  → Pattern B (Session Takeover)
  └─ Yes → Backend needs Hub-context awareness?
              ├─ Yes → Pattern A (Dual-Cookie) ← recommended default
              └─ No  → Can call "create session" programmatically?
                          ├─ Yes → Pattern C (Proxy Session)
                          └─ No  → Pattern A (Dual-Cookie)
```

### Which user mapping strategy?

```
Users already exist in app DB?
  ├─ No  → Strategy 2 (Auto-Provision)
  └─ Yes → Should Hub login create accounts for unknowns?
              ├─ Always      → Strategy 2 (Auto-Provision)
              ├─ Sometimes   → Strategy 3 (Match + On-Demand)
              ├─ Never       → Strategy 1 (Strict Email Match) ← Raggit
              └─ Complex     → Strategy 4 (Custom Mapping)
```

---

## 5. Common Tasks — Which Doc to Read

| Task | Read |
|---|---|
| Set up local dev environment from scratch | `README.md` |
| Check if Hub is ready for downstream dev | `docs/integration/onboarding/quickstart.md` |
| Register a new downstream app | `docs/integration/onboarding/downstream-app-onboarding-contract.md` |
| Implement frontend integration | `docs/integration/contracts/frontend-contract-v2.md` + `hub-chrome-contract.md` |
| Implement backend integration | `docs/integration/contracts/backend-contract-v2.md` |
| Assess effort for integrating an existing app | `docs/integration/playbook/pre-onboarding-checklist.md` |
| Choose session coexistence pattern | `docs/integration/playbook/session-coexistence-guide.md` |
| Fix bootstrap sequencing / 401 loops | `docs/integration/playbook/frontend-bootstrap-guide.md` |
| Map Hub users to local users | `docs/integration/playbook/user-mapping-guide.md` |
| Implement logout correctly | `docs/integration/playbook/logout-flow-guide.md` |
| Set up Docker, CSP, DNS, TLS | `docs/integration/playbook/infrastructure-prerequisites.md` |
| Call another app's API on behalf of a user | `docs/integration/playbook/inter-app-delegation-guide.md` |
| Create modelo.manifest.json | `docs/integration/playbook/modelo-manifest-guide.md` |
| Verify integration is complete (45-item check) | `docs/integration/playbook/integration-completion-checklist.md` |
| Study the first real integration (Raggit) | `docs/integration/playbook/raggit-reference-implementation.md` |
| Size Kubernetes infrastructure | `docs/kubernetes-infra-sizing-report.md` |
| Configure staging secrets | `docs/staging-secrets.md` |
| Understand entity model / event bus | `docs/integration/contracts/entity-model-contract.md` |
| Understand integration type field | `docs/integration/contracts/integration-type-decision.md` |

---

## 6. Critical Rules

1. **Never run `node`, `bun`, `npm`, or `pip` on the host** — all commands go through Docker via `make` targets.
2. **All apps launch via redirect** — `integrationType` is informational only, no iframe embedding exists.
3. **Fail-closed everywhere** — if session validation fails, deny access. Never fall back to unauthenticated.
4. **No bearer tokens in browser** — the BFF model uses cookies for browser↔Hub, API keys for backend↔backend.
5. **Never propagate cookies backend-to-backend** — use token exchange for inter-app calls.
6. **Bridge endpoints are ~20% of integration effort** — the other 80% is coexistence (auth guard, bootstrap sequencing, 401 handling, CSP, Docker networking).
