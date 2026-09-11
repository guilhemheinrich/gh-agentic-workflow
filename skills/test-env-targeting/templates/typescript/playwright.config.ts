// tests/playwright.config.ts — one config, one target, categories as projects.
//
// Projects encode the CATEGORY (api / e2e), never the environment and not
// the lane either: the environment is `env.TEST_ENV`, chosen before this
// file loads, and the lane is a `--grep` the Makefile composes (LANE=fast).
// A project-level `grep` would AND with that --grep and silently drop every
// spec that lacks the lane tag. A "staging" project is the other
// anti-pattern: it duplicates lanes and diverges on demo data.
//
// No `webServer`: it waits for one URL and wants to own the process behind
// it, while a compose stack serves two origins and belongs to `make up`.
// Readiness of both origins is checked once in globalSetup instead.
import { defineConfig, devices } from "@playwright/test";
import { env } from "./shared/env";

export default defineConfig({
  testDir: ".",
  globalSetup: "./shared/wait-for-target.ts",
  fullyParallel: true,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? [["github"], ["html", { open: "never" }]] : "list",
  use: { trace: "on-first-retry", screenshot: "only-on-failure" },

  projects: [
    {
      name: "api",
      testDir: "./api",
      use: { baseURL: env.API_BASE_URL },
    },
    {
      name: "e2e",
      testDir: "./e2e",
      use: { ...devices["Desktop Chrome"], baseURL: env.E2E_BASE_URL },
    },
  ],
});
