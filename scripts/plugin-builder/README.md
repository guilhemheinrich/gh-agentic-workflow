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
dist/plugins/<plugin>/.claude-plugin/plugin.json      # name, description, author; no version
dist/plugins/<plugin>/{skills,agents,commands,hooks}/ # as applicable
```

## Why Node and not Python

The registry is 2,000 lines of YAML (folded `>-` scalars, flow lists, quoted
strings). Python's standard library has no YAML parser, and a hand-written
subset parser would silently misread the first construct it did not anticipate.
Node is already a project dependency here (`package.json` is ESM, `js-yaml`
is installed, `scripts/sync-asset-registry.ts` is Node), so the generator is
plain `.mjs` on `js-yaml` with no new dependency.

## Grouping rule

**Plugin = registry `category`, nothing else.** Every category present among the
built assets becomes one plugin whose name and description come straight from
`x-category-descriptions`. There is no merge table, no per-asset override and no
`plugin:` field, so the split stays 100% mechanical: when categories are
reworked in the registry, the plugins follow on the next build.

| Plugin (= category) | Skills | Agents | Commands | Hooks | Total |
|---|---:|---:|---:|---:|---:|
| `architecture` | 3 | 0 | 0 | 0 | 3 |
| `devx-and-agentic` | 10 | 0 | 0 | 9 | 19 |
| `domain-specific` | 4 | 0 | 0 | 0 | 4 |
| `frameworks-and-libraries` | 13 | 0 | 0 | 0 | 13 |
| `other` | 0 | 1 | 1 | 0 | 2 |
| `philosophy` | 2 | 0 | 0 | 0 | 2 |
| `programming-languages` | 6 | 0 | 0 | 0 | 6 |
| `quality-assurance` | 12 | 4 | 2 | 0 | 18 |
| `standards` | 2 | 0 | 0 | 0 | 2 |
| `templates-and-models` | 0 | 0 | 2 | 0 | 2 |
| `tools-and-configurations` | 18 | 1 | 7 | 0 | 26 |
| `workflows-and-processes` | 10 | 5 | 1 | 0 | 16 |
| | **80** | **11** | **13** | **9** | **113** |

Skills are installed as `/<plugin>:<skill>`, e.g. `/quality-assurance:e2e-playwright`.
Plugin names are long and some plugins are tiny (2 assets); both are expected to
improve when the categories are cleaned up.

`bundles` was rejected as a grouping key (24 of 147 entries, mostly rules).

## Registry <-> filesystem mapping (reported, never silent)

The build prints every drift under `Registry drift`; `--fail-on-drift` turns it into an error.

* The library lives in `skills/`, `agents/`, `commands/` and `hooks/`. `.agents/` was a duplicate of `skills/` and has been deleted; `.claude/skills` is for Claude working on this repo and is never built.
* `skills/` wins over any other location for the same name (`canonicalRoots` in `config.json`). Today the only duplicates are `.cursor/commands/k8s-troubleshoot.md` (content differs) and `.cursor/commands/spt.md` (identical); both lose to `commands/`, and their registry categories disagree with the copy that wins.
* Registered but missing on disk: `agents/gitter.md`, `commands/commit.md` (the repo has `agents/commiter.md` and `commands/git.md`).
* **Unregistered, so not built:** skills `bitbucket-pipelines`, `docstring-python-docs`, `godoc-go-docs`, `openapi-client-generator`, `phpdoc-php-docs`, `rustdoc-rust-docs`; agents `commiter`, `fixer`, `workflow`; commands `debug`, `git`; hook `enforce-tools`.
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
the same marketplace, sorted). Today that is 11 plugin pairs, and they contain
cycles (e.g. `tools-and-configurations` <-> `quality-assurance`). Claude Code
accepts that: installing `tools-and-configurations` pulled in its four
transitive dependencies, including the cyclic ones. The practical effect is that
most plugins drag in a few others until the categories are reworked.

## Hooks

`hooks/hooks.json` is generated per plugin with commands of the form
`bash "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh"`. A hook is shipped only if all hold:

1. its own header declares the wiring, one line per event: `# @hook claude <Event> [matcher=<regex>] [timeout=<seconds>]`. The hook file is the single source of truth, and another harness can add `# @hook <harness> ...` lines. A test checks the headers against the installer manifest `scripts/hooktools/claude-code-hooks.json`;
2. it has no `# @plugin-exclude <reason>` line (repo-specific hooks carry one);
3. its source never mentions `asset-registry.yml` (this repo's own file);
4. every `skills/<x>` path it uses is built into the **same** plugin (hooks find skill scripts via `hooks/../skills/<x>/`, and plugins cannot see each other).

Result: 9 hooks shipped (all in `devx-and-agentic`, together with the skills they call); `registry-sync-on-skill.sh` excluded.

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

Run with Claude Code 2.1.325 (see the PR description for the exact output).

* `claude plugin validate dist` -> passes, 12 warnings (one per plugin), all `plugin.json -> version: No version specified`.
* `claude plugin validate dist --strict` therefore **fails**, only because `version` is deliberately omitted (the brief says to omit it for now). With a version it would be clean. `author` is set to silence the other warning.
* `claude --plugin-dir dist/plugins/devx-and-agentic -p ...` (stream-json init event): 10 skills loaded, all namespaced `devx-and-agentic:*`, no plugin errors.
* `claude plugin marketplace add ./dist` + `claude plugin install tools-and-configurations@gh-agentic-workflow` worked and installed its 4 dependencies (then removed again).

Not verified: the hooks actually firing with the intended behaviour inside a real desktop session, behaviour with only a subset of plugins installed, and `claude plugin validate <plugin> --profile directory` (that profile is only for Anthropic directory submissions).

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
