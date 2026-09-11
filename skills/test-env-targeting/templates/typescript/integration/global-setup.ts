// tests/integration/global-setup.ts — refuse the wrong target, once.
//
// Runs in Vitest's main process, before the workers start. Anything that
// must reach the tests (a testcontainers URL, for example) goes through
// `provide()` / `inject()`, not through process.env: the workers evaluate
// tests/shared/env.ts on their own and would not see a late assignment.
import type { TestProject } from "vitest/node";
import { env, isRemote } from "../shared/env";

export default async function setup(_project: TestProject): Promise<void> {
  if (env.TEST_ENV === "prod") {
    throw new Error("Integration tests never target prod.");
  }
  if (isRemote && env.TEST_LIVE !== "1") {
    throw new Error(
      `Integration tests target local backing services. TEST_ENV=${env.TEST_ENV} ` +
        "needs TEST_LIVE=1 to opt into the live lane (see references/integration.md).",
    );
  }
  if (!env.DATABASE_URL) {
    throw new Error(`TEST_ENV=${env.TEST_ENV}: DATABASE_URL missing in tests/env/.env.${env.TEST_ENV}`);
  }
  // Optional: apply migrations here so every file starts from the same schema.
  // await runMigrations(env.DATABASE_URL);
}
