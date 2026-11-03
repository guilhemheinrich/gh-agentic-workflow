# Adversarial review — round 3, plan

**Date**: 2026-09-17
**Subject**: `plan.md`, with `research.md`, `spec.md` and `templates/validate-on-edit.sh`
**Panel**: `gpt-5.6-sol-high`, `cursor-grok-4.6-high`

**Convergence.** The two lanes ranked the same defects first, independently: D6's identity test accepts the wrong container, D5's cache has no invalidation model, D7's floor is a preference, D2's empty-output row is undefined until "empty" is defined, and D8's mutant is stated as a result rather than as an operation. Both also answered the regression question with overlapping lists. That is the strongest agreement of the three rounds.

## Triage

| # | Finding | Source | Verdict | Action |
|---|---|---|---|---|
| 1 | D6 accepts a container that does not read the edited file. A named volume over `/app/src`, above a checkout bound at `/app`, passes a source-only test while the validator reads the volume's stale copy | both | **CONFIRMED by measurement** — the case was built and reproduced: the validator read `STALE content from the volume`, the source-only test passed, the deepest-destination test named the volume (`research.md` §3d) | Design change. D6 starts from the container path, takes the deepest matching destination, maps it back to its source, and refuses a volume outright |
| 2 | The nonce proves the shell started, not that the validator ran; and a validator may legitimately exit 124, 126 or 127, which D2 claimed for the runner | gpt-sol | **CONFIRMED** | D1 restates what the nonce proves — the call reached inside the container — and D2 only claims 126/127 when the accompanying diagnostic is the shell's own |
| 3 | Stripping every occurrence of the nonce deletes text from a validator whose output contains it. The risk table's claim was backwards | gpt-sol | **CONFIRMED, and it was my error** | Exactly one occurrence, the first, matched against the exact injected value. The risk row is rewritten |
| 4 | A status-only check — `grep -q`, `cmp -s` — communicates through its exit code alone and was turned into a warning | gpt-sol | **CONFIRMED** | Spec reversal: FR-004 now requires a synthesized violation naming the code |
| 5 | Emptiness is undefined until it is said whether it is tested before or after stripping. Before, and every silent validator yields a finding whose payload is the nonce | grok | **CONFIRMED** | D2 states it: after stripping, always |
| 6 | D5 has no invalidation model, and the state directory outlives the agent | both | **CONFIRMED** | A fingerprint over the Compose files, their modification times, and the Compose environment. A mismatch re-resolves |
| 7 | D5 contradicts FR-011, which demanded a hand-written filename order | grok | **CONFIRMED — the spec was wrong, not the plan** | FR-011 rewritten: delegate to Compose and record what it reported, rather than reimplement precedence |
| 8 | The runner's JSON extractor returns the FIRST `"name"`, and a Compose document can serialise a nested one first | grok | **CONFIRMED in code** (`validate-on-edit.sh:58-80`) | D5 names reading the top-level key as part of the work. It is the same shape of defect as the one being fixed |
| 9 | D7's floor is unmeasured, taxes the path SC-005 protects, and no requirement asks for it | both | **CONFIRMED** | **The floor is dropped.** When the runner cannot decide, it warns. That is what FR-010 actually demands |
| 10 | D3's four rows are not a partition; a scaled service can match two, and `head -n1` closes the pipe early | both | **CONFIRMED** | D3 reads the output as a set and consumes it whole |
| 11 | D8 states the mutant as a result, not as an operation, so a faithful suite risks re-encoding the classifier | both | **CONFIRMED** | D8 names the site, the operator, and requires exactly one match |
| 12 | A container with a validator and no POSIX shell works today and would fail entirely | gpt-sol | **CONFIRMED** | D1 gains a fallback: probe for a shell once per service, invoke directly when absent, classify by signature, and say so |
| 13 | Preference presented as measurement: D7, and D6's parent heuristic | grok | **CONFIRMED for both** | D7 dropped; D6 replaced and then measured (`research.md` §3d). The Compose figure and the mount inventory moved into `research.md`, where grok correctly noted they were missing |

Thirteen findings, thirteen confirmed, six design-changing. None rejected.

## What this round changed most

Grok's answer to "what does this plan make worse" is the sentence worth keeping: *the current runner's bug is noisy, and several of the replacements were silent wrongness or total mute.* A plan that trades a false violation for a silent non-validation has not improved the contract. Three decisions were cut or reversed on that ground — the budget floor, the source-only identity test, and the warning for status-only checks.

## Convergence call

Phase 2 closes here. Across three rounds: 32 findings, 32 confirmed, 13 design-changing, none rejected. The design is now measured on every point the reviewers challenged, and two of my own claims were refuted by my own probes — the nonce is not a prefix, and source-only membership accepts the wrong container.
