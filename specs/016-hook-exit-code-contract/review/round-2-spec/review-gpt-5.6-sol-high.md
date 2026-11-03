Ranked findings:

1. Critical — FR-001 is inherently racy `[Design]`

Construct:

1. A real validator exits 1 and reports a finding beginning `Error response from daemon: No such container: …`.
2. `docker exec` completes normally with that validator output.
3. The container is removed before the bounded probe.
4. The output shape says “infrastructure”; the probe says “container gone”. Both agree, both are wrong.

The probe proves only container/daemon state when the probe runs. It cannot prove whether the validator started or who produced the earlier output. The reverse race also exists: an exec infrastructure failure followed by a container restart makes the probe report healthy.

FR-001 therefore cannot guarantee FR-003 from post-hoc evidence (`specs/016-hook-exit-code-contract/spec.md:92-93`, `:104-108`). This needs execution-time provenance—such as an unforgeable invocation marker emitted inside the container before launching the validator—not another after-the-fact observation.

2. High — Exhausted budget makes classification impossible `[Design]`

If the failed invocation consumes the remaining budget, FR-001 still requires a probe while FR-001a forbids running it (`specs/016-hook-exit-code-contract/spec.md:104-105`). The current budget wrapper returns 124 immediately when no time remains (`skills/static-validation-hooks/templates/validate-on-edit.sh:208-213`).

The specification defines no outcome for “ambiguous rc=1, probe could not run.” None is safe:

- Violation can expose a daemon error.
- Warning can discard a real finding.
- Silence loses both.
- Budget warning misstates what happened.

Reserve time for classification, collect provenance during the original exec, or explicitly define a conservative ambiguous outcome.

3. High — FR-006b cannot be established by the Compose working-directory label `[Design]`

`com.docker.compose.project.working_dir` is creation metadata, not proof that the edited file is mounted from this checkout.

It can:

- False-reject equivalent symlink and canonical paths.
- False-reject Compose started from a repository subdirectory, while the runner uses Git’s top-level root (`validate-on-edit.sh:389-397`).
- Become stale after a checkout rename.
- False-accept a stack whose working directory is this checkout but whose bind mount points elsewhere.
- Say nothing about whether the specific file path maps to the container path passed to the validator.

FR-006b neither names the label nor defines canonicalization, mount verification, or compatibility behavior (`spec.md:113-117`). It also overrides the existing explicit `VALIDATE_WORKTREE=run` escape hatch (`validate-on-edit.sh:408-424`), breaking consumers that intentionally share a stack today.

The design must define identity in terms of the effective source mount for the validated file, plus an explicit opt-out/override policy.

4. High — A non-zero validator with empty output remains silently lost `[Design]`

The runner explicitly ignores any non-zero result with no output (`validate-on-edit.sh:341-347`). FR-003 only protects validators exiting with “their own output” (`spec.md:108`).

A validator crash, killed process, or exit-code-only checker therefore produces a clean-looking hook result. It should at least become “validator failed without diagnostics; file not validated.”

5. Medium — The two-cause infrastructure model is neither exhaustive nor reliably decidable `[Design]`

A later probe cannot determine the cause of the earlier exec because state can change between calls. The current lookup also discards Docker stderr, conflating “no matching container” with probe failure (`validate-on-edit.sh:239-243`).

A third cause is Docker socket authorization failure: the daemon may be alive and the container present, but the client cannot inspect or exec it. It is neither “container gone” nor “daemon unreachable.” Today it falls through as a violation (`validate-on-edit.sh:341-347`); the proposed requirements leave its retry and warning-key behavior undefined (`spec.md:110-112`).

Even “stopped container” does not fit “gone, re-resolution fixes it,” despite being assigned that outcome (`spec.md:52`).

6. Medium — Warning cardinality requirements contradict each other `[Design]`

With two services and one dead daemon, the agent should see exactly one warning (`spec.md:94-96`).

- `daemon-down-$service` produces two warnings.
- Global `daemon-down` produces one and can coexist safely with `missing-container-$service`.
- But the global key violates the blanket per-service requirement in FR-011 (`spec.md:120`).

No key scheme satisfies both statements. Warning scope should be cause-dependent: daemon/client outage global, container absence per service.

7. Medium — Test acceptance is partly tautological and one metric is unmeasurable `[Wording/testability]`

US3 scenario 1 merely requires each row to be “asserted against the agent-visible outcome” without naming an independent oracle; a snapshot of any implementation satisfies it (`spec.md:84-85`). Scenario 2 is a mutation-test requirement but defines no mechanism for injecting that regression (`spec.md:86-88`).

SC-002’s “100% of runs” cannot be established by a finite suite (`spec.md:133`). It should quantify a defined test matrix. SC-001 also misstates its population: excluding unreachable 125 leaves seven table rows only by counting clean and real-finding executions; only five are cases where no validator ran (`spec.md:18-27`, `:132`).

8. Medium — SC-007 is not verifiable in this review boundary `[Scope]`

Only this repository’s runner is present. FR-012 requires a separate change in another repository (`spec.md:122`), while scope explicitly says the plugin copy is elsewhere and diverged (`spec.md:145-146`). The byte-identity assertion does not prove that external copy received the port or passes the suite (`spec.md:156-157`).

SC-007 (`spec.md:140`) needs external CI evidence from a pinned plugin revision, or it must be an external release criterion rather than acceptance for this change.

Additional uncovered runner path: when Docker is absent from `PATH`, `_run` synthesizes 125 (`validate-on-edit.sh:298-300`) and reports “no running container” (`:328-333`). That is neither of FR-004’s causes and should be represented in FR-009’s reachable-path matrix.
