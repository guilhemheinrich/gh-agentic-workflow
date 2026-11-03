---
name: static-validation-hooks
description: >-
  Generate a bespoke static-validation hook inside a consumer repo so agents
  never carry the burden of remembering to lint. One script in `.agents/hooks/`
  routes each edited file to a fast file-local linter running in the project's
  already-up compose container, and stays silent unless something is wrong.
  Ships a generic runner plus go / python / typescript / nestjs routing tables,
  the Claude and Cursor registration adapters, a SessionStart hook that installs
  dependencies in Claude Code cloud sessions (where the runner switches to host
  mode, no Docker there), a pre-commit replay, and a per-language reference for
  proving a branch actually rejects something. Use when adding lint-on-edit to
  a project, adapting the routing table to a new stack or workspace, making it
  work in cloud sessions, or debugging a hook that is slow, noisy, or silently
  doing nothing.
---

# Static Validation Hooks

Static validation is a machine's job. Asking an agent to remember `make lint`
turns a deterministic check into a prompt instruction — the first thing dropped
when context fills up. This skill moves it into the harness: the hook fires on
every file write, and the agent only ever hears about it when something is
actually wrong.

```text
agent writes a file
      │
      ▼
.agents/hooks/validate-on-edit.sh
      │  ┌──────────────────────────────┐
      ├─▶│ RUNNER (generic, copy as-is) │ protocol · budget · brake · state
      │  └──────────────────────────────┘
      │  ┌──────────────────────────────┐
      └─▶│ ROUTING TABLE (yours)        │ glob → service → linter
         └──────────────────────────────┘
                    │
                    ▼  docker exec on the container `make up`/`task up` already started
                       (host mode in a Docker-less cloud session, §5)
              clean → exit 0, silence
          violation → exit 2, stderr back to the model
```

## 1. Files in this bundle

| File                              | Role                                | Adapt?             |
| --------------------------------- | ----------------------------------- | ------------------ |
| `templates/validate-on-edit.sh`   | Runner + empty routing table.       | Routing table only |
| `routing/python.sh`               | Routing table — ruff.               | Fork it            |
| `routing/typescript.sh`           | Routing table — eslint/biome.       | Fork it            |
| `routing/nestjs.sh`               | Routing table — Nest api + web.     | Fork it            |
| `routing/go.sh`                   | Routing table — gofmt + golangci-lint. | Fork it         |
| `templates/claude-settings.json`  | Claude registration.                | Path only          |
| `templates/cursor-hooks.json`     | Cursor registration.                | Path only          |
| `templates/session-start.sh`      | Claude cloud-session dependency install + pre-commit activation (§5). | Install/build steps |
| `templates/pre-commit.sh`         | Replays the hook on staged files (§10). | As is          |
| `references/proving-the-hook-bites.md` | Per-language canaries, coverage probes, silent-pass traps. | Read it |

There is no standard, cross-agent hook format: Claude reads
`.claude/settings.json` (`PostToolUse`, stderr on exit 2), Cursor reads
`.cursor/hooks.json` (`postToolUse`, `{"additional_context": …}` on stdout, exit 0),
and their payloads differ. So the **logic** lives once in `.agents/hooks/`, and
each agent gets a thin registration file pointing at it.

On the Cursor side, `postToolUse` is the only file-edit event with an output
channel: `afterFileEdit` has no output fields, so a violation reported there
never reaches the agent. The runner answers `{"additional_context": …}` on exit
0 there: the edit already happened, and exit 2 would read as a deny. Cursor's
schema also has no per-hook `env`, so the runner tells the hosts apart from the
payload (Cursor sends `cursor_version` and `tool_output`, Claude sends
`tool_response`) instead of relying on `VALIDATE_HOST`.

## 2. Install

```bash
mkdir -p .agents/hooks .claude .cursor
cp <this-repo>/skills/static-validation-hooks/templates/validate-on-edit.sh .agents/hooks/
chmod +x .agents/hooks/validate-on-edit.sh
```

Then paste the routing table closest to the stack (`routing/*.sh`) between the
`BEGIN ROUTING TABLE` / `END ROUTING TABLE` markers, replacing the placeholder
`route()`, and adapt the globs to the real workspace layout. Keep the two
marker lines byte-for-byte: the runner upgrade path (§8) and any tooling that
reads the table locate it with a regex on `^# BEGIN ROUTING TABLE `; a table
spliced outside the markers is invisible to them.

If the repo is ever worked on from Claude Code cloud sessions, also install the
session-start hook (§5, *Cloud sessions*):

```bash
mkdir -p .claude/hooks
cp <this-repo>/skills/static-validation-hooks/templates/session-start.sh .claude/hooks/
chmod +x .claude/hooks/session-start.sh
```

Merge the `hooks` block of
`templates/claude-settings.json` into `.claude/settings.json` — it registers
both the `PostToolUse` validation and the `SessionStart` install below — and copy
`templates/cursor-hooks.json` to `.cursor/hooks.json` as is. That file carries
only `version` and `hooks` on purpose: Cursor silently stopped loading it when
it held `_comment*` keys with documentation text (observed with
`cursor-agent 2026.09.02`), so any note about it lives here, not in the JSON.

Install the pre-commit replay (§10):

```bash
mkdir -p .githooks
cp <this-repo>/skills/static-validation-hooks/templates/pre-commit.sh .githooks/pre-commit
chmod +x .githooks/pre-commit
git config core.hooksPath .githooks   # wrap it in a `hooks` target, call it from `setup`
```

The session-start hook runs that `git config` itself in cloud sessions.

Smoke-test, in this order:

```bash
.agents/hooks/validate-on-edit.sh --doctor
```

```bash
.agents/hooks/validate-on-edit.sh --dry-run src/some/file.ts
```

```bash
.agents/hooks/validate-on-edit.sh --check src/some/file.ts
```

`--doctor` reports docker reachability and whether each service named in the
routing table has a running container — count that list against your own
branches before trusting it, for the reason in the reference doc §2. `--dry-run` prints the routing decision
without executing. `--check` runs for real and prints the elapsed time.

Then prove each branch actually rejects something — a canary file carrying a
violation the repo's own config refuses:

```bash
.agents/hooks/validate-on-edit.sh --check src/zz-canary-probe.ts
```

Exit 2 means the branch bites; exit 0 on a file that violates the config means
it does not, whatever `--doctor` says. Read the message too: it must name the
canary's own line, or the rejection came from something other than the file's
content. A green check that checked nothing is the one failure no output
reveals. The canary, the per-language coverage probes, and the measured
silent-pass traps for Go, Python and TypeScript are in
[references/proving-the-hook-bites.md](references/proving-the-hook-bites.md).
Run it again after every routing-table change and every runner upgrade.

## 3. Writing the routing table

Five verbs, evaluated top-down, first match wins:

| Verb            | Effect                                                                  |
| --------------- | ----------------------------------------------------------------------- |
| `svc NAME`      | Target compose service. Required, and must come first in the branch.    |
| `strip PREFIX`  | Sets `$F` to the path the container expects (drops a workspace prefix). |
| `fix CMD…`      | Best-effort auto-fix. Failures are logged, never shown to the agent.    |
| `check CMD…`    | Validation. A non-zero exit becomes agent feedback.                     |
| `skip`          | Declare the path as deliberately unvalidated.                           |

Plus one predicate, `fixing`, false under `VALIDATE_NO_FIX=1` (the pre-commit).
`fix` verbs are skipped there on their own; a `check` whose linter fixes in place
must branch on it, or the pre-commit repairs the working tree and commits the
unfixed index:

```bash
    *.ts)
      svc api
      if fixing; then check npx --no-install eslint --fix --max-warnings=0 "$F"
      else            check npx --no-install eslint --max-warnings=0 "$F"; fi
      ;;
```

```bash
route() {
  case "$REL" in
    */migrations/*|*.generated.ts) skip ;;

    apps/api/*.ts)
      svc api; strip apps/api/
      check npx --no-install eslint --fix --max-warnings=0 "$F"
      ;;

    *.py)
      svc api
      fix   ruff format "$F"
      check ruff check --fix --quiet "$F"
      ;;

    *) ;;
  esac
}
```

`$REL` is the repo-relative path; `$F` is what the container sees after
`strip`. `${F}` without `strip` equals `$REL`.

`$F` is a claim about the container's filesystem, so verify it once per branch
rather than reasoning about the mount: `docker exec <svc> test -f "<$F>" && echo
seen`. A wrong `strip`, a service mounting only part of the repo, or a
symlinked checkout all end the same way — a path nobody reads. The three cases
and their measurements are in
[references/proving-the-hook-bites.md](references/proving-the-hook-bites.md) §7.

**Branch ordering is load-bearing:**

1. `skip` globs first — generated code, snapshots, lockfiles.
2. Workspace branches before generic extension branches. `apps/web/*.ts` must
   precede `*.ts`, or a frontend file gets linted with the backend config.
3. Generic extension branches.
4. Empty `*)` catch-all. Leave it empty on purpose: the runner then warns the
   agent **once per unknown extension** that nothing validates it. An unroutable
   file type failing silently is how coverage rots.

### Prefer one `check` per branch

Modern linters fix and report in one pass — `eslint --fix`, `ruff check --fix`,
`biome check --write` all exit non-zero on what they could not fix. Reach for a
separate `fix` only for a pure formatter that always exits 0 (`ruff format`,
`prettier --write`). Every extra command is another `docker exec` round-trip
against the same per-edit budget.

## 4. What must never go in the routing table

The budget is per edit (`VALIDATE_BUDGET_S`, default 3s) and it is enforced by
killing the command. Anything project-wide blows it:

| Tool                          | Why it does not belong here                            |
| ----------------------------- | ------------------------------------------------------ |
| `tsc --noEmit`                | No per-file mode; loads the whole program (15–40s).    |
| `phpstan analyse`             | Whole-project graph, 20s+.                             |
| `mypy` (even on one file)     | Follows imports; 5–20s on a real project.              |
| `nest build`, `next build`    | Compilation, not validation.                           |
| Any test runner               | Behaviour, not static analysis. Not the same tool.     |

These stay in CI and in the verify phase of the pipeline. The hook shortens
that stage; it does not replace it.

## 5. Degraded behaviour — the hook never blocks work

The hook only blocks (exit 2) on a genuine violation. Everything else is
reported **at most once per session** and then falls silent:

| Situation                     | Agent sees                                     | Then         |
| ----------------------------- | ---------------------------------------------- | ------------ |
| Lint passes                   | nothing                                        | silent       |
| Violation                     | linter output (Claude: stderr, exit 2; Cursor: `additional_context`) | see §6 |
| No running container          | "start the stack" (`task up` / `make up`), once | silent      |
| Tool missing in container     | "`ruff` is not installed in `api`", once       | silent       |
| Budget exceeded               | "too slow for a hook, move it to CI", once     | silent       |
| No branch matches the file    | "no validation branch matches `.rs`", once     | silent       |
| Worktree pinned to main stack | nothing                                        | silent       |
| Excluded dir, deleted file    | nothing                                        | silent       |
| Cloud session, no deps/stack  | "not installed" / "no running container", once | silent — install them at session start (below) |

Every one of these is written to `$TMPDIR/validate-on-edit.log` regardless, and
`--doctor` counts the warnings suppressed this session.

### Cloud sessions — install dependencies at session start

A Claude Code cloud session (claude.ai/code, mobile, GitHub Action) runs in a
fresh container cloned from the repo. Two things the runner relies on are
missing there:

- **No dependencies.** No `node_modules`, no virtualenv, no Go module cache. A
  routing table that runs linters on the host (`node_modules/eslint`, `.venv/bin/ruff`)
  finds nothing, warns once, and validates **nothing** for the rest of the session.
- **Usually no stack.** There is no `make up` behind the session, so a
  docker-routed branch reports "no running container" once and falls silent.

Both look like a working hook — one warning, then silence — which is exactly
the false pass §2 warns about. The fix is a `SessionStart` hook that installs
the dependencies before the session begins:
`templates/session-start.sh`, copied to `.claude/hooks/session-start.sh` and
registered by the `SessionStart` block of `templates/claude-settings.json`.

| Rule                                         | Why                                                                 |
| -------------------------------------------- | ------------------------------------------------------------------- |
| Guard on `CLAUDE_CODE_REMOTE=true`           | Local dependencies are the developer's; a local session must not reinstall them. |
| Mirror the CI install **and build** steps    | Linters and tests often need workspace packages built (`dist`) first. CI is the step already proven on a clean checkout. |
| Plain install (`pnpm install`, `npm install`), not `ci`/`--frozen-lockfile` | The container is cached after the hook; a plain install reuses it. |
| Send install output to stderr                | The hook's stdout is a protocol channel.                            |
| Synchronous by default                       | The session starts only once dependencies exist, so the first edit is validated. Async (`{"async": true}` on stdout) starts faster but races the agent's first edit. |
| Idempotent, non-interactive                  | It runs on every session start, resume included.                    |

For cloud coverage the linters have to run on the host, since there is no
Docker daemon to `docker exec` into. The runner does it on its own — **host
mode**:

- `VALIDATE_EXEC=auto` (default) picks `host` when `CLAUDE_CODE_REMOTE=true`,
  `docker` everywhere else. Force either with `VALIDATE_EXEC=docker|host`.
- The same routing table runs from the repo root, or from the `strip`ped prefix
  when the branch has one, so `$F` resolves exactly as in the container's
  WORKDIR. Write linter paths relative (`node_modules/.bin/eslint`), never
  container-absolute (`/app/node_modules/...`).
- `svc` is still required (it names the branch), but no container is looked up.
- A missing tool warns once and names the host install, not a container; a
  `strip` prefix that does not exist on the host warns once too. Neither passes
  silently as clean.

Anything the image installs outside the lockfile (a system `ruff`,
`golangci-lint`) must be installed by the session-start hook too, or that
branch warns once and validates nothing. Prove each branch with a canary in
host mode as well (`CLAUDE_CODE_REMOTE=true .agents/hooks/validate-on-edit.sh
--check …`).

Measured on 2026-10-15 on a pnpm monorepo (12 workspace projects, host-routed
ESLint): `pnpm install` + workspace package build took ~30 s from an empty
`node_modules`, ~3 s when already installed; afterwards ESLint answered in 1–2 s
per file, cold included, and the CI unit-test suites passed in the session.

Validate it the way the session will run it:

```bash
CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$PWD" .claude/hooks/session-start.sh </dev/null
```

Then run one `--check` canary (§2) and one test. The hook takes effect for the
sessions started after it reaches the default branch.

### Git worktrees

Validation **does** work in a linked worktree, as long as that worktree has its
own stack, and as long as the runner resolves the same project name compose
does.

**Check that name before anything else.** The runner derives it from the
directory basename unless `COMPOSE_PROJECT_NAME` is exported. Compose resolves
five sources, in this order: `-p` / `--project-name` on the command line, the
exported `COMPOSE_PROJECT_NAME`, the same variable in the project's `.env`, the
top-level `name:` of the compose file, then the basename. The runner reads the
second and the fifth. A repo using any of the other three gets a runner pointed
at a project no container carries: the lookup finds nothing, the agent reads one
"no running container" warning, and the hook validates nothing in silence for
the rest of the session. Measured on 2026-09-09 on a monorepo whose compose file
declares a `name:` that differs from its checkout directory.

`-p` is the one source no file on disk records, so a stack started that way
cannot be resolved by inspection: either export `COMPOSE_PROJECT_NAME` for the
hook, or accept that it will report "no running container".

Until the runner reads the file-recorded sources, redefine `compose_project()`
**inside** the `BEGIN/END ROUTING TABLE` markers, so the §8 upgrade path
preserves it, and confirm with `--doctor` plus one canary (§2).

A resolved name is only trustworthy when the container it names serves the
bytes just edited. That question is about the **mount**, and only the mount
answers it: take the container path the linter will receive, find the deepest
mount destination covering it, map it back to its source, and compare the two
sides physically (`cd … && pwd -P` on each). A destination served by a named or
anonymous volume carries no host source, so it cannot be verified and must be
refused rather than assumed.

Do not use `com.docker.compose.project.working_dir` as that test, tempting as
it is. The label records the project directory as compose spelled it, not the
source of the mount the file is read through: started with `-f real/compose.yml`
from the parent directory, the label reads `…/real` (measured 2026-09-17). It
also goes stale on a rename, and it can accept a container whose mount does not
contain the edited path while refusing one whose mount does.

Ownership is the precondition for reading the other three sources, not an extra
precaution. Today a linked worktree is protected by accident: the basename
resolves a project no container carries, so the hook warns instead of
validating the wrong bytes. A runner that reads `.env` and the compose `name:`
without deciding ownership would resolve a worktree onto its main checkout's
stack and validate the file the agent did not write. Whoever adds the one adds
the other in the same change.

Three cases, all handled by `VALIDATE_WORKTREE=auto` (the default):

| Worktree situation                              | Behaviour                              |
| ----------------------------------------------- | -------------------------------------- |
| Own duplicated stack                            | Validates normally.                    |
| No stack running                                | "no running container", once, then silent. |
| `COMPOSE_PROJECT_NAME` exported in the env      | Silent skip — see below.               |

That last case is the only dangerous one. An exported `COMPOSE_PROJECT_NAME`
pins *every* worktree to the same stack as the main checkout, whose bind mount
holds a stale copy of the edited file: the linter would pass on the old
content. That is a false *pass*, worse than no check, so `auto` skips it.
`--doctor` prints which of the three applies. Force with `VALIDATE_WORKTREE=run`
if the shared stack genuinely mounts the worktree's parent, or `=skip` to
disable in worktrees outright.

Note this is orthogonal to whether the *harness* runs agents in worktrees — the
verify phase stays mandatory either way, because of §10.

## 6. The retry brake

`exit 2` feeds the message back to the model, which rewrites the file, which
fires the hook again. On a violation the agent cannot fix — a false positive, a
broken linter config, a rule it does not understand — that is an infinite loop
burning context.

After `VALIDATE_MAX_RETRIES` (default 3) consecutive rejections of the *same*
path, the last message tells the agent validation is now muted for that file,
and subsequent edits pass silently for `VALIDATE_MUTE_TTL_S` (default 900s).
One clean pass resets the counter immediately.

## 7. Env knobs

| Variable                | Default | Purpose                                          |
| ----------------------- | ------- | ------------------------------------------------ |
| `VALIDATE_ON_EDIT=0`    | `1`     | Kill-switch.                                     |
| `VALIDATE_BUDGET_S`     | `3`     | Hard wall-clock cap **per edit**, not per command.|
| `VALIDATE_MAX_RETRIES`  | `3`     | Rejections before muting a file.                 |
| `VALIDATE_MUTE_TTL_S`   | `900`   | How long a muted file stays muted.               |
| `VALIDATE_WORKTREE`     | `auto`  | `auto` \| `skip` \| `run` in a linked worktree.  |
| `VALIDATE_EXEC`         | `auto`  | `docker` \| `host`; `auto` = `host` when `CLAUDE_CODE_REMOTE=true` (§5, Cloud sessions). |
| `VALIDATE_NO_FIX=1`     | `0`     | Report only: skips `fix`, `fixing` is false (pre-commit). |
| `VALIDATE_UP_CMD`       | sniffed | Command named in "start the stack": `task up` with a Taskfile, else `make up`. |
| `VALIDATE_HOST`         | sniffed | `claude` \| `cursor` response shape; the sniff reads `cursor_version`/`tool_output` (Cursor) vs `tool_response` (Claude). |
| `VALIDATE_DEBUG=1`      | `0`     | Trace to stderr as well as the log.              |

Install GNU coreutils where possible (`brew install coreutils` on macOS): the
runner uses `timeout`/`gtimeout` when present and falls back to a bash watchdog
otherwise. Both enforce the budget; the watchdog just costs an extra process.

## 8. Updating the runner

The runner and the routing table live in one file on purpose — one file to read,
no indirection. To pick up a new runner version, replace everything **outside**
the `BEGIN/END ROUTING TABLE` markers and keep the table. The markers exist for
exactly this.

## 9. Anti-patterns

| Anti-pattern                                        | Why it fails                                                        |
| --------------------------------------------------- | ------------------------------------------------------------------- |
| `tsc --noEmit` / `phpstan` in a branch              | Blows the budget on every edit; the hook gets disabled within a day.|
| Generic `*.ts` branch before the workspace branch   | Wrong linter config runs; violations are wrong in both directions.  |
| Catch-all `*)` calling `skip`                       | New file types silently bypass validation forever.                  |
| `npx eslint` without `--no-install`                 | Cache miss downloads a random version mid-hook and blows the budget.|
| `docker run` instead of the running container       | Cold start per edit — seconds, not milliseconds.                    |
| Reporting a missing tool on every edit              | Unactionable noise; the agent starts ignoring hook output.          |
| Running tests from the hook                         | Not static, not fast, not file-local. Three strikes.                |
| Editing the runner to add project logic             | Wrong layer. Project logic goes in the routing table.               |
| Treating the hook as full coverage                  | The Bash tool bypasses it entirely — see below.                     |
| A `check` that prints but cannot fail               | `gofmt -l` exits 0 while naming the file. The branch is decorative. |
| `eslint` without `--max-warnings=0`                 | An ignored or out-of-base file warns and exits 0 — a false pass on every edit.|
| Installing a branch without running a canary        | Nothing distinguishes "found nothing" from "checked nothing".        |

## 10. Known coverage gap

Claude `PostToolUse Edit|Write` and Cursor `postToolUse Write` fire on agent
*file-edit tools*. Cursor reports both its create and its search-replace edit
tool as `Write`, so the single matcher covers both.
Files written through the Bash tool (`cat > f.ts`, `sed -i`, code generators
like `nest g` or `prisma generate`) never trigger the hook.
`templates/pre-commit.sh` closes that gap at commit time: it runs `--check` on
every staged file with `VALIDATE_NO_FIX=1` and a 30s budget, blocks on a
violation, and prints warnings without blocking. It reads the working-tree copy
of each file, not the index blob, so a partially staged file is checked as it
stands on disk.

## 11. See also

- [references/proving-the-hook-bites.md](references/proving-the-hook-bites.md) — canaries, coverage probes and silent-pass traps, per language.
- [makefile-conventions](../makefile-conventions/SKILL.md) — Docker-first Makefile baseline.
- `rules/04-tools-and-configurations/4-static-validation.mdc` — the repo rule that mandates installing this hook.

This skill replaced `makefile-lint-router`, which routed through a `make lint
FILE=…` recipe. That indirection meant two files to keep in sync and a Makefile
target to write per project; the routing table now lives in the hook itself.
The historical design record is kept under `specs/014-lint-on-edit-hook/`.

---

## Implementation Status

**Fully Implemented.** Host mode, `VALIDATE_NO_FIX`, the up-command hint and
the pre-commit template were added on 2026-10-21 after a pnpm
monorepo (Hono API + Expo app) installed the hook from a Claude Code cloud
session: there, every canary passed in host mode and a canary commit was
refused by the pre-commit. The runner ships with `--dry-run`, `--check` and
`--doctor`, and was exercised against a stubbed docker on all paths: clean,
violation, container down, tool missing, budget exceeded, unrouted extension,
the three linked-worktree cases, retry brake, mute expiry, Claude and Cursor
response shapes, and the kill-switch. The Cursor path was proven end-to-end on
2026-09-08 with `cursor-agent 2026.09.02`: a `postToolUse` hook on `Write`
returned the linter message to the agent through `additional_context`, and the
agent quoted it back. Measured hot-path overhead is ~110ms per edit with a stub
container; add the real `docker exec` round-trip (~150–400ms per command) on a
warm container. The four routing tables are starting points and **must** be
adapted to the consumer repo's workspace layout — they are not drop-in.
