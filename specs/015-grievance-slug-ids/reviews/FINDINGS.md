# Adversarial review — findings ledger

**Round 1** · 2026-08-26 · panel from outside the authoring lineage, via OpenRouter

| Reviewer | Outcome |
|---|---|
| `openai/gpt-5.6-sol` | 6 findings |
| `x-ai/grok-4.6` | 8 findings |
| `google/gemini-3.7-flash` | discarded — leaked its reasoning transcript into the answer and truncated |
| `moonshotai/kimi-k3` | **no usable output after 3 attempts** — twice `finish_reason=length` with an empty completion (the whole output budget spent on reasoning), once `finish_reason=error`. Raising `--max-tokens` from 12k to 30k did not help. Recorded rather than hidden: the panel is 2 lineages, not 3 |

Context sent: spec, plan, tasks, research, data-model, contracts, plus
`grievances.py` in full and `SKILL.md` — 29k tokens. Sending the real source is
what let the panel check the plan's line citations instead of trusting them, and
it is what produced the blocker.

Every finding below was verified against the source before being applied or
rejected. Verification probes ran in `python:3.12-alpine`.

## Applied

| # | From | Severity | Finding | Verification |
|---|---|---|---|---|
| 1 | GPT | **blocker** | The 4-segment cap let two **distinct** descriptions derive one identifier, re-creating the duplicate that makes `Ledger.load` refuse the file. | Confirmed. 3 of 4 probed pairs collided under the cap. Removing the cap fixed 2; the third still collided because the 40-char ceiling truncates regardless. → research D8 |
| 2 | GPT | major | A marker whose identifier fails the block pattern is silently skipped, so the grievance vanishes from the model and the tables while its text stays in the file. | Confirmed. Probed 3 markers, 1 consumed, 2 silently skipped. → research D9, FR-021 |
| 3 | GPT + Grok | major | The length ceiling is enforced nowhere on the read path: the pattern carries no length bound and `Ledger.load` never calls `check_id`. | Confirmed. A 48-character identifier matches the widened pattern. → FR-020 |
| 4 | GPT | major | FR-004 and SC-004 bound **supplied** identifiers to the description, contradicting the escape hatch they exist to provide. | Confirmed by reading the spec. → FR-004a, SC-004 |
| 5 | Grok | major | `--force` no longer works. It skips the duplicate-description guard, and derivation then refuses the identical identifier anyway. | Confirmed at `grievances.py:645`. → `--force` now requires `--id` |
| 6 | Grok | major | A **supplied** `--id` was never checked for uniqueness: the taken-set check lived inside `derive_id`, which that path skips. | Confirmed by reading the planned task. → uniqueness moved out of derivation, applied on both paths |
| 7 | Grok | major | The written algorithm folded to lowercase *before* testing whether a short token is an uppercase acronym — impossible as ordered, and it reproduces the `DB naming` regression. | Confirmed. The probe implementation tested the pre-fold token; only the prose was wrong. → data-model step order corrected |
| 8 | Grok | major | The stop-word set was named but never enumerated, leaving FR-003 determinism unimplementable. Grok added the sharp part: the documented example needs `not`, which the repository's branch-name list does not carry. | Confirmed. The repo list alone yields `GRV-worker-hosted-api-not-scale`, not the documented `GRV-worker-hosted-api-scale`. → 48 base words + a 6-word documented delta |
| 9 | GPT | minor | A task claimed its test "Must FAIL" when nothing in the list would make it fail. | Confirmed by reading the task. → wording corrected |
| 10 | Grok | major | The task text quoted the **unanchored** pattern as the value for `ID_RE`, so an implementer copying it literally would drop the `^…$` anchors. | The code claim was wrong — `ID_RE` is already anchored — but the task wording was genuinely dangerous. → applied on the wording |

## Rejected

| # | From | Claim | Why rejected |
|---|---|---|---|
| 11 | Grok | "Cited line 82 is `COMMIT_RE`, not `ID_RE`; `ID_RE` is at line 83." | **False, and off by one in the opposite direction.** Line 81 is `COMMIT_RE`, line 82 is `ID_RE`. The plan's citation was correct. Verified with `sed -n '78,84p'`. |

## Already handled before the review landed

| # | From | Claim | Status |
|---|---|---|---|
| 12 | Grok | Two surviving tokens that already exceed the ceiling would emit an illegal identifier instead of refusing. | The greedy fill returns fewer than 2 segments and refuses. Probed: `"internationalization misconfiguration"` and a 63-character pair both refuse. |

## What the round cost, and what it bought

Two reviewers, ~29k tokens in each. The blocker alone justified it: without
finding 1, the feature would have shipped claiming to remove a collision while
reintroducing it through a narrower door, and the failure would have surfaced as
an unloadable ledger on someone else's branch.

Findings 5, 6, 7 and 8 are the ones a same-lineage review would most likely have
missed, because each is a consequence of a decision the author had already
accepted as settled.
