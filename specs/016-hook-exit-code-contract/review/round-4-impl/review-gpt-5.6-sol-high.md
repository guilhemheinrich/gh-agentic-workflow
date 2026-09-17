The strongest regression is in the identity proof: it proves `WorkingDir/$F`, not the path actually passed to the validator, and then caches that proof per service rather than per served path. A valid route can therefore be refused, or a later route can validate a volume-backed stale copy under the same cached container.
## Findings, ranked

1. **P1 — Identity verifies the wrong path and is cached too broadly.** `[code]`  
`container_reads_checkout` proves `WorkingDir/$F`, not the actual path passed to the validator (`validate-on-edit.sh:599-637`). Example:

- checkout bind: `/repo -> /app`
- stale volume: `/workspace`
- `WorkingDir=/app`
- route: `check eslint "/workspace/$F"`

The identity test approves `/app/$F`, then eslint reads the stale volume. Its result becomes a finding about a file the agent did not write.

The inverse falsely refuses a valid route: put the volume at `/app`, checkout at `/workspace`, and still invoke `/workspace/$F`.

It gets worse because the CID cache is service-scoped. After one path proves `/app/src` is a bind, a later path under `/app/generated` can be volume-backed and still take the unchecked hot path (`validate-on-edit.sh:938-947`). An in-container remount or symlink retarget has the same effect. Docker restart normally preserves mounts and recreation changes the CID, but in-place namespace changes do not.

2. **P1 — Exhausting the budget can permanently cache an unverified foreign container.** `[code]`  
If `docker ps` consumes the remaining time, `identity_ok` accepts without inspection (`validate-on-edit.sh:680-694`). The caller then caches that CID (`validate-on-edit.sh:1009-1019`). The current edit gets a budget warning, but the next edit uses the unchecked hot path and may validate another checkout. “Zero-cost” here costs the core identity guarantee. A skipped proof must not populate the persistent cache.

3. **P1 — A genuine validator exit 124 is lost whenever GNU `timeout` is available.** `[code]`  
Concrete validator:

```sh
printf '/work/a.ts:1: finding\n'
exit 124
```

GNU `timeout` also returns 124 when its child itself returns 124. The runner raises its budget sentinel solely from that status (`validate-on-edit.sh:257-261`), then the budget arm wins before provenance is considered (`validate-on-edit.sh:1252-1272`). The agent receives “was killed”; the real finding is discarded. This directly breaks “a finding must never be lost.”

4. **P1 — Shell-less infrastructure still becomes a code violation when Docker changes wording.** `[code]`  
Cache a shell-less container, then use a long Unix `DOCKER_HOST` producing `socket path … is too long`, or an older client producing `error during connect … connection refused`. Neither matches `is_docker_error` (`validate-on-edit.sh:1141-1149`).

`exec_reached_inside` therefore claims the validator ran (`validate-on-edit.sh:873-883`), and `classify_degraded` emits Docker’s text as a violation (`validate-on-edit.sh:1159-1187`).

The reverse also fails: a shell-less validator legitimately printing `Error response from daemon:` with exit 1 loses its finding and gets an infrastructure warning.

5. **P1 — The nonce proves that the wrapper printed, not that the validator started.** `[code]`  
The marker is emitted before `exec` (`validate-on-edit.sh:855-859`). A deterministic counterexample is a container with a custom executable named `sh` that:

- returns 7 for the probe command, passing `probe_shell` (`validate-on-edit.sh:795-808`);
- for the real wrapper, prints argv 4—the nonce—and exits 1 without invoking the validator.

Nonce presence makes the runner accept provenance (`validate-on-edit.sh:875-879`), producing a status-only violation or exposing the fake shell’s text as a finding. A real shell killed between `printf` and `exec` has the same race.

6. **P2 — “Once per session” actually means once for the lifetime of `/tmp`.** `[code]`  
State is keyed only by project root (`validate-on-edit.sh:168-182`); the payload’s session ID is ignored. Sequence:

1. Session A encounters a daemon outage; `warn-daemon` is created.
2. Docker recovers.
3. Session B encounters a new outage.

The second warning is suppressed, `WARNING` remains empty, and the hook exits silently (`validate-on-edit.sh:1197-1205,1628-1630`). Budget, foreign, missing-container, and wiring warnings have the same cross-session persistence.

7. **P2 — The Compose fingerprint misses inputs that can change the project name.** `[code]`  
Concrete Compose file:

```yaml
name: ${STACK_NAME}
```

Run once with `STACK_NAME=blue`, then with `STACK_NAME=green` without touching the file. `STACK_NAME` is absent from the fingerprint (`validate-on-edit.sh:401-415`), so the cached `blue` result is reused (`validate-on-edit.sh:435-446`).

Likewise, `COMPOSE_ENV_FILES` records only the path, not the referenced file’s timestamp/content. File mtimes are second-resolution, so same-second rewrites or preserved timestamps also evade invalidation.

8. **P2 — The advertised wall-clock budget does not cover resolution.** `[code]`  
`docker compose config/ls`, `docker ps`, `docker inspect`, and the shell probe are not wrapped by `with_budget` (`validate-on-edit.sh:382-391,509-513,590-595,795-808`). A slow TCP Docker endpoint can make a 3-second hook wait for the client’s much longer connection timeout.

After a prior budget warning, the persistent warning sentinel can also turn the eventual undecided result into complete silence.

9. **P2 — A successful listing followed by failed identity inspection is misreported as `foreign`.** `[code]`  
Let `docker ps` succeed, then make the daemon unavailable before `docker inspect`. Every candidate is rejected because facts cannot be read (`validate-on-edit.sh:599-607,700-706`), and the caller assigns `foreign` (`validate-on-edit.sh:1009-1014`). The agent is told the mount points at another checkout, although the runner established no such fact. A later genuine foreign-container incident can then be suppressed by that incorrect key.

The shellful exhaustive `unclassified` bucket itself is safe: it does not reach a violation.

10. **P2 — Exact-one nonce stripping cannot identify the injected occurrence.** `[code]`  
If a validator emits the current nonce to stderr—obtainable by a cooperating process inspecting the wrapper argv—and Docker presents that stream before the wrapper’s stdout, `strip_nonce_once` removes the validator’s occurrence and leaves the plumbing occurrence (`validate-on-edit.sh:773-781`). Classification remains a violation, but output provenance is corrupted and the injected marker leaks.

Ordinary chunk boundaries are sound because capture is into one file; closing stdout after startup and reading stdin to EOF do not erase the already-written nonce.

## Suite defect

**`format-then-validate-shares-recovery` does not prove that `fix` shares recovery.** `[test]`  
Its own validator independently repairs the stale CID. Delete the `fix` call at `format-then-validate-shares-recovery.sh:37`, and the `check` at lines 38–39 still recovers and emits the expected finding; assertions at lines 58–60 remain green. The case passes for the check’s recovery, not the formatter’s.

A second gap: `declared-name-with-uppercase-and-dots` does not exercise normalization of Compose’s answer. Compose already returns the normalized name, so deleting the normalization call at `validate-on-edit.sh:453` leaves `declared-name-with-uppercase-and-dots.sh:21-49` green.

## Regressions outside the matrix

Two previously working consumers now fail:

- A shell-less validator whose legitimate output resembles Docker wording is converted from a finding into a warning.
- A validator invoked through an absolute path different from `WorkingDir/$F` can now be falsely refused—or validate a stale mount—by the new identity inference.

All substantive findings above require code changes; the suite findings require test changes, not comments.Follow-up addendum—four additional code findings:

- **P1:** Cached CIDs bypass Compose fingerprinting entirely. After project A is cached, changing `name:` or `COMPOSE_PROJECT_NAME` to B still executes in A (`validate-on-edit.sh:936-947`). Findings from B can be lost.
- **P1:** Explicit `COMPOSE_FILE=deploy/compose.yml` is ignored when no standard root Compose file exists; resolution returns the basename before consulting Compose (`validate-on-edit.sh:428-432`).
- **P2:** Removing a missing CID does not remove its shell-capability cache (`validate-on-edit.sh:967-971`). A subsequent shell-less replacement inherits `shell=yes`, so its working validator is never attempted.
- **P2:** A nonce can precede a transport failure. If Docker disconnects after receiving the nonce but before/during `exec`, infrastructure text is treated as validator output (`validate-on-edit.sh:855-880`).

These all require code changes.
