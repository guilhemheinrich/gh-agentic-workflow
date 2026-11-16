// tests/e2e/home.e2e.spec.ts — browser journeys against E2E_BASE_URL.
import { test, expect, requireUser } from "../shared/fixtures";

test("home page renders", { tag: ["@prod-safe", "@smoke", "@fast"] }, async ({ page }) => {
  await page.goto("/");
  await expect(page).toHaveTitle(/.+/);
  await expect(page.getByRole("main")).toBeVisible();
});

test("demo user signs in and sees the dashboard", { tag: ["@fast"] }, async ({ page }) => {
  const { email, password } = requireUser();
  await page.goto("/login");
  await page.getByLabel("Email").fill(email);
  await page.getByLabel("Password").fill(password);
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page.getByRole("heading", { name: "Dashboard" })).toBeVisible();
});
