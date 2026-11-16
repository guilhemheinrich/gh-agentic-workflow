import { FullConfig } from '@playwright/test';

// Reset first: idempotent even if the previous teardown failed.
export default async function globalSetup(config: FullConfig) {
  const baseURL = config.projects[0].use.baseURL!;
  await fetch(`${baseURL}/api/test/reset`, { method: 'POST' });
  await fetch(`${baseURL}/api/test/seed`, { method: 'POST' }); // E2E users + base data
}
