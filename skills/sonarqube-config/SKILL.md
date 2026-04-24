---
name: sonarqube-config
description: >-
  Write and maintain sonar-project.properties files for local SonarScanner CLI
  analysis. Covers analysis scope (exclusions, test detection), copy-paste
  detection exclusions, coverage report paths, rule suppression strategies, and
  language-specific examples. Use when creating or editing
  sonar-project.properties, configuring SonarQube analysis scope, excluding
  files from scan, ignoring SonarQube rules, or setting up local sonar-scanner.
tags:
  - ci-cd
  - sonarqube
  - testing
---

# SonarQube Configuration — sonar-project.properties

How to write a correct, maintainable `sonar-project.properties` for **local SonarScanner CLI** analysis.

## File Location

Place `sonar-project.properties` at the **project root** (same level as `package.json`, `pom.xml`, `build.gradle`, etc.). The scanner reads it automatically when invoked from that directory.

## Structure Template

```properties
# ──────────────────────────────────────────────
# Project identity
# ──────────────────────────────────────────────
sonar.projectKey=<org>_<project-name>
sonar.projectName=<Human-Readable Name>

# ──────────────────────────────────────────────
# Connection (local scanner — OK as env vars or in compose.yml)
# ──────────────────────────────────────────────
# sonar.host.url and sonar.token are typically passed via CLI flags
# or environment variables. They do NOT go to production — the scanner
# runs locally or in CI only.
#   npx sonar-scanner \
#     -Dsonar.host.url=$SONAR_HOST_URL \
#     -Dsonar.token=$SONAR_TOKEN

# ──────────────────────────────────────────────
# Source layout
# ──────────────────────────────────────────────
sonar.sources=src
sonar.tests=src
sonar.test.inclusions=**/*.spec.ts,**/*.test.ts,**/*.spec.tsx,**/*.test.tsx

# ──────────────────────────────────────────────
# Encoding
# ──────────────────────────────────────────────
sonar.sourceEncoding=UTF-8

# ──────────────────────────────────────────────
# Exclusions  (see sections below)
# ──────────────────────────────────────────────
sonar.exclusions=
sonar.cpd.exclusions=
sonar.coverage.exclusions=

# ──────────────────────────────────────────────
# Coverage reports
# ──────────────────────────────────────────────
sonar.javascript.lcov.reportPaths=coverage/lcov.info
```

---

## Key Properties Reference

| Property | Purpose |
|---|---|
| `sonar.sources` | Directories containing main (non-test) source code |
| `sonar.tests` | Directories containing test source code |
| `sonar.test.inclusions` | Glob patterns to **identify** test files within `sonar.tests` |
| `sonar.exclusions` | Glob patterns to **remove** source files from analysis entirely |
| `sonar.test.exclusions` | Glob patterns to remove test files from analysis |
| `sonar.cpd.exclusions` | Glob patterns excluded from **copy-paste detection** only |
| `sonar.coverage.exclusions` | Glob patterns excluded from **coverage computation** only |
| `sonar.javascript.lcov.reportPaths` | Path(s) to LCOV coverage reports (comma-separated) |
| `sonar.issue.ignore.multicriteria` | Named criteria to suppress specific rules on matching files |

---

## Glob Pattern Syntax

Patterns are relative to `sonar.projectBaseDir` (project root by default).

| Pattern | Meaning |
|---|---|
| `*` | Zero or more characters (excluding `/`) |
| `**` | Zero or more directory segments |
| `?` | Exactly one character (excluding `/`) |

**Examples:**

| Pattern | Matches |
|---|---|
| `**/*.spec.ts` | All `.spec.ts` files at any depth |
| `**/*.test.{ts,tsx}` | All `.test.ts` and `.test.tsx` files |
| `**/test/**` | Everything under any `test/` directory |
| `**/migrations/**` | All migration files |
| `packages/api-client/src/generated/**` | All generated API client code |
| `**/node_modules/**` | All `node_modules` (usually auto-excluded via `.gitignore`) |

---

## Excluding Test Files from Analysis

**Goal**: Tests should not trigger code smells, duplication warnings, or coverage complaints.

### Strategy 1: `sonar.tests` + `sonar.test.inclusions` (recommended)

Declare test source roots and identify test files by pattern. SonarQube treats them as test code (different rule set, excluded from coverage gate).

```properties
sonar.sources=src
sonar.tests=src
sonar.test.inclusions=**/*.spec.ts,**/*.test.ts
```

### Strategy 2: `sonar.exclusions` (nuclear option)

Completely remove files from analysis — they won't appear at all in SonarQube.

```properties
sonar.exclusions=**/*.spec.ts,**/*.test.ts,**/test/**,**/tests/**,**/__tests__/**
```

### Strategy 3: Combined (best for monorepos)

```properties
sonar.sources=src
sonar.tests=src
sonar.test.inclusions=**/*.spec.ts,**/*.test.ts,**/*.spec.tsx,**/*.test.tsx

# Keep tests out of duplication and coverage reports
sonar.cpd.exclusions=**/*.spec.ts,**/*.test.ts,**/test/**,**/migrations/**
sonar.coverage.exclusions=**/*.spec.ts,**/*.test.ts,**/test/**,**/migrations/**,**/generated/**
```

---

## Excluding Generated Code

Generated code (API clients, ORM output, migration SQL) should almost always be excluded. The team doesn't control it and shouldn't fix it by hand.

```properties
sonar.exclusions=packages/api-client/src/generated/**
sonar.cpd.exclusions=packages/api-client/src/generated/**,**/migrations/**
```

---

## Ignoring Specific Rules

Sometimes a rule legitimately does not apply. SonarQube offers multiple suppression mechanisms.

### 1. Inline: `// NOSONAR`

Suppresses **all** rules on that line. Use sparingly — it hides everything.

```typescript
const result = eval(expression); // NOSONAR — sandboxed eval in build script
```

### 2. Inline: `@SuppressWarnings` (Java/Kotlin)

Suppresses specific rules by key.

```java
@SuppressWarnings("java:S2077")
public void executeQuery(String sql) { ... }
```

### 3. In `sonar-project.properties`: `sonar.issue.ignore.multicriteria`

Suppress a specific rule on files matching a glob. This is the **cleanest approach** for legitimate project-wide suppressions.

```properties
# Define named criteria (comma-separated keys)
sonar.issue.ignore.multicriteria=e1,e2

# e1: Ignore "hardcoded credentials" in test fixtures
sonar.issue.ignore.multicriteria.e1.ruleKey=typescript:S2068
sonar.issue.ignore.multicriteria.e1.resourceKey=**/test/**

# e2: Ignore "cognitive complexity" in migration files
sonar.issue.ignore.multicriteria.e2.ruleKey=typescript:S3776
sonar.issue.ignore.multicriteria.e2.resourceKey=**/migrations/**
```

### 4. In `sonar-project.properties`: `sonar.issue.ignore.allfile`

Suppress **all** rules for files matching a header pattern.

```properties
sonar.issue.ignore.allfile=e1
sonar.issue.ignore.allfile.e1.fileRegexp=// @generated
```

### Decision: When is it OK to Ignore?

| Situation | Acceptable? | Mechanism |
|---|---|---|
| Generated code (codegen, ORM, API clients) | **Yes** — exclude entirely | `sonar.exclusions` |
| Test fixtures with fake credentials | **Yes** — not real secrets | `sonar.issue.ignore.multicriteria` |
| Migration files with raw SQL | **Yes** — often unfixable | `sonar.cpd.exclusions` + rule ignore |
| "Hardcoded" env vars for local scanner only | **Yes** — scanner is local, not prod | Document the rationale in comment |
| Complex function that genuinely needs complexity | **Maybe** — refactor first | `// NOSONAR` with justification |
| Actual security vulnerability | **Never** | Fix it |

---

## Local Scanner: Environment Variables

The sonar-scanner runs **locally** (dev machine or CI). Connection secrets passed via environment variables or `docker-compose.yml` are acceptable because they never reach production code.

```yaml
# docker-compose.yml — sonar-scanner service
services:
  sonar-scanner:
    image: sonarsource/sonar-scanner-cli:latest
    environment:
      SONAR_HOST_URL: http://sonarqube:9000
      SONAR_TOKEN: ${SONAR_TOKEN}
    volumes:
      - .:/usr/src
```

```bash
# CLI invocation with env vars
SONAR_HOST_URL=http://localhost:9000 \
SONAR_TOKEN=sqp_xxxx \
npx sonar-scanner
```

In `sonar-project.properties`, **do not hardcode** `sonar.token`. Pass it via `-D` flag or env var.

---

## Language-Specific Examples

### TypeScript / NestJS (monorepo)

```properties
sonar.projectKey=org_my-nestjs-app
sonar.projectName=My NestJS App

sonar.sources=src
sonar.tests=src
sonar.test.inclusions=**/*.spec.ts,**/*.test.ts,**/*.e2e-spec.ts
sonar.sourceEncoding=UTF-8

# Exclude generated and test artifacts
sonar.exclusions=**/node_modules/**,**/dist/**,**/generated/**
sonar.cpd.exclusions=**/*.spec.ts,**/*.test.ts,**/migrations/**
sonar.coverage.exclusions=**/*.spec.ts,**/*.test.ts,**/migrations/**,src/main.ts

# Coverage
sonar.javascript.lcov.reportPaths=coverage/lcov.info

# Ignore "hardcoded credentials" in test files
sonar.issue.ignore.multicriteria=e1
sonar.issue.ignore.multicriteria.e1.ruleKey=typescript:S2068
sonar.issue.ignore.multicriteria.e1.resourceKey=**/*.spec.ts
```

### TypeScript / Nuxt (monorepo with multiple apps)

```properties
sonar.projectKey=org_my-monorepo
sonar.projectName=My Monorepo

sonar.sources=apps,packages
sonar.tests=apps,packages
sonar.test.inclusions=**/*.spec.ts,**/*.test.ts,**/*.spec.tsx,**/*.test.tsx
sonar.sourceEncoding=UTF-8

sonar.exclusions=**/node_modules/**,**/dist/**,**/.nuxt/**,**/.output/**,**/generated/**
sonar.cpd.exclusions=**/*.spec.ts,**/*.test.ts,**/migrations/**
sonar.coverage.exclusions=**/*.spec.ts,**/*.test.ts,**/migrations/**

sonar.javascript.lcov.reportPaths=apps/backend/coverage/lcov.info,apps/frontend/coverage/lcov.info
```

### Java / Spring Boot (Maven)

```properties
sonar.projectKey=org_my-spring-app
sonar.projectName=My Spring App

sonar.sources=src/main/java
sonar.tests=src/test/java
sonar.sourceEncoding=UTF-8

sonar.exclusions=**/generated/**,**/dto/**/*Mapper*.java
sonar.cpd.exclusions=**/entity/**
sonar.coverage.exclusions=**/config/**,**/dto/**

sonar.java.binaries=target/classes
sonar.java.libraries=target/dependency/*.jar
sonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml
```

### Python / Django

```properties
sonar.projectKey=org_my-django-app
sonar.projectName=My Django App

sonar.sources=src
sonar.tests=tests
sonar.sourceEncoding=UTF-8

sonar.exclusions=**/migrations/**,**/venv/**,**/__pycache__/**
sonar.cpd.exclusions=**/migrations/**
sonar.coverage.exclusions=**/migrations/**,**/tests/**,manage.py

sonar.python.coverage.reportPaths=coverage.xml
```

### C# / .NET

```properties
sonar.projectKey=org_my-dotnet-app
sonar.projectName=My .NET App

sonar.sources=src
sonar.tests=tests
sonar.sourceEncoding=UTF-8

sonar.exclusions=**/Migrations/**,**/obj/**,**/bin/**
sonar.cpd.exclusions=**/Migrations/**
sonar.coverage.exclusions=**/Migrations/**,**/Tests/**

sonar.cs.opencover.reportsPaths=**/coverage.opencover.xml
```

---

## Real-World Example (modelo-calendar)

```properties
# Orval emits TypeScript under packages/api-client/src/generated/ from the OpenAPI spec.
# That output often triggers maintainability rules (e.g. S6564 redundant type aliases) that
# the team does not control and must not fix by hand — files are overwritten by make api-generate.
# Excluding this tree keeps the quality gate focused on hand-written code.

sonar.exclusions=packages/api-client/src/generated/**
sonar.cpd.exclusions=packages/api-client/src/generated/**,**/*.spec.ts,**/test/**,**/tests/**,**/migrations/**

# Coverage reports (generated by `make coverage`)
sonar.javascript.lcov.reportPaths=apps/backend/coverage/lcov.info,apps/frontend/coverage/lcov.info
```

Key takeaways from this example:
- **Comment the rationale** for each exclusion — future maintainers need to understand why
- Generated code is fully excluded (`sonar.exclusions`) so it doesn't pollute the quality gate
- Tests and migrations are excluded from CPD only (`sonar.cpd.exclusions`) — duplication in tests is expected

---

## Checklist

Before committing `sonar-project.properties`:

- [ ] `sonar.projectKey` matches the SonarQube project (check via `search_my_sonarqube_projects` MCP)
- [ ] `sonar.sources` and `sonar.tests` point to actual directories
- [ ] Test files are properly identified via `sonar.test.inclusions` globs
- [ ] Generated code is excluded via `sonar.exclusions`
- [ ] Tests/migrations are excluded from CPD via `sonar.cpd.exclusions`
- [ ] Coverage report paths exist (run coverage before scanning)
- [ ] `sonar.token` is **not** hardcoded — use env var or CLI `-D` flag
- [ ] Every exclusion and rule suppression has a comment explaining **why**
- [ ] Rule suppressions use `sonar.issue.ignore.multicriteria` (not blanket `// NOSONAR`)
