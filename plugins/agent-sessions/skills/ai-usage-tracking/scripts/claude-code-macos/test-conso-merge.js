// test-conso-merge.js - tests for conso-merge.js (ccusage -> cache merge). No dependency.
//
// Run from the repo root, in Docker:
//   docker run --rm -v "$PWD/skills/ai-usage-tracking/scripts/claude-code-macos":/t:ro node:22-slim node /t/test-conso-merge.js
const assert = require("assert");
const { merge, dayRows } = require("./conso-merge.js");

let fails = 0;
const t = (name, fn) => { try { fn(); console.log("ok   - " + name); } catch (e) { fails++; console.log("FAIL - " + name + "\n" + e.message); } };

const cc = (rows) => ({ daily: rows.map(([period, cost, models]) => ({
  period, totalCost: cost, totalTokens: 1000,
  modelBreakdowns: models.map(([m, c]) => ({ modelName: m, cost: c, inputTokens: 100, outputTokens: 50, cacheCreationTokens: 25, cacheReadTokens: 25 })) })) });
const base = { today: "2026-11-13", historyDays: 90, now: "2026-11-13T12:00:00Z", ccusageVersion: "20.0.50" };

t("ccusage rows become days with short model names and summed tokens", () => {
  const d = dayRows(cc([["2026-11-13", 5, [["claude-opus-4-7-20260101", 3], ["claude-sonnet-5", 2]]]]));
  assert.deepStrictEqual(Object.keys(d["2026-11-13"].models).sort(), ["opus-4-7", "sonnet-5"]);
  assert.strictEqual(d["2026-11-13"].models["opus-4-7"].tokens, 200);
  assert.strictEqual(d["2026-11-13"].cost, 5);
});

t("first run: schema 1, generated_at, window start", () => {
  const c = merge({ ...base, since: "2026-08-15", ccusage: cc([["2026-11-13", 5, [["claude-x", 5]]]]), old: null, usageJson: "" , usageErr: "no token" });
  assert.strictEqual(c.schema, 1);
  assert.strictEqual(c.generated_at, base.now);
  assert.strictEqual(c.covers_since, "2026-08-15");
  assert.strictEqual(c.usage.ok, false);
});

t("incremental: days before `since` are kept from the old cache, days from `since` are replaced", () => {
  const old = { schema: 1, covers_since: "2026-10-01", days: { "2026-10-20": { cost: 1, tokens: 1, models: {} }, "2026-11-10": { cost: 99, tokens: 1, models: {} } }, usage: null };
  const c = merge({ ...base, since: "2026-11-01", old, ccusage: cc([["2026-11-12", 7, [["claude-x", 7]]]]), usageJson: "" });
  assert.strictEqual(c.days["2026-10-20"].cost, 1);
  assert.strictEqual(c.days["2026-11-10"], undefined, "a re-aggregated day with no ccusage row disappears");
  assert.strictEqual(c.days["2026-11-12"].cost, 7);
  assert.strictEqual(c.covers_since, "2026-10-01");
});

t("history cap prunes days older than HISTORY_DAYS", () => {
  const old = { schema: 1, covers_since: "2026-01-01", days: { "2026-01-05": { cost: 1, tokens: 1, models: {} } }, usage: null };
  const c = merge({ ...base, historyDays: 30, since: "2026-11-01", old, ccusage: cc([]), usageJson: "" });
  assert.deepStrictEqual(Object.keys(c.days), []);
  assert.strictEqual(c.covers_since, "2026-10-14");
});

t("usage: a good response replaces the old one", () => {
  const u = JSON.stringify({ limits: [{ kind: "five_hour", percent: 3 }], extra_usage: { is_enabled: true, used_credits: 1240 } });
  const c = merge({ ...base, since: "2026-11-01", old: null, ccusage: cc([]), usageJson: u });
  assert.strictEqual(c.usage.ok, true);
  assert.strictEqual(c.usage.fetched_at, base.now);
  assert.strictEqual(c.usage.extra_usage.used_credits, 1240);
});

t("usage: a failed fetch keeps the previous figures and records the error", () => {
  const old = { schema: 1, days: {}, usage: { ok: true, fetched_at: "2026-11-13T11:00:00Z", limits: [{ kind: "five_hour", percent: 9 }], extra_usage: null } };
  const c = merge({ ...base, since: "2026-11-01", old, ccusage: cc([]), usageJson: "", usageErr: "HTTP 401" });
  assert.strictEqual(c.usage.ok, false);
  assert.strictEqual(c.usage.error, "HTTP 401");
  assert.strictEqual(c.usage.limits[0].percent, 9);
  assert.strictEqual(c.usage.fetched_at, "2026-11-13T11:00:00Z");
});

t("usage: offline refresh (-n) leaves the old usage untouched", () => {
  const old = { schema: 1, days: {}, usage: { ok: true, fetched_at: "x", limits: [], extra_usage: null } };
  const c = merge({ ...base, since: "2026-11-01", old, ccusage: cc([]), usageSkipped: true });
  assert.deepStrictEqual(c.usage, old.usage);
});

t("old cache with another schema is ignored", () => {
  const old = { schema: 2, days: { "2026-10-20": { cost: 1 } } };
  const c = merge({ ...base, since: "2026-11-01", old, ccusage: cc([]), usageJson: "" });
  assert.deepStrictEqual(c.days, {});
});

if (fails) { console.log(fails + " FAILED"); process.exit(1); }
console.log("ALL PASSED");
