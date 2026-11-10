# Bug template: proposal

Workspace-level Linear issue template « Bug ». Applies the Type label
**Bug**. Title prefix: none. Semantics and the test that decides
this type: [`../../references/ticket-types.md`](../../references/ticket-types.md).

Starts from a common Bug template; adds « In plain words » and « Promise ».

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

## Done when

The fix is merged into staging, merge pipeline green, with a test that failed before.

## Recommended proof

Link to the Proof ticket that will show that the reproduction no longer reproduces on staging (a command and its output, or a screenshot), or « none » and why.
```
