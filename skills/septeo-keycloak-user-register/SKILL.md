---
name: septeo-keycloak-user-register
description: "Register users via the Septeo Keycloak Identity API (api-identite). Use when implementing user registration, signup forms, user provisioning, or password hashing for the Septeo SSO. Covers the PATCH /v1/register endpoint with PBKDF2-SHA256 password hashing."
---

# Septeo Keycloak — User Registration via API

Procedure to register a user with password via the Septeo Identity API (`api-identite`). The API refuses plaintext passwords by design — the client must hash passwords using PBKDF2-SHA256 before sending.

## When to Use This Skill

- Implement a custom signup/registration form against Septeo SSO
- Provision users programmatically via the Identity API
- Debug failed logins after user creation via API
- Understand the password hashing requirements for Septeo Keycloak

---

## Architecture Overview

```
Backend (your app)                 Identity API                    Keycloak
─────────────────                  ────────────                    ────────
     │                                  │                              │
  1. │── POST /token ──────────────────▶│                              │
     │◀── {access_token} ──────────────│                              │
     │                                  │                              │
  2. │── PATCH /v1/register ───────────▶│                              │
     │   Authorization: Bearer <token>  │                              │
     │   Body: {user + hashed pwd       │── Create user ──────────────▶│
     │          + access roles}         │   (PBKDF2 hash stored as-is) │
     │◀── {realm, username} ───────────│                              │
     │                                  │                              │
  3. │                                  │                    User logs in
     │                                  │                    with original
     │                                  │                    password ✓
```

## Prerequisites

- A service account with credentials for the Septeo SSO realm (`sso-septeo`)
- The `client_id` and `client_secret` for your a

---

## The Working Flow (Step by Step)

### Step 1: Obtain an Access Token

```
POST https://login-sandbox.septeo.fr/auth/realms/sso-septeo/protocol/openid-connect/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials&client_id=<CLIENT_ID>&client_secret=<CLIENT_SECRET>
```

Response:

```json
{
  "access_token": "eyJhb...HZBu-A",
  "expires_in": 14400,
  "token_type": "Bearer",
  "scope": "openid email profile roles"
}
```

### Step 2: Hash the Password (Client-Side)

**CRITICAL**: The Identity API does NOT accept plaintext passwords. You must hash client-side using Keycloak's native algorithm.

| Parameter | Value | Notes |
|-----------|-------|-------|
| Algorithm | PBKDF2-SHA256 | Keycloak's native default |
| Iterations | `27500` | Keycloak standard (as string) |
| Salt | 16 random bytes | Encoded in Base64 |
| Hash output | PBKDF2 result | Encoded in Base64 |

#### Node.js / TypeScript Example

```typescript
import { randomBytes, pbkdf2Sync } from 'crypto';

function hashPasswordForKeycloak(password: string) {
  const salt = randomBytes(16);
  const hash = pbkdf2Sync(password, salt, 27500, 32, 'sha256');

  return {
    hash: hash.toString('base64'),
    hashType: 'pbkdf2-sha256',
    salt: salt.toString('base64'),
    nbIteration: '27500',
    temporary: false,
  };
}
```

#### Python Example

```python
import os, hashlib, base64

def hash_password_for_keycloak(password: str) -> dict:
    salt = os.urandom(16)
    hash_bytes = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 27500, dklen=32)

    return {
        "hash": base64.b64encode(hash_bytes).decode(),
        "hashType": "pbkdf2-sha256",
        "salt": base64.b64encode(salt).decode(),
        "nbIteration": "27500",
        "temporary": False,
    }
```

### Step 3: Register the User

```
PATCH https://api-identite-sandbox.septeo.fr/v1/register
Authorization: Bearer <access_token>
Content-Type: application/json
```

Payload:

```json
{
  "user": {
    "email": "jean.dupont@example.com",
    "firstName": "Jean",
    "lastName": "Dupont",
    "password": {
      "hashType": "pbkdf2-sha256",
      "nbIteration": "27500",
      "salt": "EL5IxzGoFuaj+2ha7csA3Q==",
      "hash": "8Gnd3+G3Ai4KkhdxzgcBWboAkdTtsdq2fKFFqWxQQ1Y=",
      "temporary": false
    },
    "emailVerified": true
  },
  "access": [
    {
      "realm": "sso-immo",
      "app": "modelo-hub",
      "role": "access:granted"
    }
  ]
}
```

Response (success):

```json
{
  "realm": "sso-septeo",
  "username": "jean.dupont@example.com"
}
```

---

## Anti-Patterns (Tested and Failed)

### DO NOT: Use `POST /v1/realms/{realm}/Users` with `credentials`

```json
// WRONG — credentials field is silently ignored
{
  "username": "user@example.com",
  "email": ["user@example.com"],
  "credentials": [
    { "type": "password", "value": "Password!1234", "temporary": false }
  ]
}
```

**Result**: User created WITHOUT password. Login fails with "invalid username or password". The `credentials` array is silently dropped — no error returned. This endpoint mimics the Keycloak Admin API but does NOT support password injection.

### DO NOT: Use bcrypt hashing

```json
// WRONG — bcrypt hash accepted but login fails
{
  "password": {
    "hash": "JDJhJDEwJE45cW84dUxPaWNrZ3gyWk1SWm9O...",
    "hashType": "bcrypt",
    "temporary": false
  }
}
```

**Result**: API returns `201 Created` (false positive!) but login fails silently. Keycloak cannot read bcrypt hashes — it only supports its native PBKDF2-SHA256 format. The API does not validate `hashType` and accepts anything, which is misleading.

### DO NOT: Send plaintext passwords

The Identity API is designed to never transit plaintext passwords. There is no field or endpoint that accepts a raw password string.

### DO NOT: Forget Base64 encoding

Both `hash` and `salt` must be Base64-encoded strings. Raw bytes or hex encoding will cause errors.

### DO NOT: Use `PATCH /v1/register/access` separately

Use the unified `PATCH /v1/register` endpoint which handles both user creation and role assignment in a single transaction.

---

## Endpoint Reference

| Endpoint | Method | Purpose | Password Support |
|----------|--------|---------|-----------------|
| `/v1/realms/{realm}/Users` | POST | Create user (SCIM-like) | NO (credentials ignored) |
| `/v1/register` | PATCH | Create user + assign roles | YES (hashed only) |
| `/v1/register/access` | PATCH | Assign roles to existing user | N/A |

**Always use `PATCH /v1/register`** for user creation with password.

## Environments

| Environment | Identity API | Login |
|-------------|-------------|-------|
| Sandbox | `api-identite-sandbox.septeo.fr` | `login-sandbox.septeo.fr` |
| Production | `api-identite.septeo.fr` | `login.septeo.fr` |

## Password Field Schema

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `hashType` | `string` | Yes | Must be `"pbkdf2-sha256"` (only supported algorithm) |
| `hash` | `string` | Yes | PBKDF2 output, Base64-encoded |
| `salt` | `string` | Yes | Random salt (16 bytes), Base64-encoded |
| `nbIteration` | `string` | Yes | `"27500"` (Keycloak standard, as string not number) |
| `temporary` | `boolean` | No | `true` forces password change on first login |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Login fails after successful register | Wrong `hashType` (e.g. bcrypt) | Use `pbkdf2-sha256` exclusively |
| Login fails, user exists | User created via `/Users` without password | Re-register via `PATCH /v1/register` with hashed password |
| API returns 201 but login fails | False positive — API accepts any `hashType` | Verify `hashType` is exactly `"pbkdf2-sha256"` |
| API error on hash/salt fields | Values not Base64-encoded | Encode both `hash` and `salt` in Base64 |
| `nbIteration` rejected | Sent as number instead of string | Send as `"27500"` (string) |

## Known API Documentation Gaps

These issues exist in the Septeo Swagger/docs as of the time of writing:

1. **`hash` and `salt` not documented as Base64** — Swagger shows `string` without format
2. **`hashType` not restricted** — API accepts any value (including `bcrypt`) without error, but only `pbkdf2-sha256` actually works
3. **`POST /Users` misleading** — Looks like Keycloak Admin API but silently ignores `credentials`
4. **No example payload** in official docs for the working `PATCH /v1/register` flow
