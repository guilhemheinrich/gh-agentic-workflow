// hooks/hooks.json generation for generic hooks.
//
// A hook is generic, and therefore shipped, when ALL of these hold:
//   1. config.hooks has a wiring entry for it (events/matchers), i.e. someone
//      declared which Claude Code events it listens to;
//   2. it has no `exclude` reason (repo-specific hooks carry one);
//   3. its source never mentions asset-registry.yml (the registry is this
//      repository's own file, absent from any user project);
//   4. every skills/<name> path it references resolves to a skill built into
//      the SAME plugin, because a hook reaches skill scripts relatively
//      (hooks/../skills/<name>/...) and plugins cannot see each other's files.

export function checkHook(name, source, hookConfig, skillsOfPlugin) {
  const cfg = hookConfig[name];
  if (!cfg) return { include: false, reason: 'no wiring entry in config.hooks' };
  if (cfg.exclude) return { include: false, reason: cfg.exclude };
  if (/asset-registry\.yml/.test(source)) return { include: false, reason: 'reads asset-registry.yml (repo-specific)' };
  const missing = new Set();
  for (const m of source.matchAll(/(?<![\w~$}.-])(?:\.agents\/)?skills\/([a-z0-9][a-z0-9-]*)/g)) {
    // `$here/../skills/x/...` is preceded by '/', which the lookbehind lets through
    // only for the relative-lookup idiom; absolute ~/.agents/skills paths are skipped.
    if (!skillsOfPlugin.has(m[1])) missing.add(m[1]);
  }
  for (const m of source.matchAll(/\.\.\/skills\/([a-z0-9][a-z0-9-]*)/g)) {
    if (!skillsOfPlugin.has(m[1])) missing.add(m[1]);
  }
  if (missing.size) return { include: false, reason: `references skill(s) outside its plugin: ${[...missing].sort().join(', ')}` };
  return { include: true };
}

/** Build the hooks.json object for the included hooks, in a stable order. */
export function buildHooksJson(included, hookConfig) {
  const byEvent = new Map(); // event -> Map(matcher -> [commands])
  for (const name of [...included].sort()) {
    for (const { event, matcher = '', timeout } of hookConfig[name].events) {
      if (!byEvent.has(event)) byEvent.set(event, new Map());
      const m = byEvent.get(event);
      if (!m.has(matcher)) m.set(matcher, []);
      const h = { type: 'command', command: `bash "\${CLAUDE_PLUGIN_ROOT}/hooks/${name}.sh"` };
      if (timeout) h.timeout = timeout;
      m.get(matcher).push(h);
    }
  }
  const hooks = {};
  for (const event of [...byEvent.keys()].sort()) {
    hooks[event] = [...byEvent.get(event).keys()].sort().map((matcher) => {
      const entry = {};
      if (matcher) entry.matcher = matcher;
      entry.hooks = byEvent.get(event).get(matcher);
      return entry;
    });
  }
  return { hooks };
}
