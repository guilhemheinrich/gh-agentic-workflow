---
name: hub-app-registration
description: >-
  Register a downstream application in an SSO "Hub" ecosystem (app registry,
  auth-api session introspection, service-to-service tokens, Traefik routing).
  Use when onboarding a new app, configuring Hub authentication, debugging
  registration/auth/S2S issues, or understanding the Hub SSO flow.
tags:
  - auth
  - common
  - docker
  - hub
---

# Hub app registration and authentication

Backend-agnostic (Node, PHP, Python, Go). Placeholders: `<HUB_DOMAIN>` (Hub
shell), `<AUTH_DOMAIN>` (Keycloak + auth-api), `<BASE_DOMAIN>` (apps live at
`<slug>.<BASE_DOMAIN>`), `<HUB_NETWORK>` (shared Docker network),
`<HUB_SDK>` (the Hub client library).

## Architecture

- Hub services behind Traefik (TLS): Keycloak (IdP), `auth-api`,
  `app-registry`, `entitlements`, Hub shell frontend.
- `<AUTH_DOMAIN>`: Keycloak, except `/api/*` and `/health` -> `auth-api`.
  `<HUB_DOMAIN>`: `/api/registry/*` -> app-registry, `/api/entitlements/*` ->
  entitlements, rest -> Hub shell. `<slug>.<BASE_DOMAIN>` -> the app frontend.
- Traefik polls `app-registry` (`/api/registry/traefik`, every 30 s): each
  active app gets a router on `subdomainUrl` and a service on `originDomain`.
  New apps are routable only after the next poll.
- Use `originDomain = host.docker.internal:<FRONTEND_PORT>` (frontend port
  published on the host): independent of container names and start order.
- `subdomainUrl` MUST be exactly `<slug>.<BASE_DOMAIN>`: auth-api rejects other
  `redirect_url`s with `INVALID_REDIRECT_TARGET`.

## Auth flow

1. User clicks "Launch" in the Hub: `GET <AUTH_DOMAIN>/api/auth/authorize
   ?target_slug=<slug>&redirect_url=https://<slug>.<BASE_DOMAIN>` with the
   `session_hub` cookie.
2. auth-api creates the app session and 302s back, setting
   `session_<slug>` (opaque session id, not a JWT; `Domain=<BASE_DOMAIN>`,
   HttpOnly, Secure, SameSite=Lax). The Hub sets it, not the app.
3. App backend reads `session_<slug>` and introspects it:
   `POST {HUB_AUTH_URL}/api/auth/session/introspect` with `X-API-Key` and
   `{sessionId}` -> `{userId, email, roles, expiresAt}`. Then find-or-create the
   local user. No local bootstrap from `session_hub`, no local JWT required.
4. Frontend calls `GET /api/hub/me` (credentials included). 200: render. 401:
   redirect to `<HUB_DOMAIN>`, except on public pages (token links, sharing),
   which must render without redirect and whose backend routes bypass the
   guard (`@Public()` or equivalent).

Every app exposes `GET /api/hub/me`, `POST /api/hub/logout`,
`GET /api/hub/health` (no auth).

## API keys: three different things

| Key | Where | Good for | Knows the caller? |
|---|---|---|---|
| Registry `apiKey` | `POST /api/registry/apps` response | Traefik routing, catalog | No |
| Static `APP_API_KEY` | `ALLOWED_API_KEYS` in auth-api env | Introspection only | No |
| Dynamic `APP_API_KEY` | `apiKey` column in the registry (seed/admin) | Introspection and S2S | Yes (`callerAppSlug`) |

Static keys on `/service-token` give `403 SERVICE_TOKEN_CALLER_UNRESOLVED`. A
dynamic key is >= 32 chars. After changing `.env` use `docker compose up -d
<service>`: `restart` does not re-read it.

## Registration procedure

1. **Admin session**: on `<HUB_DOMAIN>` console,
   `fetch('https://<AUTH_DOMAIN>/api/auth/me',{credentials:'include'})` must
   give `isAdmin: true` (email in `INITIAL_ADMIN_EMAILS`). `/api/auth/me` lives
   on `<AUTH_DOMAIN>`, not `<HUB_DOMAIN>` (that one returns the SPA HTML).
2. **Register** via the API (the admin UI has enum validation bugs):
   `POST https://<HUB_DOMAIN>/api/registry/apps` with cookie, header
   `X-CSRF-Token` (from `/api/auth/me`, `data.csrfToken`) and
   `{slug, name, description, originDomain, subdomainUrl, ssoMode: "oidc",
   integrationType: "native", category: "tools"}`. Other routes: `GET/PUT/DELETE
   /api/registry/apps/:slug`.
3. **App `.env`**: `HUB_AUTH_URL=http://auth-api:3000` (origin only, no
   `/api`: the SDK appends `/api/auth/...`), `APP_API_KEY`, `APP_SLUG`,
   `APP_SESSION_SECRET`, `FRONTEND_URL=https://<slug>.<BASE_DOMAIN>` (also
   passed in the backend `environment`, or emails get localhost links).
4. **Docker**: backend (and frontend) join `<HUB_NETWORK>` (`external: true`;
   start the Hub first). Backend -> auth-api is plain HTTP on that network:
   no TLS, no `extra_hosts`, never `NODE_TLS_REJECT_UNAUTHORIZED=0`. The
   hostname is the service name or the Hub's `container_name`: check with
   `docker ps --filter network=<HUB_NETWORK> --format '{{.Names}}'`. Port 3000
   is internal, not published.
5. **Local DNS**: `127.0.0.1 <slug>.<BASE_DOMAIN>` in the hosts file. Vite:
   `server.allowedHosts: ['<slug>.<BASE_DOMAIN>']` and a `/api` proxy to the
   backend (without it the SPA HTML answers `/api/hub/me` and the app bounces).
6. **Entitlements**: users need feature `app:<slug>:access` in a plan of their
   tenant. `PUT /api/entitlements/admin/plans/:id` with the plan's features plus
   `{key: "app:<slug>:access", enabled: true, quota: null}` (same cookie and
   CSRF header; role `hub-admin`). Catalog flips from UPGRADE REQUIRED to
   AVAILABLE.

Dev-only shortcut without an admin session: insert the rows directly in the
registry DB (`apps`, with `apiKey`, `originDomain`, `subdomainUrl`) and the
entitlements DB (`entitlement_plan_apps`, one row per plan), through
`docker exec -i <postgres-container> psql`. It skips validation, CSRF and
audit log; the `apiKey` you choose must be copied into the app's `APP_API_KEY`.

## Service-to-service (S2S)

auth-api is the single trust point: it signs 5-minute JWTs with an RSA key and
publishes JWKS at `<auth>/.well-known/jwks.json` (public). Receivers verify
only that JWKS, never Keycloak.

- Caller: `POST {HUB_AUTH_URL}/api/auth/service-token`, `X-API-Key: <dynamic
  key>`, body `{target_audience: "<target slug>", on_behalf_of: {session_id}}`
  (`on_behalf_of` omitted = M2M mode, `sub` = caller slug; present = delegated,
  `sub` = user, `act.sub` = caller). Response `{data: {access_token, expires_in}}`.
- Target registry entry must list the caller in `trustedApps` (or an external
  client in `trustedOidcClients`) via `PUT /api/registry/apps/:slug` or the
  seed: **the admin UI does not expose these fields**.
- Receiver verifies `Authorization: Bearer` with `jose`
  (`createRemoteJWKSet`, `issuer`, `audience = own slug`, `clockTolerance: 30`).
- Backend -> backend calls use Docker-internal URLs
  (`http://<target-container>:<port>`), never the external Traefik URL.
- Hub prerequisites: service token issuance enabled, RSA keys configured,
  JWKS reachable.

| Error | Cause / fix |
|---|---|
| 403 `SERVICE_TOKEN_CALLER_UNRESOLVED` | Static key: use a dynamic registry key |
| 403 policy deny | Caller missing from target `trustedApps` |
| 401 `SESSION_NOT_FOUND` | Hub session gone (often after Hub re-login: the browser holds two `session_<slug>` cookies, a local JWT and the opaque id; parse all values and refresh the subject cookie from the non-JWT one) |
| 503 | App registry down |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| App not in catalog | Not registered or no entitlement |
| `ERR_NAME_NOT_RESOLVED` | Hosts file entry |
| Vite "host not allowed" | `allowedHosts` |
| `ERR_CONNECTION_REFUSED` | `originDomain`/published port; wait for Traefik poll |
| Redirect loop app <-> Hub | No `session_<slug>` cookie (user typed the URL instead of launching from the Hub); introspection failing; frontend redirecting before `isLoading` ends; backend reading `session_hub` |
| `401 INVALID_API_KEY` | `APP_API_KEY` not in `ALLOWED_API_KEYS` (introspection) or not a dynamic key (S2S) |
| `UNABLE_TO_VERIFY_LEAF_SIGNATURE` | `HUB_AUTH_URL` is the HTTPS Traefik URL: use `http://auth-api:3000` |
| `ECONNREFUSED`/`ENOTFOUND` | Backend not on `<HUB_NETWORK>`, Hub down, wrong hostname/port (test with `wget -qO- http://auth-api:3000/health` from the backend) |
| `HubCircuitOpenError` | SDK circuit opens after 5 failures for 30 s (3 attempts per request). Read the first error before it, fix, restart the backend |
| HTML instead of JSON from the SDK | `HUB_AUTH_URL` points to `<HUB_DOMAIN>` (SPA catch-all) instead of auth-api |
| Cookie missing on cross-site `fetch` | `SameSite=Lax`: the bootstrap must go through the Hub redirect |

Compare keys with `docker inspect <container> --format '{{range
.Config.Env}}{{println .}}{{end}}' | grep -E 'APP_API_KEY|ALLOWED_API_KEYS'`.

## Declarative manifest

A `<app>.manifest.json` at the project root only documents slug, origin, SSO
mode and bridge endpoints: it registers nothing. The Hub SDK configures the
introspection client; it does not register the app.
