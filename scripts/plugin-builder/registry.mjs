// Registry loading and resolution: turns asset-registry.yml entries into a
// deduplicated list of buildable assets, and reports every drift between the
// registry and the filesystem instead of silently dropping anything.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import yaml from 'js-yaml';

const JUNK = new Set(['.DS_Store', '__pycache__', 'node_modules']);
const isJunk = (name) => JUNK.has(name) || name.endsWith('.pyc');

export function loadRegistry(root) {
  const file = path.join(root, 'asset-registry.yml');
  return yaml.load(fs.readFileSync(file, 'utf8'));
}

/** Sorted list of files (posix, relative) under `dir`, junk excluded. */
export function walk(dir) {
  const out = [];
  const rec = (rel) => {
    const abs = path.join(dir, rel);
    for (const e of fs.readdirSync(abs, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
      if (isJunk(e.name)) continue;
      const r = rel ? `${rel}/${e.name}` : e.name;
      if (e.isSymbolicLink()) throw new Error(`symlink not supported: ${path.join(dir, r)}`);
      if (e.isDirectory()) rec(r);
      else out.push(r);
    }
  };
  rec('');
  return out;
}

function treeHash(abs, isDir) {
  const h = crypto.createHash('sha256');
  if (!isDir) return h.update(fs.readFileSync(abs)).digest('hex');
  for (const f of walk(abs)) h.update(f).update('\0').update(fs.readFileSync(path.join(abs, f)));
  return h.digest('hex');
}

/** Map a registry path to {kind-specific name, normalized path, isDir}. */
function describe(entry) {
  let p = entry.path;
  const type = entry.type;
  if (type === 'skill') {
    if (p.endsWith('/SKILL.md')) p = p.slice(0, -'/SKILL.md'.length);
    p = p.replace(/\/$/, '');
    return { type, rel: p, name: path.posix.basename(p), isDir: true };
  }
  if (type === 'command' || type === 'agent') {
    return { type, rel: p, name: path.posix.basename(p).replace(/\.md$/, ''), isDir: false };
  }
  if (type === 'hook') {
    return { type, rel: p, name: path.posix.basename(p).replace(/\.sh$/, ''), isDir: false };
  }
  return { type, rel: p.replace(/\/$/, ''), name: path.posix.basename(p), isDir: false };
}

function rank(roots, rel) {
  const i = roots.findIndex((r) => rel.startsWith(r));
  return i === -1 ? roots.length : i;
}

/**
 * @returns {{assets: object[], issues: object[], skippedRules: object[]}}
 * issues: {code, message}; codes: MISSING_PATH, DUPLICATE_DROPPED,
 * CATEGORY_CONFLICT, UNREGISTERED.
 */
export function resolveAssets(root, registry, config) {
  const issues = [];
  const skippedRules = [];
  const groups = new Map(); // `${type}:${name}` -> [described entries]
  for (const entry of registry.assets) {
    const d = { ...describe(entry), entry };
    if (d.type === 'rule') {
      skippedRules.push(d.rel);
      continue;
    }
    const key = `${d.type}:${d.name}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(d);
  }

  const assets = [];
  for (const key of [...groups.keys()].sort()) {
    const cands = groups.get(key);
    const type = cands[0].type;
    const roots = config.canonicalRoots[type] ?? [];
    const existing = [];
    for (const c of cands) {
      const abs = path.join(root, c.rel);
      if (fs.existsSync(abs)) existing.push(c);
      else issues.push({ code: 'MISSING_PATH', message: `${type} '${c.name}': registered path '${c.entry.path}' does not exist` });
    }
    if (existing.length === 0) continue;
    existing.sort((a, b) => rank(roots, a.rel) - rank(roots, b.rel) || (a.rel < b.rel ? -1 : 1));
    const [chosen, ...dropped] = existing;
    const chosenHash = treeHash(path.join(root, chosen.rel), chosen.isDir);
    for (const d of dropped) {
      const same = treeHash(path.join(root, d.rel), d.isDir) === chosenHash;
      issues.push({
        code: 'DUPLICATE_DROPPED',
        message: `${type} '${d.name}': '${d.rel}' dropped in favour of '${chosen.rel}' (${same ? 'identical content' : 'CONTENT DIFFERS'})`,
      });
      if (d.entry.category !== chosen.entry.category) {
        issues.push({ code: 'CATEGORY_CONFLICT', message: `${type} '${d.name}': category '${d.entry.category}' vs '${chosen.entry.category}'` });
      }
    }
    assets.push({
      type,
      name: chosen.name,
      rel: chosen.rel,
      isDir: chosen.isDir,
      category: chosen.entry.category,
      tags: chosen.entry.tags ?? [],
      description: chosen.entry.description ?? '',
    });
  }

  // Unregistered: present on disk, absent from the registry (by type + name).
  const have = new Set(assets.map((a) => `${a.type}:${a.name}`));
  const scan = (type, dir, filter, nameOf) => {
    const abs = path.join(root, dir);
    if (!fs.existsSync(abs)) return;
    for (const e of fs.readdirSync(abs, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
      if (isJunk(e.name) || !filter(e)) continue;
      const name = nameOf(e);
      if (!have.has(`${type}:${name}`) && !groups.has(`${type}:${name}`)) {
        issues.push({ code: 'UNREGISTERED', message: `${type} '${name}' exists at '${dir}/${e.name}' but is not in asset-registry.yml (not built)` });
      }
    }
  };
  scan('skill', 'skills', (e) => e.isDirectory(), (e) => e.name);
  scan('skill', '.agents/skills', (e) => e.isDirectory(), (e) => e.name);
  scan('agent', 'agents', (e) => e.name.endsWith('.md'), (e) => e.name.replace(/\.md$/, ''));
  scan('command', 'commands', (e) => e.name.endsWith('.md'), (e) => e.name.replace(/\.md$/, ''));
  scan('hook', 'hooks', (e) => e.name.endsWith('.sh'), (e) => e.name.replace(/\.sh$/, ''));

  return { assets, issues, skippedRules };
}
