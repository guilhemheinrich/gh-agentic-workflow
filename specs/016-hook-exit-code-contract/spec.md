# Feature Specification: The hook's exit-code contract, measured rather than assumed

**Feature Branch**: `016-hook-exit-code-contract`
**Created**: 2026-09-17
**Status**: Draft
**Input**: The on-edit validation hook misreads Docker infrastructure failures as lint violations, because its exit-code contract assumes `docker exec` returns 125 for a missing container when it returns 1 — the same code a linter returns when it found a real problem. Separately, it resolves the Compose project name from two of the four sources Docker Compose reads, so a repository that names its stack in `compose.yml` gets a runner pointed at a project no container carries, and validation stops in silence.

## Context

The factory at `skills/static-validation-hooks/` ships a runner, `templates/validate-on-edit.sh`, that consumers install as a PostToolUse hook. After an agent writes a file, the runner routes that path to a service, runs a file-local validator inside the running container, and feeds any finding back to the agent.

Its whole value rests on one promise, stated in the skill: an infrastructure problem must never reach the agent as a finding, and a finding must never be lost. `check()` implements that promise with four exit-code arms — 124 budget, 125 no container, 126/127 tool missing, everything else a violation.

Measured on Docker via OrbStack, 2026-09-17, `docker exec` exit codes:

| Situation | Exit code | First line of output |
|---|---|---|
| Container running, validator clean | 0 | — |
| Container running, validator found 3 problems | 3 | validator output |
| Validator absent from the container | 127 | `OCI runtime exec failed: ... not found` |
| Container stopped | 1 | `Error response from daemon: container ... is not running` |
| Container removed | 1 | `Error response from daemon: No such container: ...` |
| Container id never existed | 1 | `Error response from daemon: No such container: ...` |
| Docker daemon unreachable | 1 | `failed to connect to the docker API ...` |
| `docker run --nonsense-flag` | 125 | CLI usage error |
| `docker exec --bogus-flag <id>` | 125 | CLI usage error |

No situation the runner can reach returns 125. Not because `docker exec` cannot produce it — every docker subcommand returns 125 for a CLI usage error, `exec` included — but because the runner composes its own argument list and never passes an unknown flag. A test asserting "exec never returns 125" would assert something false; one asserting "no edit can reach 125" is true, and that is the one the suite carries. The 125 arm is reachable only from the runner's own synthetic returns. The three infrastructure failures that actually occur all return 1, which is also the exit code of a validator that found something. The contract cannot be repaired by remapping an exit code, and it cannot be repaired by reading the error text either: a validator's own output may legitimately contain such a line.

Two consequences follow, both already observed. `exec_in` keys its stale-container recovery on 125 (`templates/validate-on-edit.sh:262`), so that branch never fires, the cached id is never dropped, and every later edit repeats the failure. And rc=1 falls into the default arm of `check()`, so the agent is told the file it just wrote has a violation whose text is `Error response from daemon: No such container: <id>`.

Declared as `GRV-stale-cached-container-reported-aa46` (high) in `specs/GRIEVANCES.md`, observed 2026-09-16 in `modelo-broker-pa`: the hook failed twice with that daemon error, a subagent fell back to running the validator by hand, and five real findings in that branch's own code survived to the end of the batch.

The second defect is the same failure class through a different door. `compose_project()` reads `COMPOSE_PROJECT_NAME` or the directory basename. Docker Compose reads five sources. Four are visible to a hook, in order: the exported variable, `COMPOSE_PROJECT_NAME` in the project `.env`, the top-level `name:` of the Compose file, then the basename. The fifth is `-p` on the command line that started the stack, which outranks the file's `name:` and which nothing on disk records. A repository using either middle source gets a lookup that matches nothing, a single "no running container" warning, and silence thereafter. Measured in `modelo-broker-pa`, whose `compose.yml:4` declares `name: broker-pa` while the checkout directory is `modelo-broker-pa`.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An agent is never told an outage is its mistake (Priority: P1)

An agent edits a file while the project's stack is down, restarting, or has been recreated since the last edit. The hook cannot validate anything. The agent must learn that validation did not run, and must never be handed a daemon error dressed as a finding about the file it just wrote.

**Why this priority**: This is the promise the skill exists to keep, and the one currently broken. A false violation costs the agent a correction cycle on code that was fine; worse, an agent that has seen the noise twice stops reading the hook, so the real findings that follow are discarded too.

**Independent Test**: Start a stack, edit a routed file to confirm validation runs, remove the container, edit again. The second edit must produce a warning naming the stopped service, not a violation naming the file.

**Acceptance Scenarios**:

1. **Given** a cached container that has since been removed, **When** the agent edits a routed file, **Then** the hook reports that the file was not validated, and no text from the Docker daemon reaches the agent as a finding.
2. **Given** that same removed container, **When** the stack is started again and the agent edits a routed file, **Then** validation runs against the new container without any manual cache clearing.
3. **Given** a running container whose validator exits 1 with real findings, **When** the agent edits that file, **Then** the findings reach the agent unchanged — including when the validator's own output opens with a line that looks like a Docker daemon error.
4. **Given** an unreachable Docker daemon, **When** the agent edits a routed file, **Then** the hook warns once that validation is unavailable and stays silent on later edits.
5. **Given** a container that is stopped rather than removed, **When** the agent edits a routed file, **Then** the outcome matches scenario 1.
6. **Given** a routing-table check that communicates only through its exit code, such as a silent pattern search, **When** it fails on the edited file, **Then** the agent receives a violation naming the exit code, not a warning and not silence.
7. **Given** a Docker client that reaches a live daemon but is refused permission on the socket, **When** the agent edits a routed file, **Then** the outcome is a warning, not a violation.

---

### User Story 2 - The runner finds the stack the project actually declares (Priority: P2)

A consumer installs the hook in a repository whose Compose project name comes from `compose.yml` or from the project `.env`, not from the directory name. Validation must run without the consumer discovering, and hand-patching, a name mismatch.

**Why this priority**: The failure is silent and permanent, not intermittent. The consumer sees one warning, assumes the stack is down, and never learns that every edit since has been unvalidated. It is a lower priority than US1 only because the current workaround — an override inside the routing-table markers — works and is documented.

**Independent Test**: In a checkout whose directory name differs from the `name:` in its Compose file, run the runner's own diagnostic and confirm the reported project matches the one the containers carry.

**Acceptance Scenarios**:

1. **Given** a Compose file declaring `name:` and no exported variable, **When** the runner resolves the project, **Then** it resolves the declared name.
2. **Given** a project `.env` setting `COMPOSE_PROJECT_NAME` and no exported variable, **When** the runner resolves the project, **Then** it resolves that value.
3. **Given** an exported `COMPOSE_PROJECT_NAME`, **When** any other source also declares one, **Then** the exported value wins.
4. **Given** none of the three, **When** the runner resolves the project, **Then** it falls back to the sanitized directory basename, as today.
5. **Given** an existing consumer that overrode the resolver inside its routing-table markers, **When** it upgrades the runner, **Then** its override still wins and validation keeps working.
6. **Given** a linked worktree of a repository whose Compose name comes from the Compose file, and a stack running only for the main checkout, **When** the agent edits a file in the worktree, **Then** the hook does NOT validate against the main checkout's container, and says the file was not validated.
7. **Given** a declared name carrying uppercase letters or dots, **When** the runner resolves it, **Then** it matches the label Compose actually writes.

---

### User Story 3 - A maintainer can prove each degradation path without a stack (Priority: P3)

A maintainer changing the runner can run a suite that asserts, for every failure mode in the table above, whether the agent sees a violation, a warning, or nothing.

**Why this priority**: The defect survived because nothing exercised `exec_in` against a container that had ceased to exist. Without this suite the next change to the contract is as unverified as the one being fixed.

**Independent Test**: Run the suite on a machine with Docker and no project stack; every case decides on its own fixture.

**Acceptance Scenarios**:

1. **Given** the suite, **When** a maintainer runs it, **Then** every situation the runner can reach is asserted against an outcome written down in the specification — violation, warning, or silence — and not against a snapshot of current behaviour.
2. **Given** the suite mutates the runner to classify every exit 1 as infrastructure, **When** it runs, **Then** the case covering a validator that legitimately exits 1 fails. The mutation is applied by the suite to a copy of the runner, so the guard is exercised rather than asserted.
3. **Given** a machine with Docker present and no project stack, **When** a maintainer runs the suite, **Then** it decides every case from its own fixtures.

---

### Edge Cases

- A validator whose own output begins with `Error response from daemon:` — a test fixture, or a tool linting Docker logs. Classification must not rest on the message text at all.
- A validator that exits non-zero and prints nothing: a crash, a killed process, or a checker that speaks only in exit codes.
- A live daemon that refuses the client on the socket: neither the container nor the daemon is missing, and the runner cannot exec.
- Docker absent from the path entirely.
- A container that dies between execution and any later observation. Evidence gathered after the fact cannot say whether the validator ran; evidence produced during the execution can.
- Two services in the routing table, one running and one removed: the warning must name the removed one, and the running one must keep validating.
- The time budget already exhausted when a decision is needed: the second Docker call cannot run at all, and the outcome must still be safe.
- A daemon that is down while the routing table names two services: the agent must not receive the same warning twice, and that suppression must not later silence a genuine missing-container warning for one of those services.
- A budget exhausted before the command starts: the temporary output file created by the budget wrapper is currently left behind, one per edit.
- A cached id whose container is now running under a different Compose project, after a rename.
- A linked worktree that resolves the same Compose project as its main checkout. The container's bind mount then holds the main checkout's copy of the edited file, so a pass or a fail describes a file the agent did not write.
- A consumer that shares one stack across checkouts on purpose, and whose validation must keep working.
- A stack started from a subdirectory of the repository, or before the directory was renamed, or reached through a symlinked path: three ways a recorded directory stops matching the runner's own project root.
- More than one Compose file present (`compose.yml`, `compose.yaml`, `docker-compose.yml`, `docker-compose.yaml`): the runner must read the one Compose itself would read.

## Requirements *(mandatory)*

### Functional Requirements

**Classification**

- **FR-001**: The runner MUST establish, at the moment of execution, whether the call reached inside the container. Classification MUST rest on that evidence, not on the exit code and not on the wording of an error message. Exit 1 occurs both when a validator found something and when the container is gone, so the code carries no information; and a validator's own output may legitimately contain a line that reads like a Docker daemon error.
- **FR-002**: When the validator did not run, the outcome MUST be a warning naming the service and stating the file was not validated. It MUST NOT be a violation, and no text produced by Docker itself MUST reach the agent as a finding.
- **FR-003**: When the validator did run and exited non-zero, the outcome MUST be a violation carrying its output, including at exit 1. A validator MAY choose 124, 126 or 127 as its own signal; those codes MUST NOT be claimed by the runner unless the accompanying diagnostic shows the runner itself produced them.
- **FR-004**: When the validator ran and exited non-zero with no output at all, the outcome MUST be a violation stating that the validator exited with that code and said nothing. It MUST NOT be a warning. A check that communicates only through its exit code is a legitimate routing-table entry — a pattern search, a file comparison — and today the runner discards it in silence.
- **FR-005**: Establishing provenance MUST cost zero additional Docker calls on every path, successful or not.
- **FR-005a**: A container that cannot host the provenance evidence MUST keep being validated, by a weaker rule that the agent is told about, rather than stop being validated at all.

**Recovery and causes**

- **FR-006**: The runner MUST distinguish the infrastructure causes it can act on differently: no running container for the service, a daemon or client that cannot be reached or is refused, and anything else. The third bucket MUST exist and MUST be reported, so an unforeseen cause degrades to a warning rather than to a violation. A Docker client absent from the path and a socket permission refusal both land in it today without being named.
- **FR-007**: On "no running container", the runner MUST discard the cached container identifier and resolve again once before deciding. A stack recreated since the last edit MUST validate on the first subsequent edit, with no manual cache clearing and no agent restart.
- **FR-008**: On "daemon unreachable or refused", the runner MUST NOT resolve again, because resolution uses the same unreachable daemon.
- **FR-009**: Warning suppression scope MUST follow the cause. A daemon or client outage warns once for the whole session, since it is not a property of any service. A missing container warns once per service. Neither key MUST suppress the other, so a daemon outage cannot hide a later genuine missing-container warning for a service.
- **FR-010**: When the time budget for an edit is already exhausted at the moment a decision is needed, the runner MUST report that the file was not validated because the budget ran out. It MUST NOT emit a violation, and MUST NOT report the edit as validated.

**Finding the right stack**

- **FR-011**: The runner MUST resolve the Compose project name the way Compose itself resolves it, across every source it can reach and whichever Compose files apply. It MUST obtain that answer by delegating to Compose rather than by reimplementing the precedence, and it MUST record which files Compose reported so the resolution is inspectable instead of inferred. Where delegation is impossible — no Compose file, or Compose fails — it MUST fall back to today's rule and say which rule it used.
- **FR-012**: A resolved name MUST be normalised the way Compose normalises it before it is matched against container labels, so a declared name carrying uppercase letters or punctuation still matches.
- **FR-013**: When it resolves a container, the runner MUST establish that the container's copy of the edited file is this checkout's copy. This check MUST happen at resolution time only, never on the path that reuses a cached identifier, so it costs nothing per edit.
- **FR-014**: The evidence for FR-013 MUST be the mount the validated file is actually read through. The directory Compose was invoked from is NOT that evidence and MUST NOT be used as a checkout test. It is creation metadata: it goes stale on a rename, it differs from the runner's project root whenever Compose was started from a subdirectory, and one path spelled through a symlink or through a platform's private prefix is not equal to itself as a string. Six situations that validate correctly today would be refused by such a test.
- **FR-015**: A consumer that deliberately shares one stack across checkouts MUST keep an explicit way to say so, and that statement MUST bypass FR-013. The existing worktree opt-out already carries that meaning.
- **FR-016**: The rule deciding whether to validate inside a linked worktree MUST be restated for the new resolution. Today it skips only when the project name is exported in the environment, and its stated reason is that the name otherwise comes from the worktree's own directory. FR-011 removes that reason: the dangerous share becomes a name declared in the Compose file with no variable exported, and the current rule would return "validate".
- **FR-017**: Cache invalidation MUST live where the container is executed in, not in the branch that classifies. A routing table that runs a formatter before a validator shares the same execution path, and a formatter that ignores its result MUST NOT leave a dead identifier cached for the validator that follows.
- **FR-018**: The runner MUST state which Compose file it read and which name source it used, on demand, so a consumer can see the resolution rather than infer it. One source stays invisible to any hook and MUST be documented as such: a project name passed on the command line when the stack was started.
- **FR-019**: A consumer override of the project resolver placed inside the routing-table markers MUST keep taking precedence after a runner upgrade, and MUST keep validating rather than being refused by FR-013.

**Honesty of the artefact**

- **FR-020**: The comment stating the exit-code contract MUST match the measured codes, and MUST cite the date and platform of the measurement.
- **FR-021**: The skill MUST ship a test suite covering every situation the runner can reach, each asserted against an outcome written in this specification. The `docker run` usage error is not such a situation; the suite MUST assert only that no path can produce it from an exec.
- **FR-022**: The message shown when a validator exceeds its time budget MUST NOT assert a cause the runner did not establish. Today it tells the agent the tool is too slow for an on-edit hook and should be removed from the routing table, which is wrong whenever the stall came from a loaded machine or a cold start.
- **FR-023**: The runner MUST NOT leave a temporary output file behind on any path, including the path where the budget is exhausted before the command starts.
- **FR-024**: The same correction MUST reach the runner copy consumers install from — the `claude-flow` plugin copy — as a separate change in that repository, because the observed failure happened on a consumer installed from it.

### Key Entities

- **Container cache**: one file per service under the runner's state directory, holding a resolved container identifier. Survives stack recreation, which is why it is the defect's home.
- **Execution provenance**: evidence, produced during the invocation itself, that the validator started inside the container. It is what separates a finding from an infrastructure failure, and it costs nothing because it travels with the call already being made.
- **Exit-code contract**: the mapping from a failed invocation to one of three agent-visible outcomes — violation, warning, silence.
- **Routing table**: the consumer-owned region between the `BEGIN`/`END ROUTING TABLE` markers, preserved across runner upgrades.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Across the five situations where no validator runs — container stopped, container removed, cached id stale, daemon unreachable, socket refused — zero produce a violation attributed to the edited file.
- **SC-002**: Across the test matrix of FR-017, every case where a validator ran and exited non-zero delivers its output to the agent. That matrix includes the adversarial case: a validator exiting 1 whose first output line reads as a Docker daemon error.
- **SC-003**: After a stack is destroyed and recreated, the first subsequent edit validates successfully, with zero manual intervention.
- **SC-004**: In a repository whose Compose project name comes from the Compose file or the project `.env`, validation runs on the first edit after installation, with no hand-patching of the runner.
- **SC-005**: Zero additional Docker calls on every edit that reuses a cached container, successful or not. Extra calls happen only when a container is resolved, or after the validator is known not to have run, and stay inside the edit's existing time budget.
- **SC-005b** *(amended 2026-09-17, after the implementation review)*: one exception is accepted. A **failing** validator in a container with no POSIX shell costs one extra listing. Provenance is unavailable there, and the alternative was classifying by the wording of Docker's error text — which turns an unrecognised wording into a violation about the agent's file. The extra call buys a state-based answer on the only path that cannot have evidence. A successful validation still costs nothing extra, on every container.
- **SC-006**: In a linked worktree whose main checkout holds the only running stack, zero edits are validated against the main checkout's copy of the file, and a consumer that has opted into sharing a stack keeps validating.
- **SC-006a**: Of the six resolution shapes that validate correctly today — Compose file in a subdirectory, `up` run from a subdirectory, a directory renamed after start, a platform private path prefix, a symlinked path, and a deliberately shared stack — six still validate after the change.
- **SC-007** *(amended 2026-09-17)*: The suite covers every reachable situation and runs in **under 120 seconds** on a machine with Docker and no project stack. The original 60 seconds was written against a five-case suite and measured at 3 s; the suite is now 35 cases on two shells, 184 assertions, and measured at 85 s on a host carrying fifteen unrelated containers at load 7.4. About 12 s of that is deliberate sleeping, in the cases that prove a budget is respected and a stall is reported honestly — time that cannot be removed without removing what those cases prove. The criterion is raised rather than the suite trimmed, and the reason is recorded so the next reader knows which was chosen.
- **SC-008**: The plugin copy carries the same correction and passes the same suite. This is verified in that repository against a named revision, not from here, and is a release criterion for the port rather than acceptance for this change.

## Scope: OUT

- `SKILL.md`, `references/`, and the routing tables under `routing/`. A concurrent session owns those files. This feature changes `templates/validate-on-edit.sh` and adds `tests/` under the same skill; those two paths collide with nothing that session holds.
- `GRV-routing-table-ships-factory-e300`, the missing Go routing table. Already resolved by that session.
- Reconciling the three diverged copies of this skill in full. The plugin copy is roughly 1100 lines against 600 here, and carries verbs and a `--capabilities` surface this copy lacks. This feature ports the two defective functions into it and nothing else. Declared as `GRV-static-validation-hooks-skill-da25`.
- (Moved IN by adversarial review round 1, see FR-006b.) Rejecting a container whose Compose labels place its working directory in another checkout was going to stay a manual check. Reading the two extra name sources makes it mandatory: without it this feature would introduce a worse defect than the one it fixes.
- The coverage gap where the agent's shell tool bypasses the hook entirely.

## Assumptions

- Consumers run Docker or a Docker-compatible daemon exposing the same CLI exit codes. Measured on OrbStack only. Docker Desktop and Colima ship the same CLI binary, which is the reason to expect the same codes, but neither was measured. FR-001's two-evidence rule is what keeps a wording difference from turning into a false finding.
- The runner stays a single self-contained bash file with a consumer-owned routing-table region, as the skill's upgrade path depends on that shape.
- The repository constitution governs backend TypeScript and does not apply to this bash runner. No waiver is required, and none is claimed.
- The measured exit codes are a property of the Docker CLI, not of a Compose version, so no Compose version is pinned.
- The two runner copies have diverged, but the two defective functions are byte-identical apart from one test marker in the plugin copy. Verified 2026-09-17. The correction therefore ports without redesign.
- The plugin copy already carries a self-test surface. The suite required by FR-017 lives beside the runner in this repository, and the port reuses it rather than introducing a second harness.
- Containers routed by this hook can run a POSIX shell. They already run linters, so this is not a new requirement, but it is a requirement and the plan must confirm it per routed service.
