# Proof template: proposal

Workspace-level Linear issue template « Proof ». Applies the Type label
**Proof**. Title prefix: « Proof: ». Semantics and the test that decides
this type: [`../../references/ticket-types.md`](../../references/ticket-types.md).

A Proof is an execution, not code: a command, or a Playwright or browser
session that takes the screenshot. Each Proof is blocked by every issue of its
lot, including the code tickets that recommended it, and sits in the lot's milestone.

```markdown
## In plain words, with an example

<What is proved, in one sentence a product owner understands. E.g. « On staging, an invitation opens as an invite in the mail app. »>

## What is proved

* Environment: staging | prod
* Lot: <the milestone> — this proof is « blocked by » every issue of the lot
* Expected version: <tag, SHA, or « the one of the lot's last merge »>

## How to prove it

* Kind of proof: command output | screenshot (Playwright or browser session)
* Path or command: <URL and persona, or the exact command>
* What the command does: <one sentence>
* Expected result: <what must be seen, precisely>
* E.g. `kubectl exec deploy/agenda -- node --version` reads the Node version in the staging pod; expected: `v22.x`.

If proving needs code first (an e2e test, a script), that code is a Technical task, and this Proof is blocked by it.

## Proof

Posted as a comment, one comment per proof:

* Screenshot: the screen on the environment, URL visible.
* Command: the command, what it does, its real output, the date and the deployed version.
* A code excerpt is not enough: it proves the code exists, not that it runs.

## Validation

* Proof posted by: <agent or person>
* Validated by: <the person who looked at the proof and closes the ticket>
```
