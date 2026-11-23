---
name: linear-semantics
description: >-
  What a Linear ticket means, in this workspace: six issue types (Bug, Blocker,
  Question, Research, Proof, Technical task), the order of questions that picks
  one, a template body for each, and the rules around them, written as data in
  `references/semantics.json`. A milestone is a feature (no Feature or
  Improvement type); every Technical task carries a complexity from 1 to 5 that
  both suggests a model (haiku, sonnet, opus, configurable) and forces a split
  above 3; a Bug describes the problem and is fixed by Technical tasks as
  sub-issues; a feature stays small (about 8 dev tickets at most); each feature
  has a Proof per environment, blocked by every dev ticket of the milestone
  (never partial), whose observations live in sub-issue Proofs that each answer
  exactly one fact or question. Use when choosing which ticket type to open,
  setting or reading a complexity, splitting a ticket or a milestone, creating
  Linear templates, planning a feature's proofs, or changing the vocabulary the
  `linear-atlas` check enforces. Triggers on "ticket type", "Linear template",
  "complexity", "complexité", "estimate", "split a ticket", "découper",
  "milestone", "feature", "proof ticket", "sub-issue proof", "preuve staging",
  "preuve prod", "Question or Blocker", "which model for this ticket",
  "semantics.json".
license: Apache-2.0
tags:
  - linear
  - process
  - workflow
---

# Linear semantics: what a ticket means

The full reference is [`references/ticket-types.md`](references/ticket-types.md); the same rules
as data are [`references/semantics.json`](references/semantics.json), which
`linear_deps.py verify` (skill [`linear-atlas`](../linear-atlas/SKILL.md)) runs against a project.

## The shape of the work

A **milestone is a feature**. Its description says what it delivers and holds the acceptance
criteria. It holds **Technical tasks** (the only tickets that merge), **Bugs** (the problem, fixed
by Technical tasks as sub-issues) and **one Proof per environment**. There is no Feature and no
Improvement type.

## The six types: first yes wins

| # | First yes to | Type | Template |
|---|---|---|---|
| 1 | Something delivered breaks a promise you can cite | Bug | [`bug.md`](templates/tickets/bug.md) |
| 2 | Someone outside the team must **do** something | Blocker | [`blocker.md`](templates/tickets/blocker.md) |
| 3 | Someone must **tell** us something | Question | [`question.md`](templates/tickets/question.md) |
| 4 | Ours to find out, within a time-box | Research | [`research.md`](templates/tickets/research.md) |
| 5 | One thing must be shown working on an environment, by running something | Proof | [`proof.md`](templates/tickets/proof.md), [`proof-fact.md`](templates/tickets/proof-fact.md) |
| 6 | Otherwise: work that ends in a merge | Technical task | [`technical-task.md`](templates/tickets/technical-task.md) |

## Complexity and the model

Every Technical task gets a **complexity 1 to 5** (Linear `estimate`) when it is created.

| Complexity | Model advised (`model_hints`, editable in the binding) |
|---|---|
| 1 | haiku |
| 2 to 3 | sonnet |
| 4 to 5 | opus |

Above **3**, split into sub-issues now, so that each lands at 3 or less; a ticket that cannot be
split says « Atomic: » and why in a `Complexity` section. Example (made up): « Move invoicing to the
new tax engine » (5) becomes « Extract the tax interface » (2), « Port VAT rules » (3), « Switch the
call sites » (2): haiku is out of reach, sonnet takes all three. When you pick a model for a ticket,
read `binding.attributes.complexity.model_hints` in `semantics.json`; a failed attempt may go one
level up.

## Features you can digest

More than **8 dev tickets** in one milestone usually means it is cut too coarsely: propose two
features. Count per milestone before commenting on a plan.

## Proofs, per feature, never partial

- One top-level Proof per environment (Staging, Prod), **blocked by every dev ticket of the
  milestone**: no partial proof, it waits until everything is developed. Prod is blocked by Staging.
- The top-level Proof is for the product owner: a little context, what will be proved, where we
  stand. The observations are **sub-issue Proofs, one fact or one question each**: if the title
  needs « and », split it. Example (made up): « A PDF under 10 MB is accepted » and « A PDF over
  10 MB is refused with the size message » are two sub-issues, never « the deposit accepts and
  refuses correctly ».

## Changing the vocabulary

Edit `references/semantics.json` (or write a rules overlay with `linear_deps.py verify --init-rules`):
rule `max` values (`complexity-max-unsplit` 3, `feature-stays-digestible` 8), `model_hints`,
environments. Then `verify` reports against the new vocabulary; the engine and its tests stay in
`linear-atlas`.
