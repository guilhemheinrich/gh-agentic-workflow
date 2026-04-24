---
name: hub-app-registration
description: >-
  Register a downstream application in the Modelo Hub ecosystem. Use when
  onboarding a new app, configuring Hub authentication, debugging
  registration/auth issues, or understanding the Hub SSO flow.
tags:
  - auth
  - common
  - docker
  - hub
---

# Hub App Registration & Authentication

Complete procedure to register an application in the Modelo Hub, configure SSO authentication, and troubleshoot common issues. This skill is **agnostic**: the principles apply regardless of the backend (Node.js, PHP, Python, Go…).

## When to Use This Skill

- Register a new app in the Hub App Registry
- Understand the Hub → App authentication flow
- Debug auth issues (401, redirect loop, missing cookies)
- Configure Docker networking, TLS, and entitlements

## Prerequisites

- Modelo Hub running locally (`hub.modelo.dev`, `auth.modelo.dev`)
- Hub admin account (email listed in `INITIAL_ADMIN_EMAILS` in the Hub compose)
- The app to register must be started and reachable from Docker

---

## Architecture — Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              MODELO HUB                                     │
│                                                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │ Keycloak │  │ auth-api │  │ app-registry │  │ entitlements │           │
│  │ (IdP)    │  │          │  │              │  │              │           │
│  └────┬─────┘  └────┬─────┘  └──────┬───────┘  └──────────────┘           │
│       │              │               │                                      │
│  ┌────┴──────────────┴───────────────┴──────────────────────────────┐      │
│  │                         Traefik (reverse proxy)                   │      │
│  │  *.modelo.dev → TLS termination → route to services               │      │
│  │  HTTP provider polls app-registry/traefik every 30s               │      │
│  └──────────────────────────────────────────────────────────────────┘      │
│                                                                             │
│  Docker network: modelo-network (Hub-internal)                              │
└─────────────────────────────────────────────────────────────────────────────┘
         │
         │  host.docker.internal (Traefik → app frontend via the host)
         │  modelo-network (backend → auth-api in mode A, direct access)
         │
┌─────────────────────────────────────────────────────────────────────────────┐
│                          DOWNSTREAM APP (e.g. Calendar)                      │
│                                                                             │
│  ┌──────────────┐         ┌──────────────┐         ┌──────────────┐        │
│  │   Frontend   │ ──/api──│   Backend    │ ──SDK──▶│  Hub auth-api│        │
│  │ (Vite, Nginx)│         │ (NestJS, etc)│         │ (introspect) │        │
│  └──────┬───────┘         └──────────────┘         └──────────────┘        │
│         │ port exposed on the host                                          │
│  Docker network: app-network (internal)                                     │
└─────────┼───────────────────────────────────────────────────────────────────┘
          │
          │  host.docker.internal:<PORT>
          │  (Traefik routes {slug}.modelo.dev → host → app frontend)
          │
```

### Traefik Routing

| Domain              | Service      | Routes                              |
| ------------------- | ------------ | ----------------------------------- |
| `auth.modelo.dev`   | keycloak     | Everything except `/api` and `/health` |
| `auth.modelo.dev`   | auth-api     | `/api/*`, `/health`                 |
| `hub.modelo.dev`    | app-registry | `/api/registry/*`                   |
| `hub.modelo.dev`    | entitlements | `/api/entitlements/*`               |
| `hub.modelo.dev`    | hub-shell    | Everything else (Hub frontend)      |
| `{slug}.modelo.dev` | app frontend | Dynamic proxy to `originDomain`     |

Traefik uses an **HTTP provider** that polls the App Registry:

```
--providers.http.endpoint=http://app-registry:3002/api/registry/traefik
--providers.http.pollInterval=30s
```

For each active app, the App Registry generates a router (`Host(\`{subdomainUrl}\`)`) and a service (`loadBalancer → http://{originDomain}`).

**`originDomain` uses `host.docker.internal`** (e.g. `host.docker.internal:3101`), not the Docker container name. Traefik resolves `host.docker.internal` to the host machine, where the app ports are exposed. This avoids having to declare an external Docker network (`modelo-network`) on each downstream project.

---

## Authentication Flow — The Critical Part

This is the most complex part and the source of most bugs.

### Full Flow: Launching an App from the Hub

```
  Browser                     Hub (auth-api)              App Backend
  ───────                     ──────────────              ───────────
      │                              │                          │
  1.  │──── Click "Launch App" ─────▶│                          │
      │                              │                          │
  2.  │  GET /api/auth/authorize     │                          │
      │  ?target_slug=calendar       │                          │
      │  &redirect_url=https://      │                          │
      │   calendar.modelo.dev        │                          │
      │  Cookie: session_hub=xxx     │                          │
      │─────────────────────────────▶│                          │
      │                              │                          │
  3.  │                              │ Validates session_hub    │
      │                              │ Creates app session      │
      │                              │ (session_calendar=yyy)   │
      │                              │                          │
  4.  │◀── 302 Redirect ────────────│                          │
      │  Location: https://calendar.modelo.dev                  │
      │  Set-Cookie: session_calendar=yyy;                      │
      │    Domain=.modelo.dev; HttpOnly; Secure; SameSite=Lax   │
      │                              │                          │
  5.  │──── GET https://calendar.modelo.dev ───────────────────▶│
      │  Cookie: session_hub=xxx; session_calendar=yyy          │
      │                              │                          │
      │                              │                          │
  6.  │  (Frontend loads, calls GET /api/hub/me)                │
      │──── GET /api/hub/me ───────────────────────────────────▶│
      │  Cookie: session_calendar=yyy                           │
      │                              │                          │
  7.  │                              │◀── POST /session/introspect
      │                              │    X-API-Key: <key>      │
      │                              │    Body: {sessionId: yyy}│
      │                              │                          │
  8.  │                              │──── 200 {userId, email,  │
      │                              │     roles, expiresAt}───▶│
      │                              │                          │
  9.  │◀── 200 {userId, email, ...} ───────────────────────────│
      │                              │                          │
 10.  │  Frontend: isAuthenticated=true, displays the app       │
      │                              │                          │
```

### Key Points of the Flow

1. **The Hub sets the `session_{slug}` cookie** — it is the Hub's auth-api that creates the app session and sets the cookie, not the app's backend. The cookie is set on the `.modelo.dev` domain during the redirect (step 4).

2. **The cookie contains a Hub session ID** — it is an opaque UUID (e.g. `47c534df-5863-4aeb-adb2-c8b4d570a6bf`), not a JWT. It must be introspected via the Hub SDK on every request.

3. **The app does NOT perform a local bootstrap** — no need to read `session_hub` to create a local session. The Hub has already done everything. The app reads `session_{slug}` and introspects it.

4. **No local JWT needed** — the app can store local data (user provisioned in DB), but authentication relies on Hub introspection.

### Flow: Authenticated API Requests (After Launch)

```
  Browser                     App Backend               Hub auth-api
  ───────                     ───────────               ────────────
      │                            │                          │
      │── GET /api/v1/calendars ──▶│                          │
      │  Cookie: session_calendar  │                          │
      │                            │                          │
      │                            │── POST /session/introspect
      │                            │   X-API-Key + sessionId ▶│
      │                            │                          │
      │                            │◀── 200 {userId, roles} ──│
      │                            │                          │
      │                            │ Provision local user     │
      │                            │ (find or create in DB)   │
      │                            │                          │
      │◀── 200 [{calendars}] ─────│                          │
      │                            │                          │
```

### Flow: Direct Access (Without Going Through the Hub)

```
  Browser                     App Frontend              Hub
  ───────                     ────────────              ───
      │                            │                      │
      │── GET calendar.modelo.dev ▶│                      │
      │                            │                      │
      │  (Frontend loads)          │                      │
      │── GET /api/hub/me ────────▶│                      │
      │  Cookie: (none or expired) │                      │
      │                            │                      │
      │◀── 401 NO_SESSION ────────│                      │
      │                            │                      │
      │  Frontend: isAuthenticated=false                  │
      │  → window.location = hub.modelo.dev               │
      │                            │                      │
      │── GET hub.modelo.dev ─────────────────────────────▶
      │  (login if needed, then re-triggers the           │
      │   "Launch App" flow above)                        │
```

### Flow: Public Pages (RSVP, Sharing)

```
  Browser                     App Frontend / Backend
  ───────                     ──────────────────────
      │                            │
      │── GET /rsvp?token=abc ────▶│
      │                            │
      │  (Frontend loads)          │
      │── GET /api/hub/me ────────▶│  → 401 (no cookie)
      │◀── 401 ───────────────────│
      │                            │
      │  Frontend: user=null       │
      │  BUT /rsvp is NOT         │
      │  protected → display the  │
      │  page anyway              │
      │                            │
      │── GET /api/v1/events/     │
      │   rsvp/by-token/abc ─────▶│  → @Public() → no guard
      │◀── 200 {eventDetails} ────│
      │                            │
      │  (No Hub redirect)        │
```

**Rule**: public endpoints (RSVP, token-based sharing) must be marked `@Public()` (or equivalent) on the backend, and the frontend must **not** trigger a Hub redirect when the user is not authenticated on these pages.

---

## Key Concepts

### `modelo.manifest.json` Is Declarative Only

The `modelo.manifest.json` file at the project root **does not trigger any automatic registration**. It is a reference file that documents the slug, origin, SSO mode, and bridge endpoints. Registration in the Hub is a **manual step** via the API or admin UI.

### The SDK Does Not Handle Registration

The Hub SDK (e.g. `HubModule.forRoot()` in NestJS, or an HTTP client in PHP/Python) configures the **client** that communicates with the Hub (session introspection). It does not register in the registry.

### API Keys: Three Systems Not to Confuse

The Hub has **three types of API keys** with different roles:

| Key | Generated by | Stored in | Used for | Identifies the caller? |
| --- | --- | --- | --- | --- |
| `apiKey` (App Registry) | `POST /api/registry/apps` | App Registry DB | Traefik routing, catalog | No |
| Static `APP_API_KEY` | Manual config | `ALLOWED_API_KEYS` in Hub compose | Session introspection only | **No** (`callerAppSlug = undefined`) |
| Dynamic `APP_API_KEY` | App Registry (seed or admin UI) | App Registry DB (`apiKey` column) | Introspection **AND** S2S (`/service-token`) | **Yes** (`callerAppSlug = slug`) |

> **CRITICAL**: **static keys** (e.g. `dev-api-key`) work for `/session/introspect` but **NOT for `/service-token`**. The `/service-token` endpoint needs to know *which app* is calling (to check `trustedApps`). Only **dynamic keys** (registered in the App Registry with an associated `slug`) carry a `callerAppSlug`.
>
> If a static key is sent to `/service-token`, the Hub responds with `403 SERVICE_TOKEN_CALLER_UNRESOLVED`: "API key is not tied to a registry app; use a dynamic app API key".

**How to tell which type of key you're using?**

```bash
# Key used by the app
docker inspect <app-backend> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep APP_API_KEY

# Static keys accepted by the Hub (introspection only)
docker inspect <auth-api-container> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep ALLOWED_API_KEYS

# Dynamic key in the registry (introspection + S2S)
# → visible in the seed or via GET /api/registry/apps/:slug
```

**In dev**: the Hub seed often provides a static key `dev-api-key`. For S2S, you **must** switch to a dynamic key registered in the App Registry.

**Static → dynamic migration**:

1. Ensure the app is registered in the App Registry with an `apiKey` (see Step 2)
2. Retrieve or define the `apiKey` in the App Registry seed (≥ 32 characters)
3. Set `APP_API_KEY=<dynamic key>` in the app's `.env`
4. Restart the backend (**`docker compose up -d backend`**, not `restart` — `restart` does not re-read the `.env`)

---

## Service-to-Service Authentication (S2S)

### Overview

Since spec `040-hub-s2s-auth`, the Hub centralizes backend-to-backend authentication. The `auth-api` becomes the **single point of trust**: it signs short-lived JWTs (5 min) with an RSA private key, and publishes public keys via JWKS. Receiving apps verify **only** the auth-api's JWKS — never Keycloak directly.

```
  Calling app (Calendar)          auth-api (Hub)         App Registry        Target app (Meet)
  ─────────────────────────       ──────────────         ────────────        ────────────────
         │                              │                      │                     │
         │ POST /api/auth/service-token │                      │                     │
         │ X-API-Key: <dynamic_key>     │                      │                     │
         │ {target_audience: "meet",    │                      │                     │
         │  on_behalf_of: {session_id}} │                      │                     │
         ├─────────────────────────────►│                      │                     │
         │                              │                      │                     │
         │                              │ 1. Validates X-API-Key│                    │
         │                              │    → resolve slug    │                     │
         │                              ├─────────────────────►│                     │
         │                              │◄─────────────────────┤                     │
         │                              │ callerAppSlug=       │                     │
         │                              │ "calendar" ✓         │                     │
         │                              │                      │                     │
         │                              │ 2. Fetch policy for  │                     │
         │                              │    target "meet"     │                     │
         │                              ├─────────────────────►│                     │
         │                              │◄─────────────────────┤                     │
         │                              │ trustedApps=         │                     │
         │                              │ ["calendar"] ✓       │                     │
         │                              │                      │                     │
         │                              │ 3. Introspect session│                     │
         │                              │ → userId, orgId,     │                     │
         │                              │   roles              │                     │
         │                              │                      │                     │
         │                              │ 4. Sign Hub JWT:     │                     │
         │                              │ sub=userId           │                     │
         │                              │ aud=meet             │                     │
         │                              │ act.sub=calendar     │                     │
         │                              │ mode=delegated       │                     │
         │                              │ exp=5min             │                     │
         │                              │                      │                     │
         │◄──── 200 {data: {access_token: <hub_jwt>}} ────────│                     │
         │                              │                      │                     │
         │ POST /api/internal/meetings  │                      │                     │
         │ Authorization: Bearer <hub_jwt>                     │                     │
         ├──────────────────────────────────────────────────────────────────────────►│
         │                              │                      │                     │
         │                              │          Meet verifies hub_jwt against     │
         │                              │          auth-api JWKS (public keys)       │
         │                              │          → aud=="meet" ✓, exp OK ✓         │
         │                              │                      │                     │
         │◄──── 201 {id, joinUrl, hostUrl} ─────────────────────────────────────────┤
```

### Two S2S Token Modes

| Mode | When to use | JWT `sub` | `act.sub` | User claims |
| --- | --- | --- | --- | --- |
| **M2M** (machine-to-machine) | Technical calls without user context | Calling app slug | absent | No |
| **Delegated** (on behalf of) | Calls on behalf of a logged-in user | userId (Keycloak sub) | Calling app slug | Yes (`org_id`, `roles`) |

The **delegated** mode is the most common for front-end → backend → other backend apps. This is the mode used by Calendar→Meet ("create a meeting on behalf of the user").

### Endpoint `POST /api/auth/service-token`

**Authentication**: `X-API-Key: <dynamic_api_key>` (Hub-internal) or `Authorization: Bearer <keycloak_token>` (external)

**Body**:

```json
{
  "target_audience": "meet",
  "on_behalf_of": {
    "session_id": "95a3fea2-7c8b-47bf-b694-de7c0c55b2ff"
  }
}
```

| Field | Required | Description |
| --- | --- | --- |
| `target_audience` | Yes | Slug of the target app |
| `on_behalf_of` | No | If present → delegated mode |
| `on_behalf_of.session_id` | Conditional | Hub session ID of the user |

**Response (200)**:

```json
{
  "data": {
    "access_token": "<hub_jwt>",
    "token_type": "Bearer",
    "expires_in": 300
  }
}
```

**Errors**:

| Status | Code | Cause | Action |
| --- | --- | --- | --- |
| 400 | Validation | Invalid body | Check target_audience |
| 401 | `SESSION_NOT_FOUND` | Hub session expired or not found | Re-login user |
| 403 | `SERVICE_TOKEN_CALLER_UNRESOLVED` | Static key used (no `callerAppSlug`) | Migrate to a dynamic key |
| 403 | Policy deny | Caller not in `trustedApps` | Configure trustedApps in the registry |
| 503 | Registry unavailable | App Registry down | Restart the Hub |

### `trustedApps` Configuration in the App Registry

Each target app declares **who is allowed** to request S2S tokens targeting it:

| Field | Type | Description |
| --- | --- | --- |
| `trustedApps` | `string[]` | Slugs of authorized Hub apps (e.g. `["calendar"]`) |
| `trustedOidcClients` | `string[]` | Authorized external Keycloak client IDs |

**Configuration**: via the App Registry seed or via the API `PUT /api/registry/apps/:slug`.

> **Known bug**: the Hub admin UI (hub-shell) **does not expose** the `trustedApps` / `trustedOidcClients` fields (see spec fix `004-admin-missing-trusted-apps-ui`). Workaround: direct API call or Prisma seed.

```javascript
// Via the browser console on hub.modelo.dev (admin)
const me = await fetch("https://auth.modelo.dev/api/auth/me", {
  credentials: "include",
}).then((r) => r.json());

await fetch("https://hub.modelo.dev/api/registry/apps/meet", {
  method: "PUT",
  credentials: "include",
  headers: {
    "Content-Type": "application/json",
    "X-CSRF-Token": me.data.csrfToken,
  },
  body: JSON.stringify({
    trustedApps: ["calendar"],
  }),
}).then((r) => r.json());
```

Or via the App Registry Prisma seed (`apps/app-registry/prisma/seed.ts`):

```typescript
await prisma.app.upsert({
  where: { slug: 'meet' },
  create: {
    slug: 'meet',
    name: 'Modelo Meet',
    apiKey: 'meet-dev-api-key-s2s-000000000000', // ≥ 32 chars
    trustedApps: ['calendar'],
    // ...
  },
  update: { trustedApps: ['calendar'] },
});
```

### JWKS Verification on the Receiving App (Meet)

The target app verifies the Hub JWT with the auth-api's public JWKS:

```
GET {HUB_AUTH_URL}/.well-known/jwks.json  (public, no auth)
```

Verification middleware (Hono example):

```typescript
import { createRemoteJWKSet, jwtVerify } from 'jose';

const jwksUrl = `${process.env.HUB_SERVICE_AUTH_ISSUER}/.well-known/jwks.json`;
const JWKS = createRemoteJWKSet(new URL(jwksUrl));

async function verifyHubServiceToken(token: string) {
  const { payload } = await jwtVerify(token, JWKS, {
    issuer: process.env.HUB_SERVICE_AUTH_ISSUER,
    audience: process.env.APP_SLUG, // "meet"
    clockTolerance: 30,
  });
  return payload; // { sub, aud, act, org_id, roles, mode, exp, ... }
}
```

---

## Registration Procedure

### Step 1: Verify the Admin Session

In the **browser console** on `https://hub.modelo.dev`:

```javascript
fetch("https://auth.modelo.dev/api/auth/me", { credentials: "include" })
  .then((r) => r.json())
  .then((d) =>
    console.log("isAdmin:", d.data?.isAdmin, "| roles:", d.data?.roles),
  );
```

**Expected**: `isAdmin: true`, `roles: ["hub-admin"]`

| Result               | Cause                                 | Solution                                         |
| -------------------- | ------------------------------------- | ------------------------------------------------ |
| `isAdmin: false`     | Email not in `INITIAL_ADMIN_EMAILS`   | Log in again with a listed email                 |
| `SyntaxError` (HTML) | Wrong domain                          | Use `auth.modelo.dev`, not `hub.modelo.dev`      |
| `401`                | Session expired                       | Log out / log back in                            |

### Step 2: Register the App via the API

The Hub admin UI may have validation bugs (incorrect `integrationType` enum). Prefer a direct API call.

```javascript
const me = await fetch("https://auth.modelo.dev/api/auth/me", {
  credentials: "include",
}).then((r) => r.json());

const result = await fetch("https://hub.modelo.dev/api/registry/apps", {
  method: "POST",
  credentials: "include",
  headers: {
    "Content-Type": "application/json",
    "X-CSRF-Token": me.data.csrfToken,
  },
  body: JSON.stringify({
    slug: "<APP_SLUG>",
    name: "<APP_NAME>",
    description: "<description>",
    originDomain: "host.docker.internal:<FRONTEND_PORT>",
    subdomainUrl: "<APP_SLUG>.modelo.dev",
    ssoMode: "oidc",
    integrationType: "native",
    category: "tools",
  }),
}).then((r) => r.json());

console.log(
  "Registered:",
  result.data?.slug,
  "| API Key:",
  result.data?.apiKey,
);
```

| Field             | Description                                      | Example                     |
| ----------------- | ------------------------------------------------ | --------------------------- |
| `slug`            | Unique identifier (lowercase, hyphens)           | `calendar`                  |
| `originDomain`    | `host.docker.internal` + port exposed on the host | `host.docker.internal:3101` |
| `ssoMode`         | SSO protocol                                     | `oidc`                      |
| `integrationType` | Integration mode                                 | `native`                    |

### Step 3: Configure the App's `.env`

The environment variable is called **`HUB_AUTH_URL`** (not `HUB_BASE_URL`). This name reflects that the URL points to the Hub's **auth-api**, not the Hub shell (frontend).

> **IMPORTANT**: `HUB_AUTH_URL` is the **origin** of the auth-api (e.g. `http://auth-api:3000`). Do NOT append a path (`/api`). The SDK concatenates `/api/auth/session/introspect` automatically. If `HUB_AUTH_URL` ends with `/api`, the resulting URL will be `.../api/api/auth/...` (double `/api`).

#### Direct Docker Access via `modelo-network` (Recommended)

The backend calls `auth-api` directly via the Docker network `modelo-network`, over HTTP, without going through Traefik or TLS. This is the **recommended mode in dev**: simple, reliable, no certificate management.

```env
# Direct HTTP to auth-api container via modelo-network
HUB_AUTH_URL=http://auth-api:3000
APP_API_KEY=<key from ALLOWED_API_KEYS of auth-api>
APP_SLUG=<slug>
APP_SESSION_SECRET=<secure secret>
FRONTEND_URL=https://<slug>.modelo.dev
```

**`compose.yml` configuration**:

```yaml
services:
  backend:
    environment:
      HUB_AUTH_URL: ${HUB_AUTH_URL:-http://auth-api:3000}
    networks:
      - <app>-app-network   # app's internal network
      - modelo-network       # shared network with the Hub

networks:
  <app>-app-network:
  modelo-network:
    external: true
```

**Why this mode**:

- **No TLS**: backend → auth-api communication is internal to the Docker network, no certificates needed
- **No `extra_hosts`**: Docker DNS resolves `auth-api` directly on `modelo-network`
- **No dependency on mkcert, OrbStack, or Docker Desktop**: works everywhere
- **Reliable**: no circuit breaker opening due to TLS issues

**Prerequisite**: the `modelo-network` network must exist (created by the Hub). If the Hub is not started, `docker compose up` will fail with `network modelo-network declared as external, but could not be found`. Start the Hub first (`make up` in the Hub repo).

> **Note**: only the backend needs `modelo-network` (for direct access to `auth-api`). The frontend does **not** need it for authentication — but it is also on `modelo-network` so that Traefik can reach it directly (`{slug}.modelo.dev` routing).

#### Hostname `auth-api` vs `modelo-auth-api`

The hostname to use in `HUB_AUTH_URL` depends on the Hub configuration:

- If the Hub uses `container_name: modelo-auth-api` → `http://modelo-auth-api:3000`
- If the Hub has no `container_name` → `http://auth-api:3000` (Compose service name)

Check with: `docker ps --filter network=modelo-network --format '{{.Names}}'`

The `.env.example` should document both variants:

```env
# Direct HTTP to auth-api container via modelo-network.
# Use the container name visible on modelo-network:
#   docker ps --filter network=modelo-network --format '{{.Names}}'
HUB_AUTH_URL=http://auth-api:3000
```

#### Why NO TLS Between Containers

Backend → auth-api communication happens **entirely on the internal Docker network** (`modelo-network`). This network is isolated from the outside — only containers connected to it can communicate. Traffic never leaves the host machine.

TLS between Docker containers on a local bridge network provides no additional security and adds significant complexity (certificate management, trust stores, `extra_hosts`, mkcert/OrbStack dependency). In production, the reverse proxy (Traefik, Nginx, etc.) terminates TLS at the cluster entry point — internal communications remain HTTP.

#### Why NOT `NODE_TLS_REJECT_UNAUTHORIZED=0`

Even in direct HTTP mode, never add this variable. It disables **all** TLS verification globally in the Node.js process, including for legitimate outgoing calls (Sentry, npm, third-party APIs). If the connection mode ever changes, this variable would mask TLS errors instead of reporting them.

### Step 4: Docker Network + Local DNS

#### 4a. `originDomain` and Traefik Routing to the App

The `originDomain` registered in the Hub App Registry tells Traefik **where to route traffic** for `{slug}.modelo.dev`.

**Recommended approach: `host.docker.internal`**

```
originDomain: "host.docker.internal:<FRONTEND_PORT>"
```

Traefik (in the Hub network) resolves `host.docker.internal` to the host machine. The app's frontend exposes its port on the host (e.g. `3101:3101` in `compose.yml`). Traefik thus reaches the frontend via the host.

**Why this approach**:
- **Simplicity**: no dependency on container naming
- **Portability**: works regardless of Hub / App startup order
- **Reliable**: `host.docker.internal` is always resolved by Docker

> **Note**: although the frontend is also on `modelo-network` (for Traefik routing), `host.docker.internal` remains preferable for `originDomain` because it does not depend on the container name.

#### 4b. Local DNS

The browser must resolve `{slug}.modelo.dev` to `127.0.0.1`.

| OS            | File                                    | Command                                                                         |
| ------------- | --------------------------------------- | ------------------------------------------------------------------------------- |
| Linux         | `/etc/hosts`                            | `echo "127.0.0.1 <slug>.modelo.dev" >> /etc/hosts`                              |
| Windows (WSL) | `C:\Windows\System32\drivers\etc\hosts` | `Add-Content -Path ... -Value "127.0.0.1 <slug>.modelo.dev"` (PowerShell admin) |
| macOS         | `/etc/hosts`                            | `sudo sh -c 'echo "127.0.0.1 <slug>.modelo.dev" >> /etc/hosts'`                 |

### Step 5: Configure Entitlements

For users to access the app, the feature `app:<slug>:access` must be in a plan linked to the tenant.

In dev, the Hub seeds a **"Starter"** plan with a subscription for `org-acme`. Add the feature:

```javascript
const me = await fetch("https://auth.modelo.dev/api/auth/me", {
  credentials: "include",
}).then((r) => r.json());
const plans = await fetch(
  "https://hub.modelo.dev/api/entitlements/admin/plans",
  {
    credentials: "include",
    headers: { "X-CSRF-Token": me.data.csrfToken },
  },
).then((r) => r.json());

const plan = plans.data.find((p) => p.name === "Starter");
await fetch(`https://hub.modelo.dev/api/entitlements/admin/plans/${plan.id}`, {
  method: "PUT",
  credentials: "include",
  headers: {
    "Content-Type": "application/json",
    "X-CSRF-Token": me.data.csrfToken,
  },
  body: JSON.stringify({
    name: plan.name,
    features: [
      ...plan.features,
      { key: "app:<APP_SLUG>:access", enabled: true, quota: null },
    ],
  }),
})
  .then((r) => r.json())
  .then((d) => console.log(JSON.stringify(d, null, 2)));
```

**Verify**: reload the Hub catalog — the app should change from "UPGRADE REQUIRED" to "AVAILABLE".

### Step 6: Implement Authentication on the App Side

The app must expose at minimum:

| Endpoint          | Method | Auth                    | Role                       |
| ----------------- | ------ | ----------------------- | -------------------------- |
| `/api/hub/me`     | GET    | Cookie `session_{slug}` | Returns the current user   |
| `/api/hub/logout` | POST   | Cookie `session_{slug}` | Local logout               |
| `/api/hub/health` | GET    | None                    | Health check               |

**`/api/hub/me` logic** (agnostic pseudo-code):

```
sessionId = read_cookie("session_{slug}")
if not sessionId:
    return 401 {"error": "NO_SESSION"}

hubSession = hub_sdk.introspect_session(sessionId)
localUser  = find_or_create_user(hubSession.userId, hubSession.user.email)

return 200 {userId: localUser.id, email: localUser.email, ...}
```

**Auth guard logic** (pseudo-code):

```
sessionId = read_cookie("session_{slug}") OR read_bearer_token()
if not sessionId:
    return 401

hubSession = hub_sdk.introspect_session(sessionId)
localUser  = find_or_create_user(hubSession)
request.user = localUser
continue
```

**NestJS example**:

```typescript
// Guard — reads session_calendar, introspects via Hub SDK
const sessionId = this.parseCookies(request.headers.cookie)["session_calendar"];
const session = await this.hubClient.introspectSession(sessionId);
const user = await this.provisioning.provisionFromSession(session);
request.user = user;
```

**Laravel (PHP) example**:

```php
// Middleware
$sessionId = $request->cookie('session_myapp');
$session = $this->hubClient->introspectSession($sessionId);
$user = User::firstOrCreate(['hub_user_id' => $session->userId], [...]);
Auth::login($user);
```

**FastAPI (Python) example**:

```python
# Dependency
session_id = request.cookies.get("session_myapp")
session = hub_client.introspect_session(session_id)
user = get_or_create_user(session["userId"], session["user"]["email"])
request.state.user = user
```

### Step 7: Configure the Frontend

The frontend must:

1. On load, call `GET /api/hub/me` (with `credentials: 'include'`)
2. If 200 → user is authenticated, display the app
3. If 401 → redirect to `hub.modelo.dev` (the Hub will re-trigger the authorize flow)
4. On public pages (RSVP, sharing) → **do not redirect**, display the page

```
// Frontend pseudo-code
user = await fetch("/api/hub/me", {credentials: "include"})

if (user.ok) {
    renderApp(user)
} else if (currentPage.isPublic) {
    renderPublicPage()  // NO redirect
} else {
    window.location = "https://hub.modelo.dev"
}
```

**Vite** — add the domain to allowed hosts:

```typescript
server: {
  allowedHosts: ['<slug>.modelo.dev'],
}
```

### Step 8: Configure Inter-App S2S (If Needed)

If the app needs to call another Hub backend (e.g. Calendar → Meet), configure S2S:

#### 8a. On the Calling App Side (Calendar)

1. **Dynamic key**: `APP_API_KEY` must be a registry key (not static). See "API Keys: Three Systems".
2. **Service token**: implement the call to `POST {HUB_AUTH_URL}/api/auth/service-token`
3. **Subject token**: resolve the Hub session ID from cookies (`session_{slug}` or `hub_subject_{slug}`)
4. **Internal Docker URL**: the target app must be reachable via the Docker network (e.g. `http://modelo-meet-backend-1:3001`), **not** via the external URL (`https://meet.modelo.dev`)

```env
# .env of the calling app
APP_API_KEY=calendar-dev-api-key-s2s-00000000   # Dynamic key from registry
MEET_BASE_URL=http://modelo-meet-backend-1:3001  # Docker-internal, NOT https://
```

#### 8b. On the Target App Side (Meet)

1. **`trustedApps`**: add the calling app's slug in the registry
2. **JWKS**: configure the verification middleware with the auth-api JWKS
3. **Variables**: `HUB_SERVICE_AUTH_ISSUER` (auth-api URL for JWKS)

#### 8c. On the Hub Side

1. **S2S enabled**: `HUB_SERVICE_TOKEN_ISSUANCE_ENABLED=true` on auth-api
2. **RSA signing key** configured
3. **Apps registered** in the registry with their dynamic `apiKey`s
4. **Policy**: `trustedApps` configured on the target app

---

## Inter-App Integration Guide — Calendar→Meet Lessons Learned

This guide documents the **complete** S2S integration procedure between two Hub apps, based on the real Calendar → Meet experience. Encountered issues are documented to avoid reproducing them.

### S2S Integration Checklist

```
App1 → App2 Integration (S2S delegated)
═══════════════════════════════════════

Hub Prerequisites:
├── [ ] auth-api: HUB_SERVICE_TOKEN_ISSUANCE_ENABLED=true
├── [ ] auth-api: RSA signing keys configured
├── [ ] auth-api: /.well-known/jwks.json accessible (public)
└── [ ] modelo-network created and shared between apps

App Registry:
├── [ ] App1 (caller) registered with dynamic apiKey (≥ 32 chars)
├── [ ] App2 (target) registered with dynamic apiKey
└── [ ] App2.trustedApps includes "app1"
    ⚠️  Hub admin UI does NOT show trustedApps → use direct API or seed

App1 (caller) — .env:
├── [ ] APP_API_KEY = <App1 dynamic key from registry>    ← NOT dev-api-key!
├── [ ] HUB_AUTH_URL = http://<auth-api-container>:3000   ← Docker-internal
└── [ ] APP2_BASE_URL = http://<app2-container>:<port>    ← Docker-internal, NOT https://

App1 (caller) — Code:
├── [ ] Resolve Hub session ID from cookies
│       (session_{slug} opaque Hub, NOT the local JWT)
├── [ ] POST /api/auth/service-token with X-API-Key + target_audience + on_behalf_of
├── [ ] Extract data.access_token from response (envelope {data: ...})
└── [ ] Call App2 with Authorization: Bearer <hub_jwt>

App2 (target) — Code:
├── [ ] Middleware: verify Bearer via auth-api JWKS (jose)
├── [ ] Verify aud == its own slug
└── [ ] Extract sub (userId) and act.sub (calling app) from JWT

Docker:
├── [ ] App1 backend on modelo-network
├── [ ] App2 backend on modelo-network
└── [ ] Test connectivity: docker exec <app1> wget -qO- http://<app2>:<port>/health
```

### Encountered Issues and Solutions

#### Issue 1 — `403 SERVICE_TOKEN_CALLER_UNRESOLVED`

**Symptom**: The Hub validates the API key but returns 403 with code `SERVICE_TOKEN_CALLER_UNRESOLVED`.

**Hub logs**:
```
[HUB:VALIDATE_API_KEY] matched static key (no callerAppSlug!) — returning ok=true WITHOUT callerAppSlug
[HUB:SERVICE_TOKEN] FAIL: API key valid but NOT tied to a registry app (static key?)
```

**Root cause**: `APP_API_KEY=dev-api-key` is a **static** key (in `ALLOWED_API_KEYS`). It works for `/session/introspect` but NOT for `/service-token` which needs a `callerAppSlug` to verify `trustedApps`.

**Fix**:
1. Register the app in the App Registry with a dynamic `apiKey` (via seed or API)
2. Set the dynamic key in `APP_API_KEY` of the `.env`
3. `docker compose up -d backend` (not `restart`!)

**Time wasted**: ~30 min debugging. **Lesson**: always verify the API key is dynamic (linked to a slug) when using S2S.

#### Issue 2 — `401 SESSION_NOT_FOUND` (Stale Hub Cookie)

**Symptom**: After re-login in the Hub, `/service-token` returns `401 SESSION_NOT_FOUND`. Yet the user is authenticated in Calendar.

**Hub logs**:
```
[HUB:INTROSPECT_SESSION] FAIL: session not found in store
SESSION_NOT_FOUND: Session not found: 5e80f62a-3695-45a2-8a7b-6c84c9fcf4b1
```

**Root cause**: after a Hub re-login, the browser carries **two `session_{slug}` cookies**:
- A local JWT (set by Calendar `/bootstrap` on the subdomain)
- An opaque Hub session ID (set by `/authorize` on `.modelo.dev`)

Calendar's `/api/hub/me` endpoint "short-circuits" when the local JWT is valid → it never refreshes the `hub_subject_{slug}` cookie with the **new** Hub session ID. The next S2S call uses the old session ID (expired/deleted from Redis).

**Fix**: in the `/api/hub/me` controller, add a `refreshHubSubjectCookie` logic that:
1. Parses **all** `session_{slug}` cookies (not just the first one)
2. Identifies an opaque Hub session ID (non-JWT) among them
3. Updates `hub_subject_{slug}` if different from the current one

```typescript
private refreshHubSubjectCookie(req: Request, res: Response): void {
  const rawCookie = req.headers.cookie;
  if (!rawCookie) return;

  const cookieName = this.bridgeService.getCookieName();
  const allValues = this.parseAllCookieValues(rawCookie, cookieName);
  const freshHubSessionId = allValues.find((v) => !isLocalSessionToken(v));

  if (!freshHubSessionId) return;

  const currentSubject = parseCookieValue(
    rawCookie,
    this.bridgeService.getHubSubjectCookieName(),
  );
  if (currentSubject === freshHubSessionId) return;

  res.cookie(
    this.bridgeService.getHubSubjectCookieName(),
    freshHubSessionId,
    this.bridgeService.getCookieOptions(),
  );
}
```

**Time wasted**: ~1h debugging. **Lesson**: when the browser carries multiple cookies with the same name (different domains), you must parse **all** values and distinguish local JWT vs opaque Hub session.

#### Issue 3 — `fetch failed` / `ECONNREFUSED` (Docker URL)

**Symptom**: The S2S token is obtained successfully, but the HTTP call to the target app fails.

**Calendar logs**:
```
[MEET_CLIENT] => POST https://meet.modelo.dev/api/internal/meetings
HttpException: fetch failed
```

**Root cause**: `MEET_BASE_URL=https://meet.modelo.dev` is the **external** URL (Traefik). From inside the Docker container, this URL is not routable or refuses the connection.

**Fix**: use the Docker-internal URL:
```env
MEET_BASE_URL=http://modelo-meet-backend-1:3001
```

Verify connectivity: `docker exec calendar-backend wget -qO- http://modelo-meet-backend-1:3001/health`

**Time wasted**: ~10 min. **Lesson**: all backend→backend communication in Docker must use Docker-internal hostnames, never external Traefik URLs.

#### Issue 4 — Admin UI Does Not Show `trustedApps`

**Symptom**: Unable to configure `trustedApps` via the Hub admin interface.

**Root cause**: spec 040 wired the backend API but the hub-shell frontend was not updated (see bug report `004-admin-missing-trusted-apps-ui`). The `RegistryApp` type, the Zod form schema, and the `AppForm` component do not declare these fields.

**Workaround**: use the direct API or Prisma seed (see examples in the "`trustedApps` Configuration" section above).

**Lesson**: do not rely on the admin UI for recent S2S features. Always plan a direct API or seed path.

---

## Troubleshooting

### Decision Tree — "It Doesn't Work"

```
Is the app in the Hub catalog?
├── NO → Step 2 (registration) + Step 5 (entitlements)
└── YES
    │
    Does clicking "Launch" redirect to {slug}.modelo.dev?
    ├── NO (DNS_PROBE / ERR_NAME_NOT_RESOLVED)
    │   → Step 4b (local DNS: /etc/hosts)
    ├── NO (Vite "Blocked request. This host is not allowed")
    │   → allowedHosts in vite.config
    ├── NO (ERR_CONNECTION_REFUSED)
    │   → Check originDomain (`host.docker.internal:<PORT>`) + exposed port
    └── YES
        │
        Does the app display content?
        ├── NO (redirect loop → hub.modelo.dev)
        │   │
        │   Is the backend receiving requests?
        │   ├── NO → check frontend proxy (Vite/Nginx → backend)
        │   └── YES
        │       │
        │       Is the session_{slug} cookie present?
        │       ├── NO → see "Missing Cookie" below
        │       └── YES
        │           │
        │           Does Hub introspection succeed?
        │           ├── 401 INVALID_API_KEY → see "API Keys"
        │           ├── 401 SESSION_NOT_FOUND → session expired, re-login
        │           ├── UNABLE_TO_VERIFY_LEAF → see "TLS" below
        │           ├── ECONNREFUSED → see "Network" below
        │           └── 200 OK → bug in app code (provisioning, response)
        │
        └── YES
            │
            Does the app call another Hub backend (S2S)?
            ├── NO → Done!
            └── YES
                │
                Does /service-token succeed?
                ├── 403 SERVICE_TOKEN_CALLER_UNRESOLVED
                │   → APP_API_KEY is static! Migrate to a dynamic key (registry)
                │   → See "Issue 1" in the inter-app guide
                │
                ├── 401 SESSION_NOT_FOUND
                │   → Hub session expired or stale hub_subject cookie
                │   → Re-login + check refreshHubSubjectCookie
                │   → See "Issue 2" in the inter-app guide
                │
                ├── 403 Policy deny (trustedApps)
                │   → Caller not in target app's trustedApps
                │   → Configure via seed or API (admin UI doesn't show this field!)
                │
                ├── 200 OK → token obtained, does the call to target app fail?
                │   ├── fetch failed / ECONNREFUSED
                │   │   → External URL (Traefik) from Docker → use Docker-internal hostname
                │   │   → See "Issue 3" in the inter-app guide
                │   ├── 401/403 on target app side
                │   │   → Check JWKS config, audience, middleware
                │   └── 200/201 → S2S works!
                │
                └── Other error → check Hub auth-api logs
```

### Missing `session_{slug}` Cookie

**Symptom**: the backend logs "cookies: NONE" or the cookie does not appear in DevTools.

**Main cause**: the cookie is set by the Hub auth-api during `/api/auth/authorize`. If the user accesses `{slug}.modelo.dev` directly without going through the Hub, the cookie does not exist.

**Verification**:

1. Go to `hub.modelo.dev` → log in
2. Click on the app in the catalog (do not type the URL directly)
3. Check in DevTools → Application → Cookies → `{slug}.modelo.dev` that `session_{slug}` is present

**SameSite gotcha**: the `session_{slug}` cookie is `SameSite=Lax`. It is sent for top-level navigations (GET) and same-origin requests. But it is **not** sent for cross-origin `fetch()` calls (e.g. from `hub.modelo.dev` to `calendar.modelo.dev`). This is why the bootstrap must go through the Hub redirect, not via a cross-site `fetch` call.

**Anti-pattern**: trying to read `session_hub` from the app's frontend to do a "local bootstrap". The `session_hub` cookie is `HttpOnly` and even though it is on `.modelo.dev`, modern browsers increasingly restrict third-party cookies in `fetch()`.

### API Keys — 401 INVALID_API_KEY

**Symptom**: `Hub request failed (401) on "/api/auth/session/introspect"`, code `INVALID_API_KEY`.

**Cause**: `APP_API_KEY` in the app's `.env` does not match `ALLOWED_API_KEYS` in the Hub compose.

**Diagnosis**:

```bash
# Key used by the app
docker inspect <app-backend> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep APP_API_KEY

# Keys accepted by the Hub
docker inspect <auth-api-container> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep ALLOWED_API_KEYS
```

**Fix (introspection only)**: copy the value from `ALLOWED_API_KEYS` into `APP_API_KEY` in the app's `.env`.

**Fix (S2S needed)**: use a **dynamic** key from the registry (see "API Keys: Three Systems"). Static keys do NOT work for `/service-token`.

> **Warning**: the `apiKey` returned by `POST /api/registry/apps` is not the same as the one in the registry database. The registration API's `apiKey` is the registry key (Traefik routing). For S2S, the app must use its own dynamic `apiKey` configured in the seed.

### TLS — UNABLE_TO_VERIFY_LEAF_SIGNATURE

**Symptom**: `fetch failed`, cause `UNABLE_TO_VERIFY_LEAF_SIGNATURE`.

**Cause**: `HUB_AUTH_URL` points to `https://auth.modelo.dev` instead of `http://auth-api:3000`. The backend tries to go through Traefik over HTTPS, but the mkcert certificate is not in the container's trust store.

**Fix**: use direct Docker access (HTTP) via `modelo-network` — no TLS needed.

```env
HUB_AUTH_URL=http://auth-api:3000
```

If for a specific reason HTTPS mode via Traefik is needed, see the notes below.

<details>
<summary>HTTPS mode via Traefik (not recommended in dev)</summary>

Requires resolving `auth.modelo.dev` to the host and trusting the mkcert certificate:

1. **`extra_hosts`**: `"auth.modelo.dev:host-gateway"` in the compose
2. **Trust store**:
   - **OrbStack**: `NODE_OPTIONS: --use-openssl-ca` (OrbStack injects its CA into `/etc/ssl/certs/`, the flag tells Node.js to use the system trust store instead of its internal Mozilla snapshot)
   - **Docker Desktop**: mount the mkcert CA + `NODE_EXTRA_CA_CERTS`

Never use `NODE_TLS_REJECT_UNAUTHORIZED=0` — disables all TLS verification.

</details>

### Network — ECONNREFUSED / fetch failed

**Symptom**: `fetch failed`, cause `ECONNREFUSED` or `ENOTFOUND`.

**Checklist** (direct access via `modelo-network`):

1. **Is the backend on `modelo-network`?** Check in `compose.yml` that the backend service has `modelo-network` in its `networks`.

2. **Does the `modelo-network` network exist?** The Hub must be started first.
   ```bash
   docker network ls | grep modelo-network
   ```

3. **Is the auth-api container running?**
   ```bash
   docker ps --filter network=modelo-network --format '{{.Names}}'
   ```

4. **Does the hostname in `HUB_AUTH_URL` match the name visible on the network?**
   ```bash
   # Direct test from the backend
   docker compose exec backend wget -qO- http://auth-api:3000/health
   # If ENOTFOUND, try the Hub's container_name:
   docker compose exec backend wget -qO- http://modelo-auth-api:3000/health
   ```

5. **Is the port correct?** Port `3000` is the auth-api container's internal port, not a port exposed on the host. Do not use `443` or `80`.

### Circuit Breaker — HubCircuitOpenError

**Symptom**: `HubCircuitOpenError: Circuit is open for feature "auth"` — all requests fail immediately.

**Cause**: the `@septeo-immo/hub-sdk` SDK includes a circuit breaker. After 5 consecutive failures (default threshold), the circuit opens and **blocks all requests for 30 seconds** without even attempting the network call.

**Default parameters**:

| Parameter | Value | Effect |
| --- | --- | --- |
| `threshold` | 5 | Opens after 5 consecutive failures |
| `resetTimeout` | 30,000 ms | Waits 30s before a half-open probe |
| `retries` | 2 | Each request is retried 2x |

Each user request generates 3 attempts (1 + 2 retries). Two quick requests (bootstrap + /me) = 6+ failures → circuit open.

**Diagnosis**: look in the logs for the **first** error (before `HubCircuitOpenError`). That one reveals the actual cause:

- `ECONNREFUSED` → network issue (see above)
- `UNABLE_TO_VERIFY_LEAF_SIGNATURE` → TLS issue (see above)
- `401 INVALID_API_KEY` → wrong API key

**Fix**: fix the root cause, then **restart the backend** (`docker compose restart backend`). The circuit breaker is in-memory and resets on restart.

### Hub ↔ App Redirect Loop

**Symptom**: `{slug}.modelo.dev` → redirects to `hub.modelo.dev` → redirects to `{slug}.modelo.dev` → loop.

**Possible causes** (by frequency):

1. **Missing `session_{slug}` cookie** — the user did not go through the `/api/auth/authorize` flow. See "Missing Cookie" above.

2. **Introspection fails** — the backend receives the cookie but introspection returns 401 (API key, expired session, TLS). See the corresponding sections.

3. **Frontend redirects too early** — `fetchMe()` returns 401, the frontend redirects to the Hub before allowing time for the cookie to be processed. Verify that `isLoading` blocks rendering during the call.

4. **Backend reads the wrong cookie** — e.g. reads `session_hub` instead of `session_{slug}`, or tries to verify a JWT when it's a Hub session ID.

### Public Pages (RSVP, Sharing) — Unwanted Redirect

**Symptom**: an external user (not logged into the Hub) accesses `/rsvp?token=xxx` and gets redirected to the Hub.

**Cause**: the frontend triggers `onUnauthorized` (Hub redirect) when `/api/hub/me` returns 401, even on public pages.

**Fix**: do not trigger the Hub redirect on public pages.

```
// Pseudo-code
if (response.status === 401 && currentPage.isPublic) {
    // Do NOT redirect — let the public page display
    throw ApiError(401)
}
```

**Backend side**: public endpoints must be marked to bypass the auth guard (e.g. `@Public()` in NestJS, conditional middleware in PHP/Python).

### Email URLs (RSVP, Invitations)

**Symptom**: links in emails point to `localhost:3101` instead of `{slug}.modelo.dev`.

**Cause**: the `FRONTEND_URL` variable is not configured or not passed to the backend container.

**Fix**:

1. Add `FRONTEND_URL=https://{slug}.modelo.dev` in `.env`
2. Ensure `FRONTEND_URL` is in the backend's `environment` section in `compose.yaml`
3. Restart the backend

---

## API Reference

### App Registry

| Endpoint                   | Method | Description      |
| -------------------------- | ------ | ---------------- |
| `/api/registry/apps`       | GET    | List apps        |
| `/api/registry/apps`       | POST   | Create an app    |
| `/api/registry/apps/:slug` | GET    | App details      |
| `/api/registry/apps/:slug` | PUT    | Update an app    |
| `/api/registry/apps/:slug` | DELETE | Delete an app    |

### Entitlements Admin

| Endpoint                                | Method | Description            |
| --------------------------------------- | ------ | ---------------------- |
| `/api/entitlements/admin/plans`         | GET    | List plans             |
| `/api/entitlements/admin/plans`         | POST   | Create a plan          |
| `/api/entitlements/admin/plans/:id`     | PUT    | Update a plan          |
| `/api/entitlements/admin/subscriptions` | GET    | List subscriptions     |
| `/api/entitlements/admin/subscriptions` | POST   | Create a subscription  |

**Auth required**: cookie `session_hub` + header `X-CSRF-Token` + role `hub-admin`.

### Auth API (Introspection + S2S)

| Endpoint | Method | Auth | Description |
| --- | --- | --- | --- |
| `/api/auth/authorize` | GET | Cookie `session_hub` | Creates app session + redirects |
| `/api/auth/session/introspect` | POST | Header `X-API-Key` | Validates a session ID |
| `/api/auth/me` | GET | Cookie `session_hub` | Returns the current user |
| `/api/auth/service-token` | POST | `X-API-Key` (Hub-internal) or `Bearer` (external) | Issues a Hub S2S JWT (M2M or delegated) |
| `/.well-known/jwks.json` | GET | None (public) | JWKS public keys for verification |

### App Registry (Internal — S2S Policy)

| Endpoint | Method | Auth | Description |
| --- | --- | --- | --- |
| `/api/registry/internal/apps/:slug/service-token-policy` | GET | Internal (auth-api → registry) | Returns `trustedApps`, `trustedOidcClients`, `status`, `killSwitch` |

---

## Anti-Patterns

| Anti-pattern | Why it's wrong | Alternative |
| --- | --- | --- |
| Local bootstrap (read `session_hub` to create a local JWT) | The Hub already sets `session_{slug}` via `/authorize` | Introspect `session_{slug}` directly |
| `HUB_AUTH_URL=https://auth.modelo.dev` in dev | Requires TLS (mkcert, OrbStack, `extra_hosts`) | `http://auth-api:3000` via `modelo-network` |
| `HUB_AUTH_URL` with path (`/api`) | The SDK appends `/api/auth/...` → double `/api/api/auth/...` | Origin only: `http://auth-api:3000` |
| `NODE_TLS_REJECT_UNAUTHORIZED=0` hardcoded | Disables all TLS security (Sentry, npm, etc.) | Use direct HTTP via `modelo-network` |
| Calling `/api/auth/me` on `hub.modelo.dev` | It's on `auth.modelo.dev` | Check the domain |
| Confusing `apiKey` (registry) and `APP_API_KEY` (introspection) | Three distinct systems | See "API Keys: Three Systems" |
| Redirecting to the Hub on public pages | External users have no session | Condition the redirect on the page type |
| `FRONTEND_URL=http://localhost:3101` in Hub mode | Emails will contain localhost links | `FRONTEND_URL=https://{slug}.modelo.dev` |
| `HUB_AUTH_URL=https://hub.modelo.dev:3000` | Wrong hostname + wrong port | `http://auth-api:3000` (Docker direct) |
| **Static key `dev-api-key` for S2S** | No `callerAppSlug` → 403 `SERVICE_TOKEN_CALLER_UNRESOLVED` | Dynamic key in the App Registry |
| **External Traefik URL for inter-backend calls** | `fetch failed` / `ECONNREFUSED` from Docker | Docker-internal hostname (`http://service:port`) |
| **`docker compose restart` after `.env` change** | `restart` does not re-read the `.env` | `docker compose up -d <service>` (recreation) |
| **Configuring `trustedApps` via admin UI** | Fields not exposed in the form | Direct API `PUT /api/registry/apps/:slug` or seed |
| **Parsing only the first `session_{slug}` cookie** | After re-login, the browser carries 2 cookies (local JWT + Hub opaque) | Parse all, look for the opaque (non-JWT) one |

### `hub.modelo.dev` vs `auth.modelo.dev` Gotcha

`hub.modelo.dev` points to the **Hub shell** (React frontend). The authentication API is on `auth.modelo.dev`. Traefik routing:

- `hub.modelo.dev` → `hub-shell:3001` (SPA) — catch-all, returns HTML
- `auth.modelo.dev` + `PathPrefix(/api)` → `auth-api:3000` (API) — returns JSON

If `HUB_AUTH_URL` points to `hub.modelo.dev`, the SDK calls `hub.modelo.dev/api/auth/session/introspect` which hits the SPA catch-all and returns HTML instead of JSON → the circuit breaker opens.

Port `:3000` is the **internal** port of the `modelo-auth-api` container. It is not exposed on the host nor accessible via Traefik (which listens on 443).
