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
