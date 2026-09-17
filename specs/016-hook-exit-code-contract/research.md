# Research — measured behaviour the design rests on

**Date**: 2026-09-17
**Platform**: Docker via OrbStack, macOS 25.5.0. Client and daemon on one host.
**Method**: throwaway probes against real containers. Every figure below was produced, not recalled.

## 1. `docker exec` exit codes

| Situation | rc | First line of output |
|---|---|---|
| Container running, command succeeds | 0 | — |
| Container running, command exits 3 | 3 | the command's own output |
| Command not present in the container | 127 | `OCI runtime exec failed: ... not found` |
| Container stopped | 1 | `Error response from daemon: container <id> is not running` |
| Container removed | 1 | `Error response from daemon: No such container: <id>` |
| Container id never existed | 1 | `Error response from daemon: No such container: <id>` |
| Daemon unreachable | 1 | `failed to connect to the docker API at <socket> ...` |
| `docker run --nonsense-flag` | 125 | CLI usage error |

**Conclusion.** `docker exec` never returns 125. Three distinct infrastructure failures return 1, which is also the exit code of a validator that found something. The current contract at `templates/validate-on-edit.sh:246` is false, and no remapping of exit codes can repair it.

The second session reproduced four of these rows independently on the same machine, from its own probes: bogus id → 1, created-but-not-running → 1, command exit 3 → 3, command absent → 127.

## 2. The decision probe: one `docker ps` separates all three states

The question the runner must answer after a failed exec is not "which error message is this" but "is the container still there, and is the daemon still there". A single label-filtered `docker ps` — the call the runner already owns as `lookup_cid` — answers both.

| State | `docker ps` rc | stdout | Elapsed |
|---|---|---|---|
| Container alive | 0 | the container id | 32 ms |
| Container gone, daemon fine | 0 | **empty** | 34 ms |
| Daemon unreachable | **1** | `failed to connect to the docker API ...` | 28 ms |

**Conclusion.** The three outcomes are distinguished by `(rc, empty?)` alone, with no message matching in the primary decision. Cost is around 30 ms, paid only after a failed exec — never on the success path.

This is what makes FR-001 satisfiable without violating FR-003. The earlier worry, that classification would have to guess from an error string, does not survive the measurement: the probe reports state, it does not interpret text.

**Residual race.** A container can die between the exec and the probe. The probe would then say "gone" while the exec output held a real finding. The output shape is the second piece of evidence and covers exactly this: output that is not a daemon error is treated as a finding. That is the safe direction — the failure mode becomes a duplicated finding, never a lost one.

## 2b. Execution-time provenance beats the probe

Adversarial round 2 showed the probe cannot settle the question on its own: it observes state *after* the call, so a container that dies between the exec and the probe makes a real finding look like an outage. The remedy both reviewers pointed at is evidence produced *during* the call.

The invocation carries a nonce that is printed inside the container, immediately before the validator is handed control. If the nonce comes back, the validator ran; whatever follows is its own output and its own exit code. If the nonce does not come back, the validator never started.

Measured 2026-09-17:

| Case | Nonce returned | rc | Correct verdict |
|---|---|---|---|
| Validator succeeds | yes | 0 | clean |
| **Validator exits 1 printing `Error response from daemon: No such container: ...`** | **yes** | 1 | **finding** |
| Validator absent from the container | yes | 127 | wiring warning |
| Container removed | no | 1 | infrastructure |
| Daemon unreachable | no | 1 | infrastructure |

Row 2 is the exact construct the reviewers built to break the two-evidence rule. Provenance classifies it correctly.

**Cost**: 51 ms against 44 ms for the bare call — about 7 ms, and **zero additional Docker calls**, on every path. The probe of §2 is no longer the primary evidence. It survives only to answer which infrastructure cause occurred, which decides the warning text and whether to resolve again.

### 2c. The nonce is not always first — measured, and it corrects the design

A control run, added because the first probe only ever saw the nonce at the front:

```
without the wrapper, run 1 : B-stdout | D-stdout | A-stderr | C-stderr
without the wrapper, run 2 : A-stderr | C-stderr | B-stdout | D-stdout
with the wrapper,    run 1 : <nonce>B-stdout | D-stdout | A-stderr | C-stderr
with the wrapper,    run 2 : A-stderr | C-stderr | <nonce>B-stdout | D-stdout
```

Two conclusions.

**The stdout/stderr reordering is pre-existing and non-deterministic.** The same command, twice, ordered its lines differently, with and without the wrapper. Docker carries the two streams separately and the runner merges them. The wrapper neither causes this nor worsens it.

**The nonce is therefore not a prefix.** It attaches to the validator's first stdout write, which can land after an arbitrary amount of stderr. Detection must look for the nonce anywhere in the output, never only at the front, and the plan's first wording said otherwise.

**Residual risk, and what covers it.** If the output were cut before the nonce, a finding would read as an outage. The only thing that truncates output here is the time budget, and a budget kill is already reported as its own outcome before any nonce question arises — measured: a wrapped validator killed at 1 s returns 124, not an ambiguous 1.

**Requirement this introduces**: a POSIX shell inside every routed container. Those containers already run validators, so this is cheap, but the plan must confirm it per routed service rather than assume it.

**Behaviour preservation, measured across eight cases**: stdin reaches the validator; an argument containing a space arrives intact (`wc -c "/work/a file.txt"` -> `6 /work/a file.txt`); the container's working directory is preserved; a shell builtin works as the tool; a 66 KB output is unaffected; a validator exiting non-zero with no output is still distinguishable after the nonce is stripped; a missing tool still returns 127; a killed validator returns 124.

## 3. The ownership label exists and is readable

```
docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' <cid>
```

Returns the absolute directory Compose was invoked from. Present on a container started by `docker run --label`, so present a fortiori on one started by Compose. This is the evidence FR-006b needs, and it costs one call on the resolution path, not on every edit.

**Superseded as an identity test.** Adversarial round 2 enumerated six shapes that validate correctly today and that a `working_dir == project root` test would refuse: a Compose file in a subdirectory, `up` run from a subdirectory, a directory renamed after the stack started, a platform private path prefix such as `/private/var` on macOS, a symlinked path, and a stack deliberately shared through the worktree opt-out. The label is the directory Compose was invoked from, not the source of the bind mount the file is read through, so it can accept a container whose mount does not contain the edited path and reject one whose mount does.

The label stays useful as a hint. The identity test must rest on the mount for the validated path, and the plan owes a canonicalisation rule. Recorded here so the plan does not repeat the assumption.

## 3b. Asking Compose is cheaper than imitating it — measured

```
docker compose config --format json  ->  .name = "broker-pa"        103 ms
docker compose ls --format json      ->  ConfigFiles = the files it read   169 ms
compose.yml:4                        ->  name: broker-pa
directory basename                   ->  modelo-broker-pa
```

Run in `modelo-broker-pa` on 2026-09-17. Compose answers with the name the containers actually carry, and names the files it read, so the four-source precedence and the override file need no reimplementation.

103 ms is far too expensive per edit and unremarkable once per service, which is why this call belongs on the resolution path only.

**Two samples, not one number.** A later sample on the same day gave 64 ms and 74 ms for the same two calls. Both stand; the host carried 11 to 13 unrelated containers at varying load throughout. Read the figure as a range, and read the conclusion — too expensive per edit, cheap once per service — as the part that does not move.

**What this call cannot recover**, and the plan must say so rather than claim completeness: a file list or a project name passed on the command line when the stack was started. The hook runs in a different environment from that `up`, so `-f` and `-p` are invisible to it. Nothing measured here changes that.

## 3c. Mount inventory of a live container — measured

```
com.docker.compose.project.working_dir  /Users/…/modelo-broker-pa
mounts                                  /Users/…/modelo-broker-pa/apps/backend  -> /app
                                        /Users/…/modelo-broker-pa/apps/frontend -> /frontend
                                        /Users/…/modelo-broker-pa/specs         -> /specs
inspect cost                            33 ms
```

The working directory and the mount that actually carries the Go sources are different paths. That is the measurement behind rejecting the label as an identity test.

**It also shows what a source-only test misses.** Membership of a mount *source* does not say which mount supplies the container path the validator will read. Where mounts overlap, the deepest destination wins, and it may be a named volume holding a stale copy. The identity test must start from the container path, not from the host path.

## 3d. Mount shadowing, reproduced

A container with two mounts, a checkout bound at `/app` and a named volume over `/app/src`:

```
what the validator reads at /app/src/a.ts : STALE content from the volume
mount table  bind   | <checkout>/repo                        | /app
             volume | /var/lib/docker/volumes/voe-stale/_data | /app/src
source-only test    : PASSES on source <checkout>/repo        <- accepts a wrong container
deepest-destination : volume | /var/lib/.../voe-stale/_data | /app/src
```

The validator reads the volume's stale copy, and a test asking only whether some mount *source* is a parent of the edited host file accepts it. The deepest matching *destination* names the volume, and `Type` distinguishes a bind from a volume, so both the detection and the refusal are available from one `docker inspect`.

This is the measurement behind D6 starting from the container path rather than the host path. The first draft of that decision was source-only, and this probe is what refuted it.

## 3e. Both sides of the path comparison need resolving — measured during implementation

The plan's Phase 0 claimed Docker reports mount sources already resolved, so only the runner's own root needed canonicalising. False on macOS. A bind created under the platform temporary directory is reported by `docker inspect` with that spelling, while the physical path carries a private prefix. The two strings differ, and an identity test resolving only one side refuses every fixture on this platform.

Both sides now go through a physical resolution. Recorded here because the claim was written as settled and was not measured when written.

## 4. Compose project-name precedence

Compose resolves the project name from four sources, highest first:

1. `COMPOSE_PROJECT_NAME` exported in the environment
2. `COMPOSE_PROJECT_NAME` in the project `.env`
3. the top-level `name:` in the Compose file
4. the base name of the project directory

The runner reads 1 and 4 (`templates/validate-on-edit.sh:234-237`). Sources 2 and 3 are the silent-miss doors.

Whatever the source, the value is normalised before it becomes a label: lowercased, and reduced to `[a-z0-9_-]`. The runner already does this for source 4 and must do it for all four.

**Open for the plan**: which file wins when several of `compose.yml`, `compose.yaml`, `docker-compose.yml`, `docker-compose.yaml` are present, and whether `COMPOSE_FILE` must be honoured. Reading the wrong file yields the wrong name, which is the defect this feature exists to remove.

## 5. What was NOT measured

- Docker Desktop and Colima. Same CLI binary, so the same codes are expected; expectation is not measurement. The two-evidence rule in FR-001 is what keeps a wording difference from producing a false finding.
- Podman and other Docker-compatible daemons. Out of scope.
- The daemon-down row was measured here by pointing `DOCKER_HOST` at a socket that does not exist, not by stopping the daemon under other sessions on this machine.
