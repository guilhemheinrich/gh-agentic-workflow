# Proving the hook bites — per-language

A hook that finds nothing and a hook that checks nothing produce the same
output: silence. This page turns that silence into evidence, language by
language.

Two findings recorded on 2026-09-09, on a Go and React monorepo, are the second
kind:

- The runner resolved a compose project name no container carried. The lookup
  found nothing, the agent read one "no running container" warning, then silence
  for the rest of the session.
- `golangci-lint run ./tests/integration/` printed `0 issues.` and exited 0,
  because a build constraint excluded all 120 files in the directory.

Neither produced a red line. Install a branch, then prove it bites before
trusting it.

Every command and output below was measured on 2026-09-17: Go and ESLint inside
that monorepo's own containers (golangci-lint 2.12.2 / go 1.26.3, ESLint
9.39.4), ruff in `ghcr.io/astral-sh/ruff:latest` (ruff 0.15.21). Reproduce them
on your own stack rather than trusting the numbers — the commands are the point,
the figures are one repository's.

## 1. The canary — once per routing branch

Run this when you add a branch, when you change a `strip`, and after a runner
upgrade. Four steps, about a minute:

1. Write a file the branch's glob matches, containing a violation the repo's own
   config rejects (§3–§5 give one per language).
2. Run the hook on it: `.agents/hooks/validate-on-edit.sh --check <path>`.
3. Read the exit code. `2` means the branch bites. `0` means it does not, and
   the file is your proof, not a hypothesis.
4. Delete the canary.

Three causes account for a canary that passes: the linter never saw the file
(§2), the target container is not the one holding the edited bytes (`--doctor`),
or the command cannot fail (§3's `gofmt -l`). A rejection is also worth reading,
not only counting: the message must name the canary's own line, or the branch
rejected the file for a reason unrelated to its content.

Read the mirror case the same way. A branch that rejects a *clean* file with
output naming no line has not found anything: the tool died before analysis.
`inconsistent vendoring in /app` (§3) and `Error response from daemon: No such
container` (§6) are the two seen so far. Both reach the agent as a violation of
the file it just wrote, so a canary run also means reading the text, not only
the exit code.

Name the file so an interrupted run leaves no doubt: `zz-canary-probe.<ext>`.

## 2. Coverage probes — did the linter see the file?

A probe answers one question: does this tool consider this path in scope? It is
faster than reading the tool's exclude configuration, and it reads the same
config the hook will.

| Language   | Probe                                              | Answer meaning "sees nothing" |
| ---------- | -------------------------------------------------- | ----------------------------- |
| Go         | `go list -f '{{len .GoFiles}} {{len .TestGoFiles}} {{len .CgoFiles}} {{len .IgnoredGoFiles}}' ./pkg/dir/` | the first three are `0` |
| Python     | `ruff check --show-files <path>`                   | empty output                  |
| TS / JS    | `eslint --print-config <path>`                     | prints `undefined`            |

Measured contrast for each: `0 120` on a test directory whose every file is
build-constrained, `warning: No Python files found under the given path(s)`
under `force-exclude`, and `undefined` on a generated router file the flat
config lists in `ignores`.

## 3. Go

**Canary** (any package the branch routes):

```go
package canary

import "fmt"

func Canary() string {
	return fmt.Sprintf("%d", "not a number")
}
```

`govet`'s printf check is on by default in golangci-lint, so this fails on a
repo that selects nothing. A repo that narrows the enabled set can disable it,
so confirm with `golangci-lint linters | grep govet` before trusting a green
canary — the same confirmation §5 asks of an ESLint rule:

```text
canary.go:6:22: printf: fmt.Sprintf format %d has arg "not a number" of wrong type string (govet)
```

**Traps:**

| Trap | What happens | What to do |
| ---- | ------------ | ---------- |
| `check gofmt -l "$F"` | Prints the offending path and exits **0**. The branch can never fail. | `fix gofmt -w "$F"`, and let the linter report what formatting cannot fix. |
| Build-constrained file (`//go:build integration`) | An untagged run reports `0 issues.` and exits 0 — the package "passes" without ever compiling the file. | Route it with the tag, or `skip` it explicitly and say so in a comment. |
| `--build-tags` on a large tagged package | Correct, but slow: 6.9s on a 120-file tagged package, over a 3s budget. | `skip` and leave the tagged files to `make lint` and CI. |
| Linting one file instead of its directory | golangci-lint has no single-file mode. A lone file typechecks as a broken package — 7 false `typecheck` issues on one file of a healthy package, 2026-09-09. | `check golangci-lint run "./$(dirname "$F")/"`. |
| Vendored module without `GOFLAGS=-mod=mod` | The run dies on `inconsistent vendoring in /app` before analysing anything, listing every module and naming no line. The agent reads it as a violation of the file it just wrote. Measured 2026-09-16; with the flag the same command returned 5 real findings. | Set `GOFLAGS` in the compose service env, or inline `env GOFLAGS=-mod=mod` in the `check`. |

The untagged-versus-tagged gap, measured on the same directory the same day:

```text
golangci-lint run ./tests/integration/                    → exit 0,  "0 issues."
golangci-lint run --build-tags integration ./tests/integration/
                                                          → exit 1,  errcheck 8, staticcheck 12, unused 3
```

Twenty-three real issues sat behind an exit code of 0.

## 4. Python

**Canary:**

```python
import os


def f():
    x = 1
```

Ruff's default rule set (`E4`, `E7`, `E9`, `F`) reports `F401` and `F841`, so
this fails on a project that configures nothing.

**Traps:**

| Trap | What happens | What to do |
| ---- | ------------ | ---------- |
| `force-exclude = true` in `pyproject.toml` | Ruff applies `exclude` / `extend-exclude` to paths passed **explicitly**, which is exactly how a hook calls it. Output: `All checks passed!`, exit 0, with `warning: No Python files found under the given path(s)` on stderr only. | Probe with `--show-files`; align the branch's globs with the repo's excludes rather than fighting them. |
| Default excludes without `force-exclude` | The opposite: ruff lints an explicitly-passed excluded file, so the hook rejects generated code the repo ignores. | `skip` those globs in the routing table, ahead of the language branch. |
| `mypy` in a branch | Follows imports; 5–20s per edit. SKILL.md §4 already forbids it. | Keep it in CI. |
| `python -m py_compile` as the check | Only proves the file parses. A green pass says nothing about correctness. | Use a real linter. |

Ruff writes its "I found no file" notice to stderr, and the runner's `check`
branches on the exit code alone. That is what makes this trap silent.

## 5. TypeScript / JavaScript

**Canary** (adjust to a rule the repo's config enables — `--print-config` lists
them):

```ts
const canaryUnused = 1
export const canaryAny = (x: any) => x
```

Measured against a React SPA's flat config, typescript-eslint recommended:

```text
1:7   error  'canaryUnused' is assigned a value but never used  @typescript-eslint/no-unused-vars
2:30  error  Unexpected any. Specify a different type           @typescript-eslint/no-explicit-any
```

**Traps:**

| Trap | What happens | What to do |
| ---- | ------------ | ---------- |
| File outside the flat config's base path — usually a wrong or missing `strip` | `File ignored because outside of base path`, **exit 0**. A false pass on every edit. | Always pass `--max-warnings=0`: it turns that warning into exit 1. |
| File matched by `ignores` in `eslint.config.js` | `File ignored because of a matching ignore pattern`, exit 0. | Same flag, plus a `skip` branch so the intent is visible in the table. |
| `npx eslint` without `--no-install` | A cache miss downloads a version at random mid-hook. | `./node_modules/.bin/eslint`, or `npx --no-install`. |
| `tsc --noEmit` | No per-file mode: 15–40s. SKILL.md §4 forbids it. | Keep it in CI and the verify phase. |

`--max-warnings=0` is the single flag that converts this language's silent
no-op into a failure. Treat it as mandatory in every ESLint branch.

## 6. Infrastructure failures that read as findings

This one is language-agnostic, and it is why a canary run reads the text and
not only the exit code. `docker exec` does not separate "the linter found
something" from "there was nothing to run it on".

Measured 2026-09-17 on Docker via OrbStack, against a running application
container and a throwaway alpine container:

| Situation                        | Exit | First line of output |
| -------------------------------- | ---- | -------------------- |
| Linter found something, exits 3  | 3    | the finding          |
| Tool absent from the container   | 127  | `executable file not found in $PATH` |
| Container stopped                | 1    | `container … is not running` |
| Container removed, or bogus id   | 1    | `No such container: …` |
| Daemon unreachable               | 1    | `failed to connect to the docker API` |

`125` never appears in that table: the docker CLI reserves it for its own usage
errors. `docker exec --bogus-flag <container> echo hi` does return 125 (measured
the same day), but a runner builds its own argv, so no edit can reach that path
and no test should assert it. An empty container id, the nearest reachable
shape, exits 1 with `invalid container name or ID`. The three infrastructure failures that matter all
return `1`, the same code a linter returns when it rejects a file.
A runner that keys recovery on `125` never recovers, and the daemon's error
text reaches the agent as a violation of the file it just wrote — observed in a
linked worktree on 2026-09-16, where an agent saw it twice, stopped trusting
the hook, and ran the linter by hand.

Two consequences for a routing table. Branch output that names no line is a
candidate infrastructure failure, to be confirmed against the container state —
linters also emit config, module and parser diagnostics without a line, so the
absence of one classifies nothing on its own. And a canary that fails for the
*wrong* reason proves nothing: read the first line before concluding the branch
bites.

The daemon-unreachable row comes from the aa46 investigation; the other four
were re-measured here directly.

## 7. Paths — what the container actually sees

The hook hands a linter a path computed on the host and runs it inside a
container. Three translations sit between the two, and each one fails quietly.

**The probe, one command per branch.** Before trusting any branch, ask the
container whether the file is where the routing table says:

```bash
docker exec <service> test -f "<path after strip>" && echo seen
```

Silence means the linter will be handed a path that does not exist there, and
what happens next depends on the tool alone: ESLint answers with a warning and
exit 0 (§5), while ruff reports `E902 No such file or directory` and exits 1 —
the same code it uses for a real finding (measured 2026-09-17, ruff 0.15.21).
Neither is readable as "wrong path" without knowing to look.

**Translation 1 — `strip` versus the mount.** `strip` drops a workspace prefix
because the service mounts that workspace at its WORKDIR, not the repo root.
Get it wrong in either direction and the path is absent inside the container.
`docker inspect -f '{{json .Mounts}}' <container>` shows what is mounted where;
the probe above is faster.

**Translation 2 — a service that does not mount the edited subtree.** A branch
may route `apps/web/*.ts` to a service mounting only `apps/api`. The routing
table looks right, the container is up, and nothing is ever read.

**Translation 3 — a symlinked checkout.** The runner takes `PROJECT_ROOT` from
`git rev-parse --show-toplevel`, which resolves symlinks. Compose records
`com.docker.compose.project.working_dir` with the spelling it was given,
symlinks intact. Measured 2026-09-17 on the same directory, reached through a
symlink:

```text
compose label            …/pathprobe/link
git rev-parse toplevel   …/pathprobe/real
```

The damage lands one layer earlier than the container. The runner also compares
its own root against the path the editor sent in the hook payload, as strings.
Through a symlink the two spellings differ, the file reads as sitting outside
the project, and the runner returns through the arm reserved for files it
deliberately does not route: **silence**. A consumer then cannot tell "no
branch matches this file" from "this hook has done nothing since it was
installed". Reproduced on a throwaway repository under the platform temp
directory, 2026-09-17.

The rule that follows: resolve both sides physically (`cd … && pwd -P`, or
`realpath`) before any path comparison, at every layer that compares one.

One test this does *not* justify: using
`com.docker.compose.project.working_dir` to decide which stack owns a checkout.
That label records the project directory as compose spelled it — started with
`-f real/compose.yml` from the parent, it reads `…/real` (measured the same
day) — not the source of the mount the file is read through. Decide ownership
from the mount that covers the path, as SKILL.md §5 describes.

## 8. Write down every deliberate blind spot

An unvalidated path is acceptable. An unvalidated path nobody knows about is
the defect. When a branch calls `skip`, the comment above it states what is not
checked, why, and which gate covers it instead.

A Go branch that does it:

```bash
#    A file under a build constraint (`//go:build integration`: 120 files under
#    tests/integration, 33 under infrastructure/postgres) is invisible to an
#    untagged lint run — the package "passes" without it — and a tagged run
#    takes 6.9s, over budget. Deliberately unvalidated;
#    the repo's ledger tracks the same gap in `make lint`.
```

A blind spot worth a comment is usually worth a grievance too: the comment
stops the next reader from trusting the branch, the ledger entry keeps the gap
on someone's list.

## 9. Adding a language

Three questions, answered with commands rather than documentation, before the
branch is written:

1. **Does the tool exit non-zero on a violation?** Run the canary by hand in the
   container. `gofmt -l` is the reminder that a printing tool is not a failing
   tool.
2. **Does the tool see the file the hook will hand it?** Run the probe on one
   real path and one excluded path. A tool that silently skips is worse than a
   tool that is absent, which `--doctor` reports.
3. **Does one file cost less than the budget?** Time it warm: `time docker exec
   <svc> <cmd> <file>`. Over ~1s, the branch belongs in CI.

Then add the probe's output to this page for the next language, dated, with the
tool version.
