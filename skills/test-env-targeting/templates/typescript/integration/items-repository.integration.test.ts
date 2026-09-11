// tests/integration/items-repository.integration.test.ts — real database,
// wrapped in a transaction that is rolled back, so the file is idempotent.
import { Client } from "pg";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { env } from "../shared/env";

describe("items repository", () => {
  const db = new Client({ connectionString: env.DATABASE_URL });

  beforeAll(() => db.connect());
  afterAll(() => db.end());
  beforeEach(() => db.query("BEGIN"));
  afterEach(() => db.query("ROLLBACK"));

  it("round-trips an item", async () => {
    const name = `it-${Date.now()}`;
    const inserted = await db.query<{ id: string }>("INSERT INTO items(name) VALUES ($1) RETURNING id", [name]);
    const found = await db.query<{ name: string }>("SELECT name FROM items WHERE id = $1", [inserted.rows[0].id]);
    expect(found.rows[0]?.name).toBe(name);
  });
});
