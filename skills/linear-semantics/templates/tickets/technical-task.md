# Technical task template: proposal

Workspace-level Linear issue template « Technical task ». Applies the Type label
**Technical task**. Title prefix: none. Semantics and the test that decides
this type: [`../../references/ticket-types.md`](../../references/ticket-types.md).

Work that ends in a merge; showing it running is a Proof's job, and the Proofs belong to the feature (the milestone), not to each task.

**Set the complexity (Linear estimate, 1 to 5) at creation.** It picks the model that may take the ticket and tells whether to split: above 3, split into sub-issues now, or say in a « Complexity » section why it is atomic.

```markdown
## In plain words, with an example

<Why this work, in product terms. E.g. « Node 20 is no longer maintained: we move the service to Node 22 to keep receiving security fixes. »>

## Parent

The Bug it fixes, or the larger Technical task it was split from. « None » for a slice of the feature, debt or tooling.

## Complexity

Only when the estimate is above 3 and the ticket cannot be split: write « Atomic: » and why.

## Specification

Link and version of the spec of DD/MM.

## To do

* …

## Done when

Merged into staging, merge pipeline green. The ticket stops there: showing it running is a Proof's job.
```
