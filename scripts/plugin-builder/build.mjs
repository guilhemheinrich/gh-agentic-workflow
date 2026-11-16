// Orchestration: registry -> plugin file plan -> output tree + report.

import fs from 'node:fs';
import path from 'node:path';
import { buildHooksJson, checkHook } from './hooks.mjs';
import { loadRegistry, resolveAssets, walk } from './registry.mjs';
import { flattenExternal, rewriteText } from './rewrite.mjs';

const json = (o) => `${JSON.stringify(o, null, 2)}\n`;

function isText(buf) {
  if (buf.includes(0)) return false;
  try {
    new TextDecoder('utf-8', { fatal: true }).decode(buf);
    return true;
  } catch {
    return false;
  }
}

/** Force frontmatter `name:` of a SKILL.md to the directory name, if it differs. */
function fixSkillName(text, name) {
  if (!text.startsWith('---\n')) return { text, fixed: null };
  const end = text.indexOf('\n---', 4);
  if (end === -1) return { text, fixed: null };
  const fm = text.slice(4, end);
  const m = fm.match(/^name:[ \t]*(.*)$/m);
  if (!m || m[1].trim().replace(/^["']|["']$/g, '') === name) return { text, fixed: null };
  return { text: `---\n${fm.replace(/^name:[ \t]*.*$/m, `name: ${name}`)}${text.slice(end)}`, fixed: m[1].trim() };
}

export const VISIBILITIES = ['public', 'all'];

export function buildPlugins({ root, config, out, write, visibility = 'public' }) {
  if (!VISIBILITIES.includes(visibility)) throw new Error(`invalid visibility '${visibility}' (expected: ${VISIBILITIES.join(', ')})`);
  const privateNames = new Set(config.publication?.privatePlugins ?? []);
  const isPublicMode = visibility === 'public';
  // In public mode private plugins are indexed (so references to them resolve and can be
  // detected by the leak guard) but their own files are never planned or emitted.
  const skipPlugin = (p) => isPublicMode && privateNames.has(p);
  const registry = loadRegistry(root);
  const { assets, issues, skippedRules } = resolveAssets(root, registry, config);
  const errors = [];
  const report = [];

  // ---- grouping: plugin = explicit `plugin` field, falling back to the category ----
  const categoryDescriptions = registry['x-category-descriptions'] ?? {};
  const pluginDescriptions = registry['x-plugin-descriptions'] ?? {};
  const descriptionOf = (p) => categoryDescriptions[p] ?? pluginDescriptions[p];
  for (const a of assets) {
    a.plugin = a.plugin ?? a.category;
    if (!descriptionOf(a.plugin)) errors.push(`${a.type} '${a.name}': plugin '${a.plugin}' has no description (add it to x-category-descriptions or x-plugin-descriptions)`);
  }
  const describePlugin = (p) => String(descriptionOf(p) ?? p).replace(/\s+/g, ' ').trim();
  const live = assets.filter((a) => a.plugin);

  // ---- hooks: decide inclusion -----------------------------------------
  const skillsOf = new Map();
  for (const a of live) if (a.type === 'skill') (skillsOf.get(a.plugin) ?? skillsOf.set(a.plugin, new Set()).get(a.plugin)).add(a.name);
  const builtAssets = [];
  const excludedHooks = [];
  for (const a of live) {
    if (a.type !== 'hook') {
      builtAssets.push(a);
      continue;
    }
    const src = fs.readFileSync(path.join(root, a.rel), 'utf8');
    const verdict = checkHook(a.name, src, skillsOf.get(a.plugin) ?? new Set());
    if (verdict.include) builtAssets.push({ ...a, events: verdict.events });
    else excludedHooks.push(`${a.name}: ${verdict.reason}`);
  }

  // ---- index for reference resolution ----------------------------------
  const index = { skill: new Map(), command: new Map(), agent: new Map() };
  for (const a of builtAssets) if (index[a.type]) index[a.type].set(a.name, a.plugin);

  const external = {
    skill: flattenExternal(config.externalReferences.skill),
    agent: flattenExternal(config.externalReferences.agent),
    slash: flattenExternal(config.externalReferences.slash),
  };
  const usedExternal = new Map();

  // ---- file plan --------------------------------------------------------
  const plugins = new Map(); // plugin -> {files: Map(rel -> {buf, mode}), deps: Map(dep -> Set(from)), counts}
  const planOf = (p) => {
    if (!plugins.has(p)) plugins.set(p, { files: new Map(), deps: new Map(), counts: { skill: 0, command: 0, agent: 0, hook: 0 } });
    return plugins.get(p);
  };
  const nameFixes = [];

  const addFile = (plan, rel, buf, mode, ctx) => {
    let outBuf = buf;
    if (ctx && isText(buf)) {
      const { text, errors: errs, deps } = rewriteText(buf.toString('utf8'), ctx);
      errors.push(...errs);
      for (const d of deps) {
        if (!plan.deps.has(d)) plan.deps.set(d, new Set());
        plan.deps.get(d).add(ctx.file);
      }
      if (rel.endsWith('.md')) {
        let t = text;
        if (/^skills\/[^/]+\/SKILL\.md$/.test(rel)) {
          const r = fixSkillName(t, rel.split('/')[1]);
          if (r.fixed !== null) nameFixes.push(`${rel.split('/')[1]}: frontmatter name '${r.fixed}' -> directory name`);
          t = r.text;
        }
        outBuf = Buffer.from(t, 'utf8');
      }
    }
    plan.files.set(rel, { buf: outBuf, mode });
  };

  const excludedPrivate = new Map(); // private plugin -> asset count
  for (const a of builtAssets) {
    if (skipPlugin(a.plugin)) {
      excludedPrivate.set(a.plugin, (excludedPrivate.get(a.plugin) ?? 0) + 1);
      continue;
    }
    const plan = planOf(a.plugin);
    plan.counts[a.type]++;
    const mk = (file, rel) => ({
      plugin: a.plugin,
      index,
      config,
      file,
      external,
      usedExternal,
      skillDepth: rel?.startsWith('skills/') ? rel.split('/').length - 2 : null,
    });
    if (a.type === 'skill') {
      for (const f of walk(path.join(root, a.rel))) {
        const abs = path.join(root, a.rel, f);
        const rel = `skills/${a.name}/${f}`;
        addFile(plan, rel, fs.readFileSync(abs), fs.statSync(abs).mode & 0o111 ? 0o755 : 0o644, mk(`${a.rel}/${f}`, rel));
      }
    } else {
      const abs = path.join(root, a.rel);
      const dir = { command: 'commands', agent: 'agents', hook: 'hooks' }[a.type];
      const ext = a.type === 'hook' ? 'sh' : 'md';
      addFile(plan, `${dir}/${a.name}.${ext}`, fs.readFileSync(abs), a.type === 'hook' ? 0o755 : 0o644, mk(a.rel));
    }
  }

  // ---- leak guard: no public plugin may reference a private one ----------
  if (isPublicMode) {
    for (const [p, plan] of [...plugins].sort(([a], [b]) => a.localeCompare(b))) {
      for (const [dep, from] of [...plan.deps].sort(([a], [b]) => a.localeCompare(b))) {
        if (!privateNames.has(dep)) continue;
        for (const file of [...from].sort()) {
          errors.push(`publication leak: '${file}' (plugin '${p}') references private plugin '${dep}'; refusing a public build`);
        }
      }
    }
  }

  // ---- manifests ---------------------------------------------------------
  const hooksOf = new Map();
  for (const a of builtAssets) if (a.type === 'hook') (hooksOf.get(a.plugin) ?? hooksOf.set(a.plugin, []).get(a.plugin)).push({ name: a.name, events: a.events });
  for (const [p, names] of hooksOf) {
    planOf(p).files.set('hooks/hooks.json', { buf: Buffer.from(json(buildHooksJson(names))), mode: 0o644 });
  }
  const pluginNames = [...plugins.keys()].sort();
  for (const p of pluginNames) {
    const manifest = { name: p, description: describePlugin(p), author: config.marketplace.owner };
    if (config.version) manifest.version = config.version;
    const dependencies = [...plugins.get(p).deps.keys()].sort();
    if (dependencies.length) manifest.dependencies = dependencies;
    planOf(p).files.set('.claude-plugin/plugin.json', { buf: Buffer.from(json(manifest)), mode: 0o644 });
  }
  const marketplace = {
    name: config.marketplace.name,
    owner: config.marketplace.owner,
    description: config.marketplace.description,
    plugins: pluginNames.map((p) => ({ name: p, source: `./plugins/${p}`, description: describePlugin(p), ...(config.version ? { version: config.version } : {}) })),
  };

  // ---- report ------------------------------------------------------------
  report.push('Plugins (asset counts):');
  for (const p of pluginNames) {
    const c = plugins.get(p).counts;
    report.push(`  ${p.padEnd(18)} skills=${c.skill} agents=${c.agent} commands=${c.command} hooks=${c.hook}`);
  }
  const edges = [];
  for (const p of pluginNames) for (const [d, from] of plugins.get(p).deps) edges.push(`  ${p} -> ${d} (${from.size} file(s))`);
  report.push(`Cross-plugin references: ${edges.length}`, ...edges);
  if (usedExternal.size) {
    report.push(`Allowed external references (config.externalReferences): ${usedExternal.size}`);
    for (const k of [...usedExternal.keys()].sort()) report.push(`  ${k} x${usedExternal.get(k)}`);
  }
  const presentPrivate = new Set(builtAssets.filter((a) => privateNames.has(a.plugin)).map((a) => a.plugin));
  report.push(`Visibility: ${visibility}`);
  report.push(`Private plugins configured: ${privateNames.size} (present in registry: ${presentPrivate.size})`);
  if (isPublicMode && excludedPrivate.size) {
    report.push('Private plugins excluded from this public build:');
    for (const p of [...excludedPrivate.keys()].sort()) report.push(`  ${p} (${excludedPrivate.get(p)} asset(s))`);
  }
  report.push(`Registry drift: ${issues.length}`, ...issues.map((i) => `  [${i.code}] ${i.message}`));
  if (nameFixes.length) report.push('Skill name normalised:', ...nameFixes.map((n) => `  ${n}`));
  if (excludedHooks.length) report.push('Hooks excluded:', ...excludedHooks.map((h) => `  ${h}`));
  report.push(`Rules left out (no Claude plugin equivalent): ${skippedRules.length}`);

  if (write && errors.length === 0) {
    if (fs.existsSync(out)) {
      const entries = fs.readdirSync(out);
      if (entries.length && !fs.existsSync(path.join(out, '.claude-plugin/marketplace.json'))) {
        throw new Error(`refusing to clean '${out}': not empty and not a previous build`);
      }
      fs.rmSync(out, { recursive: true });
    }
    const put = (rel, buf, mode = 0o644) => {
      const abs = path.join(out, rel);
      fs.mkdirSync(path.dirname(abs), { recursive: true });
      fs.writeFileSync(abs, buf, { mode });
      fs.chmodSync(abs, mode);
    };
    put('.claude-plugin/marketplace.json', Buffer.from(json(marketplace)));
    for (const p of pluginNames) {
      for (const rel of [...plugins.get(p).files.keys()].sort()) {
        const f = plugins.get(p).files.get(rel);
        put(`plugins/${p}/${rel}`, f.buf, f.mode);
      }
    }
    if (isPublicMode) {
      const leaks = assertNoPrivateOutput(out, privateNames);
      if (leaks.length) {
        errors.push(...leaks);
        fs.rmSync(out, { recursive: true, force: true });
      }
    }
  }
  return { report, errors, drift: issues.length, plugins, marketplace };
}

/** Post-build check on the written tree (public mode): returns a list of leak errors. */
export function assertNoPrivateOutput(out, privateNames) {
  const leaks = [];
  for (const p of [...privateNames].sort()) {
    if (fs.existsSync(path.join(out, 'plugins', p))) leaks.push(`publication leak: output contains directory 'plugins/${p}' of a private plugin`);
  }
  const mktFile = path.join(out, '.claude-plugin/marketplace.json');
  const names = (JSON.parse(fs.readFileSync(mktFile, 'utf8')).plugins ?? []).map((e) => e.name);
  for (const p of [...privateNames].sort()) {
    if (names.includes(p)) leaks.push(`publication leak: marketplace.json lists private plugin '${p}'`);
  }
  return leaks;
}
