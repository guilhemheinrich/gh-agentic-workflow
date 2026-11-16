# E2E Test Specification: [Title]

**Feature Branch**: `[NNN]-e2e-[description]`
**Created**: [YYYY-MM-DD]
**Status**: Draft
**Source Specs**: [list of source specs]
**E2E Framework**: [Playwright/Cypress, from $E2E_INFRA]

## Context

[Why these E2E tests are needed. Reference to source specs.
Description of user flows covered.]

## User Scenarios & Testing

### User Story 1 - [Title] (Priority: [P0/P1/P2])

[Full user story text, adapted to the E2E context]

**Source**: specs/[XXX-feature]/spec.md
**Why this priority**: [Justification]
**Independent Test**: [How to test this story alone]

**Acceptance Scenarios**:

1. **Given** [context], **When** [action], **Then** [result]
2. **Given** [context], **When** [action], **Then** [result]
[... at least as many as the source spec]

**Edge Cases**:
- [Boundary condition 1] -> [expected behavior]
- [Boundary condition 2] -> [expected behavior]

### User Story 2 - [Title] (Priority: [P0/P1/P2])
[... same structure ...]

## Requirements

### Functional Requirements

- **FR-001**: The E2E test MUST [testable requirement]
- **FR-002**: The E2E test MUST [testable requirement]

### Technical Requirements

- **TR-001**: Tests MUST use `data-testid` for element selection
- **TR-002**: Tests MUST use `test.step()` to decompose scenarios
- **TR-003**: Tests MUST be independent (no shared state between tests)

### Data-TestID Requirements

| Component | `data-testid` attribute | Reason |
|-----------|------------------------|--------|
| [component] | [proposed-testid] | [used in which test] |

## Source Code Policy (CRITICAL)

The source application MUST NOT be modified, except to add `data-testid`
attributes to existing UI components listed above.
No modifications to logic, styles, structure, or behavior.

## Success Criteria

- **SC-001**: [Measurable, technology-agnostic criterion]
- **SC-002**: [Measurable, technology-agnostic criterion]
