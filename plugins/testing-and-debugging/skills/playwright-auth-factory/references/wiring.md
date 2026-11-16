# Wiring the state file into Playwright

## One environment, one state file

```ts
// playwright.config.ts
import { defineConfig } from "@playwright/test";

const environment = process.env.ENVIRONMENT ?? "staging";

export default defineConfig({
  globalSetup: "./e2e/global-setup.ts",
  use: {
    baseURL: process.env.BASE_URL,
    storageState: `.auth/${environment}.json`,
  },
});
```

```ts
// e2e/global-setup.ts
import { execFileSync } from "node:child_process";

export default function globalSetup(): void {
  // stdout is the state file path; stderr carries the redacted report and any
  // password prompt, so it must stay attached to the terminal.
  const path = execFileSync(process.execPath, ["scripts/auth-state.mjs"], {
    env: { ...process.env, ENVIRONMENT: process.env.ENVIRONMENT ?? "staging" },
    encoding: "utf8",
    stdio: ["inherit", "pipe", "inherit"],
  }).trim();
  process.env.STORAGE_STATE = path;
}
```

`process.execPath` rather than the string `"node"`: it runs the same runtime
Playwright is running under, which matters when a version manager puts a
different one first on `PATH`.

## Several roles, several state files

Mint one file per role and select it per project. A single shared file forces
every test to be the same user, which hides authorization bugs.

```ts
export default defineConfig({
  projects: [
    { name: "admin",  use: { storageState: `.auth/${environment}.admin.json` } },
    { name: "member", use: { storageState: `.auth/${environment}.member.json` } },
    // A project with no storageState is how you test the logged-out paths.
    { name: "anon",   use: { storageState: { cookies: [], origins: [] } } },
  ],
});
```

## Tests that must not share the session

```ts
test.use({ storageState: { cookies: [], origins: [] } });
```

## What never goes in the repository

```gitignore
.auth/
.env.*
!.env.*.example
```

`.auth/*.json` holds a live session: anyone with the file is logged in as that
user until it expires. Treat it exactly like the password that produced it.

## CI

Give CI its own environment file, written from the runner's secret store at the
start of the job, never committed:

```bash
umask 077
printf '%s\n' "$E2E_ENV_FILE" > .env.ci      # one secret holding the whole file
ENVIRONMENT=ci npm run auth:state
```

One secret carrying the whole file beats five separate variables: the file stays
the single shape the script already validates, and a missing key fails at the
same place locally and in CI.

```json
{
  "scripts": {
    "auth:state": "node scripts/auth-state.mjs"
  }
}
```
