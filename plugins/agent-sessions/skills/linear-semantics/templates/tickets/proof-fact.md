# Proof fact template: proposal

Workspace-level Linear issue template « Proof fact ». Applies the Type label
**Proof**. Title prefix: « Proof: ». It is created as a **sub-issue of a top-level Proof**.
Semantics: [`../../references/ticket-types.md`](../../references/ticket-types.md).

One sub-issue answers **exactly one fact or one question**. If the title needs « and », it is two
sub-issues. An agent usually runs it: a command, or a Playwright or browser session that takes the
screenshot.

```markdown
## In plain words, with an example

<The one fact or question, in one sentence. E.g. « On staging, an invitation opens as an invite in the mail app. »>

## How to prove it

* Kind of proof: command output | screenshot (Playwright or browser session)
* Path or command: <URL and persona, or the exact command>
* What it does: <one sentence>
* Expected result: <what must be seen, precisely: one observation>

If proving needs code first (an e2e test, a script), that code is a Technical task, and this sub-issue is blocked by it.

## Proof

Posted as one comment:

* Screenshot: the screen on the environment, URL visible.
* Command: the command, what it does, its real output, the date and the deployed version.
* A code excerpt is not enough: it proves the code exists, not that it runs.

## Verdict

<Observed as expected | Not as expected, and what was seen instead>
```
