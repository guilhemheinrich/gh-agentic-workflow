import { defineConfig, devices } from '@playwright/test';

const BASE_URL = process.env.BASE_URL ?? 'http://localhost:3000';
const SLOW_MO = process.env.CI ? 0 : Number(process.env.SLOW_MO ?? 50);
type VideoMode = 'off' | 'on' | 'retain-on-failure' | 'on-first-retry';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 1,
  workers: Number(process.env.WORKERS) || undefined,
  globalSetup: require.resolve('./global-setup'),
  globalTeardown: require.resolve('./global-teardown'),

  // HTML for humans, JSON for LLMs and CI analysis (both are required).
  reporter: [
    ['html', { outputFolder: 'playwright-report', open: 'never' }],
    ['json', { outputFile: 'playwright-report/results.json' }],
    ['list'],
  ],

  use: {
    baseURL: BASE_URL,
    actionTimeout: 10_000,
    navigationTimeout: 30_000,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: {
      mode: (process.env.PW_VIDEO as VideoMode) || 'off',
      size: { width: 1280, height: 720 },
    },
    launchOptions: { slowMo: SLOW_MO },
  },

  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ],

  timeout: 60_000,
  expect: { timeout: 10_000 },
});
