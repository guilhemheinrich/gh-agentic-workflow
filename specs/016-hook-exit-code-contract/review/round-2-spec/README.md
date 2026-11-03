# Adversarial review — round 2, spec

**Date**: 2026-09-17
**Subject**: `spec.md` after round 1, plus `templates/validate-on-edit.sh`
**Panel**: `gpt-5.6-sol-high`, `cursor-grok-4.6-high` — both lanes answered, both carried the real prompt.

**Convergence.** The two models found the same five design axes independently: the two-evidence rule is racy, the working-directory label is not a checkout identity, the cause split is not decidable after the fact, no warning-key scheme satisfies both cardinality statements, and an exhausted budget leaves no safe outcome. Agreement across two vendors on five of eight findings is the signal; the disagreements were in what each added on top.

## Triage

| # | Finding | Source | Verdict | Action |
|---|---|---|---|---|
| 1 | Two post-hoc evidences can agree and both be wrong. A validator printing a daemon-like line, plus a container removed before the probe, classifies a real finding as infrastructure | both | **CONFIRMED, and the remedy adopted** | Design change. Evidence moves from after the fact to during the call: the invocation carries a nonce printed inside the container before the validator starts. Measured: the adversarial case classifies correctly, at 7 ms and zero extra Docker calls (`research.md` §2b) |
| 2 | `com.docker.compose.project.working_dir` is not a checkout identity. Six shapes that validate today would be refused, and `VALIDATE_WORKTREE=run` becomes a no-op | both, grok with the table | **CONFIRMED** | Design change. FR-014 forbids that label as the test; FR-013 moves the check to resolution time so SC-005 holds; FR-015 preserves the opt-out; SC-006a counts the six shapes |
| 3 | The cause split is not decidable from a later observation, and a third cause — socket permission refused — lands as a violation today | both | **CONFIRMED** | FR-006 makes the cause set exhaustive with a named third bucket; provenance decides finding-vs-infrastructure before any cause question arises |
| 4 | No warning-key scheme satisfies both "warn once for a dead daemon" and "keys are per service" | both | **CONFIRMED** | FR-009: scope follows the cause. Daemon outage is session-wide, container absence is per service, neither suppresses the other |
| 5 | With the budget exhausted, no outcome was defined and none of the obvious four is safe | both | **CONFIRMED** | FR-010 names the outcome: not validated, budget exhausted. Never a violation, never reported as validated |
| 6 | A non-zero validator with empty output is discarded in silence today (`validate-on-edit.sh:341`) | gpt-sol | **CONFIRMED in code** | FR-004 added |
| 7 | `fix()` shares the execution path and ignores its result, so a dead identifier survives into the `check` that follows | grok | **CONFIRMED in code** (`:303-309`) | FR-017: invalidation lives in the execution path, not in the classifier |
| 8 | The Compose-file rule points at Compose instead of stating an order; `compose.yaml` wins over `compose.yml`, override files merge, an explicit file list exists, and a name passed at `up` time is invisible to any hook | grok | **CONFIRMED** | FR-011 demands a written rule; FR-018 requires the runner to report its resolution and to document the one invisible source |
| 9 | The budget message asserts a cause the runner never established — it tells the agent to remove the tool from the routing table | grok | **CONFIRMED** | FR-022 |
| 10 | US3 scenario 1 is satisfied by a snapshot of current behaviour; scenario 2 names no mutation mechanism | gpt-sol | **CONFIRMED** | Scenarios rewritten: assertions bind to outcomes written in this spec, and the mutation is applied by the suite to a copy of the runner |
| 11 | SC-002's "100% of runs" cannot be established by a finite suite; SC-001's population was miscounted | gpt-sol | **CONFIRMED** | SC-002 binds to the test matrix; SC-001 counts the five situations where no validator runs |
| 12 | SC-007 cannot be verified from this repository | both | **CONFIRMED** | SC-008: a release criterion for the port, verified in the other repository against a named revision |

Twelve findings, twelve confirmed, five design-changing. None rejected.

## What the round cost and what it bought

Round 1 ran with an empty prompt through a tooling fault and still returned seven confirmed findings from one lane. Round 2 returned twelve from two. The single most valuable output is finding 1's remedy, which was not in the spec and is better than what the spec proposed: it removes a race rather than bounding it, and it is cheaper.

## Convergence call

Phase 1 closes here. A third spec round would re-litigate wording; the remaining open questions are implementation shape — the Compose-file order rule, the mount-identity rule, and the nonce's exact form — and belong to PLAN, where the next adversarial round runs.
