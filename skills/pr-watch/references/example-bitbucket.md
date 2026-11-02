# Worked example — Bitbucket Cloud, on this machine

The first instance, measured on the machine this skill was written on
(macOS, Claude desktop app, zsh login shell, fish interactive). Values are
copied from the machine; secrets are not.

## What `prw plan` said

```
prw plan — what this machine needs (read-only, nothing is changed)
hosts     bitbucket 48 · github 10 · other 2
tokens    bitbucket ok · github missing
daemon    launchd
comments  Bitbucket MCP declared in ~/Library/Application Support/Claude/claude_desktop_config.json; GitHub through Bash (gh)
instance  legacy bitbucket-pr-watch found:
            - skill copy ~/.agents/skills/bitbucket-pr-watch
            - launchd agent com.bitbucket-pr-watch.daemon
            - state ~/.local/state/bitbucket-pr-watch
            - credential file ~/.config/bitbucket-pr-watch/env
            - hook scripts in ~/.agents/hooks
            - hook entries in ~/.claude/settings.json
next
  1. prw migrate
  2. prw setup --github  (GitHub: 10 repositories)
  3. prw doctor
```

Counts come from the `origin` remotes of the repositories under `~/code` and
`~/lab` (worktrees skipped); the scan took 3 s.

## The instance before the generic name

| Piece | Value |
|---|---|
| Daemon | launchd label `com.bitbucket-pr-watch.daemon`, runs `/bin/bash ~/.agents/skills/bitbucket-pr-watch/scripts/bbw daemon run` |
| Credential | `~/.config/bitbucket-pr-watch/env` (0600): `BITBUCKET_WATCH_USER`, `BITBUCKET_WATCH_TOKEN`, sourced from `.zshenv` because the desktop app runs its shell as `zsh -c` |
| Hooks | four scripts in `~/.agents/hooks/`, three commands in `~/.claude/settings.json` |
| Subscription | `septeo-immobilier/modelo-workspace#38`, status `open` |
| `doctor` | `ok` on deps, credential (`accepted by Bitbucket (scoped token)`), env mode 600, daemon, subscriptions, hooks |

`prw migrate` carries all of it onto the generic names; every step asks first
and a state directory that already exists is never overwritten.

## What this host taught

- **A scoped Atlassian token is refused on `GET /user` (403) yet works on the
  repositories it was scoped to.** `doctor` treats 403 there as accepted, 401 as
  rejected.
- **A PR diffstat answers `302` to the repository diffstat.** The transport
  follows it (`-L`; curl keeps the credential on a same-host redirect only). A
  daemon that kept the pre-fix code logged 164 `fetch error (code 13)` lines
  over two hours while `doctor` said `ok`: hence the self re-exec on stale
  scripts and the per-subscription health check.
- **The agent and the human share one Bitbucket account**, so a wake cannot be
  filtered by author: the session's pushed heads and posted comment ids are
  recorded instead.
- **Bitbucket Pipelines and external builds both report as commit statuses**,
  which is why the build phase follows the statuses of the merge commit and not
  the pipelines endpoint.

## Wake lines, as the session receives them

```
modelo-bill-e#229 pipeline "PR analysis" INPROGRESS→FAILED · https://bitbucket.org/septeo-immobilier/modelo-bill-e/pull-requests/229
modelo-bill-e#229 comment by Julien Boutet on src/cockpit/filters.ts:42 (id 4521)
modelo-bill-e#229 after merge into staging @1a2b3c4: "Pipeline staging" FAILED · https://bitbucket.org/…/pipelines/results/812
```
