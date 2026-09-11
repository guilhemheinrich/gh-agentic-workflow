// tests/integration/vitest.integration.config.ts — integration scope only.
// A separate config file keeps `vitest` (unit) fast and dependency-free;
// this one needs the local backing services from tests/env/.env.local.
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["tests/integration/**/*.test.ts"],
    setupFiles: ["tests/shared/env.ts"],
    globalSetup: ["tests/integration/global-setup.ts"],
    fileParallelism: false, // one shared database
    testTimeout: 30_000,
    hookTimeout: 60_000,
  },
});
