# Tasks: The hook's exit-code contract, measured rather than assumed

**Branch**: `016-hook-exit-code-contract` | **Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

**Blast radius.** One shipped file changes: `skills/static-validation-hooks/templates/validate-on-edit.sh`. It is a template, not executed code in this repository, so no test in this repository exercises it today — which is how the defect survived. The suite built in Phase B is therefore both the test scope and a deliverable. Files owned by a concurrent session — `SKILL.md`, `references/`, `routing/` — are out of scope and must not be edited.

**Test policy.** Each phase is verified by its own cases only. The single full run is T024, at the end, and it is the only task that runs every case.

**Delegation.** Every implementation and test task below is delegated to a sub-agent. The orchestrator writes no runner code.

---

## Phase A — The harness first, so the defect is reproducible before it is fixed

- [ ] **T001** Create `skills/static-validation-hooks/tests/run.sh`: a black-box driver that copies the runner to a temporary directory, writes a routing table per case, and asserts the agent-visible outcome. It never decides for itself what infrastructure means. Exits non-zero on the first failing case unless `--all`.
- [ ] **T002** Create `skills/static-validation-hooks/tests/fixtures/`: a helper that starts a throwaway container carrying `com.docker.compose.project` and `com.docker.compose.service` labels, and tears it down. No project stack required.
- [ ] **T003** [RED] Case `stale-container-reported-as-violation` in `skills/static-validation-hooks/tests/cases/`: resolve, cache, remove the container, edit again. Assert a warning. **Must fail against the current runner** — this is the defect reproduced.
- [ ] **T004** [RED] Case `daemon-unreachable`: point `DOCKER_HOST` at a socket that does not exist. Assert a warning, not a violation. Must fail today.
- [ ] **T005** [RED] Case `validator-exit-1-with-findings`: a validator exiting 1 with output. Assert a violation. **Must pass today** — it is the guard that the fix must not break.
- [ ] **T006** [RED] Case `validator-output-looks-like-a-daemon-error`: exits 1, first line `Error response from daemon: No such container: deadbeef`. Assert a violation. The adversarial case.
- [ ] **T007** [RED] Case `status-only-check`: `grep -q` exiting 1 with no output. Assert a violation naming the code. Must fail today, where it is silence.
- [ ] **T008** Verify Phase A: run T003-T007 only, against the untouched runner, and record the measured outcome of each in `tests/BASELINE.md`. Do not assert the distribution in advance — T005 and T006 are guards expected to be green before and after, the other three are expected red, and a case that lands the other way is information, not a harness bug to work around.

## Phase B — Provenance and classification

- [ ] **T009** Implement the nonce wrapper in `exec_in` (`templates/validate-on-edit.sh`): per-invocation value, `sh -c 'printf …; shift; exec "$@"'`, arguments positional, tool name passed after `--`.
- [ ] **T010** Implement stripping: exactly one occurrence, the first, matched against the exact injected value. Emptiness is tested after stripping.
- [ ] **T011** Rewrite `check()`'s decision table per plan D2. Remove the exit-code arms that claimed 124, 126 and 127 unconditionally; claim 126/127 only when the diagnostic is the shell's own; recognise a budget kill by the runner's own sentinel.
- [ ] **T012** Implement the shell-less fallback: probe once per service at resolution, invoke directly when absent, classify by Docker's error signature, and say so in the warning text.
- [ ] **T013** Verify Phase B: run T003-T007 plus new cases for a missing tool, a shell-less container, and a validator choosing 127 as its own signal. No other case runs.

## Phase C — Causes, recovery, cache

- [ ] **T014** Rewrite the cause decision per plan D3: read the lookup as a set, consume it whole, four outcomes, candidates verified before caching.
- [ ] **T015** Move cache invalidation from `check()` into `exec_in`, so the format path cannot leave a dead identifier for the validation path.
- [ ] **T016** Implement cause-scoped warning keys: `daemon` session-wide, the rest per service, none able to suppress another.
- [ ] **T017** Remove the temporary output file on every path, including the budget-exhausted path, and rewrite the budget message so it stops asserting a cause the runner never established.
- [ ] **T018** Verify Phase C: recovery after a stack is recreated, a scaled service with two containers, a format-then-validate routing branch, two services with one dead daemon, and an exhausted budget. No other case runs.

## Phase D — Finding the right stack

- [ ] **T019** Implement project-name resolution per plan D5: routing-table override, then Compose, then basename. Read the **top-level** `name` — the existing extractor returns the first `"name"` in the document and must not be used here.
- [ ] **T020** Implement the name cache and its fingerprint: the Compose files reported, their modification times, and the Compose environment. A mismatch re-resolves.
- [ ] **T021** Implement the checkout-identity test per plan D6: container path, deepest matching destination, map back to source, compare physically, refuse a volume. Resolution path only.
- [ ] **T022** Restate `worktree_decision` on D6, and preserve both escape hatches: `VALIDATE_WORKTREE=run` and a routing-table override of the resolver.
- [ ] **T023** Verify Phase D: a stack named in the Compose file, a name in the project `.env`, a name with uppercase and dots, a linked worktree sharing its main checkout's stack, the deliberate-sharing opt-out, and the shadowing case — a volume over a subdirectory of a bound checkout. No other case runs.

## Phase E — Honesty of the artefact, and the single full run

- [ ] **T024** Correct the exit-code comment at `templates/validate-on-edit.sh:246` to the measured codes, with the date and platform. Extend the runner's diagnostic to print the resolved project name, its source, the Compose files reported, and which services are in the shell-less fallback.
- [ ] **T025** Implement the mutation case per plan D8: one textual substitution in a copied runner, asserting exactly one site matched, then replaying the black-box cases. Zero or several matches is a suite failure.
- [ ] **T026** **The single full run.** Every case in the suite, on a machine with Docker and no project stack. Record the elapsed time against the 60-second criterion.
- [ ] **T027** Adversarial review round 4, on the implementation diff rather than the documents, with the same two models. Fold or refute each finding in `review/round-4-impl/README.md`.

## Phase F — Ledger and port

- [ ] **T028** Resolve `GRV-stale-cached-container-reported-aa46` in `specs/GRIEVANCES.md` with the implementing commit. Do not re-declare it: it is already committed on `main`. `GRV-routing-table-ships-factory-e300` was resolved by a concurrent session and is not this feature's to close.
- [ ] **T030** Declare the pre-existing defect found in passing: `find_project_root` takes the git top-level, which git answers physically, while the hook payload may carry the symlinked spelling. The runner then skips in silence. Reproduced on a throwaway repository. Outside this feature's scope; it belongs in the ledger, not in this branch's code.
- [ ] **T029** Port the two functions and the classifier to the `claude-flow` plugin copy, in that repository, as its own commit. Run the same suite against it. This is a release criterion for the port, not acceptance for this change.

---

## Dependencies

- T001 and T002 precede every other task.
- T003-T007 precede T009; the suite must be red before the fix.
- T009 and T010 precede T011.
- T014 precedes T016.
- T019 precedes T020 and T021.
- T021 precedes T022.
- T026 requires Phases B, C and D complete.
- T029 requires T026 green.

## Parallelisable

`[P]` T003, T004, T005, T006, T007 — independent cases against the same harness.
`[P]` T019 and T021 — different functions, no shared state.
`[P]` T024's two halves — the comment and the diagnostic.

## Out of scope

`SKILL.md`, `references/`, `routing/` — owned by a concurrent session. Reconciling the three diverged copies of the skill beyond the two functions ported in T029, declared as `GRV-static-validation-hooks-skill-da25`.
