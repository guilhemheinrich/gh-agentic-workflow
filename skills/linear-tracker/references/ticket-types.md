# Ticket types: which issue to open, and what it must carry

Status: **proposal**. Eight issue types, one order of questions to pick one,
and a template body per type in [`../templates/tickets/`](../templates/tickets/).
The point is that two people facing the same piece of work open the same type,
and that the person who must answer knows from the ticket alone what is asked
of them.

The template bodies are written in French because that is the language of the
workspace they were drafted for. Translate the headings when you paste them
into an English-speaking workspace; keep the structure.

Every example below is made up.

## Where the templates live

In Linear, as **workspace-level** templates, so every team sees them. The files
in this skill are the proposal to paste from; once a template exists in Linear,
Linear is the source and edits happen there.

| | Workspace template | Team template |
|---|---|---|
| Visible to | every team | one team (and its sub-teams) |
| Can apply | workspace labels only | that team's labels and statuses too |
| Consequence | the Type label must be a **workspace** label | a team can override with its own default |

Only Linear's form templates can make a field required, and only at creation.
A standard template enforces nothing: the creation sequence below ends with a
read-back for that reason.

## Pick the type: ask in this order, stop at the first yes

The order is the rule. It settles the cases that could be two types: an outage
that stops the whole team is a Bug first, and a Blocage only when its cause is
out of the team's hands.

| # | Question | Type | Template |
|---|---|---|---|
| 1 | Does something delivered fail to do what was promised? You can cite the promise: a spec, an API contract, a doc, or the behaviour before. | Bug | [`bug.md`](../templates/tickets/bug.md) |
| 2 | Do you need someone outside the team to **do** something: grant an access, deliver a piece of work, intervene? | Blocage | [`blocage.md`](../templates/tickets/blocage.md) |
| 3 | Do you need someone to **tell** you something: a decision, an information? | Question | [`question.md`](../templates/tickets/question.md) |
| 4 | Do we not know yet what to do, and is it ours to find out, within a time-box? | Recherche | [`recherche.md`](../templates/tickets/recherche.md) |
| 5 | Will a user or a client get a capability they did not have? | Fonctionnalité | [`fonctionnalite.md`](../templates/tickets/fonctionnalite.md) |
| 6 | Will a user or a client see something they already have change for the better? | Amélioration | [`amelioration.md`](../templates/tickets/amelioration.md) |
| 7 | Must we show that one thing works on an environment, once the lot it belongs to is merged? | Preuve | [`preuve.md`](../templates/tickets/preuve.md) |
| 8 | Otherwise: dev work with no visible change (a slice of a feature, debt, tooling, infra, docs, a data migration). | Tâche technique | [`tache-technique.md`](../templates/tickets/tache-technique.md) |

## Question or Blocage: what is asked, not how urgent it is

Both wait on someone outside the team. They differ by **what that person must
give back**:

| | Question | Blocage |
|---|---|---|
| The answer is | words: a decision, an information | an act: an access, a deliverable, an intervention |
| It is closed when | the person has answered, in the ticket | the thing has been done and can be checked |
| The person asked is | a decider, who may answer in a sentence | an owner, who must spend time or rights |
| Example | « Which database may the new service use? » | « Create that database on the shared cluster. » |

**Whether it stops the work is not part of the type.** A Question can stop
everything and a Blocage can wait a month. That is said by the **Blocked by**
relation, not by the type. When one situation holds both, open two tickets and
link them: « Who validates the access? » (Question), then « Grant the access »
(Blocage), blocked by the first.

### Destinataire: who must answer or act

A Question or a Blocage is created in **the team that must answer or act**, so
it lands in that team's triage; the issues that wait are linked to it. When the
person is outside Linear (a client, a vendor), the ticket stays in the asking
team with an internal owner who chases.

| Destinataire | Expected from them | Must be in the ticket |
|---|---|---|
| Produit | scope decision, missing spec, arbitration | the question in one sentence, the options, the effect on the client, the date |
| Technique | access, environment, another team's deliverable | the exact action, the account or resource, the delay after which it costs |
| Sécurité / juridique | review, compliance validation, contract clause | the scope submitted, the deadline |
| Externe | an answer or a deliverable from a client or vendor | the contact, the last follow-up date, the plan B |
| Organisation | budget, licence, headcount | the amount or duration, the decider, what waiting costs |

## The eight types, with the test that decides each

| Type | Test | Example | Not this type |
|---|---|---|---|
| Bug | can you fill « Attendu » by citing a source? | the export returns 500 for an invoice with no line, the API contract says 200 | « there is no CSV export » when nobody promised one |
| Blocage | can you name who must act, what, and who waits? | the deploy account lacks read access to the prod namespace | a red test on our own code (Bug or Tâche technique) |
| Question | can you write it in one sentence and name who decides? | « Do we bill at COMPLETED or at ACCEPTED? » | « please do X » (Blocage) |
| Recherche | is the deliverable a written decision or a proof of concept, never shipped code? | « Which queue library? », half a day, written decision | something someone else will tell us (Question) |
| Fonctionnalité | can you write « En tant que *rôle*, je peux *action* »? | calendar invitations open as invites in the mail client | a better version of what exists (Amélioration) |
| Amélioration | could the user already do it before? | the existing export gains a VAT column | a new export format (Fonctionnalité) |
| Preuve | can you say in one sentence what is proved and what an observer sees? | « the invitation opens as an invite in the mail client », on staging | « the lot works » (too broad: split it) |
| Tâche technique | none of the seven questions got a yes | send the invitation as a `text/calendar` attachment | anything a user would notice |

## Preuve, and Livraison as a milestone

- A dev issue is **Done once merged into staging** with the merge pipeline
  green. What happens after the merge is the Preuves' job.
- A Preuve proves **one thing on one environment**. A lot that needs five
  proofs has five Preuves.
- **Each Preuve is blocked by every dev issue of its lot**, not only the one it
  seems to prove: a later merge in the same lot can break a proof that held on
  its own. Adding an issue to a lot already proved means reopening its Preuves,
  or moving the issue to the next lot.
- A **Livraison is a project milestone** per lot and per environment
  (« Staging : invitations », « Prod : invitations »). The staging milestone
  holds the dev issues, the Tâches techniques for infrastructure prerequisites
  (Helm values, secrets, migrations, feature flags) and the staging Preuves; it
  reaches 100 % when its last Preuve closes. Prod Preuves are blocked by the
  staging ones. Product owners follow the milestones and open the Preuves.
- The proof is a **comment**: a screenshot with the URL visible, or the command,
  what it does, its real output, the date and the deployed version. A code
  excerpt is not a proof: it shows the code exists, not that it runs.
- An agent can post it through the Linear MCP: `prepare_file_upload`, a `PUT`
  of the raw bytes to the signed URL with the returned headers (it expires
  after 60 s, so one file at a time), then `save_comment` with the returned
  markdown. Whoever closes has looked at the proof; by default the agent moves
  the Preuve to In Review and a human closes it.

## Every ticket opens with an example in plain words

Whatever the type, the body starts with « En clair, avec un exemple »: what the
user, the client or the team cannot do or will be able to do, and one concrete
case, for a reader who does not know the technique. Server names, routes and
error codes go in the sections below it.

❌ « Lecture refusée sur le namespace de prod pour le compte de déploiement. »
✅ « Les clients voient encore l'ancien écran de suivi : la nouvelle version ne
peut pas partir en production tant que l'équipe infra ne nous donne pas
l'accès. »

## Labels

Two **workspace** label groups, so every team and every workspace template can
use them:

- **Type**, single choice: the eight types. Each template applies its own, so a
  ticket created from « Bug » carries Bug without anyone adding it.
- **Destinataire**, single choice, on Question and Blocage only.

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
| 4 | Fill the sections, « En clair » first | `save_issue` with `id` and `patch` |
| 5 | Type label, and Destinataire for Question and Blocage | `addLabels` |
| 6 | Dependencies | `blockedBy` / `blocks` |
| 7 | Estimate, project, milestone | `estimate`, `project`, `milestone` |
| 8 | Read back; do not conclude while a step is missing | `get_issue` |
