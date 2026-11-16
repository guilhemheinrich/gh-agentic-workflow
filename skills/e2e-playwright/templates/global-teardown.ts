import { FullConfig } from '@playwright/test';

// Remove test users and everything they created.
export default async function globalTeardown(config: FullConfig) {
  const baseURL = config.projects[0].use.baseURL!;
  await fetch(`${baseURL}/api/test/cleanup`, { method: 'POST' });
}
