---
name: playwright-auth-factory
description: >-
  Build the authentication script a Playwright suite needs, so no test — and no
  agent — ever types a credential into a login form. A script reads a
  per-environment secrets file, obtains a session out of band, and writes a
  Playwright `storageState` the browser starts from; the secret goes from disk
  to the network without passing through a prompt, a transcript, or a page
  object. Ships a runnable Node template (`scripts/auth-state.mjs`, Node 20.12+,
  `util.parseEnv`) covering environment selection by `ENVIRONMENT=<name>`,
  mode-600 enforcement, session reuse, atomic writes and redacted reporting,
  plus three recipes for the ways a session is actually obtained — a credential
  endpoint, a JWT in localStorage, an existing cookie jar — and the browser-once
  recipe for logins that cannot be scripted at all (MFA, CAPTCHA, consent).
  Use when writing or reviewing E2E authentication setup, when an agent refuses
  to fill a password field, when adding a second environment or a second role to
  a suite, or when a storageState loads but the app still shows logged out.
tags:
  - e2e
  - playwright
  - authentication
  - node
---

# Playwright auth factory

## The problem this solves

An agent driving Playwright will not type a password into a form, and it should
not. The reflex — "then I cannot test the authenticated app" — is wrong. The
login form was never the point; the **session** is. Produce the session another
way and hand it to the browser.

Playwright's name for that is `storageState`: a JSON file of cookies and
per-origin `localStorage` entries, loaded before the first navigation. A suite
that starts from one never sees a login page.

The whole skill is one script per application, and this shape:

```
.env.staging ──► auth-state script ──► .auth/staging.json ──► browser starts logged in
   (mode 600)      (the only reader)       (mode 600)
```

## Step 1 — answer three questions before writing anything

Everything downstream follows from these. Getting them from the running app
takes minutes; guessing costs an afternoon of a state file that loads and
changes nothing.

**Where does the session live?** Open the app, log in by hand, then look:

```js
// In the browser console, on the app's origin:
document.cookie                      // non-httpOnly cookies only
Object.keys(localStorage)            // SPA token storage
```

The httpOnly cookies do not appear in `document.cookie` — read those from the
network panel's `Set-Cookie`, or from the server's source. Their absence from
the console is exactly why a `localStorage`-only guess fails: the real session
was a cookie you could not see.

| Where it lives | What the script produces |
|---|---|
| Cookie (httpOnly or not) | `cookies[]` |
| JWT / token in `localStorage` | `origins[].localStorage[]` |
| Both (token plus a refresh cookie) | both, in one state file |

**How is it obtained without a browser?** In decreasing order of preference:

1. A credential endpoint the app already exposes — one request, one `Set-Cookie`.
   The template's default.
2. A token endpoint (`grant_type=password`). Works only when the realm holds the
   users itself; see the trap below.
3. A tool that already holds a session — a shell script, a CLI, another team's
   helper. Convert its cookie jar rather than building a second mechanism.
4. None of the above: a real browser, once, with a human. `recipe-browser-once.mjs`.

**How many roles?** One state file per role, selected per Playwright project.
A single shared file makes every test the same user and hides authorization
bugs. See `references/wiring.md`.

## Step 2 — the environment file convention

One file per environment at the project root, named for the environment, chosen
by an environment variable:

```bash
ENVIRONMENT=staging npm run auth:state
ENVIRONMENT=local   npm run auth:state
```

```
.env.local              mode 600, never committed
.env.local.example      committed, no values, documents every key
.env.staging            mode 600, never committed
.env.staging.example    committed
```

**Never edit one file in place to point it at another environment.** That is the
accident separate files exist to design out: a script that authenticates against
production because nobody noticed which values were loaded. The same reasoning
puts the environment name in the output path — `.auth/staging.json`, not
`.auth/session.json` — so a stale state file cannot be silently reused against
the wrong target.

The `.example` file is where the reasoning goes: what each key is, which are
optional, what breaks when one is wrong. It is committed, so it is the
documentation that cannot drift away from the code that reads it.

## Step 3 — how modern Node reads that file

Node handles this natively now; no `dotenv` dependency.

| Approach | Available since | What it does |
|---|---|---|
| `node --env-file=.env.staging app.js` | v20.6.0 | loads into `process.env`, errors if the file is missing |
| `node --env-file-if-exists=.env.local app.js` | v22.9.0 (unflagged v22.21.0 / v24.10.0) | same, tolerates absence |
| `process.loadEnvFile(path)` | v20.12.0 | the same load, from inside the program |
| `util.parseEnv(contents)` | v20.12.0 | parses to a **plain object**, touching nothing |

**The template uses `util.parseEnv`, and the reason is not style.** The other
three push every key into `process.env`, where **any child process inherits the
password** — a spawned browser, a `git` call, a test reporter. `parseEnv` returns
an object that stays in the function that asked for it.

It also sidesteps a trap in the flag-based approaches, documented in Node's own
CLI reference: *if the same variable is defined in the environment and in the
file, the value from the environment takes precedence.* A stale
`export AUTH_PASSWORD` in your shell silently beats `.env.staging`, and you debug
a credential that is not the one being sent.

Multiple `--env-file` flags stack, later overriding earlier — useful for a
committed base plus a local override, and worth knowing before you build that
layering by hand.

## Step 4 — start from the template

`scripts/auth-state.mjs` is runnable as it stands. Copy it into the target
project, then **replace one function**: `authenticate(config)`. Everything else
is application-agnostic and already handles the parts that are easy to get
subtly wrong.

Adapt, in order:

1. `REQUIRED_KEYS` — the keys your `authenticate()` reads. Each one is checked
   before the network call, so a missing key fails with its own name rather than
   as a 401.
2. `COOKIE_ALLOWLIST` — which cookies belong in the state file.
3. `authenticate()` — the recipe that matches your answers from step 1.

Recipes, all in `references/`:

- `recipe-jwt-localstorage.mjs` — token endpoint, `origins[].localStorage`.
- `recipe-external-jar.mjs` — convert a curl Netscape cookie jar.
- `recipe-browser-once.mjs` — a human logs in once; the only recipe that
  survives MFA, CAPTCHA or a JavaScript-rendered IdP form.

Wiring into `playwright.config.ts`, per-role state files, `.gitignore` and CI:
`references/wiring.md`.

## Invariants every generated script holds

These are in the template already. Keep them when you adapt it; each one is a
real failure that has happened.

- **Refuses a secrets file that is group- or world-readable.** Cheap check,
  catches the common mistake before the password is read.
- **Prints names and lengths, never values.** `session_app: 36 chars,
  httpOnly=true, expires in 3600s`. A cookie value is a live credential; it does
  not belong in a terminal, a CI log, or a conversation.
- **Writes the state file mode 600, atomically** (temp file then rename), so a
  crashed run leaves no half-written state that loads as "logged out".
- **Reuses a still-valid state file**, with a margin. Sessions outlive test runs;
  authenticating once per lifetime instead of once per run is the difference
  between a password used daily and one used hourly.
- **Puts only the path on stdout**, everything else on stderr, so it composes:
  `export STORAGE_STATE=$(ENVIRONMENT=staging npm run --silent auth:state)`.

## Traps, each one measured

**`grant_type=password` against a brokered realm cannot work.** If the realm the
app points at does not hold users itself — it federates to a corporate IdP — a
password grant has no local user to match. The failure looks exactly like a
wrong password. Check what the realm is before designing around this path; when
it brokers, use recipe 3 or 4.

**`response.headers.get("set-cookie")` is wrong.** It joins multiple cookies into
one comma-separated string, and any cookie value containing a comma then splits
into garbage. Use `response.headers.getSetCookie()`, which returns an array.

**An expiry of `0` is not "no expiry".** Playwright spells a session cookie
`-1`. A literal `0` is the Unix epoch, so the browser drops the cookie on load
and the app renders logged out with no error anywhere.

**A cookie on the wrong domain is never sent.** If the server sets
`Domain=.example.com`, the state file must say `.example.com`, leading dot
included — not the hostname you happened to request. Copy what `Set-Cookie`
says; do not derive it from the URL.

**`storageState` seeds `localStorage` per origin, not per page.** A token stored
under `https://app.example.com` is invisible to a test that opens
`https://example.com`. Match the origin exactly, scheme and port included.

**The Netscape jar format carries no SameSite field.** When converting a curl
jar, read the real value from the server's `Set-Cookie` once and hardcode it.
Defaulting to `Lax` is usually right and occasionally the reason a cross-site
redirect drops the session.

## Proving it works

A state file that loads is not a state file that authenticates. The check:

```ts
test("the session state authenticates", async ({ page }) => {
  await page.goto("/");
  // Assert on something only an authenticated user sees, and do it without a
  // fixed timeout — a redirect to the login page resolves fast and passes a
  // naive "no error" assertion.
  await expect(page.getByTestId("user-menu")).toBeVisible();
  expect(page.url()).not.toContain("/login");
});
```

Run it once with a deliberately emptied state file. If it still passes, it is
asserting on something a logged-out user also sees, and it will not catch the
day authentication breaks.

## What an agent may and may not do

**May**: run the script, read its redacted report, write and wire the config,
convert a cookie jar, and assert on the result.

**May not**: read a `.env.<environment>` file into its context, echo a cookie or
token value, copy a secrets file to another path, or type a credential into a
form — including `page.fill("#password", ...)`.

The script is the boundary. That is its whole purpose: it lets an agent build,
run and debug the authenticated suite end to end while the credential stays
between the disk and the server.
