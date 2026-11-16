// hooks/hooks.json generation for generic hooks.
//
// A hook is generic, and therefore shipped, when ALL of these hold:
//   1. its own header declares the wiring for Claude Code, one line per event:
//        # @hook claude <Event> [matcher=<regex>] [timeout=<seconds>]
//      (the hook file is the single source of truth; other harnesses can add
//      their own `# @hook <harness> ...` lines);
//   2. it has no `# @plugin-exclude <reason>` line (repo-specific hooks carry one);
//   3. its source never mentions asset-registry.yml (the registry is this
//      repository's own file, absent from any user project);
//   4. every skills/<name> path it references resolves to a skill built into
//      the SAME plugin, because a hook reaches skill scripts relatively
//      (hooks/../skills/<name>/...) and plugins cannot see each other's files.

/** Read the `# @hook` / `# @plugin-exclude` header lines of a hook script. */
export function parseHookHeader(source, harness = 'claude') {
  const events = [];
  let exclude = null;
  for (const line of source.split('\n')) {
    const x = line.match(/^# @plugin-exclude\s+(.+)$/);
    if (x) exclude = x[1].trim();
    const m = line.match(/^# @hook (\S+) (\S+)((?: \S+=\S+)*)\s*$/);
    if (!m || m[1] !== harness) continue;
    const ev = { event: m[2] };
    for (const kv of m[3].trim().split(/\s+/).filter(Boolean)) {
      const [k, v] = [kv.slice(0, kv.indexOf('=')), kv.slice(kv.indexOf('=') + 1)];
      if (k === 'matcher') ev.matcher = v;
      else if (k === 'timeout') ev.timeout = Number(v);
    }
    events.push(ev);
  }
  return { events, exclude };
}

export function checkHook(name, source, skillsOfPlugin) {
  const { events, exclude } = parseHookHeader(source);
  if (exclude) return { include: false, reason: exclude };
  if (!events.length) return { include: false, reason: 'no `# @hook claude <Event>` header line' };
  if (/asset-registry\.yml/.test(source)) return { include: false, reason: 'reads asset-registry.yml (repo-specific)' };
  const missing = new Set();
  for (const m of source.matchAll(/(?<![\w~$}.-])skills\/([a-z0-9][a-z0-9-]*)/g)) {
    // `$here/../skills/x/...` is preceded by '/', which the lookbehind lets through
    // only for the relative-lookup idiom.
    if (!skillsOfPlugin.has(m[1])) missing.add(m[1]);
  }
  for (const m of source.matchAll(/\.\.\/skills\/([a-z0-9][a-z0-9-]*)/g)) {
    if (!skillsOfPlugin.has(m[1])) missing.add(m[1]);
  }
  if (missing.size) return { include: false, reason: `references skill(s) outside its plugin: ${[...missing].sort().join(', ')}` };
  return { include: true, events };
}

/** Build the hooks.json object for the included hooks, in a stable order. */
export function buildHooksJson(included) {
  const byEvent = new Map(); // event -> Map(matcher -> [commands])
  for (const { name, events } of [...included].sort((a, b) => (a.name < b.name ? -1 : 1))) {
    for (const { event, matcher = '', timeout } of events) {
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
