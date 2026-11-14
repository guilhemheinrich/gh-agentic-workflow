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

**Plugin = registry `category`, with small categories merged by a table in
`config.json` (`plugins.<name>.categories`).** Nothing else decides placement:
no per-asset overrides exist.

Alternatives considered:

| Option | Verdict |
|---|---|
| `bundles` | Only 24 of 177 entries have one (`common`), and half of those are rules. Cannot partition the library. |
| 12 categories 1:1 | Plugins of 2, 3, 3 and 4 assets (philosophy, standards, architecture, domain), and `other` holds SpecKit commands. 10 cross-plugin references and several hard path conflicts. |
| New `plugin:` schema field | Cleanest long term, but means hand-assigning ~150 entries and a schema change. Left as an owner decision (see below). |
| **Categories merged into 7 plugins** | Sizes 4 to 43, and the commands that point deep into skill files (`specify-mcp-*` -> `mcp-*` skills) land in the same plugin. |

Category -> plugin table (assets actually built):

| Plugin | Categories | Skills | Agents | Commands | Hooks | Total |
|---|---|---:|---:|---:|---:|---:|
| `devx-agentic` | devx-and-agentic | 10 | 0 | 0 | 9 | 19 |
| `domain` | domain-specific | 4 | 0 | 0 | 0 | 4 |
| `foundations` | architecture, standards, philosophy, programming-languages | 13 | 0 | 0 | 0 | 13 |
| `frameworks` | frameworks-and-libraries, templates-and-models | 13 | 0 | 2 | 0 | 15 |
| `quality` | quality-assurance | 12 | 4 | 2 | 0 | 18 |
| `tools` | tools-and-configurations | 18 | 1 | 7 | 0 | 26 |
| `workflows` | workflows-and-processes, other | 15 | 6 | 22 | 0 | 43 |
| | | **85** | **11** | **33** | **9** | **138** |

Skills are installed as `/<plugin>:<skill>`, so `/quality:e2e-playwright` and so on.

Known quirk: `other` was merged into `workflows` because it is mostly SpecKit
commands, but it also contains `scrape-site` and the `scraper` agent.

## Registry <-> filesystem mapping (reported, never silent)

The build prints every drift under `Registry drift` and counts it; `--fail-on-drift` turns it into an error.

* **`.agents/skills/` vs `skills/`.** 10 skills are registered under `.agents/skills/`. Four of them (`documentation-writer`, `gh-cli`, `git-commit`, `k8s-troubleshoot`) also exist under `skills/` and are registered twice. Canonical roots are `skills/` > `.agents/skills/` (config `canonicalRoots`). `.agents/skills/` copies differ from `skills/` for three of the four (`git-commit` there is a 39-byte stub). The other five (`speckit-git-*`) exist only under `.agents/skills/` and are built from there.
* Stale entry: `.agents/skills/web-analysis/SKILL.md` does not exist (the skill is registered a second time under `skills/web-analysis/`).
* Registered but missing on disk: `agents/gitter.md`, `commands/commit.md` (the repo has `agents/commiter.md` and `commands/git.md`).
* Commands registered under both `.cursor/commands/` and `commands/` (`spt`, `k8s-troubleshoot`) are deduplicated the same way (`commands/` wins); their categories disagree in the registry.
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
| path, same plugin | `.agents/skills/x/`, `skills/x/a.md` | `skills/x/...` (normalised) |
| path, other plugin | `skills/x/scripts/a.sh` | `plugin:x/scripts/a.sh` (a namespaced address, no longer a file path) |
| relative link to sibling skill | `../x/SKILL.md` | unchanged if same plugin, else `plugin:x/SKILL.md` |

Install paths such as `~/.agents/skills/x/` are not references to built assets and are untouched.

**The build fails** when a reference in one of these forms names nothing the build ships and is not allowlisted. Unknown plain-text `/word` is ignored (it may be a filesystem path), but an unknown `` `/word` `` in inline code fails. Names that really are external are listed in `config.json` under `externalReferences`, grouped by reason (HTTP endpoints, Claude Code built-ins, SpecKit project commands, ...). Every use is printed in the report. Unresolved references found on this repo today: none besides the allowlisted ones (43 distinct names/uses; the dangling relative links `../../scripts`, `../skills`, `../shared` and the unbuilt `linear-watch` skill are source bugs worth fixing).

Cross-plugin references (11 plugin pairs, with cycles) are reported but **not** turned into `dependencies` in `plugin.json`, because the graph has cycles. Users who install only some plugins get dangling `plugin:name` mentions.

## Hooks

`hooks/hooks.json` is generated per plugin with commands of the form
`bash "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh"`. A hook is shipped only if all hold:

1. `config.json` `hooks.<name>` declares its events/matchers (registry entries carry no event, only prose comments in the scripts; wiring copied from the session-title skill doc);
2. it has no `exclude` reason;
3. its source never mentions `asset-registry.yml` (this repo's own file);
4. every `skills/<x>` path it uses is built into the **same** plugin (hooks find skill scripts via `hooks/../skills/<x>/`, and plugins cannot see each other).

Result: 9 hooks shipped (all in `devx-agentic`, together with the skills they call); `registry-sync-on-skill.sh` excluded.

## Determinism

No timestamps, sorted traversal, fixed JSON key order, LF output, file modes normalised to 0644/0755, `.DS_Store`/`__pycache__`/`*.pyc`/`node_modules` skipped. `build.test.mjs` builds the real repo twice and compares every path, mode and byte. The output directory is only cleaned if it is empty or a previous build, and nothing is written when any reference fails.

## Validation

Run with Claude Code 2.1.325 (see the PR description for the exact output).

* `claude plugin validate dist` -> passes, 7 warnings, all `plugin.json -> version: No version specified`.
* `claude plugin validate dist --strict` therefore **fails**, only because `version` is deliberately omitted (the brief says to omit it for now). With a version it would be clean. `author` is set to silence the other warning.
* `claude --plugin-dir dist/plugins/devx-agentic -p ...` (stream-json init event): 10 skills loaded, all namespaced `devx-agentic:*`, no plugin errors.
* `claude plugin marketplace add ./dist` + `claude plugin install quality@gh-agentic-workflow` worked (then removed again).

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
