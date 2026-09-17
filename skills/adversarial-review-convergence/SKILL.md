---
name: adversarial-review-convergence
description: >-
  Drive a multi-round adversarial review to a decision instead of to an
  ever-larger document. An adversarial panel finds real defects and never
  terminates on its own: every revision adds detail, detail adds attack
  surface, and a reviewer charged to attack will always find something. This
  skill is the method that bounds it — charter the panel against the objective
  rather than the artifact, hand it the settled arbitrations and forbid
  relitigating them, declare a clean verdict a legitimate outcome, collapse
  findings into root causes before revising, read the trend rather than the
  count, and terminate on a checklist rather than on a feeling. Ships the
  charter template with its verdict vocabulary, the round ledger that makes the
  trend visible, and the dispositions contract that forces one verdict per
  finding. Transport-agnostic: run the lanes through cursor-adversarial-review
  or openrouter-adversarial-review. Use when a spec or plan is going through
  more than one round of external review, when round N returns more findings
  than round N-1, when the panel and the author are arguing instead of
  converging, or when deciding whether a review is finished.
tags:
  - llm
  - quality
  - process
  - verification
  - meta
---

# Adversarial Review Convergence

A panel of foreign-lineage models finds defects no self-review reaches. It also
**never terminates on its own**. Every revision adds detail, detail adds attack
surface, and a reviewer charged to be adversarial will always return something.
Left unbounded the method inflates the artifact instead of converging it.

The purpose of the review is an **implementable plan**, not an unfalsifiable
one. Everything below exists to keep that distinction from eroding round by
round.

This skill is transport-agnostic. It says what to put in the charter, how to
read what comes back, and when to stop. How the lanes are actually dispatched
belongs to [cursor-adversarial-review](../cursor-adversarial-review/SKILL.md)
(staged workspace, `path:line` findings, better for code) or
[openrouter-adversarial-review](../openrouter-adversarial-review/SKILL.md)
(pay-per-token, benchmark-ranked catalogue).

## 1. What is in this bundle

| File | Role |
| ---- | ---- |
| `SKILL.md` | The twelve rules, each with the run that produced it. Sections 3–8. |
| `templates/charter.md` | The system prompt, with every slot that must be filled before dispatch. Both lanes get it byte-identical. |
| `templates/round-ledger.md` | One row per round — findings, criticals, convergence, artifact size. Makes the trend readable. |
| `templates/dispositions.md` | One row per finding, exactly one verdict, closing on one `## Conclusion` line. |

## 2. The evidence base

One real run, 2026-09-17: four rounds on one spec plus its plan
(`modelo-broker-pa` spec 200, shared document identity across tenants). Two
lanes, `gpt-5.6-sol-high` and `cursor-grok-4.6-high`, dispatched through
`cursor-review.sh` into a staged ephemeral workspace, so the repository stayed
out of the reviewers' context.

| Round | Artifact | Findings | Criticals | Outcome |
| ----- | -------- | -------- | --------- | ------- |
| spec-1 | spec | 23 | — | blocking ×2 → structural rewrite |
| plan-1 | plan | 22 | 5 | blocking ×2 → three root causes named |
| plan-2 | plan | 29 | 7 | blocking ×2 → measured the data, design shrank |
| plan-3 | plan | 17 | 3 | blocking ×2 → fixed in place, no rewrite |

**The count rose from 22 to 29 after a correct revision.** That is the signal
this method exists to read. The revision answered real findings, the plan grew,
and a bigger plan offers more grip. Reading 29 as "the design got worse" would
have triggered a fourth rewrite of a design that was converging.

Everything in sections 3–8 is a rule that run paid for.

## 3. The twelve rules

### 3.1 — Charter the reviewer against the objective, not the artifact

Rank findings by whether they break the **final goal**, stated in the world
rather than in the document. A missing detail and a production-breaking defect
are not the same class and must not arrive in the same list without a severity
that separates them.

`templates/charter.md` opens on the objective for this reason, and the severity
table beneath it is the only ranking the reviewer is allowed to use.

### 3.2 — Hand over the settled arbitrations, and forbid relitigating them

State the decisions already made, verbatim, and ask whether the artifact
**honours** them — never whether they are wise. Without this the review becomes
a design debate, and a design debate has no end state.

In the real run four arbitrations were listed verbatim. Several findings
correctly reported that the artifact failed to honour one of them, which is
exactly the finding class the rule is meant to preserve.

### 3.3 — Say that a clean verdict is legitimate

The single highest-value sentence in the charter, added at round 4 and kept
verbatim:

> If the plan is implementable with known, stated residual risks, say so
> plainly — a clean verdict is a legitimate outcome and withholding it to
> appear rigorous is a failure of review.

A reviewer with no permission to approve will manufacture an objection. That
sentence is the permission.

### 3.4 — Collapse findings into root causes before revising

29 findings collapsed into three. Answering leaves grows the artifact;
answering roots shrinks it.

One root cause in that run — *what happens to a pre-existing row with no
anchor* — had appeared in every round wearing a different disguise: a read
defect, then a write defect, then a reconciliation defect. Naming it once
removed five separate patches, cut nine migrations to five, and deleted a whole
class of rollout ceremony.

The collapse happens **before** the first edit of the revision. A patch written
against a leaf is a patch that has to be removed later.

### 3.5 — Read the trend, not the count

Track findings and criticals per round, and the artifact's size alongside them.

| Pattern | Reading |
| ------- | ------- |
| Findings rise, criticals fall, artifact grew | Correct revision, more surface. Do not rewrite. |
| Findings rise, criticals rise | The revision answered leaves. Collapse (3.4), then revise. |
| Criticals fall with no rewrite required | Convergence. Go to the termination checklist (§8). |

`templates/round-ledger.md` holds the columns. Recording artifact size in the
same table is what makes a rising count interpretable rather than alarming.

### 3.6 — Make the reviewer and the reviser run queries, not reason about data

Reasoning about data produces plausible findings. Running the query produces
true ones.

Two hypotheses died by measurement in that run — one the reviewer's, one the
orchestrator's. And executing the query the reviewer demanded surfaced two
defects no lane had seen, one of which aborted the migration on the developer's
own database the same day.

The charter says it; the disposition of any data-dependent finding must carry
the query output, not an argument.

### 3.7 — Convergence is the strongest signal available, and still not proof

Two convergent findings were refuted with `file:line`. In one case the artifact
had described its own code wrongly, so both models inherited a false premise
from the document they were given.

The refutation rule follows: **disagreement is not evidence, only `file:line`
is.** Two models agreeing can mean one document misled them both.

### 3.8 — Verify every citation in the artifact

Two consecutive rounds caught a cited database column and a cited HTTP route
that do not exist.

A false citation inside a plan is worse than a missing one: it reads as proof,
and it propagates into the next round's premises — and, per 3.7, into both
lanes at once. The charter names this the most expensive error class, second in
the attack order only to breaking the objective.

### 3.9 — Budget the rounds, and name the last one in its own prompt

Decide the number of rounds before round 1. Then say so in the final dispatch,
verbatim:

> This is the LAST round; after it the pipeline moves to the next phase.
> Anything that is a genuine improvement rather than a production-breaking
> defect must be recorded as a grievance or an explicit note, NOT used to
> justify another rewrite.

The sentence does two things: it changes what the reviewer reports, and it
tells the orchestrator where a `MINOR` finding goes — to
[grievances](../grievances/SKILL.md), not into the plan.

### 3.10 — Cap artifact growth explicitly

In the charter, and in the reviser's own instruction:

> Do not grow the plan. If answering a finding makes a section longer, make
> another shorter.

Past a certain size the artifact's own internal inconsistency becomes the main
defect source. One critical in that run was exactly this: a single load-bearing
procedure described three different ways across three documents.

### 3.11 — Panel mechanics

- **Exclude your own model lineage.** `--exclude-vendor anthropic` when Claude
  wrote the artifact.
- **Both lanes get a byte-identical charter.** Two prompts produce two reviews
  of two different questions, and their convergence means nothing.
- **An empty lane is a gap, never an agreement.** One revision in that run
  correctly refused to read a silent lane as consent. The ledger records
  `2/2`, never a bare finding count.
- **Stage the context as an ephemeral workspace** so the repository stays out
  of the reviewer's window — the review boundary is the context boundary.
- **State in the charter what ambient context is injected anyway** and cannot
  be suppressed: user-level skills, rules and MCP servers reach the lane
  regardless of staging. The charter tells the reviewer to ignore them.

### 3.12 — Verify the panel tool runs before trusting a round

In that run the default dispatcher (`llm-ask.sh`) had no API key in the
environment and exited before any network call. The built-in panel agent uses
the same client, and by contract a degraded round never blocks the phase that
launched it — so the pipeline would have recorded an empty round in silence and
moved on.

**A round that cannot fail loudly is worse than no round.** Before round 1,
prove the transport answers: one throwaway call per lane, asserting a byte that
could only come from the model. Both sibling skills ship a verification step
for exactly this — §3 in each.

## 4. The charter

`templates/charter.md`, with every slot filled. Unfilled slots are the
divergence vector: the reviewer fills them with its own assumption, and the
round is spent arguing about that assumption.

| Slot | What it holds |
| ---- | ------------- |
| Objective | The outcome in the world, not in the document. Rule 3.1. |
| Settled arbitrations | Verbatim decisions. Honoured-or-not, never re-argued. Rule 3.2. |
| Established facts | Measured values the reviewer must not re-derive. Rule 3.6. |
| What to attack | Ordered: objective, false citations, unhandled cases, internal inconsistency, untestable steps. Rules 3.1, 3.8, 3.10. |
| Out of scope | Files, concerns, style, and the ambient context. Rule 3.11. |
| Evidence rules | `path:line`, run the query, `SPECULATIVE` label. Rules 3.6, 3.7. |
| Verdict | One line, from the vocabulary in §5. Rule 3.3. |
| Output format | Numbered findings, severity, target, what is wrong, the failure permitted. |
| Round position | Round N of M, and the last-round paragraph verbatim. Rule 3.9. |

## 5. Verdict vocabulary

One line, first line, from this closed set. Each one obliges the orchestrator to
a different next move.

| Verdict | Means | The orchestrator then |
| ------- | ----- | --------------------- |
| `IMPLEMENTABLE` | No critical. Residual risks are named and accepted. | Closes the review. Runs the termination checklist (§8) and moves to the next phase. |
| `IMPLEMENTABLE WITH FIXES` | Criticals exist and every one is local. | Fixes in place — no rewrite. Spends one more round only if the budget has one left. |
| `NOT IMPLEMENTABLE — ROOT CAUSE: <named>` | The findings collapse to a cause requiring a design change. | Collapses (3.4), revises against the root, re-dispatches. |
| `CANNOT REVIEW — <what is missing>` | Context is absent or self-contradictory. | Fixes the staging and re-dispatches. **Does not consume a round** — nothing was reviewed. |

A lane that returns prose instead of one of these four lines has not followed
the charter, and its round is `CANNOT REVIEW` on the orchestrator's side.

## 6. The round ledger

`templates/round-ledger.md`. Per round: findings, criticals, convergent pairs,
refuted count, lanes answering as `N/N`, verdict, outcome — plus the artifact's
size in a second table.

The ledger is the only place the trend is visible, and the trend is what §3.5
and §8 both read. Append rows; never rewrite one.

## 7. The dispositions contract

`templates/dispositions.md`. One row per finding, exactly one verdict:

| Verdict | Required evidence |
| ------- | ----------------- |
| `accepted` | Where the change landed. |
| `refuted` | `file:line` in the real repository. Nothing else counts (3.7). |
| `routed` | A grievance id or a spec path. Never a promise. |

Convergence is marked per row, and it raises the bar for refutation without
ever lowering it. The table closes on one `## Conclusion` line in the
orchestrator's own words, saying what the round changed and what happens next.

There is no fourth verdict. "Noted", "partially accepted" and "will consider"
are how a review fails to terminate.

## 8. The termination rule

A checklist, not a feeling. Stop when **either** column is satisfied.

| Budget exhausted | Converged |
| ---------------- | --------- |
| The round budget set before round 1 is spent. | ☐ The last round returned **0 criticals**, or only criticals fixed in place. |
| Stop regardless of what the last round said. | ☐ Every critical of the last round has a disposition row. |
| Every open `MAJOR` and `MINOR` is routed to a grievance or a spec. | ☐ No `accepted` finding is still unpatched. |
| The last dispatch carried the last-round paragraph (3.9). | ☐ The artifact did not grow between the last two rounds. |
| | ☐ Every citation in the artifact was verified this round (3.8). |
| | ☐ Both lanes answered — `2/2` in the ledger, not one lane and a silence. |

`CANNOT REVIEW` never counts as a spent round: fix the staging and re-dispatch.

What does **not** terminate a review: a round with no critical but a long
`MINOR` list, an orchestrator's sense that the plan "feels solid", or a lane
that went quiet.

## 9. Anti-patterns

| Anti-pattern | Why it fails |
| ------------ | ------------ |
| Answering findings one by one | Leaves grow the artifact; the next round returns more of them. Collapse first. §3.4. |
| Reading a rising finding count as regression | A correct revision that grows the artifact raises the count by construction. §3.5. |
| Reviewing the artifact without stating the objective | Every detail becomes a defect, because nothing ranks them. §3.1. |
| Letting the panel argue a settled decision | The review becomes a design debate, and a debate has no end state. §3.2. |
| A charter with no permission to approve | The reviewer manufactures an objection to look rigorous. §3.3. |
| Treating two convergent lanes as proof | Both can inherit a false premise from the artifact itself. §3.7. |
| Refuting a finding by disagreeing with it | Only `file:line` refutes. Everything else is two opinions. §3.7. |
| Reasoning about what the data contains | Run the query. Two hypotheses died that way, and the query found two defects no lane had. §3.6. |
| A cited column, route or file nobody checked | Reads as proof, propagates into the next round's premises, misleads both lanes. §3.8. |
| An unbudgeted review | It ends when someone gets tired, and the artifact is at its largest by then. §3.9. |
| Reading a silent lane as agreement | It is a gap. The ledger says `1/2` and the round has no convergence signal. §3.11. |
| Trusting a round from an unverified transport | A degraded dispatcher records an empty round in silence. §3.12. |
| Two lanes, two slightly different prompts | Their convergence means nothing: they answered different questions. §3.11. |
| Feeding the review back to the authoring agent | Two models arguing; nobody decides. |
| Keeping a `MINOR` finding "for the next version" of the plan | It belongs in `specs/GRIEVANCES.md`, with an id. §3.9. |

## 10. See also

- [cursor-adversarial-review](../cursor-adversarial-review/SKILL.md) — the transport this method was developed on: staged ephemeral workspace, `path:line` findings, `--panel N --exclude-vendor`.
- [openrouter-adversarial-review](../openrouter-adversarial-review/SKILL.md) — the same discipline through a pay-per-token gateway, when the reviewer should be picked by benchmark rather than by subscription.
- [grievances](../grievances/SKILL.md) — where every `MINOR` and every out-of-scope `MAJOR` goes, with an id, on the last round.
- [systematic-debugging](../systematic-debugging/SKILL.md) — the same discipline applied to a defect instead of to a document: measure before hypothesising.

---

## Implementation Status

**Method: derived from one complete four-round run and reported as such.
Templates: written here, not yet exercised end to end.**

**What is evidenced.** Sections 2–3 come from a single real review —
`modelo-broker-pa` spec 200, 2026-09-17, four rounds over one spec and one
plan, two lanes per round (`gpt-5.6-sol-high`, `cursor-grok-4.6-high`)
dispatched through `cursor-review.sh` into a staged workspace. The counts in §2
are that run's counts. Each of the twelve rules names the specific event that
produced it: the 22→29 rise after a correct revision (3.5), the root cause that
appeared in every round in a different disguise (3.4), the two convergent
findings refuted at `file:line` because the artifact misdescribed its own code
(3.7, 3.8), the two hypotheses killed by running a query (3.6), and the
dispatcher that exited before any network call (3.12).

**What is one sample.** One run, one repository, one pair of lanes, one
domain. The rules generalise as *procedure*; the numbers do not generalise as
*thresholds*. A four-round budget is what that artifact needed, not a constant.
Nothing here has been measured across repositories, and no claim below that
line is made.

**What is unexercised.** The three templates formalise decisions taken ad hoc
during that run — the charter slots, the four-verdict vocabulary, the ledger
columns including artifact size, and the three-verdict disposition contract.
The run used their content; it did not use these files. The verdict line was
prose in round 1 and a fixed line only from round 3 onward, so the
`CANNOT REVIEW` branch of §5 and §8 is designed, not observed. Expect the slot
list to move on first contact with a second domain.

**No script.** Deliberately. The ledger and the dispositions table are read by
a human deciding whether to spend another round, and a derived number nobody
computed by hand is a number nobody checks. If a script arrives later, it
validates the tables — it does not author them.
