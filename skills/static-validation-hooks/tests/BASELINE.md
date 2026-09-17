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
