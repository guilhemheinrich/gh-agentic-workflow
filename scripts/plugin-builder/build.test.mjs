// Run: node --test scripts/plugin-builder/
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { buildPlugins } from './build.mjs';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const realConfig = JSON.parse(fs.readFileSync(path.join(repo, 'scripts/plugin-builder/config.json'), 'utf8'));
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'plugin-build-'));

/** Sorted [relative path, mode, sha-ish content] listing of a tree. */
function snapshot(dir) {
  const out = [];
  const rec = (rel) => {
    for (const e of fs.readdirSync(path.join(dir, rel)).sort()) {
      const r = rel ? `${rel}/${e}` : e;
      const abs = path.join(dir, r);
      if (fs.statSync(abs).isDirectory()) rec(r);
      else out.push([r, fs.statSync(abs).mode & 0o777, fs.readFileSync(abs).toString('base64')]);
    }
  };
  rec('');
  return out;
}

/** Tiny fixture repo: files = {relPath: content}, assets = registry entries. */
function fixture(files, assets) {
  const root = tmp();
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    fs.writeFileSync(path.join(root, rel), content);
  }
  const yamlAssets = assets
    .map((a) => `  - path: ${a.path}\n    type: ${a.type}\n    category: ${a.category}\n    tags: [x]\n    description: d`)
    .join('\n');
  fs.writeFileSync(path.join(root, 'asset-registry.yml'), `version: 1.0.0\nassets:\n${yamlAssets}\n`);
  return root;
}

const miniConfig = (extra = {}) => ({
  marketplace: { name: 'm', owner: { name: 'o' }, description: 'd' },
  plugins: {
    alpha: { description: 'a', categories: ['cat-a'] },
    beta: { description: 'b', categories: ['cat-b'] },
  },
  canonicalRoots: { skill: ['skills/', '.agents/skills/'], command: ['commands/'], agent: ['agents/'], hook: ['hooks/'] },
  hooks: {},
  externalReferences: { skill: {}, agent: {}, slash: {} },
  ...extra,
});

test('two consecutive builds of the real repo are byte-identical', () => {
  const a = tmp();
  const b = tmp();
  const r1 = buildPlugins({ root: repo, config: realConfig, out: a, write: true });
  const r2 = buildPlugins({ root: repo, config: realConfig, out: b, write: true });
  assert.deepEqual(r1.errors, []);
  assert.deepEqual(r2.errors, []);
  assert.deepEqual(r1.report, r2.report);
  const s1 = snapshot(a);
  assert.ok(s1.length > 100, 'expected a non-trivial tree');
  assert.deepEqual(s1, snapshot(b));
});

test('rebuilding into an existing output dir replaces it deterministically', () => {
  const out = tmp();
  buildPlugins({ root: repo, config: realConfig, out, write: true });
  const first = snapshot(out);
  fs.writeFileSync(path.join(out, 'stale.txt'), 'x');
  buildPlugins({ root: repo, config: realConfig, out, write: true });
  assert.deepEqual(snapshot(out), first);
});

test('real repo: entry names equal manifest names, no version, relative sources', () => {
  const out = tmp();
  const r = buildPlugins({ root: repo, config: realConfig, out, write: true });
  assert.deepEqual(r.errors, []);
  const mkt = JSON.parse(fs.readFileSync(path.join(out, '.claude-plugin/marketplace.json'), 'utf8'));
  assert.ok(mkt.plugins.length >= 2);
  for (const entry of mkt.plugins) {
    const manifest = JSON.parse(fs.readFileSync(path.join(out, entry.source, '.claude-plugin/plugin.json'), 'utf8'));
    assert.equal(manifest.name, entry.name);
    assert.equal('version' in manifest, false);
    assert.equal('version' in entry, false);
    assert.match(entry.source, /^\.\/plugins\/[a-z0-9-]+$/);
  }
});

test('real repo: hooks.json uses CLAUDE_PLUGIN_ROOT and never ships repo-specific hooks', () => {
  const out = tmp();
  buildPlugins({ root: repo, config: realConfig, out, write: true });
  const all = snapshot(out).map(([r]) => r);
  assert.ok(!all.some((r) => r.endsWith('registry-sync-on-skill.sh')));
  const hooksJson = all.filter((r) => r.endsWith('hooks/hooks.json'));
  assert.ok(hooksJson.length >= 1);
  for (const rel of hooksJson) {
    const text = fs.readFileSync(path.join(out, rel), 'utf8');
    for (const m of text.matchAll(/"command": "(.*)"/g)) assert.match(m[1], /\$\{CLAUDE_PLUGIN_ROOT\}\/hooks\/[\w-]+\.sh/);
    const hooksDir = path.dirname(path.join(out, rel));
    for (const m of text.matchAll(/hooks\/([\w-]+\.sh)/g)) assert.ok(fs.existsSync(path.join(hooksDir, m[1])));
  }
});

test('build fails on a path reference to an unknown skill', () => {
  const root = fixture(
    { 'skills/one/SKILL.md': '---\nname: one\n---\nSee skills/ghost/SKILL.md\n' },
    [{ path: 'skills/one/', type: 'skill', category: 'cat-a' }],
  );
  const r = buildPlugins({ root, config: miniConfig(), out: tmp(), write: true });
  assert.equal(r.errors.length, 1);
  assert.match(r.errors[0], /unknown skill 'ghost'/);
});

test('build fails on skill/agent mentions and backticked slash commands that resolve to nothing', () => {
  const root = fixture(
    { 'skills/one/SKILL.md': 'Use skill `nope` and the `ghost` agent, then run `/missing`.\n' },
    [{ path: 'skills/one/', type: 'skill', category: 'cat-a' }],
  );
  const r = buildPlugins({ root, config: miniConfig(), out: tmp(), write: false });
  assert.equal(r.errors.length, 3);
});

test('an unresolved reference writes nothing', () => {
  const root = fixture(
    { 'skills/one/SKILL.md': 'See skills/ghost/\n' },
    [{ path: 'skills/one/', type: 'skill', category: 'cat-a' }],
  );
  const out = path.join(tmp(), 'dist');
  buildPlugins({ root, config: miniConfig(), out, write: true });
  assert.equal(fs.existsSync(out), false);
});

test('allowlisted external references pass and are reported', () => {
  const root = fixture(
    { 'skills/one/SKILL.md': 'Run `/health` and see skills/linear-watch/\n' },
    [{ path: 'skills/one/', type: 'skill', category: 'cat-a' }],
  );
  const config = miniConfig({
    externalReferences: { skill: { roadmap: ['linear-watch'] }, agent: {}, slash: { endpoint: ['health'] } },
  });
  const r = buildPlugins({ root, config, out: tmp(), write: true });
  assert.deepEqual(r.errors, []);
  assert.ok(r.report.some((l) => l.includes('slash health (endpoint)')));
});

test('references are rewritten through the name -> plugin mapping', () => {
  const root = fixture(
    {
      'skills/one/SKILL.md': [
        'Same plugin: skills/two/ and skill `two` and /push',
        'Other plugin: skill `three`, `three` skill, skills/three/scripts/x.sh, [l](../three/SKILL.md)',
        'Agent: agent `helper`, subagent_type: helper',
        'Home install path untouched: ~/.agents/skills/three/',
        '',
      ].join('\n'),
      'skills/two/SKILL.md': 'x\n',
      'skills/three/scripts/x.sh': '#!/bin/sh\n',
      'skills/three/SKILL.md': 'y\n',
      '.agents/skills/viaagents/SKILL.md': 'Path: .agents/skills/two/\n',
      'commands/push.md': 'p\n',
      'agents/helper.md': 'h\n',
    },
    [
      { path: 'skills/one/', type: 'skill', category: 'cat-a' },
      { path: 'skills/two/', type: 'skill', category: 'cat-a' },
      { path: 'skills/three/', type: 'skill', category: 'cat-b' },
      { path: '.agents/skills/viaagents/', type: 'skill', category: 'cat-a' },
      { path: 'commands/push.md', type: 'command', category: 'cat-a' },
      { path: 'agents/helper.md', type: 'agent', category: 'cat-b' },
    ],
  );
  const out = tmp();
  const r = buildPlugins({ root, config: miniConfig(), out, write: true });
  assert.deepEqual(r.errors, []);
  const one = fs.readFileSync(path.join(out, 'plugins/alpha/skills/one/SKILL.md'), 'utf8');
  assert.match(one, /Same plugin: skills\/two\/ and skill `alpha:two` and \/alpha:push/);
  assert.match(one, /skill `beta:three`, `beta:three` skill, beta:three\/scripts\/x\.sh, \[l\]\(beta:three\/SKILL\.md\)/);
  assert.match(one, /agent `beta:helper`, subagent_type: beta:helper/);
  assert.match(one, /~\/\.agents\/skills\/three\//);
  const via = fs.readFileSync(path.join(out, 'plugins/alpha/skills/viaagents/SKILL.md'), 'utf8');
  assert.match(via, /Path: skills\/two\//);
  assert.ok(r.plugins.get('alpha').deps.has('beta'));
});

test('hooks: repo-specific and cross-plugin hooks are excluded, generic ones wired', () => {
  const root = fixture(
    {
      'skills/one/SKILL.md': 'x\n',
      'skills/other/SKILL.md': 'x\n',
      'hooks/ok.sh': '#!/bin/bash\nexec "$(dirname "$0")/../skills/one/run.sh"\n',
      'hooks/uses-registry.sh': '#!/bin/bash\ngrep x asset-registry.yml\n',
      'hooks/crosses.sh': '#!/bin/bash\nsource "$(dirname "$0")/../skills/other/run.sh"\n',
      'hooks/unwired.sh': '#!/bin/bash\n',
    },
    [
      { path: 'skills/one/', type: 'skill', category: 'cat-a' },
      { path: 'skills/other/', type: 'skill', category: 'cat-b' },
      { path: 'hooks/ok.sh', type: 'hook', category: 'cat-a' },
      { path: 'hooks/uses-registry.sh', type: 'hook', category: 'cat-a' },
      { path: 'hooks/crosses.sh', type: 'hook', category: 'cat-a' },
      { path: 'hooks/unwired.sh', type: 'hook', category: 'cat-a' },
    ],
  );
  const config = miniConfig({
    hooks: {
      ok: { events: [{ event: 'Stop' }] },
      'uses-registry': { events: [{ event: 'Stop' }] },
      crosses: { events: [{ event: 'Stop' }] },
    },
  });
  const out = tmp();
  const r = buildPlugins({ root, config, out, write: true });
  assert.deepEqual(r.errors, []);
  const hj = JSON.parse(fs.readFileSync(path.join(out, 'plugins/alpha/hooks/hooks.json'), 'utf8'));
  assert.deepEqual(hj, {
    hooks: { Stop: [{ hooks: [{ type: 'command', command: 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/ok.sh"' }] }] },
  });
  assert.ok(fs.existsSync(path.join(out, 'plugins/alpha/hooks/ok.sh')));
  for (const n of ['uses-registry', 'crosses', 'unwired']) assert.ok(!fs.existsSync(path.join(out, `plugins/alpha/hooks/${n}.sh`)));
  assert.equal(r.report.filter((l) => /^ {2}(uses-registry|crosses|unwired):/.test(l)).length, 3);
});

test('drift is reported: missing path, duplicate, unregistered', () => {
  const root = fixture(
    {
      'skills/dup/SKILL.md': 'canonical\n',
      '.agents/skills/dup/SKILL.md': 'copy\n',
      'skills/orphan/SKILL.md': 'x\n',
    },
    [
      { path: 'skills/dup/', type: 'skill', category: 'cat-a' },
      { path: '.agents/skills/dup/', type: 'skill', category: 'cat-a' },
      { path: '.agents/skills/gone/SKILL.md', type: 'skill', category: 'cat-a' },
    ],
  );
  const r = buildPlugins({ root, config: miniConfig(), out: tmp(), write: false });
  const text = r.report.join('\n');
  assert.match(text, /\[MISSING_PATH\] skill 'gone'/);
  assert.match(text, /\[DUPLICATE_DROPPED\] skill 'dup'.*CONTENT DIFFERS/);
  assert.match(text, /\[UNREGISTERED\] skill 'orphan'/);
  assert.equal(r.drift, 3);
});
