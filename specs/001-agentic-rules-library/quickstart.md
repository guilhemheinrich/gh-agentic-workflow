# Quickstart: Agentic Rules Library

## Prerequisites

- A TypeScript/NestJS backend project
- Cursor IDE installed
- fp-ts skills installed in `skills/` (optional, for linked guidance)

## Installation

1. Copy the `.cursor/rules/` directory into your project root:
   ```
   .cursor/rules/
   ├── architecture-overview.mdc
   ├── rule-01-explicit-typing.mdc
   ├── rule-02-semantic-jsdoc.mdc
   ├── rule-03-anti-currying.mdc
   ├── rule-04-pure-domain.mdc
   ├── rule-05-flat-orchestration.mdc
   ├── rule-06-typed-boundaries.mdc
   └── rule-07-module-isolation.mdc
   ```

2. Copy `.specify/memory/constitution.md` from this repo if you use SpecKit planning/review (optional).

3. If you want linked skill examples, copy or symlink the `skills/` directory (e.g. `fp-ts-pragmatic`, `fp-ts-errors`) next to your project **or** adjust relative links inside the `.mdc` files to match your layout.

4. Restart Cursor to pick up new or changed rules.

## Verification

1. Open any `.ts` file in Cursor
2. Ask the agent: "What architecture rules apply to this project?"
3. The agent should respond citing the architecture overview and relevant rules

## Usage

- **Scaffolding**: Ask "Create a new [module-name] module" — the agent follows the rules to generate the correct structure
- **Review**: Write code and the agent flags violations against the 7 rules
- **Learning**: Ask "Explain Rule 4" — the agent loads the rule and linked fp-ts skills

## Rule Summary

| # | Name | Scope | Key Directive |
|---|------|-------|---------------|
| 1 | Explicit Typing | `/domain` | All functions must have explicit input/output types |
| 2 | Semantic JSDoc | `/domain` | File headers + `@description` on every function |
| 3 | Anti-Currying | `/domain` | No deep currying; use named parameter objects |
| 4 | Pure Domain | `/domain` | No NestJS, no DB, no throw; typed errors only |
| 5 | Flat Orchestration | `/application` | Use cases as flat `pipe()` flows |
| 6 | Typed Boundaries | `/infrastructure` | Zod validation at all I/O; tech-prefixed file names |
| 7 | Module Isolation | all layers | No cross-module internal imports |
