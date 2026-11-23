# Proof template: proposal

Workspace-level Linear issue template « Proof ». Applies the Type label
**Proof**. Title prefix: « Proof: ». Semantics and the test that decides
this type: [`../../references/ticket-types.md`](../../references/ticket-types.md).

This is the **top-level Proof**, the one a product owner opens: one per environment of the
feature (the milestone). It is blocked by **every dev ticket of the milestone** (no partial
proof: it waits until everything is developed) and its facts are checked by **sub-issue Proofs**
(template `proof-fact.md`), each answering exactly one fact or one question. It is Done when all
its sub-issues are.

```markdown
## In plain words, with an example

<What is proved, in one sentence a product owner understands. E.g. « On staging, an invitation opens as an invite in the mail app. »>

## What is proved

* Environment: the **Environment** label, Staging | Prod (one value)
* Feature: <the milestone> — this proof is « blocked by » every dev ticket of the feature
* Expected version: <tag, SHA, or « the one of the lot's last merge »>

## Sub-issue Proofs

One sub-issue per fact or question, from `proof-fact.md`. List them here as they are created, with a one-line status, so the owner sees where we stand.

## Where we stand

<Updated by whoever moves a sub-issue: « 3 of 5 facts observed; the 2 left wait for the staging deploy. »>

## Proof

The observations live in the sub-issues, not here. This ticket only carries the summary above.

## Validation

* Proof posted by: <agent or person>
* Validated by: <the person who looked at the proof and closes the ticket>
```
