/**
 * Recipe: let a real browser authenticate once, then reuse the result.
 *
 * This is the answer whenever the login cannot be scripted: MFA/OTP, a CAPTCHA,
 * an IdP that renders its form with JavaScript, or a consent screen. A human
 * authenticates once per session lifetime; every later run is offline.
 *
 * It is also the ONLY recipe an agent can run end to end without a human,
 * because the agent never handles the credential — the person types it into a
 * real browser window.
 *
 *   ENVIRONMENT=staging node references/recipe-browser-once.mjs
 */
import { chromium } from "@playwright/test";
import { readFile } from "node:fs/promises";
import { parseEnv } from "node:util";
import process from "node:process";

const environment = process.env.ENVIRONMENT ?? "staging";
const config = parseEnv(await readFile(`.env.${environment}`, "utf8"));
const out = `.auth/${environment}.json`;

// headless:false is the point: the human needs to see the form.
const browser = await chromium.launch({ headless: false });
const context = await browser.newContext();
const page = await context.newPage();

await page.goto(config.BASE_URL);
console.error("[auth-state] complete the login in the browser window, including any second factor.");

// Wait on a signal that authentication SUCCEEDED, never on a fixed timeout.
// A URL alone is weak: some apps land on the target and then bounce back.
await page.waitForURL(new RegExp(config.POST_LOGIN_URL_PATTERN ?? "/dashboard"), { timeout: 300_000 });
await page.getByTestId("user-menu").waitFor({ state: "visible", timeout: 30_000 });

await context.storageState({ path: out });
await browser.close();

console.error(`[auth-state] wrote ${out}`);
console.log(out);

/**
 * TWO THINGS THIS FILE DOES NOT DO, DELIBERATELY.
 *
 * 1. It never types the password. `page.fill('#password', config.AUTH_PASSWORD)`
 *    would work and is the reason this recipe exists — an agent will not write
 *    that line, and a human at the keyboard does not need it.
 * 2. It does not chmod the output. `context.storageState()` writes with the
 *    process umask, so set `umask 077` in the wrapper, or chmod after the fact.
 *    The file holds a live session.
 */
