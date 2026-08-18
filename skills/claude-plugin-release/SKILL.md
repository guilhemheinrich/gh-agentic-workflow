---
name: claude-plugin-release
description: >-
  Version, locally test, and release Claude Code plugins
  (.claude-plugin/plugin.json + marketplace). Covers the version-resolution
  model (plugin.json vs marketplace.json vs git SHA), the local dev loop
  (--plugin-dir live loading + shell-alias persistence — no settings.json key
  exists for it, /reload-plugins, claude plugin validate), the plugin cache pitfall
  (installs are copied to ~/.claude/plugins/cache even from a local directory
  marketplace), update propagation to installed users, and semantic-release
  automation that bumps plugin.json from Conventional Commits. Use when
  bumping a plugin version, testing a plugin locally before publishing,
  wiring release automation for a plugin repo, or debugging why users don't
  receive a plugin update.
tags:
  - ci-cd
  - claude
  - git
  - versioning
---

# `claude-plugin-release` — version, test, and release a Claude Code plugin

Doc sources (fetch when details matter — the CLI evolves fast):

- <https://code.claude.com/docs/en/plugins-reference.md> (manifest schema, CLI commands)
- <https://code.claude.com/docs/en/plugins.md#test-your-plugins-locally>
- <https://code.claude.com/docs/en/plugin-marketplaces.md> (version resolution, release channels)

## 1. The version-resolution model (read this first)

Claude Code resolves a plugin's version from the first match:

1. `version` in the plugin's own `.claude-plugin/plugin.json` — **always wins, silently**
2. `version` in the marketplace entry (`.claude-plugin/marketplace.json`)
3. Git commit SHA of the plugin source — the default when neither is set

Consequences that explain most "why didn't my update ship?" bugs:

| State | Update behaviour for installed users |
|---|---|
| `version` **omitted** everywhere | Every commit = a new version (SHA). Updates flow automatically. |
| `version: "1.2.0"` set in `plugin.json` | Users get an update **only when the string changes**. A commit without a bump is silently skipped. |
| `version` set in **both** plugin.json and marketplace.json | `plugin.json` wins **without warning** — a bump made only in the marketplace entry is invisible. |

**Convention**: put the version in exactly ONE place — `plugin.json`.
Omit it entirely during pre-1.0 active development (SHA mode) and pin a
semver string once real users install the plugin, so only intentional
releases reach them.

Update delivery: there is no `claude plugin update <name>` for a single
plugin — Claude Code checks in the background during sessions, and
`/plugin marketplace update <marketplace-name>` forces a catalog
refresh. If the resolved version matches the cache
(`~/.claude/plugins/cache`), the update is skipped.

## 2. Local dev loop — never install/uninstall to test

The only live-loading mechanism is the `--plugin-dir` CLI flag — it
loads the plugin for that session straight from its working directory,
bypassing marketplace install entirely:

```bash
claude --plugin-dir ./path/to/plugin
```

It points at the **plugin directory** (the one containing
`.claude-plugin/plugin.json`), not the marketplace repo root, and reads
the directory **live** — no cache, no version resolution.

There is **no settings.json key and no environment variable** for
persistent plugin-dir loading (verified against settings.md and the
CLI 2.1.220 settings schema — a `pluginDirs` key is rejected). Two
persistence routes exist instead:

**a) Shell alias** — terminal-launched sessions only:

```bash
# bash/zsh          alias claude-dev='claude --plugin-dir /abs/path/to/plugin'
# fish              alias claude-dev "claude --plugin-dir /abs/path/to/plugin"
```

**b) `~/.claude/skills/` auto-load** — every session on every surface
(terminal CLI, desktop app, IDE extension). A plugin directory placed
(or **symlinked** — links are followed, verified on CLI 2.1.220) under
`~/.claude/skills/<name>/` auto-loads as `<name>@skills-dir`:

```bash
ln -s /abs/path/to/plugin ~/.claude/skills/my-plugin
claude plugin details my-plugin@skills-dir   # confirm resolution
```

- Shadowing precedence differs between the two routes (both verified
  empirically): a `--plugin-dir` plugin **shadows** an installed
  same-name plugin, but a `@skills-dir` plugin is **suppressed by** an
  installed same-name plugin — even a *disabled* one; only
  `claude plugin uninstall <name>@<marketplace>` frees the name.
- That inversion makes skills-dir a clean two-state toggle: leave the
  symlink in place permanently, then `uninstall` the marketplace copy
  to go live-local everywhere, `install` it again to return to the
  released version (the reinstall automatically re-suppresses
  skills-dir). Plugin changes apply to NEW sessions — restart open ones.
- Multiple plugins: repeat the flag (`--plugin-dir ./a --plugin-dir ./b`)
  or one symlink per plugin.
- Mid-session, `/reload-plugins` hot-reloads **skills, agents, hooks,
  MCP/LSP servers**. It does NOT reload `settings.json` or directory
  structure changes — those need a session restart.

**Cache pitfall — a "local marketplace" is NOT live.** `claude plugin
marketplace add ./local-repo` + `/plugin install x@local-repo` still
COPIES the plugin into `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`,
pinned at the resolved version. Edits to the source directory are
invisible until a version bump + `/plugin marketplace update`, or an
uninstall/reinstall. Pointing the marketplace at a local directory only
avoids the network fetch — for live iteration use `--plugin-dir`.
Also note: re-running `marketplace add` with the same
marketplace name and a different source (path vs git URL) silently
**overwrites** the previous declaration.

Validate before every publish (exit code 0/1, CI-friendly):

```bash
claude plugin validate ./path/to/plugin --strict
```

`--strict` turns warnings into errors and catches field-name typos
(e.g. `vversion`). Run it on the marketplace root too — it checks
duplicate plugin names and source path traversal.

To test the full marketplace install path (not just the plugin):

```bash
claude plugin marketplace add ./path/to/marketplace-repo
# then inside a session:
#   /plugin install <plugin>@<marketplace-name>
```

## 3. Release automation with semantic-release

The plugin system **never reads git tags or forge releases** — it reads
the `version` string (or the SHA). So automation must WRITE the computed
version back into `plugin.json` and commit it; a tag alone ships
nothing. semantic-release does this cleanly from Conventional Commits
via `@semantic-release/exec` + `@semantic-release/git`:

```json
{
  "branches": ["main"],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    "@semantic-release/changelog",
    ["@semantic-release/exec", {
      "prepareCmd": "jq --arg v \"${nextRelease.version}\" '.version = $v' .claude-plugin/plugin.json > .claude-plugin/plugin.json.tmp && mv .claude-plugin/plugin.json.tmp .claude-plugin/plugin.json"
    }],
    ["@semantic-release/git", {
      "assets": [".claude-plugin/plugin.json", "CHANGELOG.md"],
      "message": "chore(release): ${nextRelease.version} [skip ci]"
    }],
    "@semantic-release/github"
  ]
}
```

Adapt the path if the plugin lives in a subdirectory of a multi-plugin
marketplace repo (e.g. `plugins/<name>/.claude-plugin/plugin.json`), and
swap `@semantic-release/github` for the forge in use (`@semantic-release/gitlab`,
or drop it on Bitbucket and keep tags + changelog only).

Minimal CI shape (any runner):

```bash
claude plugin validate ./plugins/my-plugin --strict   # gate
npx semantic-release                                   # bump + changelog + tag + push
```

Manual-release repos (no semantic-release) should enforce the same
invariant with a fail-closed script: refuse the tag when
`plugin.json.version` ≠ the newest `CHANGELOG.md` heading (see
`release-verify.sh` in the Septeo `claude-flow` repo for a working
example of that pattern).

## 4. Extras that matter at release time

- **Release channels**: two marketplaces pointing at different git
  `ref`s (`stable` / `latest`) of the same plugin repo. Each ref must
  resolve to a *different* version string (or omit `version` so SHAs
  differ).
- **Renames**: when renaming a plugin, add a `renames` map to
  `marketplace.json` (`"old-name": "new-name"`) so installed users
  migrate automatically.
- **Dependencies between plugins**: pin with git tags named
  `{plugin-name}--v{version}` consumed by the `dependencies` field in
  `plugin.json`.

## Pitfall checklist

- [ ] Version lives in `plugin.json` only (not duplicated in the marketplace entry)
- [ ] Every release commit actually changes the `version` string (tags alone don't ship)
- [ ] `claude plugin validate --strict` passes in CI before the release step
- [ ] `settings.json` / structure changes tested with a fresh session, not `/reload-plugins`
- [ ] Local iteration done via `--plugin-dir` (live), not via a directory marketplace (cached copy)
- [ ] CHANGELOG heading matches `plugin.json.version` (fail-closed check)
