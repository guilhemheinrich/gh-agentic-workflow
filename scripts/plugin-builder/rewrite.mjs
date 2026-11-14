// Deterministic cross-reference rewriting.
//
// Inside a plugin every skill, command and agent is namespaced `<plugin>:<name>`.
// This module finds references between assets in four syntactic forms and
// rewrites them through one mapping (name -> owning plugin):
//
//   path     skills/<name>[/...] and .agents/skills/<name>[/...]
//   relative ../<name>/... between sibling skills (resolved from the file's depth)
//   slash    /<name>  (known command or skill names; backticked unknown ones fail)
//   skill    skill `<name>`  |  `<name>` skill
//   agent    agent `<name>`  |  `<name>` agent  |  subagent_type: <name>
//
// Anything in one of these forms that names no known asset and is not listed
// under `externalReferences` in the config is an error: the build must fail.

const NAME = String.raw`[a-z0-9][a-z0-9-]*`;
const CMD = String.raw`[a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*)*`;

const RE = new RegExp(
  [
    // path: not preceded by ~/, $HOME/, another path segment or a word char
    String.raw`(?<path>(?<![\w~/$}.-])(?<agentsdir>\.agents\/)?skills\/(?<pname>[^\s/\`'")\],;:]+)(?<prest>\/[^\s\`'")\]]*)?)`,
    // relative sibling-skill link: ../<name>/ (only acted on when it lands in skills/)
    String.raw`(?<rel>(?<![\w./~$}-])(?<ups>(?:\.\.\/)+)(?<rname>[a-z0-9][a-z0-9-]*)(?=\/))`,
    // skill `x` | skills `x`
    String.raw`(?<skillA>\b[Ss]kills? \`(?<sa>${NAME})\`)`,
    // `x` skill
    String.raw`(?<skillB>\`(?<sb>${NAME})\` skill\b)`,
    // agent `x` | subagent `x`
    String.raw`(?<agentA>\b(?:sub)?agent \`(?<aa>${NAME})\`)`,
    // `x` agent | `x` subagent
    String.raw`(?<agentB>\`(?<ab>${NAME})\` (?:sub)?agent\b)`,
    // subagent_type: x | subagent_type="x"
    String.raw`(?<agentC>subagent_type(?<ac1>[:=] ?["']?)(?<ac>${NAME}))`,
    // slash command
    String.raw`(?<slash>(?<![\w/.~$}-])\/(?<sname>${CMD})(?![\w/-]|\.\w))`,
  ].join('|'),
  'g',
);

/** {reason: [names]} -> Map(name -> reason) */
export function flattenExternal(groups = {}) {
  const m = new Map();
  for (const [reason, names] of Object.entries(groups)) for (const n of names) m.set(n, reason);
  return m;
}

/**
 * @param {string} text
 * @param {{plugin:string, index:{skill:Map,command:Map,agent:Map}, config:object, file:string}} ctx
 * @returns {{text:string, errors:string[], deps:Set<string>}}
 */
export function rewriteText(text, ctx) {
  const { plugin, index, config, file } = ctx;
  const ext = ctx.external ?? {
    skill: flattenExternal(config.externalReferences.skill),
    agent: flattenExternal(config.externalReferences.agent),
    slash: flattenExternal(config.externalReferences.slash),
  };
  const used = ctx.usedExternal ?? new Map();
  const allow = (kind, n) => {
    const reason = ext[kind].get(n);
    if (reason) used.set(`${kind} ${n} (${reason})`, (used.get(`${kind} ${n} (${reason})`) ?? 0) + 1);
    return Boolean(reason);
  };
  const errors = [];
  const deps = new Set();

  const qualify = (kind, name) => {
    const owner = index[kind].get(name);
    if (owner !== plugin) deps.add(owner);
    return `${owner}:${name}`;
  };

  const out = text.replace(RE, (m, ...args) => {
    const g = args[args.length - 1];
    const offset = args[args.length - 3];
    if (g.path) {
      const raw = g.pname.replace(/[.]+$/, '');
      if (!/^[a-z0-9][a-z0-9._-]*$/.test(raw)) return m; // placeholder like <name> or *
      const trailing = g.pname.slice(raw.length);
      const owner = index.skill.get(raw);
      if (!owner) {
        if (allow('skill', raw)) return m;
        errors.push(`${file}: path '${m}' names unknown skill '${raw}'`);
        return m;
      }
      if (owner === plugin) return `skills/${raw}${trailing}${g.prest ?? ''}`;
      // Another plugin's skill: a filesystem path cannot cross plugins, so the
      // path becomes a namespaced address '<plugin>:<skill>[/<path>]'.
      deps.add(owner);
      return `${owner}:${raw}${g.prest ?? ''}${trailing}`;
    }
    if (g.rel) {
      if (ctx.skillDepth !== g.ups.length / 3) return m; // does not land in skills/
      const owner = index.skill.get(g.rname);
      if (!owner) {
        if (allow('skill', g.rname)) return m;
        errors.push(`${file}: relative link '${m}' names unknown sibling skill '${g.rname}'`);
        return m;
      }
      if (owner === plugin) return m;
      deps.add(owner);
      return `${owner}:${g.rname}`;
    }
    if (g.skillA || g.skillB) {
      const n = g.sa ?? g.sb;
      if (!index.skill.has(n)) {
        if (!allow('skill', n)) errors.push(`${file}: '${m}' names unknown skill '${n}'`);
        return m;
      }
      return g.skillA ? m.replace(`\`${n}\``, `\`${qualify('skill', n)}\``) : `\`${qualify('skill', n)}\` skill`;
    }
    if (g.agentA || g.agentB || g.agentC) {
      const n = g.aa ?? g.ab ?? g.ac;
      if (!index.agent.has(n)) {
        if (!allow('agent', n)) errors.push(`${file}: '${m}' names unknown agent '${n}'`);
        return m;
      }
      if (g.agentA) return m.replace(`\`${n}\``, `\`${qualify('agent', n)}\``);
      if (g.agentB) return m.replace(`\`${n}\``, `\`${qualify('agent', n)}\``);
      return `subagent_type${g.ac1}${qualify('agent', n)}`;
    }
    if (g.slash) {
      const n = g.sname;
      const before = text[offset - 1];
      const after = text[offset + m.length];
      const known = index.command.has(n) ? 'command' : index.skill.has(n) ? 'skill' : null;
      if (known) {
        if (index.command.has(n) && index.skill.has(n) && index.command.get(n) !== index.skill.get(n)) {
          errors.push(`${file}: '${m}' is ambiguous: command in '${index.command.get(n)}', skill in '${index.skill.get(n)}'`);
          return m;
        }
        return `/${qualify(known, n)}`;
      }
      // Unknown names are only an error when clearly written as a command: `/name`.
      if (before === '`' && (after === '`' || after === ' ') && !allow('slash', n)) {
        errors.push(`${file}: '${m}' looks like a slash command but matches no command or skill`);
      }
      return m;
    }
    return m;
  });
  return { text: out, errors, deps };
}
