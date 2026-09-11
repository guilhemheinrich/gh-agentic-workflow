// tests/api/health.api.spec.ts — API tests over HTTP against API_BASE_URL.
// `request` resolves relative paths against the `api` project's baseURL.
import { test, expect, env, requireUser } from "../shared/fixtures";

test("GET /health answers 200", { tag: ["@prod-safe", "@smoke"] }, async ({ request }) => {
  const res = await request.get("/health");
  expect(res.status()).toBe(200);
});

test("GET /version reports the deployed build", { tag: ["@prod-safe", "@smoke"] }, async ({ request }) => {
  const res = await request.get("/version");
  expect(res.ok()).toBeTruthy();
  const body = (await res.json()) as { version: string };
  expect(body.version).toMatch(/^\d+\.\d+\.\d+/);
});

// Creates data: @business, never @prod-safe. The prodGuard fixture fails it
// on prod even if someone passes the wrong --grep.
test("POST /items creates an item for the demo user", { tag: ["@business"] }, async ({ request }) => {
  const { email, password } = requireUser();
  const login = await request.post("/auth/login", { data: { email, password } });
  expect(login.ok()).toBeTruthy();
  const { token } = (await login.json()) as { token: string };
  const auth = { Authorization: `Bearer ${token}` };

  // Run-scoped name: staging is shared, so cleanup must find its own rows.
  const name = `e2e-${env.TEST_ENV}-${Date.now()}`;
  const created = await request.post("/items", { headers: auth, data: { name } });

  // Read the id before any assertion, and delete in `finally`: a failing
  // assertion must not leave the row behind on a shared staging.
  const id = created.ok() ? ((await created.json()) as { id?: string }).id : undefined;
  try {
    expect(created.status()).toBe(201);
    expect(id).toBeTruthy();
  } finally {
    if (id) {
      const deleted = await request.delete(`/items/${id}`, { headers: auth });
      expect(deleted.status()).toBe(204);
    }
  }
});
