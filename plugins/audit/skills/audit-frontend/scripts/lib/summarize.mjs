#!/usr/bin/env node
// summarize.mjs <out-dir> - turn the raw outputs of static-battery.sh into
// summary.json and a table. Node stdlib only. Never throws on a missing or
// malformed tool output: that tool is reported as "unreadable" instead.

import fs from 'node:fs';
import path from 'node:path';

const out = process.argv[2] || '/out';
const read = (f) => fs.readFileSync(path.join(out, f), 'utf8');
const exists = (f) => fs.existsSync(path.join(out, f));
const json = (f) => JSON.parse(read(f));
const top = (counts, n = 10) =>
  Object.entries(counts)
    .sort((a, b) => b[1] - a[1])
    .slice(0, n)
    .map(([id, count]) => ({ id, count }));
const bump = (o, k, by = 1) => {
  o[k] = (o[k] || 0) + by;
};

const statuses = exists('status.ndjson')
  ? read('status.ndjson')
      .split('\n')
      .filter(Boolean)
      .map((l) => {
        try {
          return JSON.parse(l);
        } catch {
          return { tool: 'unparsable-status', state: 'error', exit: 1, note: l.slice(0, 200) };
        }
      })
  : [];

function tscSummary(file) {
  const codes = {};
  const files = {};
  let errors = 0;
  for (const line of read(file).split('\n')) {
    const m = line.match(/^(.+?)\((\d+),(\d+)\): error (TS\d+):/) || line.match(/^()()()error (TS\d+):/);
    if (!m) continue;
    errors++;
    bump(codes, m[4]);
    if (m[1]) bump(files, m[1]);
  }
  return { findings: errors, detail: { errors, topCodes: top(codes), topFiles: top(files, 5) } };
}

function eslintSummary(file) {
  const rules = {};
  let errors = 0;
  let warnings = 0;
  let fatal = 0;
  for (const f of json(file)) {
    errors += f.errorCount;
    warnings += f.warningCount;
    for (const m of f.messages) {
      if (m.fatal) fatal++;
      bump(rules, m.ruleId || 'parse-error');
    }
  }
  return { findings: errors + warnings, detail: { errors, warnings, parseErrors: fatal, topRules: top(rules, 15) } };
}

const PARSERS = {
  tsc: () => tscSummary('tsc.txt'),
  'tsc-strict': () => {
    const strict = tscSummary('tsc-strict.txt');
    const base = exists('tsc.txt') ? tscSummary('tsc.txt').findings : 0;
    strict.detail.strictnessGap = strict.findings - base;
    return strict;
  },
  'svelte-check': () => {
    const lines = read('svelte-check.txt').split('\n');
    const errors = lines.filter((l) => / ERROR /.test(l)).length;
    const warnings = lines.filter((l) => / WARNING /.test(l)).length;
    return { findings: errors + warnings, detail: { errors, warnings } };
  },
  'eslint-project': () => eslintSummary('eslint-project.json'),
  'eslint-audit': () => eslintSummary('eslint-audit.json'),
  stylelint: () => {
    const rules = {};
    let errors = 0;
    let warnings = 0;
    let parseErrors = 0;
    for (const f of json('stylelint.json')) {
      parseErrors += (f.parseErrors || []).length;
      for (const w of f.warnings || []) {
        if (w.severity === 'error') errors++;
        else warnings++;
        bump(rules, w.rule || 'unknown');
      }
    }
    return { findings: errors + warnings + parseErrors, detail: { errors, warnings, parseErrors, topRules: top(rules) } };
  },
  knip: () => {
    const data = json('knip.json');
    const counts = {};
    if (Array.isArray(data.files)) counts.files = data.files.length;
    for (const issue of data.issues || []) {
      for (const [k, v] of Object.entries(issue)) {
        if (Array.isArray(v) && v.length) bump(counts, k, v.length);
      }
    }
    return { findings: Object.values(counts).reduce((a, b) => a + b, 0), detail: { byKind: counts } };
  },
  bundle: () => {
    const data = json('bundle.json');
    const real = data.flags.filter((f) => f.level !== 'info');
    return { findings: real.length, detail: { totals: data.totals, flags: data.flags, largest: data.files.slice(0, 5).map((f) => ({ file: f.file, rawKb: f.rawKb, gzipKb: f.gzipKb })) } };
  },
  'npm-audit': () => {
    const raw = read('npm-audit.json').trim();
    const sev = { critical: 0, high: 0, moderate: 0, low: 0 };
    if (raw.startsWith('{"value"') || raw === '') {
      // Yarn Berry: one JSON object per advisory, nothing at all when clean.
      for (const line of raw.split('\n').filter(Boolean)) {
        const s = String(JSON.parse(line).children?.Severity || '').toLowerCase();
        if (s in sev) sev[s]++;
      }
    } else {
      const v = JSON.parse(raw).metadata?.vulnerabilities || {};
      for (const k of Object.keys(sev)) sev[k] = v[k] || 0;
    }
    return { findings: sev.critical + sev.high + sev.moderate + sev.low, detail: { bySeverity: sev } };
  },
  osv: () => {
    const data = json('osv.json');
    const ids = new Set();
    const pkgs = {};
    for (const r of data.results || []) {
      for (const p of r.packages || []) {
        for (const vuln of p.vulnerabilities || []) {
          ids.add(vuln.id);
          bump(pkgs, `${p.package.name}@${p.package.version}`);
        }
      }
    }
    return { findings: ids.size, detail: { distinctAdvisories: ids.size, topPackages: top(pkgs) } };
  },
  vnu: () => {
    const data = json('vnu.json');
    const messages = {};
    let errors = 0;
    let warnings = 0;
    for (const m of data.messages || []) {
      if (m.type === 'error' || m.type === 'non-document-error') errors++;
      else warnings++;
      if (m.type === 'error') bump(messages, String(m.message).replace(/[“”"][^“”"]*[“”"]/g, '"…"').slice(0, 110));
    }
    return { findings: errors, detail: { errors, warnings, topErrors: top(messages, 8) } };
  },
};

const tools = [];
for (const s of statuses) {
  const entry = { tool: s.tool, state: s.state, exit: s.exit, note: s.note, findings: null };
  if (s.state === 'ran' && PARSERS[s.tool]) {
    try {
      Object.assign(entry, PARSERS[s.tool]());
    } catch (err) {
      entry.state = 'unreadable';
      entry.note += ` | output could not be parsed: ${String(err.message).slice(0, 120)}`;
    }
  }
  tools.push(entry);
}

const context = exists('context.json') ? json('context.json') : {};
const summary = {
  generatedAt: new Date().toISOString(),
  context,
  tools,
  notRun: tools.filter((t) => t.state !== 'ran').map((t) => `${t.tool}: ${t.state} (${t.note})`),
  reminder: 'A tool that did not run proves nothing: list it under "Not verified" in the report, never as passing.',
};
fs.writeFileSync(path.join(out, 'summary.json'), JSON.stringify(summary, null, 2));

console.log(`\n${'tool'.padEnd(16)} ${'state'.padEnd(10)} ${'findings'.padEnd(9)} note`);
for (const t of tools) {
  console.log(`${t.tool.padEnd(16)} ${t.state.padEnd(10)} ${String(t.findings ?? '-').padEnd(9)} ${t.note}`);
}
console.log(`\nsummary: ${path.join(out, 'summary.json')}`);
