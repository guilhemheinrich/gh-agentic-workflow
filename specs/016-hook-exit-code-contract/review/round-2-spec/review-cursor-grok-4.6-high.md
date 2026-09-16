The two-evidence rule, the checkout-membership check, and the warning-key scheme still contradict each other. Those three would change the design; the rest is untestable wording sitting on top of them.

---

### 1. FR-001’s two evidences can agree and still be wrong; the restarting case is that input
- location: `specs/016-hook-exit-code-contract/spec.md:106`, `:92`, `:39`
- trigger: a validator whose first line is `Error response from daemon: …` (the edge case already named), running in a stack that is **restarting** — the P1 story at line 39.
- consequence: the original defect returns on the exact story the spec claims to fix.

FR-001 never defines the output shape, never defines the probe, and never fills the 2×2. “Neither alone decides” leaves the off-diagonal cells empty. The diagonal is constructible.

**Both say infrastructure, both wrong (findings lost).**  
`ruff` is replaced by a fixture that prints `Error response from daemon: No such container: foo` then a real diagnostic, and exits 1. `docker exec` ran; the findings exist. Between `exec` returning and the probe, Compose recreates the container (US1: “restarting”). The probe sees the old id gone. Shape matches the table at lines 21–22. Classification: infrastructure. The findings are dropped. The probe proved “this id is not running *now*,” not “the exec that just finished did not run a validator.”

**Both say finding, both wrong (daemon text as a file violation).**  
Container is **paused**. Measured `docker exec` still returns 1; the first line is `Error response from daemon: Container … is paused`. That string is not in the table (lines 21–24). If “shape” is those rows, the output is finding-shaped. Docker’s inspect reports `State.Running=true` for a paused container, so a liveness probe agrees. Classification: finding. The agent is told the file it wrote contains a daemon error.

Reverse TOCTOU is the same bug in the other direction: exec fails because the container is down, the stack comes back before the probe, shape says infra, probe says running, and the unspecified disagreement cell has to pick one. Treat disagreement as a finding and US1 scenario 1 fails while the stack is bouncing. Treat it as infra and the Docker-log linter at line 92 loses findings on a healthy container.

What the probe can prove: Docker’s state at probe time. What can change before the conclusion: running/paused/restarting, daemon reachability, and the identity of a short id from `lookup_cid` (`skills/static-validation-hooks/templates/validate-on-edit.sh:240`, `docker ps -q`). Causality of the exec’s exit is not in that set.

Assumption line 152 says the two-evidence rule is what stops a wording difference from becoming a false finding. Conjunction does the opposite: a Colima/Desktop string that misses the OrbStack patterns fails the shape check, the probe says daemon-down, they disagree, and if disagreement is “not infra” the daemon error is a finding again.

**This changes the design.** A third fact is required (did this exec’s process start inside the container?), or the spec has to pick an explicit unsafe default and drop the “never lost / never faked” promise for the restarting window.

---

### 2. FR-006b’s natural label is not a checkout id, and it collides with SC-005, FR-007, and `VALIDATE_WORKTREE=run`
- location: `specs/016-hook-exit-code-contract/spec.md:115`, `:147`, `:137`, `:69`; `skills/static-validation-hooks/templates/validate-on-edit.sh:417-423`, `:259-262`
- trigger: any consumer whose Compose working directory is not byte-identical to `git rev-parse --show-toplevel`
- consequence: stacks that validate today are refused, or the success path pays an extra Docker call the spec forbids

The spec never names the signal. Line 147 implies `com.docker.compose.project.working_dir`. That label is the cwd of `docker compose up`, not the bind-mount source and not the git root.

| Situation | Label vs this checkout | Today | After FR-006b |
|---|---|---|---|
| Compose file in `infra/`, `up` run from `infra/`, bind `..:/app` | `working_dir` is `infra/`, git root is the repo | lookup by project+service works | refused |
| `cd apps/api && docker compose up` in the same repo | different `working_dir`, same tree | works | refused |
| Stack started, directory renamed, `name:` stable | label still has the old path | FR-006 would keep matching | refused |
| Host path is `/var/…`, Compose stored `/private/var/…` (macOS) | strings differ | works | refused |
| Symlink cwd vs physical git toplevel | strings differ | works | refused |
| `VALIDATE_WORKTREE=run` sharing the main stack | `working_dir` is the main checkout | documented and implemented | refused |

`VALIDATE_WORKTREE=run` is a supported consumer (`validate-on-edit.sh:417-420`). FR-006b “MUST refuse” makes that mode a no-op. US2 scenario 5 / FR-007 say a routing-table override of the resolver still wins **and validation keeps working**. An override that points at a shared stack then dies on the working_dir check. Those requirements cannot all be true.

FR-006b is “**before executing**.” The hot path is one `docker exec` and no lookup (`validate-on-edit.sh:259-262`). An inspect on every edit violates SC-005 (`spec.md:137`: zero extra Docker calls on the success path). Verify only at lookup and the rename edge case at line 98 is missed. Fold the check into `docker ps` filters and the hot path still never re-checks a cached id.

A bind mount that is not the project root is the common case the label does not see: membership of the *cwd* is not membership of the *file*. FR-006b can accept a container whose mount does not contain the edited path, and reject one whose mount does.

**This changes the design.** Either identity is the bind-mount source of the edited file (with a canonicalisation rule), or FR-006b is lookup-time only and SC-005 / `run` / FR-007 are rewritten to match. `working_dir == PROJECT_ROOT` is not a reliable checkout test.

`worktree_decision` is now inverted relative to risk and the spec never mentions it. `auto` skips only when `COMPOSE_PROJECT_NAME` is exported (`validate-on-edit.sh:421`). After FR-006 the dangerous share is `name:` in the Compose file, with that variable unset, so `auto` returns `run`. The comment at lines 409–412 is then false. FR-006b is asked to paper over a skip rule the spec does not update.

---

### 3. FR-004’s split is not decidable from what the runner can currently observe; a third cause lands as a finding
- location: `specs/016-hook-exit-code-contract/spec.md:110`; `skills/static-validation-hooks/templates/validate-on-edit.sh:239-243`, `:267-268`, `:299`, `:328-333`
- trigger: fresh session (no cid cache) with the daemon down; or `docker` missing; or socket permission denied; or a paused container
- consequence: “gone” vs “daemon down” is only even attempted on the hot path, so round 1’s daemon-down-as-stale-cache fix is incomplete

Exit codes cannot split the two causes: stopped, removed, bogus id, and daemon-down are all 1. Output can, but only for the four OrbStack strings in the table. A probe can split “can I talk to Docker?” from “this id is missing,” with the same TOCTOU as finding 1.

The cold path never sees the evidence. `lookup_cid` throws stderr away (`validate-on-edit.sh:242`). Daemon down, docker missing, permission denied, and “no container” all become empty stdout. `exec_in` then returns synthetic 125 (`:268`), and `check` warns “start the stack” under `nocontainer-$_SVC` (`:328-333`). That is the round-1 defect, still on the only path a new session takes.

**Third cause that is neither “container gone” nor “daemon unreachable”: the docker socket is permission-denied (daemon is up; the caller is not in the group).**  
`docker exec` returns 1. The line is `permission denied while trying to connect to the Docker daemon socket`, which is not in the table. Re-resolving cannot help (every docker call fails the same way). A table-driven classifier emits a **finding**. `_run` when `docker` is not on PATH also returns 125 (`:299`) and the agent is told to `make up`. A paused container is a second neither: lookup still finds it, the daemon is fine, re-resolve is a no-op; it lands as a finding under the table strings (finding 1) or as a useless re-resolve-once.

FR-004’s “re-resolving fixes it” is also false for a *stopped* container: `docker ps` will not see it, lookup returns empty, and the stack is not started. Handling can still match US1.5; the causal claim cannot.

**This changes the design** unless lookup is forbidden from discarding stderr and the cause enum includes “docker unusable” as a third arm with its own warning.

---

### 4. No warning-key scheme produces the number FR-004a asks for without violating FR-011
- location: `specs/016-hook-exit-code-contract/spec.md:111`, `:120`, `:50`, `:96`; `skills/static-validation-hooks/templates/validate-on-edit.sh:172-178`
- trigger: routing table names services `api` and `web`; daemon is down; agent edits one file in each
- consequence: the spec asserts both “warn once” and “per-service,” which are different numbers

`warn_once` is one sentinel file per string id (`validate-on-edit.sh:172-178`).

FR-004a and US1.4 and the edge at line 96 want **one** daemon-down warning. FR-011 wants suppression **per-service and per-cause**, which is **two** warnings (`daemon-api`, `daemon-web`).

| Key scheme | Warnings for two services × dead daemon | What it also suppresses |
|---|---|---|
| `daemon` (global) | 1 | a second daemon outage later in the session; satisfies FR-004a; **violates FR-011** |
| `daemon-$_SVC` | 2 | nothing extra; satisfies FR-011; **violates FR-004a / US1.4** |
| `nocontainer-$_SVC` (today, and still the cold path) | 2 | the later *genuine* missing-container warning for that service — the round-1 finding |

There is no key that yields one daemon warning and still warns per service for a missing container, except “global for daemon, per-service for missing.” That scheme is not “per-service and per-cause” as FR-011 is written. The spec currently requires both that scheme and its negation.

**This changes the design.** Pick a number: 1 warning per daemon outage (global daemon key), or 1 per service (and delete “does not warn twice”).

---

### 5. When the budget is already 0, FR-001a forbids the probe and no remaining outcome is safe
- location: `specs/016-hook-exit-code-contract/spec.md:107`; `skills/static-validation-hooks/templates/validate-on-edit.sh:198-211`, `:321-326`
- trigger: `_DEADLINE` is integer seconds, default budget 3. Any exec that returns in the last second, including a slow real `ruff` that exited 1, leaves `remaining_budget == 0`. `with_budget` then does not run the command and returns 124 (`:211`).
- consequence: classification is required and forbidden at the same moment

Three landings, all in conflict with the skill’s promise:

1. Probe skipped, classify on shape alone → contradicts FR-001.
2. Probe skipped, treat as infrastructure → a legitimate 1-from-`ruff` at t=3s is swallowed.
3. The 124 from the skipped probe **replaces** the exec’s 1. `check` already turns 124 into a warning that tells the agent the **tool is too slow and should be removed from the routing table** (`:321-326`). That is a persistent, wrong “fix.”

Integer-second remaining makes this common, not an edge. There is no safe default: one side fakes a finding, the other loses one, the 124 arm trains the agent to delete the linter.

**This changes the design.** Either the probe is reserved time (which breaks “do not extend the wait” / SC-005), or classification without a probe has a named, tested fallback that is **not** the 124 message.

---

### 6. The 125 “unreachable” assertion is green by construction; SC-002 cannot be measured
- location: `specs/016-hook-exit-code-contract/spec.md:85`, `:118`, `:133-134`

**Green by construction:** US3 scenario 1 together with FR-009’s “no runner path may produce 125 from an exec.” Ground truth already says `docker exec` never returns 125. The current, still-broken runner also never produces 125 *from an exec* (it only synthesises 125 from lookup / `command -v`). A suite that asserts that fact passes before this feature exists. It does not test the contract.

US1 scenario 5 is *not* vacuous: an implementation that only matches `No such container` would pass scenario 1 and fail scenario 5. Keep it.

**Unmeasurable as written:** SC-002 (`:134`) — “in 100% of runs, **unchanged from today**.” No baseline of today’s bytes is in the spec or the staged runner. “100%” has no N, no platform, no fixture. SC-001’s “seven failure situations” (`:133`) is also not a list: the table has eight rows, one is declared unreachable, two are successes, and the runner additionally reaches 124, synthetic 125, 126, empty-output-1, and `docker` missing. A tester cannot know when the seven are done.

---

### 7. SC-007 is not verifiable from this repository
- location: `specs/016-hook-exit-code-contract/spec.md:140`, `:146`, `:156-157`

SC-007 requires both runner copies to pass the suite. Scope line 146 puts the plugin copy **out** except “ports the two defective functions … as a separate change in that repository.” REVIEW-CONTEXT stages only this copy. The plugin file is not here; the copies have diverged (1100 vs 600 lines). Even if `check`/`exec_in` were byte-identical, the suite would exercise `warn_once`, `with_budget`, `lookup_cid`, `compose_project`, and `worktree_decision`, which the spec does not claim are identical.

From this workspace SC-007 cannot be evaluated. It is a success criterion on an artifact the spec itself excludes.

---

### 8. Failure modes a reader of the runner still does not find in the spec
- location: `skills/static-validation-hooks/templates/validate-on-edit.sh:242`, `:299`, `:303-309`, `:341-342`, `:321-326`, `:392`, `:409-412`

The ones above are the large holes. These are the ones the file still shows that the spec never names:

- **`fix()` shares `exec_in` and ignores rc** (`:303-309`). If cache invalidation lives only in `check`, a `fix` then `check` routing branch execs a dead id, logs, leaves the cache, then `check` classifies the same stale id. FR-004 talks about “the runner,” but every example is the check arm.
- **Empty output + rc=1 is silence** (`:341-342`). An infra failure whose text did not land in `BUDGET_OUT` is not a warning and not a finding. Not in the cause table.
- **124’s agent-facing text** (`:321-326`) is a product decision (“remove this tool from the routing table”) the spec never constrains. Combined with finding 5 it is the most damaging misclassification the hook can emit.
- **Compose file order is still not a rule.** Line 100 / FR-006 say “the one Compose itself would read.” The staged runner’s only order is `compose.yml` then `compose.yaml` (`:392`). Compose prefers `compose.yaml` when both exist, then merges `compose.override.yml`, and honours `COMPOSE_FILE`. Round 1 asked which file wins; a pointer at Compose is not a fixture. Two files with different `name:` values remain untestable. Also absent: `name: ${VAR}`, quoted scalars, and `-p` from the original `up` (a fifth source the hook cannot see).
- **`worktree_decision` is unmentioned** (finding 2). A reader sees it as the current worktree guard and will implement FR-006 without touching it, which is how the `name:` share leaks.

---

**Design, not wording:** findings 1, 2, 3 (cold path + third cause), 4, 5.  
**Wording / untestable:** 6, 7, Compose-file pointer, “seven situations,” SC-002’s “unchanged from today.”
