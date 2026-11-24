#!/usr/bin/env node
// bundle-sizes.mjs <dist-dir> - raw / gzip / brotli size of every shipped asset,
// plus an estimate of what the first page load pulls in. Node stdlib only.
//
// "initial" = files referenced by <script src>, <link rel=stylesheet> and
// <link rel=modulepreload> in the root index.html. It is a LOWER BOUND: a
// static import that the bundler did not preload is fetched too but is not
// counted here. Lighthouse's network trace is the measured figure.

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

// Budgets (documented in references/thresholds.md; keep both in sync).
const BUDGET = {
  initialJsGzipKb: 170, // classic "170 kB compressed" critical-path JS budget
  initialJsGzipPoorKb: 350, // house heuristic
  initialCssGzipKb: 50, // house heuristic
  chunkRawKb: 500, // Vite's default chunkSizeWarningLimit
};

const dist = path.resolve(process.argv[2] || 'dist');
if (!fs.existsSync(dist)) {
  console.error(`not found: ${dist}`);
  process.exit(2);
}

const KIND = {
  '.js': 'js', '.mjs': 'js', '.css': 'css', '.html': 'html', '.wasm': 'wasm',
  '.woff': 'font', '.woff2': 'font', '.ttf': 'font', '.otf': 'font',
  '.png': 'image', '.jpg': 'image', '.jpeg': 'image', '.gif': 'image', '.webp': 'image', '.avif': 'image', '.svg': 'image',
  '.map': 'sourcemap',
};
const COMPRESSIBLE = new Set(['js', 'css', 'html', 'wasm']);

function walk(dir, out = []) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(p, out);
    else if (ent.isFile()) out.push(p);
  }
  return out;
}

const kb = (n) => Math.round((n / 1024) * 10) / 10;
const files = [];
for (const file of walk(dist)) {
  const kind = KIND[path.extname(file).toLowerCase()] || 'other';
  const buf = fs.readFileSync(file);
  const entry = { file: path.relative(dist, file).split(path.sep).join('/'), kind, rawKb: kb(buf.length) };
  if (COMPRESSIBLE.has(kind)) {
    entry.gzipKb = kb(zlib.gzipSync(buf, { level: 9 }).length);
    entry.brotliKb = kb(zlib.brotliCompressSync(buf).length);
  }
  if (kind === 'js') entry.hasSourceMapComment = /\/\/# sourceMappingURL=/.test(buf.subarray(Math.max(0, buf.length - 400)).toString('utf8'));
  files.push(entry);
}

// Initial set, from the root index.html.
const initial = new Set();
const indexHtml = path.join(dist, 'index.html');
if (fs.existsSync(indexHtml)) {
  const html = fs.readFileSync(indexHtml, 'utf8');
  const refs = [];
  for (const m of html.matchAll(/<script\b[^>]*\bsrc=["']([^"']+)["']/gi)) refs.push(m[1]);
  for (const m of html.matchAll(/<link\b[^>]*>/gi)) {
    const tag = m[0];
    if (!/\brel=["']?(stylesheet|modulepreload)\b/i.test(tag)) continue;
    const href = tag.match(/\bhref=["']([^"']+)["']/i);
    if (href) refs.push(href[1]);
  }
  for (const ref of refs) {
    if (/^(https?:)?\/\//.test(ref)) continue; // third-party origin: not in dist
    const clean = ref.split(/[?#]/)[0].replace(/^\.?\//, '');
    if (files.some((f) => f.file === clean)) initial.add(clean);
  }
}
for (const f of files) f.initial = initial.has(f.file);

const total = (pred, key) => kb(files.filter(pred).reduce((a, f) => a + (f[key] || 0) * 1024, 0));
const totals = {
  jsRawKb: total((f) => f.kind === 'js', 'rawKb'),
  jsGzipKb: total((f) => f.kind === 'js', 'gzipKb'),
  cssRawKb: total((f) => f.kind === 'css', 'rawKb'),
  cssGzipKb: total((f) => f.kind === 'css', 'gzipKb'),
  imageRawKb: total((f) => f.kind === 'image', 'rawKb'),
  fontRawKb: total((f) => f.kind === 'font', 'rawKb'),
  initialJsGzipKb: total((f) => f.initial && f.kind === 'js', 'gzipKb'),
  initialCssGzipKb: total((f) => f.initial && f.kind === 'css', 'gzipKb'),
  files: files.length,
};

const flags = [];
if (!fs.existsSync(indexHtml)) flags.push({ id: 'no-index-html', level: 'info', detail: 'no root index.html: initial load could not be estimated (SSR or multi-page build)' });
if (totals.initialJsGzipKb > BUDGET.initialJsGzipPoorKb) flags.push({ id: 'initial-js', level: 'poor', detail: `${totals.initialJsGzipKb} kB gzip > ${BUDGET.initialJsGzipPoorKb} kB` });
else if (totals.initialJsGzipKb > BUDGET.initialJsGzipKb) flags.push({ id: 'initial-js', level: 'needs-improvement', detail: `${totals.initialJsGzipKb} kB gzip > ${BUDGET.initialJsGzipKb} kB` });
if (totals.initialCssGzipKb > BUDGET.initialCssGzipKb) flags.push({ id: 'initial-css', level: 'needs-improvement', detail: `${totals.initialCssGzipKb} kB gzip > ${BUDGET.initialCssGzipKb} kB` });
for (const f of files) {
  if (f.kind === 'js' && f.rawKb > BUDGET.chunkRawKb) flags.push({ id: 'large-chunk', level: 'needs-improvement', detail: `${f.file}: ${f.rawKb} kB raw > ${BUDGET.chunkRawKb} kB` });
}
const maps = files.filter((f) => f.kind === 'sourcemap');
if (maps.length) flags.push({ id: 'sourcemaps-shipped', level: 'info', detail: `${maps.length} .map file(s) in the build output: confirm whether exposing the source is intended` });
if (initial.size > 0 && files.filter((f) => f.kind === 'js').length === 1 && totals.jsRawKb > BUDGET.chunkRawKb) flags.push({ id: 'no-code-splitting', level: 'needs-improvement', detail: 'all JavaScript ships in a single chunk' });

files.sort((a, b) => b.rawKb - a.rawKb);
console.log(JSON.stringify({ dist: process.argv[2] || 'dist', budgets: BUDGET, totals, flags, files }, null, 2));
