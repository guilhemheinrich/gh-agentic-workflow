# Technical task template: proposal

Workspace-level Linear issue template « Technical task ». Applies the Type label
**Technical task**. Title prefix: none. Semantics and the test that decides
this type: [`../../references/ticket-types.md`](../../references/ticket-types.md).

Work that ends in a merge; showing it running is a Proof's job.

```markdown
## In plain words, with an example

<Why this work, in product terms. E.g. « Node 20 is no longer maintained: we move the service to Node 22 to keep receiving security fixes. »>

## Product issue

Link to the product issue, as parent or « related to ». « None » for debt or tooling.

## Specification

Link and version of the spec of DD/MM.

## To do

* …

## Done when

Merged into staging, merge pipeline green. The ticket stops there: showing it running is a Proof's job.

## Recommended proof

Link to the Proof ticket that will show that it runs on staging (a command and its output, or a screenshot), or « none » and why.
```
