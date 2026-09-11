// tests/shared/env.ts — the single typed view of the test target.
//
// Imported by playwright.config.ts (so the run fails before the first test)
// and by vitest setupFiles. Everything downstream reads `env`, never
// process.env, so a missing variable has exactly one error message.
//
// The canonical loader is tests/env/with-env.sh. The fallback below makes a
// bare `npx playwright test` from an IDE work the same way, using Node's
// built-in process.loadEnvFile (Node >= 20.12 / 21.7). No dotenv package.
// The bare path is a convenience for local and staging; prod goes through
// with-env.sh, which is the only thing that sets PROD_CONFIRM.
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";

export const TEST_ENVS = ["local", "staging", "prod"] as const;
export type TestEnvName = (typeof TEST_ENVS)[number];

const here = dirname(fileURLToPath(import.meta.url)); // CommonJS: use __dirname
const envDir = process.env.TEST_ENV_DIR ?? resolve(here, "../env");
if (process.env.TEST_ENV === "") delete process.env.TEST_ENV; // empty counts as unset
const name = process.env.TEST_ENV ?? "local";

// Run flags are honoured only when with-env.sh set them (it leaves the
// TEST_ENV_LOADER marker). In a bare run they are discarded whatever their
// source — a file, or an `export PROD_CONFIRM=1` in a shell profile — so the
// bare path can never reach prod or the live lane.
const RUN_FLAGS = ["PROD_CONFIRM", "TEST_LIVE"] as const;
const loadedByShell = process.env.TEST_ENV_LOADER === "with-env";
const callerFlags = Object.fromEntries(RUN_FLAGS.map((k) => [k, loadedByShell ? process.env[k] : undefined]));

if (typeof process.loadEnvFile !== "function") {
  throw new Error("tests/shared/env.ts needs Node >= 20.12 (process.loadEnvFile), or run through tests/env/with-env.sh");
}
// loadEnvFile never overrides a variable already present, so the .secret
// file is loaded FIRST to win over the committed file. Caller env still wins.
for (const file of [`.env.${name}.secret`, `.env.${name}`]) {
  const path = resolve(envDir, file);
  if (existsSync(path)) process.loadEnvFile(path);
}
for (const k of RUN_FLAGS) {
  if (callerFlags[k] === undefined) delete process.env[k];
  else process.env[k] = callerFlags[k];
}

const httpUrl = z
  .string()
  .url()
  .refine((u) => /^https?:$/.test(new URL(u).protocol), "must be an http(s) URL");

// Both origins are required because the shipped Playwright config has an
// `api` and an `e2e` project. A repo with one surface deletes the other
// field here, its project, and its wait in wait-for-target.ts.
const schema = z
  .object({
    TEST_ENV: z.enum(TEST_ENVS).default("local"),
    E2E_BASE_URL: httpUrl,
    API_BASE_URL: httpUrl,
    DATABASE_URL: z.string().min(1).optional(), // local only
    TEST_USER_EMAIL: z.string().email().optional(),
    TEST_USER_PASSWORD: z.string().min(1).optional(),
    PROD_CONFIRM: z.string().optional(),
    TEST_LIVE: z.string().optional(),
  })
  .superRefine((v, ctx) => {
    if (v.TEST_ENV !== name) {
      ctx.addIssue({
        code: "custom",
        path: ["TEST_ENV"],
        message: `file .env.${name} declares TEST_ENV=${v.TEST_ENV}; the selector and the file disagree`,
      });
    }
    if (v.TEST_ENV === "prod" && v.PROD_CONFIRM !== "1") {
      ctx.addIssue({
        code: "custom",
        path: ["PROD_CONFIRM"],
        message: "TEST_ENV=prod runs only through `make … ENV=prod PROD_CONFIRM=1` (with-env.sh --confirm-prod)",
      });
    }
    if (v.TEST_ENV === "prod" && v.TEST_USER_PASSWORD) {
      ctx.addIssue({
        code: "custom",
        path: ["TEST_USER_PASSWORD"],
        message: "prod is anonymous read-only: no credential may be loaded",
      });
    }
    // A non-prod run must not reach a prod host through a caller override.
    if (v.TEST_ENV !== "prod") {
      const prodHosts = hostsDeclaredIn(resolve(envDir, ".env.prod"));
      for (const key of ["E2E_BASE_URL", "API_BASE_URL"] as const) {
        const host = new URL(v[key]).hostname;
        if (prodHosts.has(host)) {
          ctx.addIssue({
            code: "custom",
            path: [key],
            message: `${v[key]} points at a host declared in .env.prod while TEST_ENV=${v.TEST_ENV}`,
          });
        }
      }
    }
  });

/** Hostnames of every *_BASE_URL declared in a committed env file. */
function hostsDeclaredIn(path: string): Set<string> {
  const hosts = new Set<string>();
  if (!existsSync(path)) return hosts;
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const m = /^[A-Za-z0-9_]*_BASE_URL=["']?([^"'\s]+)/.exec(line.trim());
    if (!m) continue;
    try {
      hosts.add(new URL(m[1]).hostname);
    } catch {
      /* not a URL: ignore */
    }
  }
  return hosts;
}

const parsed = schema.safeParse(process.env);
if (!parsed.success) {
  const issues = parsed.error.issues.map((i) => `  ${i.path.join(".")}: ${i.message}`);
  throw new Error(
    [
      `Invalid test environment for TEST_ENV=${name}`,
      ...issues,
      `Expected in ${envDir}/.env.${name} (secrets: .env.${name}.secret), or exported by the caller.`,
    ].join("\n"),
  );
}

export const env = parsed.data;
/** True when the target is a deployment we do not start ourselves. */
export const isRemote = env.TEST_ENV !== "local";
/** False on prod: only @prod-safe (read-only) tests may run there. */
export const writesAllowed = env.TEST_ENV !== "prod";

/** Credentials for an authenticated journey. Fails loudly, never skips. */
export function requireUser(): { email: string; password: string } {
  if (!env.TEST_USER_EMAIL || !env.TEST_USER_PASSWORD) {
    throw new Error(
      `TEST_ENV=${env.TEST_ENV}: TEST_USER_EMAIL / TEST_USER_PASSWORD missing ` +
        `(email in .env.${env.TEST_ENV}, password in .env.${env.TEST_ENV}.secret)`,
    );
  }
  return { email: env.TEST_USER_EMAIL, password: env.TEST_USER_PASSWORD };
}
