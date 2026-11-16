// tests/shared/wait-for-target.ts — Playwright globalSetup: prove that both
// origins answer before any project starts, and fail with the command to run.
//
// Playwright's `webServer` waits for ONE url and expects to own the process
// that serves it. A compose stack serves two origins (frontend, API) and is
// owned by `make up`, so readiness is checked here instead, for every target:
// locally it catches a stack that is not up, remotely a VPN that is not.
import { env, isRemote } from "./env";

const TIMEOUT_MS = isRemote ? 30_000 : 120_000;

async function answers(origin: string): Promise<boolean> {
  try {
    // Any HTTP status proves the origin is reachable; 404 on "/" is fine.
    const res = await fetch(origin, { redirect: "manual", signal: AbortSignal.timeout(5_000) });
    return res.status > 0;
  } catch {
    return false;
  }
}

async function waitFor(name: string, origin: string): Promise<void> {
  const deadline = Date.now() + TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (await answers(origin)) return;
    await new Promise((r) => setTimeout(r, 1_000));
  }
  const hint = isRemote ? "check the URL and your network access" : "run `make up` first";
  throw new Error(`TEST_ENV=${env.TEST_ENV}: ${name}=${origin} did not answer within ${TIMEOUT_MS / 1000}s — ${hint}`);
}

export default async function globalSetup(): Promise<void> {
  await Promise.all([waitFor("E2E_BASE_URL", env.E2E_BASE_URL), waitFor("API_BASE_URL", env.API_BASE_URL)]);
}
