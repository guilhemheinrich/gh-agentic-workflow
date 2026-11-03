# Baseline — the five Phase A cases against the UNMODIFIED runner

**Date**: 2026-09-17
**Runner**: `skills/static-validation-hooks/templates/validate-on-edit.sh`, unchanged
at commit `7ffd01d` (`git diff --stat` on that path is empty)
**Command**: `bash skills/static-validation-hooks/tests/run.sh --all`
**Platform**: Docker 29.4.0 via OrbStack, macOS 25.5.0, `alpine:3.20` fixtures, no project stack
**Elapsed**: 2 s for all five cases (SC-007 allows 60 s)

Outcomes are read from outside the runner only: the exit status, and the first
line of stderr. The mapping is documented at the top of `run.sh` with line
citations. Nothing in the suite knows which failures the runner considers
infrastructure.

## Measured

| Case | Observed today | Exit | Expected after the fix | Today |
|---|---|---|---|---|
| `stale-container-reported-as-violation` | **violation** | 2 | warning | **RED** |
| `daemon-unreachable` | warning | 2 | warning | green — see note 1 |
| `validator-exit-1-with-findings` | violation | 2 | violation | green (guard) |
| `validator-output-looks-like-a-daemon-error` | violation | 2 | violation | green (guard) |
| `status-only-check` | **silence** | 0 | violation | **RED** |

3 passed, 2 failed.

## Verbatim stderr, per case

### `stale-container-reported-as-violation` — rc 2

```
[validate] app.txt — sh (exit 1)

Error response from daemon: No such container: cfe472fd2638
```

This is `GRV-stale-cached-container-reported-aa46` reproduced exactly: a Docker
daemon message delivered to the agent as a finding about the file it just wrote,
attributed to the validator (`sh`) and to an exit code the validator never
returned. The container was removed between the two edits; the runner's hot path
(`validate-on-edit.sh:260-262`) re-used the cached id, `docker exec` returned 1,
and 1 is not 125, so the stale-cache branch never fired and rc fell through to
the default arm of `check()` (`:341-346`).

### `daemon-unreachable` — rc 2

```
[validate] service `voe` has no running container, so app.txt was not validated.
Start the stack (`make up`) to re-enable on-edit validation.
```

### `validator-exit-1-with-findings` — rc 2

```
[validate] app.txt — sh (exit 1)

/work/app.txt:1: forbidden token
```

### `validator-output-looks-like-a-daemon-error` — rc 2

```
[validate] app.txt — sh (exit 1)

Error response from daemon: No such container: deadbeef
/work/app.txt:1: and a real finding after it
```

The finding survives although its first line is a verbatim Docker daemon error.
Any fix that classified by matching that wording would delete this finding, and
this case is what will catch it.

### `status-only-check` — rc 0, stderr empty

Nothing reaches the agent. The runner logged, to its log file only:

```
[validate 09:29:21] grep rc=1 with no output, ignoring
```

`check()` discards a non-zero exit with no output at `:342`. A `grep -q` or
`cmp -s` entry in a routing table therefore fails silently forever.

## Note 1 — `daemon-unreachable` is green today, for a reason the fix must not inherit

The case passes, and the outcome is the right one, but the runner reached it by
the wrong door. With no cached container id, `exec_in` goes to `lookup_cid`
(`:267`), `docker ps` fails against the dead socket and prints nothing, the empty
result is read as "no container" and `exec_in` returns its synthetic 125
(`:268`). The agent is then told to run `make up`, which will not help: the
daemon is down, not the stack. The runner's own log names the wrong cause —
`no running container for service 'voe'`.

So the outcome is accidentally safe and the diagnosis is wrong. FR-006 and
FR-008 ask for the two causes to be distinguished; this case cannot see that
difference, because both causes produce a warning and the suite deliberately does
not assert message text beyond the attribution shape.

**The same failure on the cached path is not safe at all.** Measured with a
throwaway probe on the same day and the same harness — a live container resolved
and cached on a first edit, `DOCKER_HOST` then pointed at an absent socket, a
second edit:

```
[validate] app.txt — sh (exit 1)

failed to connect to the docker API at unix:///tmp/voe-test-51628-absent.sock; check if the path is correct and if the daemon is running: dial unix /tmp/voe-test-51628-absent.sock: connect: no such file or directory
```

A violation, on a file that was never validated. That shape is the same defect as
`stale-container-reported-as-violation` and is already covered red by it, which
is why no sixth case was added for it here. It is recorded so the fix is not
credited with repairing a path this suite already showed green.

The probe also produced an incidental finding worth keeping: a `DOCKER_HOST`
unix path longer than about 104 bytes makes the Docker client fail with
`socket path ... is too long` rather than a connection error. The case therefore
uses a short `/tmp` path it never creates, so it tests an unreachable daemon
rather than a malformed client argument.

## Note 2 — a violation and a warning are not separable by exit status

Both are `emit_feedback` (`:151-159`): stderr plus exit 2 under the Claude host
shape. The only outside discriminator is the first line, and only because a
violation is the sole message carrying the attribution shape
`[validate] <path> — <tool> (exit N)` (`:343`). `--check` does separate them
(exit 1 vs 0, `:509-510`), but that is the human CLI, not what an agent sees.

This is a property of the runner, not of the suite, and it is worth stating
before the fix lands: nothing in the current contract prevents a future warning
from being written in the violation's shape, and the agent would have no way to
tell.

---

# Phase B — nine cases on two images, before and after the provenance fix

**Date**: 2026-09-17
**Runner before**: `git show HEAD:…/validate-on-edit.sh` at `9289e18`, run through
`VOE_RUNNER=` so one suite drove both sides
**Runner after**: the working tree, tasks T009-T012 applied
**Images**: `alpine:3.20` (busybox ash) and `debian:12-slim` (dash) — see "The
fixture monoculture" below for why there are now two
**Commands**:

```
VOE_RUNNER=/tmp/voe-before/head-runner.sh \
  bash skills/static-validation-hooks/tests/run.sh --all --image alpine:3.20
VOE_RUNNER=/tmp/voe-before/head-runner.sh \
  bash skills/static-validation-hooks/tests/run.sh --all --image debian:12-slim
bash skills/static-validation-hooks/tests/run.sh --all
```

**Platform**: Docker 29.4.0 via OrbStack, macOS 25.5.0, no project stack.
9 s for eighteen runs (SC-007 allows 60 s).

| Case | Before alpine | Before debian | After (both) | Expected | |
|---|---|---|---|---|---|
| `stale-container-reported-as-violation` | violation | violation | **warning** | warning | red → green |
| `daemon-unreachable` (reworked, cached path) | violation | violation | **warning** | warning | red → green |
| `validator-exit-1-with-findings` | violation | violation | violation | violation | guard held |
| `validator-output-looks-like-a-daemon-error` | violation | violation | violation | violation | guard held |
| `status-only-check` | silence | silence | **violation** | violation | red → green |
| `tool-absent-from-container` (new) | warning | warning | warning | warning | held |
| `leading-dash-tool-name` (new) | warning | warning | warning | warning | see below |
| `validator-chooses-127` (new) | warning | warning | **violation** | violation | red → green |
| `shell-less-container` (new) | silence | silence | **violation** | violation | red → green |

4 passed / 5 failed per image before; 18 passed / 0 failed after. The
agent-visible text is byte-identical on the two images.

## The fixture monoculture, and the regression it hid

Every fixture container was `alpine:3.20`. The runner injects a `sh -c` wrapper
into every validator call, so the shell inside the container is part of the
contract — and one image proved that contract for one shell while the suite
reported full coverage. That is the same failure shape as the defect this
feature removes: a check that is green while exercising none of the ground it
claims.

What it hid, measured on the first version of the wrapper shipped for T009,
which carried a `--` end-of-options marker before the tool:

```
alpine:3.20     busybox ash   exec -- echo hello   rc 0     works
debian:12-slim  dash          exec -- echo hello   rc 127   <argv0>: 1: exec: --: not found
ubuntu:24.04    dash          exec -- echo hello   rc 127   identical
```

dash does not read `--` as an end-of-options marker for `exec`; it looks for a
command named `--`. So on every Debian- or Ubuntu-based image each invocation
returned 127 with an argv0-prefixed diagnostic, which the new classifier read as
"tool not installed": one wiring warning per service, then permanent silence.
Strictly worse than the noisy defect being repaired.

The same suite, over the same nine cases, on that wrapper:

```
alpine:3.20     9 passed, 0 failed     <- the monoculture verdict
debian:12-slim  3 passed, 6 failed     <- a clean file warns; every finding becomes a warning
```

`--` is gone. `exec "$@"` is portable across busybox ash, dash and bash
(measured on all three). The case it was defending against — a tool name
beginning with `-` — is refused at routing time instead, by `refuse_dash_tool`,
where the offending branch can be named.

## What the matrix covers now, and what it still does not

Covered: every case, on busybox ash and on dash, including the wrapper, the
argv0 discriminator and the shell-less fallback. The not-found diagnostic the
discriminator keys on differs per shell and is now measured on all three:

```
busybox ash (alpine:3.20)         <argv0>: exec: line 0: <tool>: not found
dash (debian:12-slim, ubuntu)     <argv0>: 1: exec: <tool>: not found
bash 3.2 (host)                   <argv0>: line 0: exec: <tool>: not found
```

Nothing matches on the wording after the prefix; the prefix is a value the
runner invents per invocation, which is why it holds across all three.

Not covered: ubuntu:24.04 runs the same dash and was measured by hand, not by
the suite — it would add a third row proving nothing new. A shell that is
neither ash, dash nor bash (ksh, zsh as /bin/sh) is unmeasured.

## `leading-dash-tool-name` discriminates on alpine only

Run against the shipped runner with `refuse_dash_tool` removed:

```
alpine:3.20     violation   <argv0>: exec: line 0: illegal option -w   <- a false finding
debian:12-slim  warning     <argv0>: 1: exec: -weirdtool: not found    <- safe, wrong cause
```

So it is a red-before case on ash and a guard on dash. Recorded rather than
claimed as a red-to-green on both.

## `daemon-unreachable` was rewritten, not kept

Phase A's version resolved nothing: with no cached id the failure was taken by
`lookup_cid`, and the runner answered with its own synthetic 125 — the
accidentally safe warning described in note 1 above. It therefore never touched
the defect, and it passed against the broken runner.

It now resolves a live container on a first edit and only then points
`DOCKER_HOST` at an absent socket, so the second edit reaches `docker exec` on
the **cached** path. Measured against the unmodified runner at `9289e18`, that
shape is a violation — the exact stderr recorded in note 1 — which is the red
this phase had to remove.

## What the four other new cases pin

- `tool-absent-from-container` — green before and after, and a guard rather than
  a win: the old runner reached the right answer by claiming every 127 for
  itself. The new runner reaches it from evidence, and this case is what would
  catch a discriminator that stopped recognising the shell.
- `validator-chooses-127` — the reverse of that coin, and the reason the 127 arm
  had to go: a validator that ran, printed a finding and chose 127 was silently
  converted into a wiring warning.
- `shell-less-container` — FR-005a. Every shell is deleted from a live container
  while `grep` keeps working. Both halves are asserted: a clean run stays silent,
  a failing run still reaches the agent.
- `leading-dash-tool-name` — FR-002 for the plumbing's own text.

## Agent-visible text after the fix (identical on both images)

```
daemon-unreachable                          [validate] service `voe` has no running container, so app.txt was not validated.
stale-container-reported-as-violation       [validate] service `voe` has no running container, so app.txt was not validated.
tool-absent-from-container                  [validate] `definitely-not-a-linter` is not installed in the `voe` container, …
leading-dash-tool-name                      [validate] the ROUTING TABLE branch matching app.txt runs `-weirdtool`, whose name begins with `-`, …
status-only-check                           [validate] app.txt — grep (exit 1)  /  "The validator exited 1 and printed nothing."
shell-less-container                        [validate] app.txt — grep (exit 1)  /  "The validator exited 1 and printed nothing."
validator-chooses-127                       [validate] app.txt — sh (exit 127)  /  "/work/app.txt:1: this tool signals with 127"
validator-exit-1-with-findings              [validate] app.txt — sh (exit 1)    /  "/work/app.txt:1: forbidden token"
validator-output-looks-like-a-daemon-error  [validate] app.txt — sh (exit 1)    /  the daemon-shaped line AND the finding after it
```

No case leaks the nonce, and no Docker text reaches the agent as a finding.

The nonce-absent arm still emits the Phase A "no running container" wording,
including when the cause is a dead daemon. That is deliberate: naming the cause
is D3, in Phase C, and this phase does not claim it.

---

# Phase C — fifteen cases on two images, before and after the cause decision

**Date**: 2026-09-17
**Runner before**: `git show HEAD:…/validate-on-edit.sh` at `c16f50e`, driven
through `VOE_RUNNER=` so one suite drove both sides
**Runner after**: the working tree, tasks T014-T017 applied
**Images**: `alpine:3.20` (busybox ash) and `debian:12-slim` (dash)
**Commands**:

```
VOE_RUNNER=<scratch>/head-runner.sh \
  bash skills/static-validation-hooks/tests/run.sh --all --image alpine:3.20
VOE_RUNNER=<scratch>/head-runner.sh \
  bash skills/static-validation-hooks/tests/run.sh --all --image debian:12-slim
bash skills/static-validation-hooks/tests/run.sh --all
```

**Platform**: Docker 29.4.0 via OrbStack, macOS 25.5.0, no project stack.
21 s for thirty-two runs (SC-007 allows 60 s).

| Case | Before (both images) | After (both) | Expected | |
|---|---|---|---|---|
| `stale-container-reported-as-violation` | warning | warning | warning | guard held |
| `daemon-unreachable` (cause assertion added) | **warning, wrong cause** | warning, daemon named | warning | red → green |
| `validator-exit-1-with-findings` | violation | violation | violation | guard held |
| `validator-output-looks-like-a-daemon-error` | violation | violation | violation | guard held |
| `status-only-check` | violation | violation | violation | guard held |
| `tool-absent-from-container` | warning | warning | warning | guard held |
| `leading-dash-tool-name` | warning | warning | warning | guard held |
| `validator-chooses-127` | violation | violation | violation | guard held |
| `shell-less-container` | violation | violation | violation | guard held |
| `stack-recreated-recovers` (new) | **warning** | **silence** | silence | red → green |
| `scaled-service-two-containers` (new) | **warning** | **violation** | violation | red → green |
| `format-then-validate-shares-recovery` (new) | **warning** | **violation** | violation | red → green |
| `daemon-not-re-resolved` (new) | **ps=0** | **ps=1** | exactly 1 | red → green |
| `daemon-outage-then-missing-container` (new) | **one service's warning lost** | daemon once, then `voe2` | warning | red → green |
| `budget-exhausted-before-the-call` (new) | **"did not finish … was killed"** | "already spent before" | warning | red → green |
| `container-alive-but-unreachable` (new) | **"has no running container"** | "could not establish why" | warning | red → green |

8 passed / 8 failed per image before, on both images and with the same split.
32 passed / 0 failed after. The agent-visible text is byte-identical on the two
images.

## Agent-visible text after this phase

```
daemon-unreachable                          [validate] Docker could not be reached, so app.txt was not validated. The daemon is
daemon-not-re-resolved                      [validate] Docker could not be reached, so app.txt was not validated. The daemon is
daemon-outage-then-missing-container        [validate] service `voe2` has no running container, so app.txt was not validated.
stale-container-reported-as-violation       [validate] service `voe` has no running container, so app.txt was not validated.
budget-exhausted-before-the-call            [validate] the 0s budget for this edit was already spent before `sh`
stack-recreated-recovers                    (silence — the file WAS validated, in the replacement container)
scaled-service-two-containers               [validate] app.txt — sh (exit 1)   /  "/work/app.txt:1: forbidden token"
format-then-validate-shares-recovery        [validate] app.txt — sh (exit 1)   /  "/work/app.txt:1: forbidden token"
```

The nonce-absent arm no longer says "no running container" for every cause. A
dead daemon now says so, and says that no service is at fault.

## How FR-008 is proved, and why the outcome could not prove it

FR-008 says the runner must not resolve again once it has decided the daemon is
gone. Every attempt against a dead daemon fails identically, so a runner that
re-resolved three times would emit exactly the same warning as one that decided
once: the requirement is invisible in the outcome and invisible in the message.

`daemon-not-re-resolved` counts instead. A `docker` shim, first on `PATH`,
appends each subcommand to a log and then `exec`s the real binary — it counts,
it does not simulate. Measured on the failing edit, both images:

```
before   ps=0  exec=1     never establishes a cause at all
after    ps=1  exec=1     one probe, one verdict, no re-resolution
```

The case also asserts `exec >= 1`, so "one ps" cannot be satisfied by a runner
that did nothing, and it asserts that the shim was in front of the real binary
on the first edit, so a mis-wired `PATH` fails the case instead of passing it by
counting zero of everything.

This reads the process tree rather than the runner's internals, which is why it
stays black-box: no state file, no source, no log of the runner is consulted.

## `expect_stderr`, and the line it must not cross

Three of this phase's requirements are about the CAUSE the agent is told, not
about the class of message it receives — FR-006 (the causes must be
distinguished) and FR-009 (no key may suppress another). `classify_outcome`
cannot see any of that: a daemon outage and a stopped service are both
`warning`, by construction.

`expect_stderr want|reject <regex>` was added for exactly those assertions, and
for nothing else. It does not classify: each case names the sentence it expects
to find or to be absent, and the harness looks for it. The suite still holds no
opinion about which failures are infrastructure.

## What this phase did NOT measure

- **The `head -n1` pipe hazard.** Plan D3 says reading only the first line "can
  end the call in a way that reads as a failed daemon". Probed on 2026-09-17
  with 8 containers behind one label pair, ten consecutive runs: `docker ps -q |
  head -n1` returned rc 0 every time. Eight short ids are about 100 bytes
  against a 64 KB pipe buffer, so the SIGPIPE story needs thousands of
  containers and is theoretical at any plausible scale. The reason the set is
  now consumed whole is the other one: the first line cannot answer whether the
  cached id is still among the candidates, and that question is what separates
  "replaced" from "alive but unreachable from inside".
- **The stray temporary file of FR-023.** The plan says `with_budget` "creates
  it and returns 124 without unlinking". It does — and `exec_in` drains it one
  frame up, so it never survived an edit. Measured on the runner before this
  phase, on `budget-exhausted-before-the-call`: zero strays. Measured after,
  across all thirty runs of the full matrix: zero strays. The assertion is a
  guard, and the file is now simply never created when there is no time to use
  it.
- **A cause outside the four the table names.** `container-alive-but-unreachable`
  reaches the exhaustive bucket through a paused container, which is a real
  state; a cause nobody has thought of is by definition not in the suite. What
  is asserted is that the bucket exists, degrades to a warning, and does not
  leak Docker's wording.
- **Which of several candidates is chosen** on a scaled service. The case pins
  that *a* surviving sibling is used and the finding reaches the agent; the
  plan's "first acceptable candidate" becomes testable only once acceptability
  exists, which is plan D6 in Phase D.
- **A real Compose stack.** Every fixture is a plain `docker run` carrying the
  two labels, as in Phase A and B. The project-name resolution that would make a
  Compose file matter is Phase D.
- **A daemon that is down rather than absent.** `DOCKER_HOST` points at a socket
  that does not exist, as in Phase A. Stopping the real daemon would disturb
  other sessions on this machine.

---

# Phase D — twenty-four cases on two images, before and after the resolution fix

**Date**: 2026-09-17
**Runner before**: `git show HEAD:…/validate-on-edit.sh` at `21be835`, driven
through `VOE_RUNNER=` so one suite drove both sides
**Runner after**: the working tree, tasks T019-T022 applied
**Images**: `alpine:3.20` (busybox ash) and `debian:12-slim` (dash)
**Commands**:

```
VOE_RUNNER=<scratch>/head-runner.sh \
  bash skills/static-validation-hooks/tests/run.sh --all --image alpine:3.20
VOE_RUNNER=<scratch>/head-runner.sh \
  bash skills/static-validation-hooks/tests/run.sh --all --image debian:12-slim
bash skills/static-validation-hooks/tests/run.sh --all
```

**Platform**: Docker 29.4.0, Compose v5.1.2, via OrbStack, macOS 25.5.0, no
project stack. 48 s for the forty-eight runs of the after matrix (SC-007 allows
60 s); see "Elapsed is a property of the machine" below.

| Case | Before (both images) | After (both) | Expected | |
|---|---|---|---|---|
| the sixteen cases of Phases A-C | as Phase C | unchanged | unchanged | 16 guards held |
| `compose-file-declares-the-name` (new) | **warning** | silence | silence | red → green |
| `dotenv-declares-the-name` (new) | **warning** | silence | silence | red → green |
| `declared-name-with-uppercase-and-dots` (new) | **warning** | silence | silence | red → green |
| `nested-name-serialised-first` (new) | **silent without validating** | silence + exec | silence | red → green |
| `volume-shadows-the-checkout` (new) | **violation** | warning | warning | red → green |
| `worktree-shares-the-main-stack` (new) | **warning, wrong cause** | warning, mismatch named | warning | red → green |
| `worktree-sharing-opt-out` (new) | **warning** | silence | silence | red → green |
| `resolver-override-keeps-validating` (new) | silence | silence | silence | guard held |

17 passed / 7 failed per image before, with the same split on both images.
48 passed / 0 failed after. The agent-visible text is byte-identical on the two
images.

## Agent-visible text for the new refusal

```
[validate] the running `voe` container does not read this checkout's copy of
src/a.txt, so the file was NOT validated. The path it would read is served by another
directory or by a named volume, so a pass or a fail there would describe a file
you did not write. Start this checkout's own stack, or set VALIDATE_WORKTREE=run
if one stack is shared on purpose.
```

Its warning key is `foreign-<service>`, distinct from `nocontainer-<service>`
and from the session-wide `daemon`, so FR-009's rule that no key may suppress
another still holds with a fourth cause in the table.

## What the four naming cases actually pin

The three source cases (`compose.yml`, the project `.env`, uppercase and dots)
run with **no** `COMPOSE_PROJECT_NAME` at all: `run.sh` drops it from the
environment with `env -u` when a case sets `VOE_NO_CPN=1`, so a developer's own
exported value cannot make them pass for free. Each labels its container with a
name the OLD rule cannot produce — the declared name, the `.env` value, the
normalised form — so silence is only reachable by reading the source under test.

`nested-name-serialised-first` is the one that guards the extractor rather than
the sources. Measured 2026-09-17, Compose v5.1.2 serialises top-level keys in
alphabetical order, so a project whose service uses a `configs:` entry renders

```
{ "configs": { "aaa_conf": { "name": "<the config>" } }, "name": "<the project>", … }
```

and `extract_json_string` (`validate-on-edit.sh:58-80`), which returns the FIRST
`"name"`, would resolve the config. The case asserts both directions: a
container carrying only the CONFIG's name must NOT be found, and one carrying
the top-level name must validate.

### The hole that case had, and how it was found

Its first version asserted only `warning` then `silence`, and it **passed
against the unfixed runner**. Step 1 burns the per-service "no running
container" warning, so a runner that resolves neither name is silent on step 2
through `warn_once` suppression — silence that means "said nothing", not
"validated something". `worktree-sharing-opt-out` had the same shape of hole
from a different cause (a path spelled through `/var` against a git root spelled
through `/private/var`, which the runner refuses as "outside the project root").

Both now count `docker exec` through the existing shim and require at least one.
Neither hole was predicted; both were found by running the case against the old
runner and reading the result rather than the expectation. Every case whose
expected outcome is `silence` should be read with that suspicion: silence is the
one outcome a runner can produce by doing nothing.

## The volume-shadowing case, measured

Fixture: the checkout bound at `/app`, a named volume over `/app/src`,
`WorkingDir=/app`, the host file saying `FRESH` and the volume's copy `STALE`,
and a validator that fails on anything but `FRESH`.

```
mount table   bind   | <checkout>                              | /app
              volume | /var/lib/docker/volumes/…-stale/_data   | /app/src
docker exec … cat /app/src/a.txt                               -> STALE
before        VIOLATION "…/app/src/a.txt:1: stale copy"        <- a finding about a file the agent did not write
after         warning naming the checkout mismatch
```

The case verifies the shadowing with its own `docker exec` before asserting
anything, so it cannot pass against a fixture that does not carry the hazard.

## Where research.md was wrong, and it matters

§3 says "Docker reports mount sources already resolved". It does not, on this
platform: measured 2026-09-17, a bind created from
`/var/folders/…/T/voe-test-…` is reported by `docker inspect` with that exact
spelling, while the physical path is `/private/var/folders/…`. Every existing
fixture lives under `$TMPDIR`, so a runner comparing the two sides as strings
would have refused all sixteen. Both sides go through `cd … && pwd -P`.

## Elapsed is a property of the machine, not only of the suite

The alpine "before" matrix took **631 s** and the debian one **19 s**, the same
twenty-four cases against the same runner, minutes apart. The difference is
contention: seven unrelated Docker workloads from other sessions were running on
this host, and a single `docker run -d` was measured at 2 m 35 s. SC-007's 60 s
is met on an idle machine (48 s for the full after matrix) and is not a property
the suite can hold on a loaded one.

## What this phase did NOT measure

- **A real `docker compose up`.** Every fixture is still a plain `docker run`
  carrying the two labels. What Compose is asked for here is the NAME
  (`docker compose config`, `docker compose ls`), against real Compose files;
  the containers that name resolves to are the suite's own.
- **The per-edit cost of the name cache.** The cached branch stats the Compose
  files and `.env` and runs one `cksum`; it was never timed, only shown to
  re-resolve when a Compose file's mtime changes.
- **`COMPOSE_FILE` and `COMPOSE_PROFILES`.** They are in the cache fingerprint,
  so changing one re-resolves; no case sets either.
- **A Compose file outside the project root.** `compose_files_present` looks in
  the project root only, and `docker compose ls` fills the rest in for a project
  that is running. A project that is NOT running and whose files live elsewhere
  is fingerprinted on the root's candidates alone.
- **Which candidate is chosen** on a scaled service where several read this
  checkout. The plan's "first acceptable" is implemented; no case distinguishes
  two acceptable siblings from each other.
- **A container with no bind mount at all** — code baked into the image. It is
  now refused where it used to validate against the image's copy. That is a
  deliberate consequence of FR-013 and it has no case: the suite asserts the
  refusals the spec names, not this one.

---

# Phase E — twenty-five cases on two images, and the suite put to the question

**Date**: 2026-09-17
**Runner**: the working tree, tasks T024-T026 applied
**Images**: `alpine:3.20` (busybox ash) and `debian:12-slim` (dash)
**Command**: `bash skills/static-validation-hooks/tests/run.sh --all`
**Platform**: Docker 29.4.0 via OrbStack, macOS 25.5.0, no project stack

```
50 passed, 0 failed, 106 assertions, 37s elapsed      (suite clock)
                                     46.7s            (wall, `time`)
```

25 cases × 2 images. The twenty-four cases of Phases A-D are unchanged and held;
the twenty-fifth is new.

## `mutation-provenance-becomes-infrastructure` — the case that tests the suite

Every other case asserts an outcome of the runner. None of them established that
the suite would NOTICE if the classifier stopped working, and a suite whose
guards cannot fail is a green nobody earned.

```
SITE      exec_reached_inside, the one line asking whether the nonce came back
              case "$out" in *"$_NONCE"*) return 0 ;; esac
OPERATOR  delete it; `return 1` remains, so every failed exec in a service with
          a shell is an UNCONDITIONAL infrastructure verdict
MATCHES   1 (asserted; 0 or several fails the case)
REPLAY    validator-exit-1-with-findings              violation -> warning  CAUGHT
          validator-output-looks-like-a-daemon-error  violation -> warning  CAUGHT
```

The site and the operator are written down in the case rather than derived, so a
later change to the runner that MOVES that line fails the case loudly instead of
silently mutating nothing. Both directions of that guard were probed on the same
day: a copy with the line reworded reported `matched 0 line(s)` and failed; a
copy with the line duplicated reported `matched 2 line(s)` and failed.

The case asserts the transformation, not merely a failure. `expected violation,
observed warning` is the harness's own verdict line; a Docker hiccup or a broken
fixture would fail the nested run with a different message and would NOT satisfy
the case. That is why no separate control run was added: the unmutated half of
the pair is those same two cases, in this same matrix, a few rows above.

It carries no copy of the decision table, per plan D8.

## The assertion count is now measured, not read off the source

`run.sh` counts every evaluated `expect_outcome` / `expect_stderr` /
`expect_no_stray_temp_files` (and the mutation case's own checks) in a file, one
byte each, and prints the total. A count read from the source would include
helper calls inside branches that were never taken and would miss a case that
returned early. 106 assertions over the 50 case-runs of the full matrix. The
mutation case's four nested replays keep their own counter in their own sandbox
and are not folded into that total.

## Elapsed, and the machine it was measured on

SC-007 allows 60 s. Measured three times on 2026-09-17, on a machine that was
NOT idle:

```
                        suite clock   wall    load (1 min, before -> after)   unrelated containers
pre-change baseline        37 s      46.1 s   5.53 -> 8.10                    13
after T024/T025            38 s      47.2 s   4.26 -> 7.09                    12
after T024/T025 (again)    37 s      46.7 s   5.13 -> 6.14                    11
```

The criterion holds with about 22 s of margin, and it holds under a load that
Phase D's 48 s figure did not carry. **No idle measurement was taken**: the
unrelated Docker workloads on this host belong to other sessions and were not
stopped. Phase D's warning stands unchanged — the same twenty-four cases took
631 s on this machine under heavy contention, so elapsed is a property of the
host as much as of the suite, and a single number should never be read as one.

## What Phase E did NOT measure

- **An idle host.** See above. The three figures bracket one loaded machine on
  one afternoon; they do not establish a floor or a ceiling.
- **A mutation anywhere but the provenance test.** One site, one operator, as
  plan D8 specifies. The cause table, the identity test and the name resolution
  have no mutant; their cases are asserted, not put to the question.
- **The nested replays' own timing.** The mutation case costs about 1.5 s per
  image, inferred from the matrix growing 24 -> 25 cases at unchanged elapsed,
  not timed on its own.
