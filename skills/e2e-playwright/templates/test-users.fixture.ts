// One dedicated test user per spec file: no collision under parallel execution.
// Keep the pool at 20+ users so it absorbs growth in spec files.
import { test as base, type Page } from '@playwright/test';

const E2E_USER_COUNT = 20;
type E2eUserKey = `e2e-test-${string}`;

export const E2E_USERS: Record<string, { email: string; displayName: string }> =
  Object.fromEntries(
    Array.from({ length: E2E_USER_COUNT }, (_, i) => {
      const num = String(i + 1).padStart(2, '0');
      return [
        `e2e-test-${num}`,
        { email: `e2e-test-${num}@test.local`, displayName: `E2E Tester ${num}` },
      ];
    }),
  );

// One entry per spec file.
export const FILE_USER_MAP: Record<string, E2eUserKey> = {
  'auth.spec.ts': 'e2e-test-01',
  'calendar.spec.ts': 'e2e-test-02',
};

function resolveFileUser(testFilePath: string): E2eUserKey {
  const fileName = testFilePath.split('/').pop() ?? '';
  return FILE_USER_MAP[fileName] ?? 'e2e-test-01';
}

// Project-specific login (dev login endpoint, cookie injection, ...).
declare function login(page: Page, user: E2eUserKey): Promise<void>;

export const test = base.extend<{ testUser: E2eUserKey; authenticatedPage: Page }>({
  testUser: async ({}, use, testInfo) => {
    await use(resolveFileUser(testInfo.file));
  },
  authenticatedPage: async ({ page, testUser }, use) => {
    await login(page, testUser);
    await use(page);
  },
});
