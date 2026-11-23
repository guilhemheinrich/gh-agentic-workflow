// Run: node --test scripts/plugin-builder/
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import yaml from 'js-yaml';
import { assertNoPrivateOutput, buildPlugins } from './build.mjs';
import { commitBump, nextVersion } from './next-version.mjs';

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
function fixture(files, assets, extraRegistry = '') {
  const root = tmp();
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    fs.writeFileSync(path.join(root, rel), content);
  }
  const yamlAssets = assets
    .map((a) => `  - path: ${a.path}\n    type: ${a.type}\n    category: ${a.category}\n${a.plugin ? `    plugin: ${a.plugin}\n` : ''}${a.mcp ? `    mcp: ${JSON.stringify(a.mcp)}\n` : ''}    tags: [x]\n    description: d`)
    .join('\n');
  fs.writeFileSync(path.join(root, 'asset-registry.yml'), `version: 1.0.0\nx-category-descriptions:\n  cat-a: Alpha things\n  cat-b: Beta things\n${extraRegistry}assets:\n${yamlAssets}\n`);
  return root;
}

const miniConfig = (extra = {}) => ({
  marketplace: { name: 'm', owner: { name: 'o' }, description: 'd' },
  canonicalRoots: { skill: ['skills/'], command: ['commands/', '.cursor/commands/'], agent: ['agents/'], hook: ['hooks/'] },
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

test('real repo: entry names equal manifest names, one config version, relative sources', () => {
  const out = tmp();
  const r = buildPlugins({ root: repo, config: realConfig, out, write: true });
  assert.deepEqual(r.errors, []);
  const mkt = JSON.parse(fs.readFileSync(path.join(out, '.claude-plugin/marketplace.json'), 'utf8'));
  assert.ok(mkt.plugins.length >= 2);
  for (const entry of mkt.plugins) {
    const manifest = JSON.parse(fs.readFileSync(path.join(out, entry.source, '.claude-plugin/plugin.json'), 'utf8'));
    assert.equal(manifest.name, entry.name);
    assert.equal(manifest.version, realConfig.version);
    assert.equal(entry.version, realConfig.version);
    assert.match(entry.source, /^\.\/plugins\/[a-z0-9-]+$/);
    for (const dep of manifest.dependencies ?? []) assert.ok(mkt.plugins.some((p) => p.name === dep), `unknown dependency ${dep}`);
  }
  const registry = JSON.parse(JSON.stringify(yaml.load(fs.readFileSync(path.join(repo, 'asset-registry.yml'), 'utf8'))));
  const described = { ...registry['x-category-descriptions'], ...registry['x-plugin-descriptions'] };
  for (const entry of mkt.plugins) assert.ok(entry.name in described, `${entry.name} has no registry description`);
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
      'commands/push.md': 'p\n',
      'agents/helper.md': 'h\n',
    },
    [
      { path: 'skills/one/', type: 'skill', category: 'cat-a' },
      { path: 'skills/two/', type: 'skill', category: 'cat-a' },
      { path: 'skills/three/', type: 'skill', category: 'cat-b' },
      { path: 'commands/push.md', type: 'command', category: 'cat-a' },
      { path: 'agents/helper.md', type: 'agent', category: 'cat-b' },
    ],
  );
  const out = tmp();
  const r = buildPlugins({ root, config: miniConfig(), out, write: true });
  assert.deepEqual(r.errors, []);
  const one = fs.readFileSync(path.join(out, 'plugins/cat-a/skills/one/SKILL.md'), 'utf8');
  assert.match(one, /Same plugin: skills\/two\/ and skill `cat-a:two` and \/cat-a:push/);
  assert.match(one, /skill `cat-b:three`, `cat-b:three` skill, cat-b:three\/scripts\/x\.sh, \[l\]\(cat-b:three\/SKILL\.md\)/);
  assert.match(one, /agent `cat-b:helper`, subagent_type: cat-b:helper/);
  assert.match(one, /~\/\.agents\/skills\/three\//);
  assert.ok(r.plugins.get('cat-a').deps.has('cat-b'));
});

test('plugin = category and dependencies are generated from cross-plugin references', () => {
  const root = fixture(
    { 'skills/one/SKILL.md': 'See skill `two`.\n', 'skills/two/SKILL.md': 'See skill `one`.\n', 'skills/solo/SKILL.md': 'none\n' },
    [
      { path: 'skills/one/', type: 'skill', category: 'cat-a' },
      { path: 'skills/two/', type: 'skill', category: 'cat-b' },
      { path: 'skills/solo/', type: 'skill', category: 'cat-a' },
    ],
  );
  const out = tmp();
  const r = buildPlugins({ root, config: miniConfig(), out, write: true });
  assert.deepEqual(r.errors, []);
  const read = (p) => JSON.parse(fs.readFileSync(path.join(out, `plugins/${p}/.claude-plugin/plugin.json`), 'utf8'));
  assert.deepEqual(read('cat-a'), { name: 'cat-a', description: 'Alpha things', author: { name: 'o' }, dependencies: ['cat-b'] });
  assert.deepEqual(read('cat-b').dependencies, ['cat-a']);
});

test('hooks: repo-specific and cross-plugin hooks are excluded, generic ones wired', () => {
  const root = fixture(
    {
      'skills/one/SKILL.md': 'x\n',
      'skills/other/SKILL.md': 'x\n',
      'hooks/ok.sh': '#!/bin/bash\n# @hook claude Stop timeout=7\nexec "$(dirname "$0")/../skills/one/run.sh"\n',
      'hooks/uses-registry.sh': '#!/bin/bash\n# @hook claude Stop\ngrep x asset-registry.yml\n',
      'hooks/crosses.sh': '#!/bin/bash\n# @hook claude Stop\nsource "$(dirname "$0")/../skills/other/run.sh"\n',
      'hooks/unwired.sh': '#!/bin/bash\n',
      'hooks/excluded.sh': '#!/bin/bash\n# @hook claude Stop\n# @plugin-exclude repo-specific\n',
    },
    [
      { path: 'skills/one/', type: 'skill', category: 'cat-a' },
      { path: 'skills/other/', type: 'skill', category: 'cat-b' },
      { path: 'hooks/ok.sh', type: 'hook', category: 'cat-a' },
      { path: 'hooks/uses-registry.sh', type: 'hook', category: 'cat-a' },
      { path: 'hooks/crosses.sh', type: 'hook', category: 'cat-a' },
      { path: 'hooks/unwired.sh', type: 'hook', category: 'cat-a' },
      { path: 'hooks/excluded.sh', type: 'hook', category: 'cat-a' },
    ],
  );
  const out = tmp();
  const r = buildPlugins({ root, config: miniConfig(), out, write: true });
  assert.deepEqual(r.errors, []);
  const hj = JSON.parse(fs.readFileSync(path.join(out, 'plugins/cat-a/hooks/hooks.json'), 'utf8'));
  assert.deepEqual(hj, {
    hooks: { Stop: [{ hooks: [{ type: 'command', command: 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/ok.sh"', timeout: 7 }] }] },
  });
  assert.ok(fs.existsSync(path.join(out, 'plugins/cat-a/hooks/ok.sh')));
  for (const n of ['uses-registry', 'crosses', 'unwired', 'excluded']) assert.ok(!fs.existsSync(path.join(out, `plugins/cat-a/hooks/${n}.sh`)));
  assert.equal(r.report.filter((l) => /^ {2}(uses-registry|crosses|unwired|excluded):/.test(l)).length, 4);
});

test('hook headers agree with the installer manifest scripts/hooktools/claude-code-hooks.json', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(repo, 'scripts/hooktools/claude-code-hooks.json'), 'utf8'));
  const fromManifest = [];
  for (const [event, groups] of Object.entries(manifest.hooks)) {
    for (const g of groups) for (const h of g.hooks) fromManifest.push(`${path.basename(h.command.match(/[\w-]+\.sh/)[0], '.sh')} ${event} ${g.matcher ?? ''}`);
  }
  const fromHeaders = [];
  for (const name of fs.readdirSync(path.join(repo, 'hooks')).filter((f) => f.endsWith('.sh'))) {
    for (const m of fs.readFileSync(path.join(repo, 'hooks', name), 'utf8').matchAll(/^# @hook claude (\S+)(?: matcher=(\S+))?/gm)) {
      fromHeaders.push(`${name.replace(/\.sh$/, '')} ${m[1]} ${m[2] ?? ''}`);
    }
  }
  for (const entry of fromManifest) assert.ok(fromHeaders.includes(entry), `manifest wiring '${entry}' missing from hook headers`);
});

test('drift is reported: missing path, duplicate, unregistered', () => {
  const root = fixture(
    {
      'commands/dup.md': 'canonical\n',
      '.cursor/commands/dup.md': 'copy\n',
      'skills/orphan/SKILL.md': 'x\n',
    },
    [
      { path: 'commands/dup.md', type: 'command', category: 'cat-a' },
      { path: '.cursor/commands/dup.md', type: 'command', category: 'cat-a' },
      { path: 'skills/gone/', type: 'skill', category: 'cat-a' },
    ],
  );
  const r = buildPlugins({ root, config: miniConfig(), out: tmp(), write: false });
  const text = r.report.join('\n');
  assert.match(text, /\[MISSING_PATH\] skill 'gone'/);
  assert.match(text, /\[DUPLICATE_DROPPED\] command 'dup'.*CONTENT DIFFERS/);
  assert.match(text, /\[UNREGISTERED\] skill 'orphan'/);
  assert.equal(r.drift, 3);
});

// ---- publication blacklist ----------------------------------------------
const pubFixture = (extraFiles = {}) =>
  fixture(
    { 'skills/one/SKILL.md': 'plain\n', 'skills/secret/SKILL.md': 'private\n', ...extraFiles },
    [
      { path: 'skills/one/', type: 'skill', category: 'cat-a' },
      { path: 'skills/secret/', type: 'skill', category: 'cat-b' },
    ],
  );
const privateCfg = (names = ['cat-b']) => miniConfig({ publication: { privatePlugins: names } });

test('public visibility excludes private plugins from tree and marketplace', () => {
  const out = tmp();
  const r = buildPlugins({ root: pubFixture(), config: privateCfg(), out, write: true, visibility: 'public' });
  assert.deepEqual(r.errors, []);
  assert.ok(fs.existsSync(path.join(out, 'plugins/cat-a')));
  assert.equal(fs.existsSync(path.join(out, 'plugins/cat-b')), false);
  const mkt = JSON.parse(fs.readFileSync(path.join(out, '.claude-plugin/marketplace.json'), 'utf8'));
  assert.deepEqual(mkt.plugins.map((p) => p.name), ['cat-a']);
  const text = r.report.join('\n');
  assert.match(text, /Private plugins configured: 1 \(present in registry: 1\)/);
  assert.match(text, /cat-b \(1 asset\(s\)\)/);
});

test('visibility defaults to public', () => {
  const out = tmp();
  const r = buildPlugins({ root: pubFixture(), config: privateCfg(), out, write: true });
  assert.deepEqual(r.errors, []);
  assert.equal(fs.existsSync(path.join(out, 'plugins/cat-b')), false);
});

test('all visibility includes private plugins', () => {
  const out = tmp();
  const r = buildPlugins({ root: pubFixture(), config: privateCfg(), out, write: true, visibility: 'all' });
  assert.deepEqual(r.errors, []);
  assert.ok(fs.existsSync(path.join(out, 'plugins/cat-b/skills/secret/SKILL.md')));
  const mkt = JSON.parse(fs.readFileSync(path.join(out, '.claude-plugin/marketplace.json'), 'utf8'));
  assert.deepEqual(mkt.plugins.map((p) => p.name), ['cat-a', 'cat-b']);
});

test('leak guard fails when a public plugin references a private one', () => {
  const root = pubFixture({ 'skills/one/SKILL.md': 'See skill `secret`.\n' });
  const out = path.join(tmp(), 'dist');
  const r = buildPlugins({ root, config: privateCfg(), out, write: true, visibility: 'public' });
  assert.equal(r.errors.length, 1);
  assert.match(r.errors[0], /skills\/one\/SKILL\.md/);
  assert.match(r.errors[0], /plugin 'cat-a'/);
  assert.match(r.errors[0], /private plugin 'cat-b'/);
  assert.equal(fs.existsSync(out), false);
  // the same content is fine in a private build
  assert.deepEqual(buildPlugins({ root, config: privateCfg(), out: tmp(), write: true, visibility: 'all' }).errors, []);
});

test('private files are not processed in public mode (no unresolved-reference noise)', () => {
  const root = pubFixture({ 'skills/secret/SKILL.md': 'Uses skill `one` and skills/ghost/\n' });
  const r = buildPlugins({ root, config: privateCfg(), out: tmp(), write: true, visibility: 'public' });
  assert.deepEqual(r.errors, []);
});

test('unknown private plugin names are tolerated and reported', () => {
  const out = tmp();
  const r = buildPlugins({ root: pubFixture(), config: privateCfg(['does-not-exist']), out, write: true, visibility: 'public' });
  assert.deepEqual(r.errors, []);
  assert.match(r.report.join('\n'), /Private plugins configured: 1 \(present in registry: 0\)/);
  assert.ok(fs.existsSync(path.join(out, 'plugins/cat-b')));
});

test('post-build assertion detects a private plugin in an output tree', () => {
  const out = tmp();
  buildPlugins({ root: pubFixture(), config: privateCfg(), out, write: true, visibility: 'all' });
  assert.equal(assertNoPrivateOutput(out, new Set(['cat-b'])).length, 2);
});

test('explicit plugin field overrides the category; description comes from x-plugin-descriptions', () => {
  const root = fixture(
    { 'skills/one/SKILL.md': 'one\n', 'skills/two/SKILL.md': 'two\n' },
    [
      { path: 'skills/one/', type: 'skill', category: 'cat-a', plugin: 'custom-plug' },
      { path: 'skills/two/', type: 'skill', category: 'cat-a' },
    ],
    'x-plugin-descriptions:\n  custom-plug: Custom things\n',
  );
  const out = tmp();
  const r = buildPlugins({ root, config: miniConfig(), out, write: true });
  assert.deepEqual(r.errors, []);
  assert.ok(fs.existsSync(path.join(out, 'plugins/custom-plug/skills/one/SKILL.md')));
  assert.ok(fs.existsSync(path.join(out, 'plugins/cat-a/skills/two/SKILL.md')));
  assert.ok(!fs.existsSync(path.join(out, 'plugins/cat-a/skills/one')));
  const manifest = JSON.parse(fs.readFileSync(path.join(out, 'plugins/custom-plug/.claude-plugin/plugin.json'), 'utf8'));
  assert.equal(manifest.description, 'Custom things');
  const mkt = JSON.parse(fs.readFileSync(path.join(out, '.claude-plugin/marketplace.json'), 'utf8'));
  assert.deepEqual(mkt.plugins.map((p) => p.name), ['cat-a', 'custom-plug']);
});

test('a plugin field naming a category reuses the category description', () => {
  const root = fixture({ 'skills/one/SKILL.md': 'one\n' }, [{ path: 'skills/one/', type: 'skill', category: 'cat-a', plugin: 'cat-b' }]);
  const out = tmp();
  const r = buildPlugins({ root, config: miniConfig(), out, write: true });
  assert.deepEqual(r.errors, []);
  const manifest = JSON.parse(fs.readFileSync(path.join(out, 'plugins/cat-b/.claude-plugin/plugin.json'), 'utf8'));
  assert.equal(manifest.description, 'Beta things');
});

test('a plugin with no description anywhere fails the build and writes nothing', () => {
  const root = fixture({ 'skills/one/SKILL.md': 'one\n' }, [{ path: 'skills/one/', type: 'skill', category: 'cat-a', plugin: 'orphan' }]);
  const out = path.join(tmp(), 'dist');
  const r = buildPlugins({ root, config: miniConfig(), out, write: true });
  assert.equal(r.errors.length, 1);
  assert.match(r.errors[0], /plugin 'orphan' has no description/);
  assert.ok(!fs.existsSync(out));
});

test('builds with explicit plugin fields are byte-identical across runs', () => {
  const make = () =>
    fixture(
      { 'skills/one/SKILL.md': 'one\n', 'skills/two/SKILL.md': 'two\n' },
      [
        { path: 'skills/one/', type: 'skill', category: 'cat-a', plugin: 'custom-plug' },
        { path: 'skills/two/', type: 'skill', category: 'cat-b' },
      ],
      'x-plugin-descriptions:\n  custom-plug: Custom things\n',
    );
  const root = make();
  const a = tmp();
  const b = tmp();
  buildPlugins({ root, config: miniConfig(), out: a, write: true });
  buildPlugins({ root, config: miniConfig(), out: b, write: true });
  assert.deepEqual(snapshot(a), snapshot(b));
});

test('config version is applied to every manifest and marketplace entry, and omitted when unset', () => {
  const root = fixture({ 'skills/one/SKILL.md': 'one\n' }, [{ path: 'skills/one/', type: 'skill', category: 'cat-a' }]);
  const withV = tmp();
  assert.deepEqual(buildPlugins({ root, config: miniConfig({ version: '1.2.3' }), out: withV, write: true }).errors, []);
  assert.equal(JSON.parse(fs.readFileSync(path.join(withV, 'plugins/cat-a/.claude-plugin/plugin.json'), 'utf8')).version, '1.2.3');
  assert.equal(JSON.parse(fs.readFileSync(path.join(withV, '.claude-plugin/marketplace.json'), 'utf8')).plugins[0].version, '1.2.3');
  const noV = tmp();
  assert.deepEqual(buildPlugins({ root, config: miniConfig(), out: noV, write: true }).errors, []);
  assert.equal('version' in JSON.parse(fs.readFileSync(path.join(noV, 'plugins/cat-a/.claude-plugin/plugin.json'), 'utf8')), false);
});

test('real repo: every built asset has an explicit plugin, drift is limited, no public plugin depends on a private one', () => {
  const registry = yaml.load(fs.readFileSync(path.join(repo, 'asset-registry.yml'), 'utf8'));
  for (const a of registry.assets.filter((x) => x.type !== 'rule')) assert.ok(a.plugin, `${a.path} has no explicit plugin`);
  const out = tmp();
  const r = buildPlugins({ root: repo, config: realConfig, out, write: true });
  assert.deepEqual(r.errors, []);
  const privates = new Set(realConfig.publication.privatePlugins);
  for (const p of r.marketplace.plugins) {
    const manifest = JSON.parse(fs.readFileSync(path.join(out, p.source, '.claude-plugin/plugin.json'), 'utf8'));
    for (const dep of manifest.dependencies ?? []) assert.ok(!privates.has(dep), `${p.name} depends on private plugin ${dep}`);
  }
});

test('README public naming contract lists every public plugin and skill of the real build', () => {
  const readme = fs.readFileSync(path.join(repo, 'scripts/plugin-builder/README.md'), 'utf8').split('\r\n').join('\n');
  const section = readme.slice(readme.indexOf('## Public naming contract'), readme.indexOf('## Adding a branch-pinned marketplace'));
  const out = tmp();
  const r = buildPlugins({ root: repo, config: realConfig, out, write: true });
  assert.deepEqual(r.errors, []);
  for (const p of r.marketplace.plugins) {
    const start = section.indexOf(`### \`${p.name}\``);
    assert.ok(start >= 0, `README contract lacks plugin ${p.name}`);
    const next = section.indexOf('### `', start + 5);
    const block = section.slice(start, next < 0 ? undefined : next);
    const skillsDir = path.join(out, p.source, 'skills');
    for (const skill of fs.existsSync(skillsDir) ? fs.readdirSync(skillsDir) : []) assert.ok(block.includes(`\`${skill}\``), `README contract lacks ${p.name}:${skill}`);
  }
  for (const priv of realConfig.publication.privatePlugins) assert.ok(!section.includes(`### \`${priv}\``), `README contract must not list private plugin ${priv}`);
});

test('commitBump follows Conventional Commits', () => {
  assert.equal(commitBump('feat(x): add y'), 'minor');
  assert.equal(commitBump('fix: z'), 'patch');
  assert.equal(commitBump('feat!: drop q'), 'major');
  assert.equal(commitBump('chore: tidy\n\nBREAKING CHANGE: gone'), 'major');
  assert.equal(commitBump('docs: words'), 'none');
});

test('nextVersion takes the highest bump and never stays below a patch', () => {
  assert.equal(nextVersion('0.1.0', ['chore: a', 'docs: b']), '0.1.1');
  assert.equal(nextVersion('0.1.4', ['fix: a', 'feat: b']), '0.2.0');
  assert.equal(nextVersion('1.2.3', ['feat: a', 'fix!: b']), '2.0.0');
  assert.throws(() => nextVersion('x', []));
});

const mcpServer = (script) => [{ name: 'srv', command: 'python3', args: [`\${CLAUDE_PLUGIN_ROOT}/skills/one/${script}`] }];

test('a skill that declares an MCP server gets a .mcp.json in its plugin', () => {
  const root = fixture(
    { 'skills/one/SKILL.md': '---\nname: one\n---\nhi\n', 'skills/one/mcp/srv.py': 'print(1)\n' },
    [{ path: 'skills/one/', type: 'skill', category: 'cat-a', mcp: mcpServer('mcp/srv.py') }],
  );
  const out = tmp();
  const r = buildPlugins({ root, config: miniConfig(), out, write: true });
  assert.deepEqual(r.errors, []);
  const mcp = JSON.parse(fs.readFileSync(path.join(out, 'plugins/cat-a/.mcp.json'), 'utf8'));
  assert.deepEqual(mcp, { mcpServers: { srv: { command: 'python3', args: ['${CLAUDE_PLUGIN_ROOT}/skills/one/mcp/srv.py'] } } });
});

test('an MCP server whose script the plugin does not ship fails the build', () => {
  const root = fixture(
    { 'skills/one/SKILL.md': '---\nname: one\n---\nhi\n' },
    [{ path: 'skills/one/', type: 'skill', category: 'cat-a', mcp: mcpServer('mcp/missing.py') }],
  );
  const r = buildPlugins({ root, config: miniConfig(), out: tmp(), write: false });
  assert.equal(r.errors.length, 1);
  assert.match(r.errors[0], /does not ship/);
});

test('real repo: the lw and prw MCP servers ship in agent-sessions with scripts that exist', () => {
  const out = tmp();
  const r = buildPlugins({ root: repo, config: realConfig, out, write: true });
  assert.deepEqual(r.errors, []);
  const mcp = JSON.parse(fs.readFileSync(path.join(out, 'plugins/agent-sessions/.mcp.json'), 'utf8'));
  assert.deepEqual(Object.keys(mcp.mcpServers).sort(), ['lw', 'prw']);
  for (const srv of Object.values(mcp.mcpServers)) {
    const script = srv.args[0].replace('${CLAUDE_PLUGIN_ROOT}/', '');
    assert.ok(fs.existsSync(path.join(out, 'plugins/agent-sessions', script)), script);
  }
});
