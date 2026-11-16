// conso-merge.js - merge a ccusage `daily --json --breakdown` output into the conso cache.
//
// Runs inside the refresh container (node:22-slim); pure function in `merge()` so tests can require it.
// Usage: node conso-merge.js <ccusage.json>
// Env:   SINCE_YMD (first day re-aggregated, YYYY-MM-DD), TODAY (YYYY-MM-DD), HISTORY_DAYS,
//        OLD_CACHE (path, optional), USAGE_JSON (raw usage response), USAGE_ERR, USAGE_SKIPPED=1,
//        NOW (ISO UTC), CCUSAGE_VERSION
// Prints the new cache JSON (schema 1) on stdout; the host writes it atomically.
const fs = require("fs");

const short = (m) => String(m).replace(/^claude-/, "").replace(/-\d{8}$/, "");

function dayRows(ccusage) {
  const rows = (ccusage && ccusage.daily) || [];
  const days = {};
  for (const r of rows) {
    const day = r.period || r.date;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day || "")) continue;
    const models = {};
    for (const b of r.modelBreakdowns || []) {
      const m = short(b.modelName);
      const t = (b.inputTokens || 0) + (b.outputTokens || 0) + (b.cacheCreationTokens || 0) + (b.cacheReadTokens || 0);
      const cur = models[m] || { cost: 0, tokens: 0 };
      cur.cost += b.cost || 0;
      cur.tokens += t;
      models[m] = cur;
    }
    days[day] = { cost: r.totalCost || 0, tokens: r.totalTokens || 0, models };
  }
  return days;
}

function ymdMinus(ymd, n) {
  const d = new Date(ymd + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() - n);
  return d.toISOString().slice(0, 10);
}

function merge(o) {
  const old = o.old && o.old.schema === 1 && o.old.days ? o.old : null;
  const oldest = ymdMinus(o.today, o.historyDays);
  const days = {};
  if (old) for (const [k, v] of Object.entries(old.days)) if (k < o.since && k >= oldest) days[k] = v;
  Object.assign(days, dayRows(o.ccusage));
  let usage;
  if (o.usageSkipped) usage = old ? old.usage : null;
  else if (o.usageJson) {
    let u = null;
    try { u = JSON.parse(o.usageJson); } catch (e) { /* handled below */ }
    usage = u
      ? { ok: true, fetched_at: o.now, limits: u.limits || [], extra_usage: u.extra_usage || null }
      : { ...(old && old.usage ? old.usage : {}), ok: false, error: "usage endpoint returned unparsable JSON" };
  } else usage = { ...(old && old.usage ? old.usage : {}), ok: false, error: o.usageErr || "no usage data" };
  let coversSince = old && old.covers_since && old.covers_since < o.since ? old.covers_since : o.since;
  if (coversSince < oldest) coversSince = oldest;
  return {
    schema: 1,
    generated_at: o.now,
    ccusage_version: o.ccusageVersion,
    history_days: o.historyDays,
    covers_since: coversSince,
    days,
    usage,
  };
}

module.exports = { merge, dayRows };

if (require.main === module) {
  const e = process.env;
  let old = null;
  try { old = JSON.parse(fs.readFileSync(e.OLD_CACHE, "utf8")); } catch (err) { /* no usable old cache */ }
  const cache = merge({
    ccusage: JSON.parse(fs.readFileSync(process.argv[2], "utf8")),
    old,
    since: e.SINCE_YMD,
    today: e.TODAY,
    historyDays: Number(e.HISTORY_DAYS || 90),
    usageJson: e.USAGE_JSON || "",
    usageErr: e.USAGE_ERR || "",
    usageSkipped: e.USAGE_SKIPPED === "1",
    now: e.NOW,
    ccusageVersion: e.CCUSAGE_VERSION || "",
  });
  process.stdout.write(JSON.stringify(cache, null, 1) + "\n");
}
