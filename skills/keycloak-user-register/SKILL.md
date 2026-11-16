---
name: keycloak-user-register
description: >-
  Register users with a password through an Identity API that fronts Keycloak
  (PATCH /v1/register, PBKDF2-SHA256 client-side hashing). Use when
  implementing signup forms or user provisioning against such an SSO, or
  debugging logins that fail after a user was created through the API.
tags:
  - auth
  - security
---

# Keycloak user registration via an Identity API

The Identity API never accepts plaintext passwords: the client hashes with
Keycloak's native PBKDF2-SHA256 and the hash is stored as-is, so the user logs
in with the original password. Hosts, realm and credentials are configuration
(`<IDENTITY_API>`, `<LOGIN_HOST>`, `<REALM>`): never commit real values.

`scripts/register.py` does the whole sequence (standard library only; see its
docstring for the environment variables).

## Sequence

1. **Token**: `POST https://<LOGIN_HOST>/auth/realms/<REALM>/protocol/openid-connect/token`
   with `grant_type=client_credentials&client_id=...&client_secret=...`
   (form-encoded). Use `access_token`.
2. **Hash** client-side: PBKDF2-HMAC-SHA256, 27500 iterations, 16 random salt
   bytes, 32-byte output; `hash` and `salt` Base64-encoded.
3. **Register**: `PATCH https://<IDENTITY_API>/v1/register` with
   `Authorization: Bearer <token>` and:

```json
{
  "user": {
    "email": "user@example.com", "firstName": "Jane", "lastName": "Doe",
    "password": {
      "hashType": "pbkdf2-sha256", "nbIteration": "27500",
      "salt": "<base64 salt>", "hash": "<base64 hash>", "temporary": false
    },
    "emailVerified": true
  },
  "access": [{ "realm": "<REALM>", "app": "<APP>", "role": "<ROLE>" }]
}
```

Success returns `{ "realm": "...", "username": "..." }`. `temporary: true`
forces a password change at first login.

## Pitfalls (tested)

| Do not | Why |
|---|---|
| `POST /v1/realms/{realm}/Users` with `credentials` | Looks like the Keycloak Admin API, but `credentials` is silently dropped: user exists without password |
| bcrypt (or any `hashType` other than `pbkdf2-sha256`) | API answers 201 without validating, login then fails |
| Send `nbIteration` as a number | Must be the string `"27500"` |
| Send hex or raw bytes | `hash` and `salt` must be Base64 |
| Call `PATCH /v1/register/access` for new users | `PATCH /v1/register` creates the user and assigns roles in one transaction |

`/v1/register/access` only assigns roles to an existing user.

## Troubleshooting

- Register succeeded, login fails: check `hashType` is exactly
  `pbkdf2-sha256` and that the user was not created through `/Users`
  (re-register with `PATCH /v1/register`).
- Field errors on `hash`/`salt`: Base64 encoding.
- The API documentation of such services often omits the Base64 requirement,
  accepts any `hashType`, and has no example for the working flow: trust this
  sequence over the Swagger.
