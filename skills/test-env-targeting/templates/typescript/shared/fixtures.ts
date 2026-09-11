// tests/shared/fixtures.ts — import `test` from here, never from
// @playwright/test directly, so the prod guard applies to every spec.
import { test as base, expect } from "@playwright/test";
import { env, writesAllowed, requireUser } from "./env";

export const test = base.extend<{ prodGuard: void }>({
  // Auto fixture: runs before each test. On prod, a test not on the
  // read-only allowlist fails — it does not skip, so a mis-tagged spec is
  // visible in the report instead of silently absent.
  // Needs Playwright >= 1.43: `test(title, { tag }, fn)` arrived in 1.42,
  // `testInfo.tags` one release later.
  prodGuard: [
    async ({}, use, testInfo) => {
      if (!writesAllowed && !testInfo.tags.includes("@prod-safe")) {
        throw new Error(
          `TEST_ENV=prod: "${testInfo.title}" is not tagged @prod-safe. ` +
            "Prod runs the read-only allowlist only.",
        );
      }
      await use();
    },
    { auto: true },
  ],
});

export { expect, env, requireUser };
