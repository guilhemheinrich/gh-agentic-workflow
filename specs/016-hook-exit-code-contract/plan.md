# Implementation Plan: The hook's exit-code contract, measured rather than assumed

**Branch**: `016-hook-exit-code-contract` | **Date**: 2026-09-17 | **Spec**: [spec.md](./spec.md)
**Input**: [spec.md](./spec.md), [research.md](./research.md), two adversarial rounds under [review/](./review/)

## Summary

The runner decides whether a failed validation is a finding or an outage by reading an exit code, and the code it expects is one `docker exec` never returns. Every real infrastructure failure returns 1, the same code a validator returns when it found something, so outages arrive at the agent as violations and the container cache is never cleared.

The fix replaces inference with evidence. The invocation carries a nonce printed inside the container immediately before the validator starts. Its presence in the output proves the validator ran; its absence proves it did not. Measured cost: 7 ms and zero additional Docker calls. A single label-filtered `docker ps` then decides which outage occurred, and it runs only after the validator is known not to have run.

Two secondary defects ride along, both in the same two functions: the project name is resolved from two of the four sources Compose reads, and nothing establishes that the resolved container reads this checkout's copy of the file. The second only becomes dangerous once the first is fixed.

## Technical Context

**Language/Version**: bash 3.2 — the runner must run on stock macOS bash, as it does today
**Primary Dependencies**: Docker CLI and Docker Compose v2; a POSIX shell inside each routed container
**Storage**: files under `$TMPDIR/validate-on-edit/<project key>/` — container id cache, warning sentinels
**Testing**: a new self-contained bash suite under `skills/static-validation-hooks/tests/`, driving real throwaway containers
**Target Platform**: developer workstations, macOS and Linux
**Project Type**: a single self-contained shell script shipped as a template, plus its routing tables
**Performance Goals**: no added cost on the path that reuses a cached container; the resolution path may spend about 150 ms, once per service per session
**Constraints**: the consumer-owned region between the `BEGIN`/`END ROUTING TABLE` markers is preserved verbatim across upgrades; the script stays one file
**Scale/Scope**: two functions rewritten, one classifier rewritten, one new test suite, one port to a second repository

## Constitution Check

The repository constitution governs backend TypeScript — explicit type contracts, a pure functional core, NestJS orchestration, typed I/O boundaries. This feature touches a bash template and no TypeScript. **The constitution does not apply. No waiver is claimed and none is needed.**

One principle transfers by analogy and is honoured on purpose: errors are values. The classifier returns a named outcome rather than letting an exit code mean different things in different branches.

## Phase 0 — Research

Complete. [research.md](./research.md) holds every figure this plan rests on, each produced on 2026-09-17 rather than recalled: the `docker exec` exit-code table, the three-way `docker ps` probe, the provenance-nonce measurement including the adversarial case, the Compose name query, and the mount inventory of a live container.

Three questions the adversarial rounds left open were answered by measurement rather than by design argument:

1. **Which Compose file wins, and which name source.** Do not reimplement Compose's precedence. Ask Compose: `docker compose config --format json` returned `broker-pa` in 103 ms for a checkout whose directory is `modelo-broker-pa`, and `docker compose ls --format json` names the exact `ConfigFiles` it read. This also covers the override file and an explicit file list, which a hand-written rule would have to track forever.
2. **What proves a container reads this checkout's file.** Its mounts, not the directory Compose was started from. The live broker container carries `.../modelo-broker-pa/apps/backend -> /app` while its `working_dir` label is the repository root — the two differ, which is exactly why the label fails as an identity test.
3. **How to compare two spellings of one path.** Physically, on both sides. Docker reports mount sources already resolved; the runner resolves its own root the same way.

## Phase 1 — Design

### D1. Provenance: the nonce (FR-001, FR-005)

`exec_in` wraps the validator instead of invoking it directly:

```
docker exec -i <cid> sh -c 'printf "%s" "$1"; shift; exec "$@"' _ "$NONCE" <tool> <args...>
```

`exec` replaces the shell, so the validator keeps the process, its exit code, its stdin and its signal behaviour. Arguments pass as positional parameters, never through a re-quoted command string, so a path containing spaces survives — measured.

**What the nonce proves, stated honestly.** It proves the call reached inside the container and command resolution began. It does **not** prove the validator's own code ran: the shell prints the nonce before resolving the command, so a missing binary also returns it. That is the correct boundary, and it is the one the contract needs. Everything after the nonce is the container's business and is classified by D2; everything before it is Docker's, and is classified by D3.

**Detection is "present anywhere", never "present at the front".** A control run showed the nonce landing after several stderr lines, because Docker carries stdout and stderr separately and their merge order is not stable — one unchanged command, two runs, two orders, with and without the wrapper. `research.md` §2c.

**Stripping removes exactly one occurrence — the first, matched against the exact value injected.** A blanket removal of every occurrence would delete text from a validator whose own output happened to contain the nonce, which loses a finding rather than duplicating one. The first plan draft asserted the opposite and was wrong.

**Behaviour the wrapper changes, and which is accepted.** A shell builtin becomes runnable where a direct exec would fail; a file without a shebang gets interpreted rather than rejected; `PWD` and `SHLVL` differ. All three are permissive rather than restrictive, and routing tables call external binaries. A tool whose name begins with `-` is passed after `--` so no shell can read it as an option.

**The regression this introduces, and its fallback.** A container with a working validator and no POSIX shell works today and would fail entirely. At resolution time the runner therefore probes once for a shell. When there is none, it invokes directly, as today, and classification falls back to matching Docker's own daemon-error signature — weaker, and marked as such in the warning text, but not a loss of service. The diagnostic reports which services are in the fallback.

### D2. Classification (FR-001 to FR-004, FR-006, FR-010)

`check()` stops switching on the exit code alone:

| Evidence | Outcome the agent sees |
|---|---|
| nonce absent | infrastructure — the cause question (D3) |
| killed by the runner's own watchdog | warning: the budget was exhausted |
| nonce present, rc 0 | nothing |
| nonce present, rc 126 or 127, and the output after stripping is the shell's own "not found" diagnostic | warning: the tool is not installed in this service |
| nonce present, rc non-zero, output present after the nonce is stripped | **violation**, carrying that output |
| nonce present, rc non-zero, nothing left after the nonce is stripped | **violation**: "the validator exited N without diagnostics" |

Emptiness is tested **after** stripping, never before. The nonce is itself output; testing before would make every silent validator look like it spoke, and the agent would receive a finding whose entire payload is the marker.

Three rows carry the reversals this round produced.

**A validator may legitimately exit 126, 127 or 124.** The old contract claimed those codes for itself. Now 126/127 only mean "not installed" when the diagnostic accompanying them is the shell's, so a validator choosing 127 as its own signal still reaches the agent.

**Silence is a violation, not a warning.** `grep -q forbidden "$F"` and `cmp -s expected "$F"` are legitimate routing-table checks that speak only through their exit code. The previous draft turned them into warnings, which would have hidden them. The synthesized violation names the code, so the agent sees something happened even when the tool said nothing.

**Budget kills are recognised by the runner's own sentinel**, not by exit 124, which a validator can also return. On the path that delegates to an external timeout utility the two are indistinguishable; that ambiguity is pre-existing, it is named in the runner's comment, and the sentinel path is preferred where both exist.

### D3. Causes and recovery (FR-006 to FR-009)

When the nonce is absent, one label-filtered `docker ps` — the call `lookup_cid` already makes — settles the cause. It is read as a **set**, not as a first line, and its output is consumed whole: today's `head -n1` closes the pipe early, which on a scaled service can end the call in a way that reads as a failed daemon and would, under this design, mute the session.

| `docker ps` | Cause | Action |
|---|---|---|
| fails | daemon unreachable or client refused | warn once for the session, do not resolve again |
| succeeds, empty | no running container for this service | drop the cache, warn once for this service |
| succeeds, candidates that do not include the cached id | the container was replaced | verify candidates through D6, cache the first that passes, retry once |
| succeeds, candidates that include the cached id | the container is alive but the call did not reach inside it | warn once for this service, unclassified |

A scaled service runs several containers, so the cached id can be present *and* others exist. Reading the set rather than a first line removes the non-determinism the current `head -n1` hides.

The fourth row is the exhaustive bucket the spec demands. Docker absent from the path and a socket permission refusal both land in a named outcome instead of falling through to a violation.

Warning keys follow the cause, not the service: `daemon` is session-wide, since a dead daemon is not a property of any one service; `nocontainer-<service>`, `wiring-<service>-<tool>`, `budget-<service>-<tool>` and `unclassified-<service>` stay per service. No key can suppress another.

### D4. Cache invalidation moves into the execution path (FR-017)

Today the recovery lives in the classifier, so a routing branch that formats before it validates leaves a dead id behind for the validator that follows. Invalidation moves into `exec_in`, which both paths share.

### D5. Project name (FR-011, FR-012, FR-018, FR-019)

At resolution time only:

1. a consumer override of the resolver inside the routing-table markers, if present — it wins outright
2. `docker compose config --format json` run from the project root, reading the **top-level** `name`
3. the sanitised directory basename, as today, when there is no Compose file or Compose fails

Compose is asked rather than imitated, so the exported variable, the project `.env`, the `name:` key and an override file are honoured without the runner tracking Compose's precedence rules. Measured: 103 ms, against a basename that is wrong for this very repository (`research.md` §3b).

**The runner's existing JSON extractor cannot be used here.** `extract_json_string` returns the *first* `"name"` in the document (`validate-on-edit.sh:58-80`), and a Compose document can serialise a nested `name` — under `configs`, `networks`, `secrets` — before the project's own. Reading the top-level key specifically is part of this work, not a detail. This is the same shape of defect as the one being fixed: a helper that is right on the documents it was written against and silently wrong on the next one.

**The cache and what invalidates it.** The runner is a fresh process per edit, so "cached for the session" means a file. It lives beside the container-id cache, under the existing state directory keyed on the project root, so two physical checkouts never share one. Beside the value the runner stores a fingerprint: the Compose files Compose reported, their modification times, and the Compose-related variables present in the environment. A fingerprint mismatch re-resolves. Editing a Compose file, exporting a different name, or running two sessions with different Compose environments therefore all re-resolve rather than serving a stale name.

**What this cannot see, stated rather than claimed away.** A file list or a project name passed on the command line when the stack was started is invisible to a hook running in a different environment. The earlier draft said explicit lists were honoured "by construction"; that was wrong. The diagnostic prints the name, its source, and the files Compose reported, and the documentation names this blind spot.

### D6. Checkout identity (FR-013 to FR-016)

At resolution time only, never on the cached path, so the per-edit cost stays zero.

**The test starts from the container path, not from the host path.** The runner already knows the path the validator will be given, after the routing table's prefix stripping. It takes the container's mount table, selects the mount whose destination is the **deepest** prefix of that path, and maps it back to its source. The container is accepted when that source, resolved physically, is the edited file's path or a parent of it.

Starting from the host path is what the first draft did, and it is wrong in both directions. A repository mounted at `/evidence` while the validator reads `/app` would pass although nothing connects them. A named volume mounted over `/app/src`, above a repository mount at `/app`, would also pass while the validator reads the volume's stale copy — the deepest mount wins inside the container, and a source-only test never looks at it.

A destination served by a named or anonymous volume is refused outright: it is not this checkout, whatever its name suggests. The mount table carries the type beside the source and destination, so one `docker inspect` supplies all three.

This decision is measured rather than reasoned. A probe built the exact shadowing case — a checkout bound at `/app`, a named volume over `/app/src` — and confirmed three things: the validator reads the volume's stale copy, the source-only test accepts that container, and the deepest-destination test names the volume (`research.md` §3d).

Explicitly preserved: `VALIDATE_WORKTREE=run` bypasses the check entirely, and a routing-table override of the resolver keeps validating rather than being refused.

`worktree_decision` is restated in the same change. Its current rule skips only when the project name is exported, and its stated reason — that the name otherwise comes from the worktree's own directory — is removed by D5. The new rule rests on D6: in a linked worktree, validate when the resolved container reads this worktree, and skip otherwise.

### D7. Budget, without a reservation (FR-010, FR-022, FR-023)

**No floor is reserved.** The first draft reserved one second so a decision would always be reachable, and both reviewers were right to call that a preference dressed as a finding. The clock is whole seconds (`validate-on-edit.sh:197-201`), the default budget is three, and reserving a third of it would drop a 50 ms validator to protect a 30 ms probe that only ever runs after a failure. Nothing in `research.md` measured a floor, because no measurement asked for one.

What the requirements actually demand is weaker and sufficient: when the runner cannot decide, it warns rather than guesses, and it removes its temporary file. So:

- the budget is spent on the validator, as today;
- when there is no time left before the call, the runner invokes nothing and warns, and never passes zero to an external timeout utility where zero can mean "no limit";
- when there is no time left for the cause probe after a failed provenance check, the outcome is the unclassified warning — the file was not validated, cause unknown. Safe, and honest about what the runner knows.

The existing budget message asserts a cause the runner never established, telling the agent the tool is too slow and should leave the routing table. It is rewritten to report the stall and to name a loaded machine and a cold start beside a genuinely slow tool.

The temporary output file is removed on every path, including the one where the budget was already spent before the command started.

### D8. The test suite (FR-021)

A new `skills/static-validation-hooks/tests/` directory, self-contained: it builds its own throwaway containers carrying Compose labels, so it needs Docker and no project stack. Each case asserts the agent-visible outcome named in the spec, not a snapshot of current behaviour.

The suite is black-box. It never decides for itself which executions are infrastructure, because a suite that did would be a second copy of the classifier, agreeing with the first by construction.

The mutation case names its site and its operator: one textual substitution in a copied runner, turning the nonce test into an unconditional infrastructure verdict. The suite asserts that exactly one site matched — zero or several is a suite failure, not a pass — and then replays the same black-box cases. The case that must then fail is the validator exiting 1 with real findings.

### D9. The port (FR-024)

The plugin copy under `claude-flow` carries the same two defective functions, verified byte-identical apart from one test marker. It is a separate repository and a separate commit, sequenced after the suite is green here.

## Project Structure

```text
specs/016-hook-exit-code-contract/
├── spec.md
├── plan.md
├── research.md
├── tasks.md              # /speckit.tasks output, not created here
├── quickstart.md
└── review/
    ├── round-1-spec/
    ├── round-2-spec/
    └── round-3-plan/     # adversarial review of this plan
```

```text
skills/static-validation-hooks/
├── templates/
│   └── validate-on-edit.sh      # the only shipped file this feature edits
└── tests/                       # new
    ├── run.sh
    ├── cases/
    └── fixtures/
```

Untouched here, owned by a concurrent session: `SKILL.md`, `references/`, `routing/`.

## Risks and regressions

Adversarial round 3 asked what this plan makes worse for some consumer. The honest answer is five things.

| Risk or regression | Why it is acceptable, or what covers it |
|---|---|
| **A container with a validator and no POSIX shell stops working entirely** | The strongest regression in the plan. Covered by the D1 fallback: the runner probes for a shell once per service and invokes directly when there is none, with degraded classification and a warning that says so |
| **A named or synchronised volume setup can be refused** | D6 refuses a destination served by a volume on purpose: it is not this checkout. A consumer who wants it anyway keeps the worktree opt-out |
| **Shell builtins and shebangless files become runnable through the wrapper** | Permissive rather than restrictive, and routing tables call external binaries |
| **A persisted name cache could serve an obsolete value** | Fingerprinted on the Compose files, their modification times, and the Compose environment. A mismatch re-resolves |
| Output cut before the nonce, turning a finding into an outage | The only truncation here is the time budget, and a budget kill is recognised by the runner's own sentinel before the nonce is consulted |
| The nonce appearing in a validator's own output | Per-invocation with a random component, and stripping removes exactly one occurrence of the exact injected value — so a collision costs a duplicated line, never a deleted diagnostic |
| A validator killed in the window between the nonce and `exec` | Reports a violation for a validator that never ran. The only killer here is the budget, which returns its own outcome first |
| The port drifting from this copy | Sequenced after the suite is green, and it reuses the same suite |
