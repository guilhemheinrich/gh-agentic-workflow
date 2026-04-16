---
name: eslint-solid-nestjs
description: "ESLint Flat Config standard for TypeScript/NestJS monorepos — enforces SOLID principles, Clean Architecture layer boundaries, and best practices via static analysis."
risk: safe
date_added: "2026-04-12"
tags:
  - eslint
  - typescript
  - nestjs
  - solid
  - clean-architecture
  - boundaries
  - linting
  - monorepo
---

# ESLint SOLID & NestJS — Standard Configuration

Reference ESLint configuration (Flat Config v9+) for a TypeScript/NestJS monorepo.
It enforces SOLID principles and Clean Architecture layer isolation through static analysis.

## When to Use This Skill

- When bootstrapping a new NestJS project or package in the monorepo
- When configuring or updating ESLint for a TypeScript backend
- When verifying that architecture respects boundaries (controller → service → domain)
- When reviewing code and ensuring SOLID compliance
- When adding a new vertical-slice module and verifying isolation

## Global Strategy

### Why These Plugins?

| Plugin | Role | SOLID Principle Covered |
|--------|------|------------------------|
| `@eslint/js` | Base JS rules (recommended) | Quality baseline |
| `typescript-eslint` | Strict TS + type-checked rules | SRP (complexity), LSP (strict types) |
| `eslint-plugin-import-x` | Import sorting, cycle detection, unused imports | DIP (dependency control) |
| `eslint-plugin-boundaries` | Architectural layer isolation | DIP + ISP (boundaries) |
| `eslint-plugin-promise` | Async/Promise best practices | Async code reliability |

### SOLID → ESLint Rules Mapping

#### S — Single Responsibility Principle (SRP)

Static analysis cannot "understand" that a class has two responsibilities, but it can detect **symptoms** of an SRP violation:

| Rule | Threshold | Justification |
|------|-----------|---------------|
| `complexity` | max 15 | High cyclomatic complexity = too many logical paths |
| `max-lines-per-function` | max 60 (excluding blanks/comments) | Long function = likely multi-responsibility |
| `max-lines` | max 300 per file | Large file = module to split |
| `max-params` | max 4 | Too many parameters = function does too much |
| `max-depth` | max 4 | Deep nesting = logic to extract |

> **Pragmatic trade-off**: These thresholds are guardrails, not absolutes. Configuration files, DTOs with many fields, or barrel files (`index.ts`) may legitimately exceed them. Targeted overrides are used for these cases.

#### O — Open/Closed Principle (OCP)

Difficult to verify through linting alone. Relies on:
- Strict TypeScript typing (`noImplicitAny`, `strictNullChecks`) which forces thinking in terms of extensible interfaces.
- `@typescript-eslint/no-explicit-any` forbids `any` — pushes toward generic types.

#### L — Liskov Substitution Principle (LSP)

Primarily covered by the TypeScript compiler (`strict: true`). ESLint reinforces with:
- `@typescript-eslint/no-unsafe-*` (assignment, call, member-access, return) — prevents circumventing the type system.
- `@typescript-eslint/consistent-type-assertions` — limits dangerous casts.

#### I — Interface Segregation Principle (ISP)

Not directly verifiable through linting. Encouraged via:
- `max-params` (limits contract surface area).
- Boundaries that force narrow interfaces between layers.

#### D — Dependency Inversion Principle (DIP)

The most **actionable** principle for ESLint:

1. **`eslint-plugin-boundaries`**: Defines layers (`domain`, `application`, `infrastructure`, `shared`) and forbids imports in the wrong direction.
2. **`no-restricted-imports`**: Forbids direct imports of concrete infrastructure classes from domain.
3. **`import-x/no-cycle`**: Detects circular dependencies that violate inversion.

### Layer Architecture and Boundary Rules

```text
┌─────────────────────────────────────────────────────┐
│                    infrastructure/                    │
│  (controllers, repositories, gateways, DTOs)         │
│  ✅ Can import: application, domain, shared          │
│  ❌ Controller CANNOT import another Controller      │
├─────────────────────────────────────────────────────┤
│                    application/                       │
│  (use-cases, orchestration services)                 │
│  ✅ Can import: domain, shared                       │
│  ❌ CANNOT import: infrastructure                    │
├─────────────────────────────────────────────────────┤
│                    domain/                            │
│  (models, logic, ports/interfaces)                   │
│  ✅ Can import: shared/domain only                   │
│  ❌ CANNOT import: application, infra                │
├─────────────────────────────────────────────────────┤
│                    shared/                            │
│  (cross-cutting types, shared clients)               │
│  ✅ Can import: shared only                          │
│  ❌ CANNOT import: specific modules                  │
└─────────────────────────────────────────────────────┘
```

### Honest Limitations of the Approach

| Principle | ESLint Coverage | Comment |
|----------|-----------------|---------|
| SRP | ⚠️ Partial | Detects symptoms (size, complexity), not semantics |
| OCP | ❌ Weak | The TS compiler does the heavy lifting |
| LSP | ⚠️ Partial | TS strict + no-unsafe-* covers common cases |
| ISP | ❌ Weak | Indirectly encouraged by max-params and boundaries |
| DIP | ✅ Good | Boundaries + no-restricted-imports + no-cycle |

## Reference Configuration Files

### Main Configuration

The main ESLint configuration file is at:

📄 [`references/eslint.config.ts`](./references/eslint.config.ts)

This is an **ESLint Flat Config** (v9+) file in TypeScript format. It contains:
- The strict + type-checked TypeScript baseline
- SRP rules (complexity, sizes)
- Import rules (sorting, cycles, unused)
- Async/Promise rules
- The `eslint-plugin-boundaries` configuration for layer isolation
- Overrides for special files (tests, DTOs, config)

### Detailed Boundaries Configuration

For projects that want a finer or modular boundaries configuration:

📄 [`references/boundaries.config.ts`](./references/boundaries.config.ts)

This file extracts the `eslint-plugin-boundaries` configuration into a separate, reusable, and documented module. It defines:
- Architectural element types (domain, application, infrastructure, shared)
- The authorized import matrix between layers
- NestJS-specific rules (controller ↛ controller)

## npm Dependencies

```bash
npm install -D \
  eslint@^9.37.0 \
  @eslint/js \
  typescript-eslint \
  eslint-plugin-import-x \
  eslint-plugin-boundaries \
  eslint-plugin-promise \
  globals \
  jiti
```

> `jiti` is needed if you use `eslint.config.ts` (TypeScript) instead of `eslint.config.mjs`.
> Since ESLint v9.7+, native `.ts` config support is experimental via `--flag unstable_ts_config`, but `jiti` remains the most reliable method.

### Tested Versions

| Package | Version | Notes |
|---------|---------|-------|
| `eslint` | ^9.37.0 | Native Flat Config, `.ts` config support |
| `typescript-eslint` | ^8.x | Unified `tseslint.configs.*` API |
| `eslint-plugin-import-x` | ^4.16.0 | Maintained fork of `eslint-plugin-import`, native flat config |
| `eslint-plugin-boundaries` | ^5.x | Flat config support |
| `eslint-plugin-promise` | ^7.x | Flat config support |
| `globals` | ^16.x | Global definitions (node, browser) |

## Installation Workflow

### 1. Install Dependencies

```bash
npm install -D eslint @eslint/js typescript-eslint eslint-plugin-import-x eslint-plugin-boundaries eslint-plugin-promise globals jiti
```

### 2. Copy the Configuration

Copy `references/eslint.config.ts` to the project root (or the package root in a monorepo).

### 3. Add npm Scripts

```json
{
  "scripts": {
    "lint": "eslint .",
    "lint:fix": "eslint . --fix"
  }
}
```

### 4. Configure tsconfig for Linting

Ensure `tsconfig.json` (or a dedicated `tsconfig.eslint.json`) includes all files to lint:

```json
{
  "extends": "./tsconfig.json",
  "include": ["src/**/*.ts", "test/**/*.ts", "eslint.config.ts"]
}
```

### 5. Adapt Boundaries to Your Layout

If your project uses a layout different from the canonical one (`src/modules/<feature>/{domain,application,infrastructure}`), adapt the patterns in the `boundaries/elements` section of the config.

## Customization

### Adjusting SRP Thresholds

If default thresholds are too strict for your team, start with more permissive values and tighten progressively:

```typescript
// Phase 1: soft adoption
rules: {
  'complexity': ['warn', { max: 20 }],           // warn instead of error
  'max-lines-per-function': ['warn', { max: 80 }],
  'max-lines': ['warn', { max: 400 }],
}

// Phase 2: enforcement (after cleanup)
rules: {
  'complexity': ['error', { max: 15 }],
  'max-lines-per-function': ['error', { max: 60 }],
  'max-lines': ['error', { max: 300 }],
}
```

### Adding a Vertical-Slice Module

When adding a new module `src/modules/<new-feature>/`, no additional configuration is needed: the `eslint-plugin-boundaries` glob patterns automatically match the `modules/*/domain`, `modules/*/application`, etc. structure.

### Monorepo with Multiple Packages

In a monorepo (Nx, Turborepo), you can:
1. Place the base config at the root
2. Extend in each package with specific overrides

```typescript
// packages/my-api/eslint.config.ts
import baseConfig from '../../eslint.config.ts';

export default [
  ...baseConfig,
  {
    // package-specific overrides
  }
];
```

## Resources and Documentation

| Resource | URL |
|----------|-----|
| ESLint Flat Config (v9) | https://eslint.org/docs/latest/use/configure/configuration-files |
| typescript-eslint | https://typescript-eslint.io/ |
| typescript-eslint Shared Configs | https://typescript-eslint.io/users/configs/ |
| eslint-plugin-import-x | https://github.com/un-ts/eslint-plugin-import-x |
| eslint-plugin-boundaries | https://github.com/javierbrea/eslint-plugin-boundaries |
| eslint-plugin-promise | https://github.com/eslint-community/eslint-plugin-promise |
| ESLint complexity rule | https://eslint.org/docs/latest/rules/complexity |
| ESLint max-lines rule | https://eslint.org/docs/latest/rules/max-lines |
| ESLint no-restricted-imports | https://eslint.org/docs/latest/rules/no-restricted-imports |
