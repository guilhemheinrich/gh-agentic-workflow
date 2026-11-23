# Plugin generator (proof of concept)

`scripts/build-plugins.mjs` turns `asset-registry.yml` into several Claude Code
plugins plus a marketplace, written to a gitignored directory (default `dist/`).
A CI job can later publish that tree to a `dist` branch.

```bash
npm ci                                   # js-yaml
npm run build:plugins                    # node scripts/build-plugins.mjs  -> dist/
node scripts/build-plugins.mjs --out /tmp/x --report-only   # report, write nothing
node scripts/build-plugins.mjs --fail-on-drift              # CI mode: drift is an error
npm run test:plugins                     # node --test
claude plugin validate dist              # see "Validation" below
```

Output:

```
dist/.claude-plugin/marketplace.json
dist/plugins/<plugin>/.claude-plugin/plugin.json      # name, description, author, version (config.json `version`)
dist/plugins/<plugin>/{skills,agents,commands,hooks}/ # as applicable
```

## MCP servers shipped by a skill

A skill entry may declare `mcp` (array of `{name, command, args, env}`) when it ships a local MCP
server. The builder writes them to `dist/plugins/<plugin>/.mcp.json` (`{"mcpServers": {...}}`), which
Claude Code loads when the plugin is enabled, so users need no `claude mcp add`. Write script paths as
`${CLAUDE_PLUGIN_ROOT}/skills/<skill>/...`: the build fails if the plugin does not ship that file, if
two servers of one plugin share a name, or if `mcp` is set on a non-skill. Today: `lw`
(`linear-atlas`) and `prw` (`pr-watch`), both in `agent-sessions`.

## Versioning

CI (`publish-dist.yml`) computes the version on every publish with `scripts/plugin-builder/next-version.mjs`: latest `v*` tag + Conventional Commits since it (`feat` = minor, `fix`/`perf`/`revert` = patch, `!`/`BREAKING CHANGE` = major, anything else = patch, since a publish always changes content). It is passed to the builder with `--version`, and the tag `vX.Y.Z` is pushed after the publish. `config.json` `version` is only the seed used when no tag exists (first release = seed + patch).

## Why Node and not Python

The registry is 2,000 lines of YAML (folded `>-` scalars, flow lists, quoted
strings). Python's standard library has no YAML parser, and a hand-written
subset parser would silently misread the first construct it did not anticipate.
Node is already a project dependency here (`package.json` is ESM, `js-yaml`
is installed, `scripts/sync-asset-registry.ts` is Node), so the generator is
plain `.mjs` on `js-yaml` with no new dependency.

## Grouping rule

**Plugin = the asset's `plugin` field if set, otherwise its registry `category`.**
Every distinct plugin name among the built assets becomes one plugin. There is no
merge table; the split is driven only by registry data.

- `plugin` (optional, per asset, kebab-case `^[a-z][a-z0-9-]*$`) decouples the
  plugin split from `category`. With no `plugin` field anywhere, the output is
  identical to the pure category split.
- The plugin description comes from `x-category-descriptions` when the plugin
  name is also a category, otherwise from the top-level optional map
  `x-plugin-descriptions` (name -> description). A plugin with neither entry
  fails the build.

```yaml
x-plugin-descriptions:
  my-plugin: What this plugin groups
assets:
  - path: skills/my-skill/
    type: skill
    category: other
    plugin: my-plugin
```

Current split (every asset sets `plugin` explicitly; public build):

| Plugin | Skills | Agents | Commands | Hooks | Total |
|---|---:|---:|---:|---:|---:|
| `agent-sessions` | 9 | 0 | 0 | 9 | 18 |
| `agent-tooling` | 4 | 0 | 0 | 0 | 4 |
| `backend-and-data` | 6 | 0 | 0 | 0 | 6 |
| `docker-and-k8s` | 5 | 0 | 2 | 0 | 7 |
| `frontend` | 4 | 0 | 0 | 0 | 4 |
| `git-and-delivery` | 7 | 2 | 5 | 0 | 14 |
| `review-and-projection` | 5 | 0 | 0 | 0 | 5 |
| `speckit` | 3 | 9 | 2 | 0 | 14 |
| `testing-and-debugging` | 4 | 1 | 2 | 0 | 7 |
| | **47** | **12** | **11** | **9** | **79** |

Skills are installed as `/<plugin>:<skill>`, e.g. `/testing-and-debugging:e2e-playwright`.
`modelo-internal` (private, never published) and `speckit` (needs GitHub Spec Kit installed) are
described in `x-plugin-descriptions`. Cross-plugin references are limited to "see also" mentions and are
listed in every build report.

`bundles` was rejected as a grouping key (24 of 147 entries, mostly rules).

## Registry <-> filesystem mapping (reported, never silent)

The build prints every drift under `Registry drift`; `--fail-on-drift` turns it into an error.

* The library lives in `skills/`, `agents/`, `commands/` and `hooks/`. `.agents/` was a duplicate of `skills/` and has been deleted; `.claude/skills` is for Claude working on this repo and is never built.
* `skills/` wins over any other location for the same name (`canonicalRoots` in `config.json`). Today the only duplicates are `.cursor/commands/k8s-troubleshoot.md` (content differs) and `.cursor/commands/spt.md` (identical); both lose to `commands/`, and their registry categories disagree with the copy that wins.
* Both `.cursor/commands/` copies (`k8s-troubleshoot`, `spt`) are identical to the `commands/` copy and reported as `DUPLICATE_DROPPED` (informational; `scripts/sync-asset-registry.ts` re-adds them if removed).
* Unregistered, so not built: agents `fixer`, `workflow` (malformed frontmatter, depend on a Cursor-Teams `/fix` command). The Cursor-only hook `enforce-tools` is registered but has no `# @hook claude` header, so it is not shipped.
* Frontmatter `name` of `skills/dockerfile-multi-stage` is `multi-stage-dockerfile` (the name of another skill). The build rewrites it to the directory name; other skills without a `name` keep deriving it from the directory.

Left out on purpose: the 29 registered `rules` (`*.mdc`). Claude Code plugins have no rules component.

## Reference rewriting

Within a plugin, assets are addressed `<plugin>:<name>`. `rewrite.mjs` applies one mapping `name -> owning plugin` to every text file of every built asset. Rewritten forms (everything else is left alone):

| Form | Example | Result |
|---|---|---|
| slash command / skill | `/push` | `/tools:push` |
| skill mention | skill `x`, `` `x` skill `` | `` `plugin:x` `` |
| agent mention | agent `x`, `` `x` agent ``, `subagent_type: x` | `plugin:x` |
| path, same plugin | `skills/x/a.md` | unchanged |
| path, other plugin | `skills/x/scripts/a.sh` | `plugin:x/scripts/a.sh` (a namespaced address, no longer a file path) |
| relative link to sibling skill | `../x/SKILL.md` | unchanged if same plugin, else `plugin:x/SKILL.md` |

Install paths such as `~/.claude/skills/x/` are not references to built assets and are untouched.

**The build fails** when a reference in one of these forms names nothing the build ships and is not allowlisted. Unknown plain-text `/word` is ignored (it may be a filesystem path), but an unknown `` `/word` `` in inline code fails. Names that really are external are listed in `config.json` under `externalReferences`, grouped by reason (HTTP endpoints, Claude Code built-ins, SpecKit project commands, ...). Every use is printed in the report. Unresolved references found on this repo today: none besides the allowlisted ones (the dangling relative links `../../scripts`, `../skills`, `../shared` and the unbuilt `linear-watch` skill are source bugs worth fixing).

## Dependencies

Every cross-plugin reference found while rewriting becomes an entry in the
referencing plugin's `plugin.json` `dependencies` (bare plugin names, resolved in
the same marketplace, sorted). Today these are 7 plugin pairs (mostly "see also" links such as
`review-and-projection` -> `agent-sessions` for `grievances`), including one cycle
(`agent-tooling` <-> `git-and-delivery`). A public plugin never depends on a private one (leak guard).

## Hooks

`hooks/hooks.json` is generated per plugin with commands of the form
`bash "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh"`. A hook is shipped only if all hold:

1. its own header declares the wiring, one line per event: `# @hook claude <Event> [matcher=<regex>] [timeout=<seconds>]`. The hook file is the single source of truth, and another harness can add `# @hook <harness> ...` lines. A test checks the headers against the installer manifest `scripts/hooktools/claude-code-hooks.json`;
2. it has no `# @plugin-exclude <reason>` line (repo-specific hooks carry one);
3. its source never mentions `asset-registry.yml` (this repo's own file);
4. every `skills/<x>` path it uses is built into the **same** plugin (hooks find skill scripts via `hooks/../skills/<x>/`, and plugins cannot see each other).

Result: 9 hooks shipped (all in `agent-sessions`, together with the skills they call); `registry-sync-on-skill.sh` and `enforce-tools.sh` are not shipped.

## Publication blacklist

`config.json` has `publication.privatePlugins`, a list of plugin names that must never reach the public marketplace (first entry: `modelo-internal`; names that match nothing in the registry yet are allowed).

* `--visibility public|all` selects the mode. **The default is `public`** (fail-closed): private plugins are not written to the output tree nor to `.claude-plugin/marketplace.json`. `all` includes them (for a private marketplace) and must be passed explicitly.
* Leak guard (public mode): if a public plugin references an asset of a private plugin (which would also create a manifest `dependencies` entry), the build fails with the file, the referencing plugin and the private plugin. Private plugins' own files are not processed, so they produce no unresolved-reference noise.
* Post-build assertion (public mode): the written tree is scanned and the build fails (and the output is removed) if `plugins/<private>` exists or a private name appears in `marketplace.json`.
* The report prints `Private plugins configured: N (present in registry: M)` and, in public mode, the excluded plugins with their asset counts.

```bash
node scripts/build-plugins.mjs                      # public (default)
node scripts/build-plugins.mjs --visibility all     # private marketplace
```

## Determinism

No timestamps, sorted traversal, fixed JSON key order, LF output, file modes normalised to 0644/0755, `.DS_Store`/`__pycache__`/`*.pyc`/`node_modules` skipped. `build.test.mjs` builds the real repo twice and compares every path, mode and byte. The output directory is only cleaned if it is empty or a previous build, and nothing is written when any reference fails.

## Validation

* `claude plugin validate dist --strict` passes for both `--visibility public` and `--visibility all` outputs. `config.json` carries a single `"version"` (currently `0.1.0`) applied to every `plugin.json` and marketplace entry; omit it to build without versions (strict validation then fails).

Not verified: the hooks actually firing with the intended behaviour inside a real desktop session, behaviour with only a subset of plugins installed, and `claude plugin validate <plugin> --profile directory` (that profile is only for Anthropic directory submissions).

## Public naming contract

Plugin and skill names below are the public interface (`/<plugin>:<skill>`); renaming one is a breaking change.
Generated from the public build output (`node scripts/build-plugins.mjs --out <dir>`); a test checks that every
built asset sets `plugin` explicitly. `modelo-internal` exists in the registry but is private and never published.

| Plugin | Skills | Agents | Commands | Hooks | Total |
|---|---:|---:|---:|---:|---:|
| `agent-sessions` | 9 | 0 | 0 | 9 | 18 |
| `agent-tooling` | 4 | 0 | 0 | 0 | 4 |
| `backend-and-data` | 6 | 0 | 0 | 0 | 6 |
| `docker-and-k8s` | 5 | 0 | 2 | 0 | 7 |
| `frontend` | 4 | 0 | 0 | 0 | 4 |
| `git-and-delivery` | 7 | 2 | 5 | 0 | 14 |
| `review-and-projection` | 5 | 0 | 0 | 0 | 5 |
| `speckit` | 3 | 9 | 2 | 0 | 14 |
| `testing-and-debugging` | 4 | 1 | 2 | 0 | 7 |
| | **47** | **12** | **11** | **9** | **79** |

### `agent-sessions`

- Skills: `ai-usage-tracking`, `conversation-focus`, `grievances`, `linear-atlas`, `linear-semantics`, `linear-tracker`, `pilot-session`, `plain-explanation`, `pr-watch`, `session-meta`, `session-title`
- Hooks: `conversation-focus-prompt`, `conversation-focus-stop`, `pilot-reminder`, `session-title-ask`, `session-title-close-kids`, `session-title-progress`, `session-title-sync`, `session-title-watcher-check`, `session-title-working`

### `agent-tooling`

- Skills: `claude-plugin-release`, `eslint-solid-nestjs`, `lsp-mcp`, `static-validation-hooks`

### `backend-and-data`

- Skills: `apiconv`, `drizzle-pg-boss`, `mcp-spec-templates`, `openapi-client-generator`, `philosophy-data-first`, `sql-migration-guidelines`

### `docker-and-k8s`

- Skills: `compose-env-ports`, `docker-hotreload-volume`, `dockerfile`, `k8s-troubleshoot`, `npm-private-registry`
- Commands: `k8s-troubleshoot`, `pre-kubify`

### `frontend`

- Skills: `cursor-dot-glow`, `lit-web-components`, `text-clip-cloud-word`, `wc-live-demos-starlight`

### `git-and-delivery`

- Skills: `app-version-surface`, `devops-pipeline-design`, `git-activity-report`, `integration-branch-discipline`, `makefile-conventions`, `semantic-release-js-ts-pipeline`, `sonarqube-config`
- Agents: `commiter`, `dependency-updater`
- Commands: `git`, `improve`, `merge`, `pr-history`, `push`

### `review-and-projection`

- Skills: `adversarial-review-convergence`, `change-projection`, `cursor-adversarial-review`, `data-projection`, `openrouter-adversarial-review`

### `speckit`

- Skills: `e2e-spec-writing`, `notion-spec-sync`, `spec-reindex`
- Agents: `archivist`, `cartographer`, `debugger`, `implementer`, `orchestrator`, `qa-tester`, `reviewer`, `specifier`, `tester`
- Commands: `spec-release-and-versioning`, `spt`

### `testing-and-debugging`

- Skills: `e2e-playwright`, `playwright-auth-factory`, `test-env-targeting`, `web-analysis`
- Agents: `scraper`
- Commands: `debug`, `scrape-site`

## Adding a branch-pinned marketplace

From the CLI reference (`claude plugin marketplace add`): `owner/repo`, `owner/repo#ref` and `owner/repo@ref` are all parsed as a `github` source "pinned to `ref` when given", where `ref` is a branch or a tag:

```bash
claude plugin marketplace add guilhemheinrich/gh-agentic-workflow#dist
claude plugin marketplace add guilhemheinrich/gh-agentic-workflow@dist   # equivalent
```

In `settings.json` (`extraKnownMarketplaces`) use a source object with `ref`:

```json
{
  "extraKnownMarketplaces": {
    "gh-agentic-workflow": {
      "source": { "source": "github", "repo": "guilhemheinrich/gh-agentic-workflow", "ref": "dist" }
    }
  }
}
```

Docs: <https://code.claude.com/docs/en/plugins/cli-reference.md#plugin-marketplace-add>, <https://code.claude.com/docs/en/plugins/marketplace-reference.md#marketplace-sources>. The marketplace file must be at the branch root (`.claude-plugin/marketplace.json`), which is what this generator writes.
