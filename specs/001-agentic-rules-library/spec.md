# Feature Specification: Agentic Rules Library

**Feature Branch**: `001-agentic-rules-library`  
**Created**: 2026-04-05  
**Status**: Draft  
**Input**: User description: "Architecture and AI Rules Library for TypeScript/NestJS/fp-ts backend projects — Vertical Slices + Functional Core / Imperative Shell, optimized for LLM indexing (AST, RAG, Tree-sitter)"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Bootstrap a New Backend Module with AI-Guided Structure (Priority: P1)

A developer creates a new feature module (e.g., "billing") in a TypeScript/NestJS project. They invoke the AI agent (Cursor) and ask it to scaffold the module. The agent reads the Agentic Rules Library and generates a Vertical Slice module skeleton with the correct folder structure (`domain/`, `application/use-cases/`, `infrastructure/persistence/`, `infrastructure/http/`), file naming conventions, and boilerplate JSDoc headers — all conforming to the 7 architecture rules.

**Why this priority**: This is the foundational use case. Without correct scaffolding, all downstream rules (typing, functional core, orchestration) cannot be enforced. This delivers immediate value by eliminating manual setup and ensuring consistency from the first file.

**Independent Test**: Can be fully tested by asking the agent to scaffold a "user" module and verifying the output matches the expected directory tree, file names, and boilerplate content.

**Acceptance Scenarios**:

1. **Given** a project with the rules library installed, **When** the developer asks the agent to "create a new billing module", **Then** the agent generates a complete Vertical Slice directory structure under `src/modules/billing/` with `domain/`, `application/use-cases/`, `infrastructure/persistence/`, and `infrastructure/http/` sub-folders, each containing correctly named starter files.
2. **Given** the generated module, **When** inspecting domain files, **Then** each file includes a JSDoc header explaining its responsibility, and all exported functions have explicit input/output type annotations.
3. **Given** a module with fewer than 5 domain functions, **When** the agent scaffolds it, **Then** `model.ts` and `logic.ts` are merged into a single `[module].domain.ts` file to minimize embedding chunk fragmentation.

---

### User Story 2 - AI Agent Auto-Corrects Code Violating Architecture Rules (Priority: P2)

A developer writes code that violates one of the 7 rules (e.g., uses deep currying in domain logic, adds a NestJS decorator in the domain layer, or imports from another module's internal domain). The AI agent detects the violation in real-time and suggests or auto-applies the correct pattern, citing the specific rule.

**Why this priority**: Rules without enforcement are just documentation. AI-assisted correction transforms the rules from passive reference into an active guardrail, dramatically reducing review cycles.

**Independent Test**: Can be tested by writing code that intentionally violates each rule and verifying the agent flags it and proposes the correct fix.

**Acceptance Scenarios**:

1. **Given** a function in `/domain/billing.logic.ts` that uses `a => b => c => ...` deep currying, **When** the agent analyzes the file, **Then** it flags Rule 3 (Anti-Currying) and suggests refactoring to use a named parameters object `{ a, b, c }`.
2. **Given** a file in `/domain/` that imports `@nestjs/common`, **When** the agent scans imports, **Then** it flags Rule 4 (Pure Functional Core) and suggests moving the NestJS dependency to the infrastructure layer.
3. **Given** a module `billing` that imports from `user/domain/user.model.ts`, **When** the agent detects the cross-module import, **Then** it flags Rule 7 (Module Isolation) and recommends using a public API (service or event) instead.

---

### User Story 3 - Rules are Optimally Indexed for RAG Retrieval (Priority: P3)

When the AI agent's embedding model (`text-embedding-3-small`) indexes the project's codebase, the rules library files and rule-compliant code produce high-quality embedding chunks. The agent retrieves the correct rule or code reference in fewer hops (minimal multi-hop reasoning) when answering architecture questions or generating code.

**Why this priority**: This is the meta-optimization that makes the entire system efficient. If rules and code are not RAG-friendly, the agent loses context or retrieves irrelevant fragments, degrading all other stories.

**Independent Test**: Can be tested by querying the agent with architecture questions ("What are the rules for domain code?", "Show me how to structure a use case") and measuring whether it retrieves the correct rule file and relevant code in its first context window.

**Acceptance Scenarios**:

1. **Given** the rules library is installed and indexed, **When** the developer asks "What should I put in the domain layer?", **Then** the agent retrieves Rule 4 and the relevant domain file conventions in its first response without needing follow-up clarification.
2. **Given** a compliant codebase, **When** the agent searches for "how to handle validation errors", **Then** it retrieves the I/O boundary rule (Rule 6) and the validation skill references (`fp-ts-validation`, `fp-ts-errors`) together, providing a complete answer.
3. **Given** the rules are written with semantic JSDoc anchors and named variables, **When** Tree-sitter parses the files, **Then** each function produces a self-contained AST node with clear semantic boundaries (no cross-file dependency chains needed to understand the function).

---

### User Story 4 - Reference Functional Programming Skills in Rules (Priority: P2)

The rules library cross-references the existing fp-ts skills (`fp-ts-pragmatic`, `fp-ts-errors`, `fp-ts-validation`, `fp-ts-backend`, `fp-ts-async-practical`) so that when the agent applies a rule involving functional patterns, it can load the relevant skill for detailed guidance.

**Why this priority**: The rules define "what" patterns to use (Effect/fp-ts, typed errors, pipe-based orchestration), but the skills explain "how" with code examples. Linking them creates a complete guidance system.

**Independent Test**: Can be tested by verifying each rule that mentions fp-ts/Effect patterns includes a skill reference, and that following the reference loads a valid skill file.

**Acceptance Scenarios**:

1. **Given** Rule 4 (Pure Functional Core) mentions returning typed errors via Effect/fp-ts, **When** the agent reads this rule, **Then** it finds a link to `skills/fp-ts-errors/SKILL.md` and can load it for detailed error handling patterns.
2. **Given** Rule 5 (Flat Orchestration) references `pipe()` for sequential flows, **When** the agent needs to generate a use case, **Then** it follows the link to `skills/fp-ts-pragmatic/SKILL.md` for pipe/flow composition patterns and `skills/fp-ts-async-practical/SKILL.md` for async pipeline patterns.
3. **Given** Rule 6 (Typed Boundaries) mentions Zod validation at I/O boundaries, **When** the agent scaffolds a controller, **Then** it references `skills/fp-ts-validation/SKILL.md` for validation and error accumulation patterns.

---

### Edge Cases

- What happens when a module has exactly 5 domain functions (the threshold for file merging)?
  - Rule 4's merge threshold applies strictly: fewer than 5 → merge; 5 or more → separate files.
- How does the system handle mixed Effect and fp-ts usage in the same project?
  - The rules allow both but Effect is prioritized. The rules should note that mixing within the same module is discouraged; pick one per module.
- What happens when a developer creates a `/shared` domain type that another module's domain depends on?
  - `/shared/domain/` is explicitly allowed as the escape hatch for cross-cutting types. Rule 7 only forbids direct imports between module-specific domain folders.
- How are rules distributed and versioned across multiple projects?
  - Rules are packaged as `.cursor/rules/` files (or `.cursorrules`). Versioning follows the repository's semver. Updates are pulled like any other dependency.

## Clarifications

### Session 2026-04-05

- Q: How should the 7 rule files be organized in `.cursor/rules/`? → A: One file per rule (7 separate `.mdc` files, e.g., `rule-01-explicit-typing.mdc`, `rule-02-semantic-jsdoc.mdc`, …) plus one index file `architecture-overview.mdc` (Cursor frontmatter).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The library MUST define a canonical directory structure for Vertical Slice architecture (`src/modules/[module]/domain/`, `application/use-cases/`, `infrastructure/persistence/`, `infrastructure/http/`) and a `shared/` cross-cutting folder.
- **FR-002**: The library MUST contain 7 distinct architecture rules, each with a unique identifier (Rule 1-7), a context explanation (why), and an actionable directive (what to do/not do).
- **FR-003**: Each rule MUST include positive and negative code examples demonstrating compliant vs. non-compliant patterns.
- **FR-004**: Rules that rely on functional-programming or validation patterns MUST reference the relevant fp-ts skills by relative path (`skills/fp-ts-*/SKILL.md`) so agents can load detailed guidance: Rule 3 (pragmatic style), Rule 4 (errors / backend ports), Rule 5 (pragmatic + async), Rule 6 (validation + errors at I/O boundaries).
- **FR-005**: Rule 1 (Explicit Typing) MUST enforce that all `/domain` functions have explicit input and output type annotations — no `any`, no hidden inference.
- **FR-006**: Rule 2 (Semantic JSDoc) MUST require a file-level JSDoc header and per-function `@description` tags in all `/domain` files, written in natural language for embedding optimization.
- **FR-007**: Rule 3 (Anti-Currying) MUST forbid deep currying (`a => b => c`) and point-free style, requiring named parameters objects and named intermediate variables.
- **FR-008**: Rule 4 (Pure Domain) MUST forbid NestJS dependencies, database access, and thrown exceptions in `/domain` files, requiring typed error returns via Effect or fp-ts.
- **FR-009**: Rule 4 MUST specify a file-merge threshold: if a domain has fewer than 5 pure functions, `model.ts` and `logic.ts` merge into `[module].domain.ts`.
- **FR-010**: Rule 5 (Flat Orchestration) MUST require use cases to be NestJS `@Injectable()` services structured as flat `pipe()` flows: Input → Validation → Logic → Persistence.
- **FR-011**: Rule 6 (Typed Boundaries) MUST require structural validation (Zod or `@effect/schema`) at all I/O entry/exit points (controllers, repositories).
- **FR-012**: Rule 6 MUST enforce technology-prefixed naming for infrastructure files (e.g., `sql_user.repository.ts`, `http_stripe.gateway.ts`).
- **FR-013**: Rule 7 (Module Isolation) MUST forbid imports between modules' internal folders (`domain/`, `application/`, `infrastructure/`), allowing only public API communication (services, events).
- **FR-014**: The rules MUST be delivered as Cursor rule files under `.cursor/rules/` using the `.mdc` format (YAML frontmatter + Markdown body) so activation metadata (`alwaysApply`, `description`, optional `globs`) is supported. Each rule MUST be a separate file (`rule-01-explicit-typing.mdc` through `rule-07-module-isolation.mdc`) plus an index file `architecture-overview.mdc` that summarizes all rules and links to individual files. Plain `.md` rules without frontmatter are optional legacy only.
- **FR-015**: The library MUST include a constitution file (`.specify/memory/constitution.md`) encoding the core architectural principles for SpecKit workflows.

### Key Entities

- **Rule**: An architecture directive with an ID, context, directive text, positive/negative examples, and optional skill references.
- **Module**: A Vertical Slice unit containing domain, application, and infrastructure layers.
- **Skill Reference**: A link from a rule to an fp-ts skill file, providing detailed implementation guidance for the pattern mentioned in the rule.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A developer following the rules can scaffold a new module in under 5 minutes with the correct structure on the first attempt.
- **SC-002**: 100% of the 7 rules have at least one positive and one negative code example.
- **SC-003**: The AI agent retrieves the correct rule when asked about any of the 7 architectural concerns (typing, JSDoc, currying, domain purity, orchestration, boundaries, isolation) on the first query attempt.
- **SC-004**: All rules referencing fp-ts patterns include valid, resolvable links to skill files.
- **SC-005**: Domain code generated following the rules produces self-contained AST nodes parseable by Tree-sitter without requiring cross-file context.
- **SC-006**: No rule file exceeds 500 lines, ensuring each fits within a single RAG embedding chunk.

## Assumptions

- The target audience is developers using Cursor IDE with AI assistance (Claude, GPT, etc.) for TypeScript backend projects.
- The project uses NestJS as the orchestration framework; the rules are opinionated toward this stack.
- Effect is the preferred functional library, with fp-ts as a supported alternative. Both are acceptable, but mixing within the same module is discouraged.
- Zod is the default validation library at I/O boundaries; `@effect/schema` is acceptable when using full Effect stack.
- The rules are designed for monorepo or single-repo backend services, not frontend or full-stack apps.
- The existing fp-ts skills in `skills/` are stable and will not change their file paths or core APIs during this feature's lifecycle.
- Cursor's rule loading system supports `.cursor/rules/*.md` files with frontmatter metadata.
