# Bug template: proposal

Workspace-level Linear issue template « Bug ». Applies the Type label
**Bug**. Title prefix: none. Semantics and the test that decides
this type: [`../../references/ticket-types.md`](../../references/ticket-types.md).

A Bug **describes the problem**; it is not fixed by itself. Its fix is one or several
**Technical tasks, created as its sub-issues** (each with a complexity).

```markdown
## In plain words, with an example

<What the user can no longer do, and one concrete case. E.g. « Exporting an invoice with no line returns an error instead of an empty file. »>

## Promise

<The source that says what should happen: a spec, an API contract, a doc, or the behaviour before. No source, no bug.>

## Steps to reproduce

1. …
2. …

## Expected

What should happen, according to the promise.

## Observed

What actually happens: the exact response or message.

## Environment

* Environment and version:
* URL or screen:
* User / role:

## Impact

Severity, number of users affected, workaround if any.

## Logs / screenshots

## Fix

The Technical tasks that fix it, as sub-issues of this ticket, each with a complexity. The Bug is Done when they all are, with a test that failed before.
```
