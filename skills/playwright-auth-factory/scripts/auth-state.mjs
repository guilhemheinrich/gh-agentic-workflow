#!/usr/bin/env node
/**
 * Template: mint a Playwright `storageState` from a per-environment secrets file.
 *
 *   ENVIRONMENT=staging node scripts/auth-state.mjs
 *   ENVIRONMENT=local   node scripts/auth-state.mjs --force
 *
 * Replace ONE function — `authenticate()` — with the recipe that matches your
 * application. Everything else (environment selection, permission checks,
 * freshness reuse, redacted reporting, atomic 0600 write) is app-agnostic and
 * should be left alone.
 *
 * Requires Node 20.12+ for `util.parseEnv`.
 */

import { readFile, writeFile, rename, chmod, mkdir, stat } from "node:fs/promises";
import { parseArgs, parseEnv } from "node:util";
import { dirname, resolve } from "node:path";
import process from "node:process";

/** Keys `authenticate()` needs. Extend for your app; each one is required. */
const REQUIRED_KEYS = ["BASE_URL", "AUTH_USERNAME", "AUTH_PASSWORD"];

/** Cookies worth exporting. Keep this tight: a jar often holds IdP cookies too. */
const COOKIE_ALLOWLIST = /^(session|csrf|auth)/i;

class Failure extends Error {}

// ── Environment selection ────────────────────────────────────────────────
//
// `util.parseEnv` is used rather than `--env-file` or `process.loadEnvFile()`
// on purpose. Both of those push every key into `process.env`, where any child
// process inherits the password; parseEnv returns a plain object that stays in
// this function's scope. It also sidesteps the precedence trap documented for
// `--env-file`: a variable already present in the environment WINS over the
// file, so a stale `export AUTH_PASSWORD` in your shell silently beats
// `.env.staging` and you debug the wrong credential.
async function loadEnvironment(environment) {
  const path = resolve(process.cwd(), `.env.${environment}`);

  let info;
  try {
    info = await stat(path);
  } catch {
    throw new Failure(
      `secrets file not found: ${path}\n` +
        `Create it from .env.${environment}.example, then: chmod 600 ${path}`,
    );
  }

  const mode = info.mode & 0o777;
  if (mode & 0o077) {
    throw new Failure(
      `${path} is mode ${mode.toString(8)} and holds a password. Run: chmod 600 ${path}`,
    );
  }

  const config = parseEnv(await readFile(path, "utf8"));
  const missing = REQUIRED_KEYS.filter((key) => !config[key]);
  if (missing.length > 0) {
    throw new Failure(`${path}: missing or empty keys: ${missing.join(", ")}`);
  }
  return config;
}

// ── The one function to replace ──────────────────────────────────────────
//
// Contract: return an array of Playwright cookie objects, and optionally an
// `origins` array for localStorage-backed sessions. See references/ for three
// worked recipes (credential endpoint, JWT in localStorage, external cookie jar).
async function authenticate(config) {
  const response = await fetch(new URL("/api/auth/login", config.BASE_URL), {
    method: "POST",
    headers: {
      "content-type": "application/json",
      // Many login routes sit behind an origin/CSRF guard that rejects a
      // request with no Origin. Sending it costs nothing and removes a whole
      // class of confusing 403s.
      origin: new URL(config.BASE_URL).origin,
    },
    body: JSON.stringify({
      email: config.AUTH_USERNAME,
      password: config.AUTH_PASSWORD,
    }),
    redirect: "manual",
    signal: AbortSignal.timeout(Number(config.AUTH_TIMEOUT_MS ?? 20_000)),
  });

  if (!response.ok) {
    const body = (await response.text()).slice(0, 400);
    throw new Failure(`login failed (${response.status}): ${body}`);
  }

  // `getSetCookie()` is the only correct reader: a plain `get("set-cookie")`
  // joins multiple cookies into one comma-separated string, and a cookie value
  // containing a comma then splits into garbage.
  const cookies = response.headers
    .getSetCookie()
    .map((header) => parseSetCookie(header, new URL(config.BASE_URL).hostname))
    .filter((cookie) => COOKIE_ALLOWLIST.test(cookie.name));

  if (cookies.length === 0) {
    throw new Failure("login returned 200 but set no cookie matching the allowlist");
  }
  return { cookies, origins: [] };
}

// ── Set-Cookie -> Playwright cookie ──────────────────────────────────────
function parseSetCookie(header, fallbackDomain) {
  const [pair, ...attributes] = header.split(";");
  const index = pair.indexOf("=");
  const name = pair.slice(0, index).trim();
  const value = pair.slice(index + 1).trim();

  const attrs = new Map(
    attributes.map((attribute) => {
      const [key, ...rest] = attribute.split("=");
      return [key.trim().toLowerCase(), rest.join("=").trim()];
    }),
  );

  const maxAge = attrs.get("max-age");
  const expiresAttr = attrs.get("expires");
  // Playwright spells "session cookie" as -1. A literal 0 is the epoch, which
  // makes the browser drop every cookie on load.
  let expires = -1;
  if (maxAge) expires = Math.floor(Date.now() / 1000) + Number(maxAge);
  else if (expiresAttr) expires = Math.floor(Date.parse(expiresAttr) / 1000);

  const sameSite = (attrs.get("samesite") ?? "Lax").toLowerCase();
  return {
    name,
    value,
    domain: attrs.get("domain") ?? fallbackDomain,
    path: attrs.get("path") || "/",
    expires,
    httpOnly: attrs.has("httponly"),
    secure: attrs.has("secure"),
    sameSite: { strict: "Strict", lax: "Lax", none: "None" }[sameSite] ?? "Lax",
  };
}

// ── Reuse, write, report ─────────────────────────────────────────────────
async function readFreshState(path, marginSeconds) {
  try {
    const state = JSON.parse(await readFile(path, "utf8"));
    const deadline = Date.now() / 1000 + marginSeconds;
    const dated = state.cookies.filter((cookie) => cookie.expires > 0);
    // All-session-cookie states carry no expiry to check, so never reuse them.
    if (dated.length === 0) return null;
    return dated.every((cookie) => cookie.expires > deadline) ? state : null;
  } catch {
    return null;
  }
}

async function writeState(path, state) {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.tmp`;
  await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  await chmod(temporary, 0o600);
  await rename(temporary, path);
}

/** Names and lengths only. A cookie value is a live credential. */
function report(state) {
  const now = Date.now() / 1000;
  for (const cookie of state.cookies) {
    const life = cookie.expires < 0
      ? "session cookie"
      : `expires in ${Math.round(cookie.expires - now)}s`;
    console.error(
      `[auth-state] ${cookie.name}: ${cookie.value.length} chars, ` +
        `domain=${cookie.domain}, httpOnly=${cookie.httpOnly}, ${life}`,
    );
  }
}

// ── Entry point ──────────────────────────────────────────────────────────
const { values } = parseArgs({
  options: {
    out: { type: "string" },
    margin: { type: "string", default: "300" },
    force: { type: "boolean", default: false },
  },
});

const environment = process.env.ENVIRONMENT;
if (!environment) {
  console.error("ERROR: ENVIRONMENT is required, e.g. ENVIRONMENT=staging node scripts/auth-state.mjs");
  process.exit(1);
}

const out = resolve(values.out ?? `.auth/${environment}.json`);

try {
  if (!values.force) {
    const fresh = await readFreshState(out, Number(values.margin));
    if (fresh) {
      console.error(`[auth-state] ${out} still valid, reusing (--force to refresh)`);
      console.log(out);
      process.exit(0);
    }
  }

  const config = await loadEnvironment(environment);
  const state = await authenticate(config);
  await writeState(out, state);
  report(state);
  console.error(`[auth-state] wrote ${out} (mode 600)`);
  // The path is the only thing on stdout, so this composes:
  //   export STORAGE_STATE=$(ENVIRONMENT=staging node scripts/auth-state.mjs)
  console.log(out);
} catch (error) {
  console.error(`ERROR: ${error instanceof Failure ? error.message : error}`);
  process.exit(1);
}
