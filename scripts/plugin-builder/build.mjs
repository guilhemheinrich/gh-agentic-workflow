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

export function buildPlugins({ root, config, out, write }) {
  const registry = loadRegistry(root);
  const { assets, issues, skippedRules } = resolveAssets(root, registry, config);
  const errors = [];
  const report = [];

  // ---- grouping: category -> plugin ------------------------------------
  const pluginOfCategory = new Map();
  for (const [plugin, def] of Object.entries(config.plugins)) {
    for (const c of def.categories) pluginOfCategory.set(c, plugin);
  }
  for (const a of assets) {
    a.plugin = pluginOfCategory.get(a.category);
    if (!a.plugin) errors.push(`${a.type} '${a.name}': category '${a.category}' is not mapped to a plugin`);
  }
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
    const verdict = checkHook(a.name, src, config.hooks, skillsOf.get(a.plugin) ?? new Set());
    if (verdict.include) builtAssets.push(a);
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

  for (const a of builtAssets) {
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

  // ---- manifests ---------------------------------------------------------
  const hooksOf = new Map();
  for (const a of builtAssets) if (a.type === 'hook') (hooksOf.get(a.plugin) ?? hooksOf.set(a.plugin, []).get(a.plugin)).push(a.name);
  for (const [p, names] of hooksOf) {
    planOf(p).files.set('hooks/hooks.json', { buf: Buffer.from(json(buildHooksJson(names, config.hooks))), mode: 0o644 });
  }
  const pluginNames = [...plugins.keys()].sort();
  for (const p of pluginNames) {
    const manifest = { name: p, description: config.plugins[p].description, author: config.marketplace.owner };
    planOf(p).files.set('.claude-plugin/plugin.json', { buf: Buffer.from(json(manifest)), mode: 0o644 });
  }
  const marketplace = {
    name: config.marketplace.name,
    owner: config.marketplace.owner,
    description: config.marketplace.description,
    plugins: pluginNames.map((p) => ({ name: p, source: `./plugins/${p}`, description: config.plugins[p].description })),
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
  }
  return { report, errors, drift: issues.length, plugins, marketplace };
}
