# Architecture Rules Library Checklist: Agentic Rules Library

**Purpose**: Unit tests for requirements writing — validate that the feature spec and plan express clear, complete, and testable requirements for the Cursor rules library and SpecKit constitution (not implementation verification).
**Created**: 2026-04-05
**Feature**: [spec.md](../spec.md) · [plan.md](../plan.md)

**Focus**: Standard depth · **Audience**: PR / spec reviewer · **Clusters**: rule completeness, RAG/AST claims, skill traceability, format evolution (`.md` vs `.mdc`)

## Requirement Completeness

- [ ] CHK001 Are requirements defined for every deliverable named in FR-014 (overview + seven rule files + constitution per FR-015), including naming and location? [Completeness, Spec §FR-014–FR-015]
- [ ] CHK002 Are requirements explicit for what each of the seven rules must contain (context, directive, positive/negative examples, enforcement guidance)? [Completeness, Spec §FR-002–FR-003]
- [ ] CHK003 Are skill references required only where the spec says they apply (Rules 3, 4, 5 per FR-004), or is the mapping ambiguous vs User Story 4? [Consistency, Spec §FR-004 vs User Story 4]
- [ ] CHK004 Does the spec define what “public API” means for cross-module communication (services vs events) at a requirements level? [Gap, Spec §FR-013, Edge Cases §shared]
- [ ] CHK005 Are requirements stated for the merge threshold boundary (exactly five domain functions) without ambiguity? [Clarity, Spec §FR-009, Edge Cases]

## Requirement Clarity

- [ ] CHK006 Is “first query attempt” / “first response” in SC-003 defined in a way that could be assessed without a product metric definition? [Clarity, Spec §SC-003]
- [ ] CHK007 Is “self-contained AST nodes” in SC-005 tied to observable characteristics of requirements (e.g., naming, structure) rather than only aspirational wording? [Clarity, Spec §SC-005]
- [ ] CHK008 Are “positive” and “negative” code examples in FR-003 scoped so reviewers know minimum depth (snippet vs full module)? [Clarity, Spec §FR-003]
- [ ] CHK009 Does the spec resolve the file-extension tension between FR-014 (`.md`) and plan/research (`.mdc`) so requirements readers are not misled? [Conflict, Spec §FR-014 vs Plan §Key Decisions]

## Requirement Consistency

- [ ] CHK010 Are User Story 2 expectations (real-time detection) consistent with the passive nature of rule files (documentation) unless another requirement mandates tooling? [Consistency, Spec §User Story 2 vs deliverables]
- [ ] CHK011 Do assumptions about Effect vs fp-ts align across Assumptions, Edge Cases, and FR-008/FR-011? [Consistency, Spec §Assumptions, §Edge Cases, §FR-008/FR-011]
- [ ] CHK012 Is the checklist in `checklists/requirements.md` still valid given later clarifications (FR-014) and plan artifacts? [Consistency, Spec §checklists/requirements.md meta]

## Acceptance Criteria Quality

- [ ] CHK013 Can SC-001 (“under 5 minutes”) be evaluated without defining who performs the task or what “correct structure” enumerates? [Measurability, Spec §SC-001]
- [ ] CHK014 Can SC-002 (“100% of the 7 rules have examples”) be verified independently of subjective judgment about example sufficiency? [Measurability, Spec §SC-002]
- [ ] CHK015 Is SC-006 (“500 lines”) clearly a constraint on each rule file only, excluding overview/constitution, or should it apply to all deliverables? [Ambiguity, Spec §SC-006]

## Scenario Coverage

- [ ] CHK016 Are requirements present for the scenario where skills paths move or a skill is missing from `skills/`? [Coverage, Gap, Dependency §Assumptions]
- [ ] CHK017 Are requirements defined for consumers not using NestJS (partial adoption) or is exclusion fully explicit? [Coverage, Spec §Assumptions]
- [ ] CHK018 Are requirements stated for versioning/distribution of rules across repos beyond the Edge Cases bullet? [Completeness, Spec §Edge Cases]

## Edge Case Coverage

- [ ] CHK019 Is the “exactly five functions” merge rule specified in requirements with the same precision as the Edge Cases narrative? [Consistency, Spec §Edge Cases vs FR-009]
- [ ] CHK020 Are failure/ambiguous outcomes documented when two rules conflict during scaffolding (e.g., Rule 4 merge vs Rule 1 typing granularity)? [Gap, Exception scenario]

## Non-Functional Requirements (as requirements on the spec)

- [ ] CHK021 Are constraints on token/context usage (“RAG-friendly”) expressed as verifiable properties of the written rules (structure, headings, chunk size) rather than only outcomes? [Measurability, Spec §User Story 3, §SC-005–SC-006]
- [ ] CHK022 Is security/privacy explicitly out of scope for this library, or should requirements mention secrets handling in examples? [Gap, NFR]

## Dependencies & Assumptions

- [ ] CHK023 Is the assumption that `skills/` paths remain stable documented as a dependency with a mitigation if it breaks? [Assumption, Spec §Assumptions]
- [ ] CHK024 Are Cursor rule-loading capabilities (`.md` vs `.mdc`, globs) captured as assumptions or as explicit requirements? [Traceability, Spec §Assumptions vs Plan §research]

## Ambiguities & Conflicts

- [ ] CHK025 Does the spec need an explicit decision record when research overrides FR-014 file format? [Traceability, Plan §research vs Spec §FR-014]
- [ ] CHK026 Is “agent-decided” activation (plan) reflected anywhere in functional requirements, or is it plan-only? [Gap, Plan §Architecture vs Spec]

## Notes

- Check items off as completed: `[x]`
- This checklist tests **requirements quality**; it does not verify that Cursor loads rules or that code compiles.
