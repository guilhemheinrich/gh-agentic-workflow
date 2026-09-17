# Round ledger — {SPEC ID} {ARTIFACT}

One row per round, appended, never rewritten. The ledger exists so the **trend**
is visible; a single round's count means nothing on its own.

## Rounds

| Round | Artifact | Lanes answering | Findings | Criticals | Convergent | Refuted | Verdict | Outcome |
| ----- | -------- | --------------- | -------- | --------- | ---------- | ------- | ------- | ------- |
| spec-1 | spec.md | 2/2 | 23 | — | 4 | 0 | NOT IMPLEMENTABLE | structural rewrite |
| plan-1 | plan.md | 2/2 | 22 | 5 | 6 | 1 | NOT IMPLEMENTABLE | three root causes named |
| plan-2 | plan.md | 2/2 | 29 | 7 | 8 | 2 | NOT IMPLEMENTABLE | measured the data; design shrank |
| plan-3 | plan.md | 2/2 | 17 | 3 | 5 | 0 | IMPLEMENTABLE WITH FIXES | fixed in place, no rewrite |

Columns, and what each one is for:

- **Lanes answering** — `2/2`, never a bare count. An empty lane is a **gap**,
  not an agreement. A round that ran one lane is a round with no convergence
  signal, and the ledger must say so.
- **Findings** — the total the panel returned, before disposition.
- **Criticals** — the count at `CRITICAL` only. This is the column that decides
  termination; the total is context.
- **Convergent** — pairs of findings, one per lane, naming the same defect.
  Strong signal, not proof (see `Refuted`).
- **Refuted** — findings dismissed with `file:line`, convergent ones included.
  A non-zero number here after a convergent pair is the cheapest available
  warning that the artifact misled both lanes about its own code.
- **Outcome** — what the orchestrator did, in the orchestrator's words.

## Artifact size

| Round | Lines | Delta |
| ----- | ----- | ----- |
| plan-1 | 612 | — |
| plan-2 | 788 | +176 |
| plan-3 | 540 | −248 |

A revision that answers findings and grows the artifact has added attack
surface, and the next round's count will rise for that reason alone. Record the
size so a rising count can be read correctly instead of as "the design got
worse".

## Reading the trend

| Pattern | Reading |
| ------- | ------- |
| Findings rise, criticals fall, artifact grew | The revision was correct. More surface, more grip. Do not rewrite. |
| Findings rise, criticals rise, artifact grew | The revision answered leaves instead of roots. Collapse before revising again. |
| Criticals fall to 0, no rewrite required | Convergence. Terminate per the checklist. |
| Same root cause reappears wearing a new disguise | It was never fixed. Name it once and remove every patch around it. |
| Refuted count rises | The artifact is describing its own code wrongly. Verify every citation before the next round. |
