---
name: static-validation-hooks
description: >-
  Generate a bespoke static-validation hook inside a consumer repo so agents
  never carry the burden of remembering to lint. One script in `.agents/hooks/`
  routes each edited file to a fast file-local linter running in the project's
  already-up compose container, and stays silent unless something is wrong.
  Ships a generic runner plus python / typescript / nestjs routing tables and
  the Claude and Cursor registration adapters. Use when adding lint-on-edit to
  a project, adapting the routing table to a new stack or workspace, or
  debugging a hook that is slow, noisy, or silently doing nothing.
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
                    ▼  docker exec on the container `make up` already started
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
| `templates/claude-settings.json`  | Claude registration.                | Path only          |
| `templates/cursor-hooks.json`     | Cursor registration.                | Path only          |

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
spliced outside the markers is invisible to them. Merge the `hooks` block of
`templates/claude-settings.json` into `.claude/settings.json`, and copy
`templates/cursor-hooks.json` to `.cursor/hooks.json` as is. That file carries
only `version` and `hooks` on purpose: Cursor silently stopped loading it when
it held `_comment*` keys with documentation text (observed with
`cursor-agent 2026.09.02`), so any note about it lives here, not in the JSON.

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
routing table has a running container. `--dry-run` prints the routing decision
without executing. `--check` runs for real and prints the elapsed time.

## 3. Writing the routing table

Five verbs, evaluated top-down, first match wins:

| Verb            | Effect                                                                  |
| --------------- | ----------------------------------------------------------------------- |
| `svc NAME`      | Target compose service. Required, and must come first in the branch.    |
| `strip PREFIX`  | Sets `$F` to the path the container expects (drops a workspace prefix). |
| `fix CMD…`      | Best-effort auto-fix. Failures are logged, never shown to the agent.    |
| `check CMD…`    | Validation. A non-zero exit becomes agent feedback.                     |
| `skip`          | Declare the path as deliberately unvalidated.                           |

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
| No running container          | "start the stack (`make up`)", once            | silent       |
| Tool missing in container     | "`ruff` is not installed in `api`", once       | silent       |
| Budget exceeded               | "too slow for a hook, move it to CI", once     | silent       |
| No branch matches the file    | "no validation branch matches `.rs`", once     | silent       |
| Worktree pinned to main stack | nothing                                        | silent       |
| Excluded dir, deleted file    | nothing                                        | silent       |

Every one of these is written to `$TMPDIR/validate-on-edit.log` regardless, and
`--doctor` counts the warnings suppressed this session.

### Git worktrees

Validation **does** work in a linked worktree, as long as that worktree has its
own stack. Container resolution is worktree-aware by construction: the compose
project name is derived from the worktree's own directory, so `make up` run
from the worktree resolves to *its* containers.

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

## 10. Known coverage gap

Claude `PostToolUse Edit|Write` and Cursor `postToolUse Write` fire on agent
*file-edit tools*. Cursor reports both its create and its search-replace edit
tool as `Write`, so the single matcher covers both.
Files written through the Bash tool (`cat > f.ts`, `sed -i`, code generators
like `nest g` or `prisma generate`) never trigger the hook. Complement with a
pre-commit hook running the same script over `git diff --name-only` if that gap
matters for the project.

## 11. See also

- [makefile-conventions](../makefile-conventions/SKILL.md) — Docker-first Makefile baseline.
- `rules/04-tools-and-configurations/4-static-validation.mdc` — the repo rule that mandates installing this hook.

This skill replaced `makefile-lint-router`, which routed through a `make lint
FILE=…` recipe. That indirection meant two files to keep in sync and a Makefile
target to write per project; the routing table now lives in the hook itself.
The historical design record is kept under `specs/014-lint-on-edit-hook/`.

---

## Implementation Status

**Fully Implemented.** The runner ships with `--dry-run`, `--check` and
`--doctor`, and was exercised against a stubbed docker on all paths: clean,
violation, container down, tool missing, budget exceeded, unrouted extension,
the three linked-worktree cases, retry brake, mute expiry, Claude and Cursor
response shapes, and the kill-switch. The Cursor path was proven end-to-end on
2026-09-08 with `cursor-agent 2026.09.02`: a `postToolUse` hook on `Write`
returned the linter message to the agent through `additional_context`, and the
agent quoted it back. Measured hot-path overhead is ~110ms per edit with a stub
container; add the real `docker exec` round-trip (~150–400ms per command) on a
warm container. The three routing tables are starting points and **must** be
adapted to the consumer repo's workspace layout — they are not drop-in.
