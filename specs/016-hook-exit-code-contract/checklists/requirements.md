# Specification Quality Checklist: The hook's exit-code contract, measured rather than assumed

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-09-17
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
      — the measured exit-code table is observed behaviour of a dependency, not a design choice; no rule, regex or control flow is prescribed.
- [x] Focused on user value and business needs
      — the user is a coding agent and the person reading its output; the value is a checkpoint that cannot lie in either direction.
- [x] Written for non-technical stakeholders
      — partially. The subject IS a shell runner, so the Context section names files. Every requirement is stated as an outcome.
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
      — SC-005 names "Docker calls", which is the unit of cost for this hook; restating it as latency would be less measurable, not more agnostic.
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
      — Scope: OUT names five exclusions, four of them owned by a concurrent session.
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- Validation iteration 1: two items were rewritten rather than passed.
  - US1 scenario 3 originally read "a validator that exits 1 is reported" — green by construction, since that is today's behaviour. It now pins the property that must SURVIVE the change, and the suite asserts it as a guard (US3 scenario 2).
  - SC-001 originally read "no false violations". Unmeasurable. It now counts against the eight rows of the measured table.
- FR-012 and SC-007 were added after discovering that the consumer where the defect was observed installed from the `claude-flow` plugin copy, not from this repository. A fix landing only here would not reach it.
- Adversarial review round 1: seven findings, seven confirmed, two design-changing. One lane ran with an empty prompt through a tooling fault; see that round's README.
- Adversarial review round 2: twelve findings, twelve confirmed, five design-changing, two lanes converging on five of them. The design changed twice as a result — classification moved from post-hoc evidence to execution-time provenance, and the checkout-identity test moved off the Compose working-directory label.
- Requirement count grew from 12 to 24 across the two rounds. That is the review working, not scope creep: 9 of the 12 additions name a failure the runner already has and the first draft did not see.
- Validation iteration 2 re-checked "requirements are testable": FR-014 and FR-018 are stated as prohibitions on evidence and as an obligation to report, both observable. FR-016 names a rule to restate rather than a behaviour, and is verified by the suite covering the linked-worktree case rather than by reading the rule.
