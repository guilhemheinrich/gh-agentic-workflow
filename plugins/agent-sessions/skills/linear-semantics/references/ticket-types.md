# Ticket types: which issue to open, and what it must carry

Status: **proposal**. Six issue types, one order of questions to pick one, and a
template body per type in [`../templates/tickets/`](../templates/tickets/). Two
people facing the same piece of work open the same type, and the person who must
answer knows from the ticket alone what is asked of them.

Every example below is made up.

The rules below are also written as data, for a generic model and its Linear
binding, in [`semantics.json`](semantics.json); `linear_deps.py verify` (skill
`linear-atlas`) runs them against an exported project. This page stays the
reference when the two differ.

## The shape of the work

```
project
└─ milestone = a feature                      « Deposit files »
   ├─ Technical task  (complexity 1..3)       the dev tickets, the only ones that merge
   │   └─ Technical task (sub-issue)          a task above 3 is split, as early as possible
   ├─ Bug                                     the problem, described
   │   └─ Technical task (sub-issue)          its fix
   ├─ Proof  Staging                          the human face of the proof
   │   ├─ Proof (sub-issue)                   ONE fact or question
   │   └─ Proof (sub-issue)
   └─ Proof  Prod                             blocked by the Staging Proof
       └─ Proof (sub-issue) …
```

There is **no Feature or Improvement type**: a feature is a milestone, and its
acceptance criteria are the milestone's description. A new capability and a
better one are both a milestone.

## Where the templates live

In Linear, as **workspace-level** templates, so every team sees them. The files
in this skill are the proposal to paste from; once a template exists in Linear,
Linear is the source and edits happen there. A workspace that works in another
language translates the headings and keeps the structure.

| | Workspace template | Team template |
|---|---|---|
| Visible to | every team | one team (and its sub-teams) |
| Can apply | workspace labels only | that team's labels and statuses too |
| Consequence | the Type label must be a **workspace** label | a team can override with its own default |

Only Linear's form templates can make a field required, and only at creation.
A standard template enforces nothing: the creation sequence below ends with a
read-back for that reason.

## Pick the type: ask in this order, stop at the first yes

The order is the rule. An outage that stops the whole team is a Bug first, and a
Blocker only when its cause is out of the team's hands.

| # | Question | Type | Template |
|---|---|---|---|
| 1 | Does something delivered fail to do what was promised? You can cite the promise: a spec, an API contract, a doc, or the behaviour before. | Bug | [`bug.md`](../templates/tickets/bug.md) |
| 2 | Do you need someone outside the team to **do** something: grant an access, deliver a piece of work, intervene? | Blocker | [`blocker.md`](../templates/tickets/blocker.md) |
| 3 | Do you need someone to **tell** you something: a decision, an information? | Question | [`question.md`](../templates/tickets/question.md) |
| 4 | Do we not know yet what to do, and is it ours to find out, within a time-box? | Research | [`research.md`](../templates/tickets/research.md) |
| 5 | Must we show that one thing works on an environment, by running something (a command, a browser session) rather than by writing code? | Proof | [`proof.md`](../templates/tickets/proof.md), sub-issues [`proof-fact.md`](../templates/tickets/proof-fact.md) |
| 6 | Otherwise: work that ends in a merge (a slice of a feature, the fix of a Bug, a version upgrade, debt, tooling, infra, a data migration). | Technical task | [`technical-task.md`](../templates/tickets/technical-task.md) |

## Question or Blocker: what is asked, not how urgent it is

Both wait on someone outside the team. They differ by **what that person must
give back**:

| | Question | Blocker |
|---|---|---|
| The answer is | words: a decision, an information | an act: an access, a deliverable, an intervention |
| It is closed when | the person has answered, in the ticket | the thing has been done and can be checked |
| The person asked is | a decider, who may answer in a sentence | an owner, who must spend time or rights |
| Example | « Which database may the new service use? » | « Create that database on the shared cluster. » |

**Whether it stops the work is not part of the type.** A Question can stop
everything and a Blocker can wait a month. That is said by the **Blocked by**
relation, not by the type. When one situation holds both, open two tickets and
link them: « Who validates the access? » (Question), then « Grant the access »
(Blocker), blocked by the first.

### Addressee: who must answer or act

A Question or a Blocker is created in **the team that must answer or act**, so
it lands in that team's triage; the issues that wait are linked to it. When the
person is outside Linear (a client, a vendor), the ticket stays in the asking
team with an internal owner who chases.

| Addressee | Expected from them | Must be in the ticket |
|---|---|---|
| Product | scope decision, missing spec, arbitration | the question in one sentence, the options, the effect on the client, the date |
| Technical | access, environment, another team's deliverable | the exact action, the account or resource, the delay after which it costs |
| Security / legal | review, compliance validation, contract clause | the scope submitted, the deadline |
| External | an answer or a deliverable from a client or vendor | the contact, the last follow-up date, the plan B |
| Organisation | budget, licence, headcount | the amount or duration, the decider, what waiting costs |

## The six types, with the test that decides each

| Type | Test | Example | Not this type |
|---|---|---|---|
| Bug | can you fill « Expected » by citing a source? | the export returns 500 for an invoice with no line, the API contract says 200 | « there is no CSV export » when nobody promised one (a feature: a milestone) |
| Blocker | can you name who must act, what, and who waits? | the deploy account lacks read access to the prod namespace | a red test on our own code (Bug or Technical task) |
| Question | can you write it in one sentence and name who decides? | « Do we bill at COMPLETED or at ACCEPTED? » | « please do X » (Blocker) |
| Research | is the deliverable a written decision or a proof of concept, never shipped code? | « Which queue library? », half a day, written decision | something someone else will tell us (Question) |
| Proof | is the work to run something and look at the result, with no code to write? | « the invitation opens as an invite in the mail client », on staging | writing the e2e test that will prove it (Technical task) |
| Technical task | does it end in a merge? | upgrade the runtime from Node 20 to 22 | running the upgraded service on staging and reading its version (Proof) |

## Bug: a problem, fixed by Technical tasks

A Bug **describes the problem**; it is never fixed by itself. Its fix is one or
several **Technical tasks, created as its sub-issues**, each with its own
complexity. The Bug is Done when they all are.

Example (made up): Bug « The export fails on an invoice with no line »; sub-issues
« Return an empty file when an invoice has no line » (complexity 1) and « Add the
regression test for the empty invoice » (complexity 1). `linear_deps.py verify`
flags a Bug with no Technical task as a sub-issue (`bug-split-into-tasks`).

## Complexity and splitting

Every Technical task carries a **complexity from 1 to 5**, in Linear's
`estimate` field (set the team's estimation to a scale that allows 1 to 5).
It answers two questions.

**Which model may take the ticket.** The mapping is data, in the binding of
`semantics.json` (`attributes.complexity.model_hints`), never code:

| Complexity | Model advised |
|---|---|
| 1 | haiku |
| 2 to 3 | sonnet |
| 4 to 5 | opus |

It is advice: the agent that picks a model reads it, and may go higher after a
failed attempt. A project edits the table in a rules overlay.

**Whether to split it.** Above **3**, the ticket is split into sub-issues **as
early as possible**, at creation, not when someone picks it up. Example (made
up): « Move invoicing to the new tax engine » at 5 becomes « Extract the tax
interface » (2), « Port VAT rules » (3), « Switch the call sites » (2). A ticket
that really cannot be split says so in a « Complexity » section starting with
« Atomic: » and why (one data migration that must be one merge). Without a
sub-issue or that waiver, `verify` warns (`complexity-max-unsplit`); a missing
complexity is an error (`change-has-complexity`). The threshold, 3, is the
`max` of that rule.

## A feature you can digest

A milestone is a feature, so it stays small enough to read in one sitting. A
milestone that holds **more than 8 dev tickets** is usually cut too coarsely:
`verify` warns (`feature-stays-digestible`), and the move is to split it into
two features, not to shorten the tickets. When you propose a plan or comment on
a project, count the dev tickets per milestone first: that is the cheapest
signal that a cut is wrong. The 8 is the `max` of that rule.

## Proof and delivery as a feature

- A dev ticket is **Done once merged into staging** with the merge pipeline
  green. What happens after the merge is the Proofs' job.
- A **feature is a project milestone**. Its description says what it delivers
  and holds the acceptance criteria. It holds the dev tickets, the Technical
  tasks for infrastructure prerequisites (Helm values, secrets, migrations,
  feature flags) and a **Proof on each environment it concerns**. It is **never
  named after, or split by, an environment**: « Deposit files on staging » and
  « Deposit files on prod » are not two features; the feature is « Deposit
  files », and the environment lives on its Proofs. `verify` raises both as
  **warnings**, never as errors: `feature-not-named-after-environment` and
  `feature-proved-on-each-environment`. The environments are not hardcoded: they
  are the `values` and `aliases` of the `environment` attribute in the binding.
- A feature has **one proof per environment, and it is never partial**: the
  top-level Proof is **blocked by every dev ticket of the milestone**
  (`proof-blocked-by-whole-feature`). A later merge in the same milestone can
  break what held on its own, so we wait until everything is developed, then
  prove. Adding a dev ticket to a proved feature reopens its Proofs, or moves the
  ticket to the next feature. The Prod Proof is blocked by the Staging Proof
  (`prod-proof-after-staging`).
- A **top-level Proof is the human face**: the product owner opens it and reads,
  in a few lines, where we stand and what will be proved. It carries the
  **Environment** label (Staging or Prod, single choice, Proofs only). It does
  **not** hold the observations.
- The observations live in **sub-issue Proofs**, one per **fact or question**.
  Example (made up), on the Staging Proof of « Deposit files »: sub-issue « A PDF
  under 10 MB is accepted » and sub-issue « A PDF over 10 MB is refused with the
  size message ». Never « the deposit accepts and refuses correctly » in one
  ticket: if the title needs « and », it is two sub-issues. A top-level Proof
  without sub-issues is an error (`proof-has-subproofs`) and it cannot be Done
  before its sub-issues are (`done-proof-needs-done-subproofs`). The sub-issues
  inherit the environment from their parent and are not held to the blocking
  rules of the parent.
- A feature is « in staging » when its top-level Staging Proofs are all Done,
  « in prod » when its Prod Proofs are: `verify` prints it per feature
  (`Staging ✔ 1/1   Prod ⧗ 0/1`), so what is in staging and what is in prod
  reads at a glance and cannot drift from what was proved (a milestone name can
  lie, a Done Proof cannot).
- An issue has one milestone and a milestone belongs to one project. A feature
  that spans teams is fine; one that spans projects is not a feature.
- The proof is a **comment on the sub-issue**: a screenshot taken by a Playwright
  or browser session, URL visible; or the command, what it does, its real output,
  the date and the deployed version. A code excerpt is not a proof: it shows the
  code exists, not that it runs.
- An agent can post it through the Linear MCP: `prepare_file_upload`, a `PUT` of
  the raw bytes to the signed URL with the returned headers (it expires after
  60 s, so one file at a time), then `save_comment` with the returned markdown.
  Whoever closes has looked at the proof; by default the agent moves the
  sub-issue to In Review and a human closes the top-level Proof.

If proving something needs code first (an e2e test, a script), that code is a
Technical task, and the sub-issue Proof is blocked by it.

## Every ticket opens with an example in plain words

Whatever the type, the body starts with « In plain words, with an example »:
what the user, the client or the team cannot do or will be able to do, and one
concrete case, for a reader who does not know the technique. Server names,
routes and error codes go in the sections below it.

❌ « Read denied on the prod namespace for the deploy account. »
✅ « Clients still see the old tracking screen: the new version cannot reach
production until the infra team grants us access. »

## Labels

Three **workspace** label groups, so every team and every workspace template can
use them:

- **Type**, single choice: the six types. Each template applies its own, so a
  ticket created from « Bug » carries Bug without anyone adding it.
- **Addressee**, single choice, on Question and Blocker only.
- **Environment**, single choice (Staging, Prod), on top-level Proofs only.

The complexity is not a label: it is Linear's `estimate`.

## Creating a ticket through the Linear MCP

Three traps of `save_issue`:

- a `description` passed with a `template` **replaces** the template body:
  create from the template alone, then fill it with `patch`;
- `labels` **replaces** every label, including the template's: use `addLabels`;
- a link in the description only makes a Related relation: use `blockedBy`.

| # | Step | Call or check |
|---|---|---|
| 1 | Pick the type with the order above | no call |
| 2 | Pick the team: the one that must answer or act, or that owns the work | `list_teams` |
| 3 | Create from the template, no description | `save_issue` with `team`, `title`, `template` |
| 4 | Fill the sections, « In plain words » first | `save_issue` with `id` and `patch` |
| 5 | Type label, and Addressee for Question and Blocker, Environment for a top-level Proof | `addLabels` |
| 6 | Dependencies: a Proof is blocked by every dev ticket of its milestone | `blockedBy` / `blocks` |
| 7 | **Complexity** for a Technical task (split it if above 3); project, milestone; parent for a sub-issue | `estimate`, `project`, `milestone`, `parentId` |
| 8 | Read back; do not conclude while a step is missing | `get_issue` |
