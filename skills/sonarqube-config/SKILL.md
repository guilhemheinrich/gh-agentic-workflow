---
name: sonarqube-config
description: >-
  Bind a repository to a self-hosted SonarQube Community Build once, then scan it
  and read the result on demand — from one machine-level environment and one
  personal file at the repository root. Ships `scripts/sonarctl.sh`, whose
  `bind` creates the project and its analysis token from a user-level admin
  token and writes `.sonar-config`, whose `scan` runs the official Dockerized
  scanner, waits for the quality gate and prints the open issues, whose
  `status` reads gate and issues without scanning, and whose `doctor` verifies
  the whole installation (env, token permissions, git excludes, MCP). Explains
  the two-token model (user token for binding, project analysis token for
  scanning), why `.sonar-config` is ignored through `~/.gitignore_global` and
  never through the repo, and how the sonarqube MCP tools read issues, gate,
  hotspots and rules once a scan has run. Still the reference for
  `sonar-project.properties`: analysis scope, test detection, copy-paste and
  coverage exclusions, rule suppression, language-specific examples. Use when
  connecting a project to SonarQube, running or iterating on a Sonar analysis,
  reading Sonar issues through the MCP, editing sonar-project.properties, or
  diagnosing a scanner that cannot authenticate.
tags:
  - ci-cd
  - sonarqube
  - testing
---

# SonarQube — bind once, scan on demand (Community Build)

One self-hosted SonarQube Community Build, one owner, many repositories. Two
gestures cover the whole lifecycle: **bind** a repository to its project once,
then **scan** and read the result as often as the code changes. Everything
that identifies the instance or authenticates lives outside the repository —
in the user's environment and in one ignored file — so no project ever carries
a Sonar secret, and no scan ever needs its arguments typed again.

```bash
sonarctl.sh doctor        # is this machine and this repository correctly set up?
sonarctl.sh bind          # once per repository: project + token + .sonar-config
sonarctl.sh scan          # Dockerized scan, quality gate, top open issues
sonarctl.sh status        # gate + issues, no scan
```

## 1. What is in this bundle

| File                                | Role                                                                                   |
| ----------------------------------- | -------------------------------------------------------------------------------------- |
| `scripts/sonarctl.sh`               | The client: `doctor`, `bind`, `scan`, `status`. bash, curl, jq, git, docker (scan).    |
| `templates/sonar-env.sh`            | Machine-level setup — bash and zsh. Writes `~/.config/sonarqube/admin.env`.            |
| `templates/sonar-env.fish`          | Machine-level setup — fish. Same env file, plus a `conf.d` loader that reads it.        |
| `templates/sonar-config.example`    | The shape of `<repo>/.sonar-config`, for documentation only — `bind` writes the real one. |

Install the client once:

```bash
install -m 755 ~/.claude/skills/sonarqube-config/scripts/sonarctl.sh ~/.local/bin/sonarctl.sh
```

## 2. Two tokens, two scopes

SonarQube issues three token kinds. This skill uses two, and never mixes them.

|                    | Machine level                                                | Project level                                                    |
| ------------------ | ------------------------------------------------------------ | ---------------------------------------------------------------- |
| Where              | `~/.config/sonarqube/admin.env` → env `SONAR_HOST_URL`, `SONAR_ADMIN_TOKEN` | `<repo>/.sonar-config` → `SONAR_HOST_URL`, `SONAR_PROJECT_KEY`, `SONAR_TOKEN` |
| Token kind         | `USER_TOKEN` (`squ_…`) of an account holding **Create Projects** | `PROJECT_ANALYSIS_TOKEN` (`sqp_…`), scoped to that one project |
| Can do             | create projects, generate and revoke tokens, read everything | run an analysis of its project; read its results if the project is public |
| Read by            | `bind`, `doctor`. The sonarqube MCP server keeps its own copy. | `scan`, `status`                                                 |
| Git                | outside every repository                                     | ignored through `~/.gitignore_global`, never through the repo's `.gitignore` |
| Lost?              | generate a new user token in the UI, edit `admin.env`        | `sonarctl.sh bind --force` — a token value is readable only at generation |

Why the **user-level** gitignore and not the repository's: a Community Build
has one owner, so the binding is a property of this machine, not of the
project. The same `.sonar-config` appears in every repository worked this way,
and a line in each project's `.gitignore` would advertise a file the team never
sees. Concrete precedent on this machine: `~/.gitignore_global` already carries
`.scannerwork/` and `sonar-project.properties` under a `# SonarQube artifacts`
header; `bind` slots `.sonar-config` into that same block.

Never copy any of these values into `.env`, `.env.example`,
`sonar-project.properties`, a Makefile or a CI file. `doctor` warns when it
finds `SONAR_TOKEN` in `.env` (the contract this skill used before 1.0) or
`sonar.token` in `sonar-project.properties`.

## 3. Setup once per machine

Get a **User Token** in SonarQube — *My Account → Security → Generate Tokens*,
type *User Token* — on an account that holds the global **Create Projects**
permission (`provisioning`). Then run the template for your shell; both are
idempotent, never overwrite an existing value, and pre-fill the host URL from
the optional argument:

```bash
bash ~/.claude/skills/sonarqube-config/templates/sonar-env.sh https://sonarqube.example.com
```

```bash
fish ~/.claude/skills/sonarqube-config/templates/sonar-env.fish https://sonarqube.example.com
```

Both write `~/.config/sonarqube/admin.env` at mode 0600:

```bash
export SONAR_HOST_URL="https://sonarqube.example.com"
export SONAR_ADMIN_TOKEN="PASTE_YOUR_ADMIN_TOKEN_HERE"
```

The bash template adds one `source` line to `~/.bashrc`, `~/.zshrc` and
`~/.profile`; the fish template adds a loader to
`~/.config/fish/conf.d/sonarqube.fish` that parses the same file. One file to
edit when the token rotates, whichever shell starts the agent.

**The desktop-app trap.** An agent launched from the Dock, an IDE extension or
cron inherits no interactive shell rc. Measured on 2026-09-10: the Claude
desktop app runs its shell tool as `zsh -c` — non-login, non-interactive — and
that mode reads exactly one file, `~/.zshenv`. `~/.zshrc` is interactive-only
and `~/.profile` is never read by zsh, so a token declared only there is
invisible to the agent while `sonarctl.sh doctor` in a terminal stays green.
The bash template therefore creates `~/.zshenv` for zsh users and sources the
env file from it, next to `.bashrc`, `.bash_profile` and `.profile` for bash;
after that, all six modes (`bash/zsh` × `-c`, `-lc`, `-ic`) saw the variable.
Fish reads `conf.d` in every mode, so the fish loader needs no such care.
`doctor` reports "not set in this shell" when the path is broken. Last resort:
the `env` block of **user-scope** `~/.claude/settings.json` — a plaintext
secret in JSON, so never in a project-scope `.claude/settings.json`.

Then verify:

```bash
sonarctl.sh doctor
```

| `doctor` checks                         | Failure means                                                       |
| --------------------------------------- | ------------------------------------------------------------------- |
| curl, jq, git present; docker daemon up | `scan` cannot run (docker) or nothing can (curl/jq)                 |
| `admin.env` exists, mode 0600           | run the template, or `chmod 600`                                    |
| `SONAR_HOST_URL` set, https, reachable  | shell did not source the env file, or the instance is down          |
| `SONAR_ADMIN_TOKEN` valid, user has `provisioning` or `admin` | wrong token kind (an `sqp_` token is refused with a hint) or a low-privilege account |
| `core.excludesFile` set and lists `.sonar-config` | `bind` repairs it; `doctor` only reports                  |
| sonarqube MCP configured (`./.mcp.json` or `~/.claude.json`) | informational — `status` covers reading without it  |
| in a bound repo: `.sonar-config` complete, 0600, unquoted, **ignored and untracked**, token accepted, project visible | see §7 |

`doctor` exits 0 when no line reads `FAIL`. Warnings do not fail it.

## 4. Bind a repository once

From the repository root:

```bash
sonarctl.sh bind
```

What runs, in order:

1. Resolves the project key from `origin` (basename without `.git`), else the
   directory name; `--key` overrides. Letters, digits, `_ . : -` only.
2. Ensures `~/.gitignore_global` lists `.sonar-config` (sets `core.excludesFile`
   if unset, appends under `# SonarQube artifacts`).
3. Validates `SONAR_ADMIN_TOKEN`; refuses to continue on a rejected token.
4. If `.sonar-config` already binds this key on this host with a token the
   server still accepts: **stops, nothing to do**. Another key → refuses unless
   `--force`.
5. `api/projects/create` if `api/projects/search` finds nothing. Default
   visibility **public**; on a single-owner instance every existing project is
   public, and public is what lets the analysis token read its own results.
   `--visibility private` when the instance has other readers.
6. Token named `Analyze "<key>"` — the name the SonarQube UI itself uses. If a
   token of that name exists, it is **revoked first**: SonarQube never re-reads
   a token value, so a rebind is always revoke-then-generate. `--expires
   YYYY-MM-DD` sets an expiration.
7. Writes `.sonar-config` atomically at mode 0600, plain `KEY=VALUE`, then
   proves with `git check-ignore` that git ignores it, and **fails loudly** if
   `git ls-files` shows it tracked.

Real output, 2026-09-10, on a throwaway repository (token redacted):

```text
bind sonarctl-selftest → https://sonarqube.icare.ddnsgeek.com
  ok   project created: sonarctl-selftest (public)
  ok   token generated: 'Analyze "sonarctl-selftest"' (PROJECT_ANALYSIS_TOKEN, owner admin)
  ok   wrote /…/selftest/.sonar-config (0600)
  ok   .sonar-config is ignored by git

next: sonarctl.sh scan        dashboard: https://sonarqube.icare.ddnsgeek.com/dashboard?id=sonarctl-selftest
```

A second `bind` on the same repository answered `already bound … nothing to do`.

The written file (see `templates/sonar-config.example`):

```dotenv
SONAR_HOST_URL=https://sonarqube.icare.ddnsgeek.com
SONAR_PROJECT_KEY=sonarctl-selftest
SONAR_TOKEN=sqp_…
```

No quotes, no `export`: `docker run --env-file` reads such a file literally, so
a quoted value would reach the scanner with its quotes. `doctor` flags quotes.

Bind is the moment to add a `sonar-project.properties` if the repository has
none — scope, exclusions, coverage paths, nothing else. §6 covers it.

## 5. Scan and iterate

```bash
sonarctl.sh scan                       # wait for the gate, print gate + top 20 issues
sonarctl.sh scan --top 5               # fewer issues in the summary
sonarctl.sh scan --no-wait             # do not block on the gate; still polls the task for the analysis id
sonarctl.sh scan -- -Dsonar.branch.name=main   # anything after -- goes to the scanner
sonarctl.sh status                     # gate + issues from the last analysis, no scan
```

`scan` reads only `.sonar-config` and runs the official image
`sonarsource/sonar-scanner-cli` (override with `SONAR_SCANNER_IMAGE`) with the
repository mounted at `/usr/src`, the scanner cache at `~/.sonar/cache`, and
the working directory pinned to `<repo>/.scannerwork` so `report-task.txt`
survives the container. The token travels to the scanner as the `SONAR_TOKEN`
environment variable the image reads natively; the project key as
`-Dsonar.projectKey`. By default it passes `-Dsonar.qualitygate.wait=true`
(timeout `SONAR_GATE_TIMEOUT`, 300 s), so a **failed gate exits non-zero** —
usable as-is in a Makefile or a pre-push hook.

After the scanner returns, the script polls `api/ce/task` until the server has
processed the report, then prints the gate with its failing conditions, the
open-issue facets by severity and type, and the top N issues as
`file:line  severity  rule  message` — a shape an agent can act on directly.

Real run on the throwaway repository (two-line JavaScript file with `var`):

```text
  ok   scanner finished
  ok   analysis task: SUCCESS (2837b8b6-…)
  ok   quality gate: OK

open issues: 4
  severities: CRITICAL=2  MINOR=2
  types: CODE_SMELL=4

top 3 by severity (file:line  severity  rule  message)
  src/app.js:3  CRITICAL  javascript:S3504  Unexpected var, use let or const instead.
  src/app.js:2  CRITICAL  javascript:S3504  Unexpected var, use let or const instead.
  src/app.js:3  MINOR  javascript:S1481  Remove the declaration of the unused 'unused' variable.
```

Wall clock: 47 s on the first run (image pull and JRE provisioning), 23 s on
the second. The image is `linux/amd64` only; on Apple silicon Docker prints a
platform warning and runs it under emulation — harmless, and the numbers above
are from that setup.

### Which token reads the results

Reads (`status`, the summary after `scan`, `doctor`'s project check) use
`SONAR_ADMIN_TOKEN` when it is in the environment and points at the same host,
else the project token from `.sonar-config`. An analysis token can read a
**public** project's issues and gate; on a **private** project it gets HTTP
403, and the script says so and points at the admin token or the MCP. Scanning
itself never needs the admin token.

### Reading and triaging with the sonarqube MCP

Once a scan has run, the MCP is the richer reader — it returns the full issue
list with rule descriptions, and it can change issue status. Its own
configuration (a user token in `.mcp.json`, kept out of git) is independent of
this skill; `doctor` only reports whether it is there.

The **project key is `SONAR_PROJECT_KEY` in `.sonar-config`** — read it from
there before any MCP call. The MCP server's own resolution order looks at
`.sonarlint/connectedMode.json`, `sonar-project.properties`, manifests and CI
files, none of which carry the key under this skill, so a wrong guess silently
returns another project's issues.

| Tool                                 | Use it for                                                                  |
| ------------------------------------ | --------------------------------------------------------------------------- |
| `search_my_sonarqube_projects`       | confirm the key exists, or find one from a name                             |
| `get_project_quality_gate_status`    | the gate and its failing conditions — the first question after a scan       |
| `search_sonar_issues_in_projects`    | the issue list; filter by severity, type, rule, file, resolution            |
| `show_rule`                          | the full description of a rule key such as `javascript:S3504` before fixing |
| `search_security_hotspots` / `show_security_hotspot` | hotspots the gate does not count                            |
| `get_component_measures`             | coverage, duplication, complexity for a file or the project                 |
| `get_duplications` / `search_duplicated_files` | copy-paste findings, before deciding a `sonar.cpd.exclusions`     |
| `change_sonar_issue_status`          | mark false positives or won't-fix, with a justification                     |

The iteration loop: fix → `sonarctl.sh scan` → read → fix. `status` between
scans costs one HTTP round trip and no Docker start.

Without the MCP, the Web API answers the same questions with the read token:

```bash
curl -s -u "$SONAR_ADMIN_TOKEN:" "$SONAR_HOST_URL/api/issues/search?componentKeys=<key>&resolved=false&ps=50" | jq '.issues[] | {component, line, severity, rule, message}'
```

## 6. sonar-project.properties — analysis scope only

Place it at the **repository root**; the scanner reads it from `/usr/src`. It
carries scope, exclusions and coverage paths, and **never** `sonar.host.url`,
`sonar.token`, `sonar.login` or `sonar.projectKey` — those come from
`.sonar-config`, and `doctor` warns when it finds them here.

```properties
# ──────────────────────────────────────────────
# Identity — the key comes from .sonar-config
# ──────────────────────────────────────────────
sonar.projectName=<Human-Readable Name>

# ──────────────────────────────────────────────
# Source layout
# ──────────────────────────────────────────────
sonar.sources=src
sonar.tests=src
sonar.test.inclusions=**/*.spec.ts,**/*.test.ts,**/*.spec.tsx,**/*.test.tsx
sonar.sourceEncoding=UTF-8

# ──────────────────────────────────────────────
# Exclusions (see below)
# ──────────────────────────────────────────────
sonar.exclusions=
sonar.cpd.exclusions=
sonar.coverage.exclusions=

# ──────────────────────────────────────────────
# Coverage reports
# ──────────────────────────────────────────────
sonar.javascript.lcov.reportPaths=coverage/lcov.info
```

### Key properties

| Property                            | Purpose                                                                  |
| ----------------------------------- | ------------------------------------------------------------------------ |
| `sonar.sources`                     | Directories containing main (non-test) source code                       |
| `sonar.tests`                       | Directories containing test source code                                  |
| `sonar.test.inclusions`             | Globs that **identify** test files within `sonar.tests`                  |
| `sonar.exclusions`                  | Globs that **remove** source files from analysis entirely                |
| `sonar.test.exclusions`             | Globs that remove test files from analysis                               |
| `sonar.cpd.exclusions`              | Globs excluded from **copy-paste detection** only                        |
| `sonar.coverage.exclusions`         | Globs excluded from **coverage computation** only                        |
| `sonar.javascript.lcov.reportPaths` | LCOV report path(s), comma-separated                                     |
| `sonar.issue.ignore.multicriteria`  | Named criteria suppressing specific rules on matching files              |

### Glob syntax

Patterns are relative to `sonar.projectBaseDir` (the repository root).

| Pattern                                 | Matches                                            |
| --------------------------------------- | -------------------------------------------------- |
| `**/*.spec.ts`                          | all `.spec.ts` files at any depth                  |
| `**/*.test.{ts,tsx}`                    | all `.test.ts` and `.test.tsx` files               |
| `**/test/**`                            | everything under any `test/` directory             |
| `**/migrations/**`                      | all migration files                                |
| `packages/api-client/src/generated/**`  | all generated API-client code                      |

`*` is zero or more characters except `/`; `**` zero or more directory
segments; `?` exactly one character except `/`.

### Test files

**Recommended** — declare test roots and identify tests by pattern; SonarQube
applies its test rule set and keeps them out of the coverage gate:

```properties
sonar.sources=src
sonar.tests=src
sonar.test.inclusions=**/*.spec.ts,**/*.test.ts
```

**Nuclear** — remove them from analysis entirely, so they never appear:

```properties
sonar.exclusions=**/*.spec.ts,**/*.test.ts,**/test/**,**/tests/**,**/__tests__/**
```

**Combined** (monorepos) — identify tests, and keep them out of duplication and
coverage:

```properties
sonar.sources=src
sonar.tests=src
sonar.test.inclusions=**/*.spec.ts,**/*.test.ts,**/*.spec.tsx,**/*.test.tsx
sonar.cpd.exclusions=**/*.spec.ts,**/*.test.ts,**/test/**,**/migrations/**
sonar.coverage.exclusions=**/*.spec.ts,**/*.test.ts,**/test/**,**/migrations/**,**/generated/**
```

### Generated code

Codegen output, ORM output and migration SQL are excluded outright: the team
does not control them and must not fix them by hand.

```properties
sonar.exclusions=packages/api-client/src/generated/**
sonar.cpd.exclusions=packages/api-client/src/generated/**,**/migrations/**
```

### Ignoring specific rules

1. **Inline `// NOSONAR`** — suppresses *every* rule on that line. Use sparingly.

   ```typescript
   const result = eval(expression); // NOSONAR — sandboxed eval in build script
   ```

2. **`@SuppressWarnings("java:S2077")`** (Java/Kotlin) — one rule, one symbol.

3. **`sonar.issue.ignore.multicriteria`** — one rule on files matching a glob;
   the cleanest project-wide mechanism:

   ```properties
   sonar.issue.ignore.multicriteria=e1,e2
   # e1: hardcoded credentials in test fixtures are fakes
   sonar.issue.ignore.multicriteria.e1.ruleKey=typescript:S2068
   sonar.issue.ignore.multicriteria.e1.resourceKey=**/test/**
   # e2: cognitive complexity in migration files is not refactorable
   sonar.issue.ignore.multicriteria.e2.ruleKey=typescript:S3776
   sonar.issue.ignore.multicriteria.e2.resourceKey=**/migrations/**
   ```

4. **`sonar.issue.ignore.allfile`** — every rule on files whose content matches
   a header regexp:

   ```properties
   sonar.issue.ignore.allfile=e1
   sonar.issue.ignore.allfile.e1.fileRegexp=// @generated
   ```

| Situation                                        | Acceptable?                    | Mechanism                                   |
| ------------------------------------------------ | ------------------------------ | ------------------------------------------- |
| Generated code (codegen, ORM, API clients)       | **Yes** — exclude entirely     | `sonar.exclusions`                          |
| Test fixtures with fake credentials              | **Yes** — not real secrets     | `sonar.issue.ignore.multicriteria`          |
| Migration files with raw SQL                     | **Yes** — often unfixable      | `sonar.cpd.exclusions` + rule ignore        |
| Complex function that needs its complexity       | **Maybe** — refactor first     | `// NOSONAR` with a written justification   |
| A real security vulnerability                    | **Never**                      | fix it                                      |

Comment the rationale next to every exclusion and suppression — future
maintainers need the *why*, and the MCP's `change_sonar_issue_status` keeps a
justification on the server side too.

### Language examples

**TypeScript / NestJS**

```properties
sonar.projectName=My NestJS App
sonar.sources=src
sonar.tests=src
sonar.test.inclusions=**/*.spec.ts,**/*.test.ts,**/*.e2e-spec.ts
sonar.sourceEncoding=UTF-8
sonar.exclusions=**/node_modules/**,**/dist/**,**/generated/**
sonar.cpd.exclusions=**/*.spec.ts,**/*.test.ts,**/migrations/**
sonar.coverage.exclusions=**/*.spec.ts,**/*.test.ts,**/migrations/**,src/main.ts
sonar.javascript.lcov.reportPaths=coverage/lcov.info
sonar.issue.ignore.multicriteria=e1
sonar.issue.ignore.multicriteria.e1.ruleKey=typescript:S2068
sonar.issue.ignore.multicriteria.e1.resourceKey=**/*.spec.ts
```

**TypeScript / Nuxt monorepo**

```properties
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

**Java / Spring Boot (Maven)**

```properties
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

**Python / Django**

```properties
sonar.projectName=My Django App
sonar.sources=src
sonar.tests=tests
sonar.sourceEncoding=UTF-8
sonar.exclusions=**/migrations/**,**/venv/**,**/__pycache__/**
sonar.cpd.exclusions=**/migrations/**
sonar.coverage.exclusions=**/migrations/**,**/tests/**,manage.py
sonar.python.coverage.reportPaths=coverage.xml
```

**C# / .NET**

```properties
sonar.projectName=My .NET App
sonar.sources=src
sonar.tests=tests
sonar.sourceEncoding=UTF-8
sonar.exclusions=**/Migrations/**,**/obj/**,**/bin/**
sonar.cpd.exclusions=**/Migrations/**
sonar.coverage.exclusions=**/Migrations/**,**/Tests/**
sonar.cs.opencover.reportsPaths=**/coverage.opencover.xml
```

### Real-world example (modelo-calendar)

```properties
# Orval emits TypeScript under packages/api-client/src/generated/ from the OpenAPI spec.
# That output triggers maintainability rules (e.g. S6564 redundant type aliases) that
# the team does not control and must not fix by hand — files are overwritten by
# `make api-generate`. Excluding the tree keeps the gate focused on hand-written code.
sonar.exclusions=packages/api-client/src/generated/**
sonar.cpd.exclusions=packages/api-client/src/generated/**,**/*.spec.ts,**/test/**,**/tests/**,**/migrations/**

# Coverage reports (generated by `make coverage`)
sonar.javascript.lcov.reportPaths=apps/backend/coverage/lcov.info,apps/frontend/coverage/lcov.info
```

Generated code is excluded from everything; tests and migrations only from
duplication, since duplication in tests is expected.

## 7. Failure modes

| Symptom                                                        | Cause and fix                                                                                          |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `SONAR_HOST_URL is not set` from an agent, fine in a terminal  | the agent runs `zsh -c`, which reads only `~/.zshenv` — re-run `templates/sonar-env.sh`, which adds the line there (§3) |
| `SONAR_ADMIN_TOKEN: starts with sqp_ — that is an analysis token` | a project token was pasted into `admin.env`; a **User Token** is required                            |
| `projects/search: HTTP 403`                                    | the user token's account lacks **Create Projects**                                                     |
| `user_tokens/generate: HTTP 400 … already exists`              | cannot happen through `bind`: it revokes the same-named token first. Seen only with a hand-made token  |
| `.sonar-config: TRACKED BY GIT`                                | the file was committed before the exclude existed: `git rm --cached .sonar-config`, push, `bind --force` to rotate the leaked token |
| `.sonar-config: NOT ignored by git`                            | `core.excludesFile` points elsewhere, or the line is missing — `bind` repairs both                     |
| `project '<key>': private — the analysis token can scan it but not read results` | expected on a private project; `status` needs `SONAR_ADMIN_TOKEN` or the MCP         |
| `SONAR_TOKEN: rejected (HTTP 401)`                             | token revoked or expired — `bind --force`                                                              |
| `no .scannerwork/report-task.txt`                              | the scanner failed before upload; read the scanner log above the summary                               |
| `WARN Could not find HEAD commit` / `Missing blame information`| the repository has no commit yet; analysis still runs, without blame-based attribution                 |
| `WARNING: The requested image's platform (linux/amd64) …`      | Apple silicon running the amd64 image under emulation — harmless                                        |
| `.env: carries SONAR_* keys from the pre-1.0 contract`         | migrate: `bind`, then delete the `SONAR_*` lines from `.env`                                            |
| the MCP returns issues from another project                    | it guessed the key from a manifest; pass `SONAR_PROJECT_KEY` from `.sonar-config` explicitly            |

## 8. What leaves the machine

Tokens travel to exactly one host, the `SONAR_HOST_URL` of the file they come
from — over TLS (`doctor` warns on `http://`). The repository content goes to
the same host as an analysis report, minus `sonar.exclusions`. Nothing is
written to git: `.sonar-config` is excluded at user level, `.scannerwork/`
likewise, and `bind` refuses to leave a tracked `.sonar-config` behind
silently.

## 9. Checklist

Before the first `scan` on a repository:

- [ ] `sonarctl.sh doctor` — 0 failures on the machine section
- [ ] `sonarctl.sh bind` — `.sonar-config` present, 0600, `ignored by git`
- [ ] `sonar-project.properties` present, with `sonar.sources` and `sonar.tests` pointing at real directories, and **no** `sonar.host.url` / `sonar.token` / `sonar.projectKey`
- [ ] test files identified through `sonar.test.inclusions`
- [ ] generated code under `sonar.exclusions`; tests and migrations under `sonar.cpd.exclusions`
- [ ] coverage report paths exist (run coverage before scanning)
- [ ] every exclusion and suppression carries a comment saying why
- [ ] `.env` and `.env.example` carry no `SONAR_*` key

Before each iteration: `scan`, read the gate and the top issues, `show_rule`
on any unfamiliar rule key, fix, `scan` again.

## Implementation Status

**Fully implemented, live-verified end to end on 2026-09-10** against
SonarQube Community Build 25.8.0 at the author's instance.

**The live run.** A throwaway git repository with one smelly JavaScript file
(`var`, unused locals) and a two-line `sonar-project.properties`. `bind`
derived the key `sonarctl-selftest` from the fake `origin`, created the project
through `api/projects/create`, generated `Analyze "sonarctl-selftest"` through
`api/user_tokens/generate` (type `PROJECT_ANALYSIS_TOKEN`), wrote
`.sonar-config` at 0600 and proved it ignored through `~/.gitignore_global`. A
second `bind` was a no-op. `scan` — with `SONAR_ADMIN_TOKEN` and
`SONAR_HOST_URL` deliberately unset, so the project token alone was in play —
pulled `sonarsource/sonar-scanner-cli`, analysed in 47 s, waited for the gate
(`PASSED`) and printed 4 open issues (2 `javascript:S3504`, 2
`javascript:S1481`) with file and line. A second `scan --no-wait` took 23 s
and reached the analysis id through `report-task.txt` and `api/ce/task`.
`status` with the admin token in the environment returned the same gate and
issues. The test project and its token were then deleted from the instance.

**Three defects found and fixed during that run**, none of which a syntax check
catches: the HTTP status was assigned inside `$(…)` and lost to the parent
shell, so every check read `000` (fixed by passing the status through a
temporary file); a backtick pair inside a double-quoted message ran
`sonarctl.sh status` as a command; and `"${extra[@]}"` on an empty array is an
unbound variable under `set -u` in the macOS bash 3.2 that `/usr/bin/env bash`
resolves to. The image also ignores the base dir for its working directory
(`/tmp/.scannerwork`), which the script now overrides so the report file lands
in the repository.

**Not exercised.** `--visibility private` end to end (the 403 path for the
analysis token was observed on the freshly created private project before it
was switched to public, which is what prompted the read-token rule). Token
expiration (`--expires`). A SonarQube Server (commercial) instance — branch and
pull-request parameters pass through `scan -- -D…` untested. Linux hosts: the
`stat -f` / `stat -c` fallback is in place but only the macOS branch ran.

**Removed in this version.** The `resources/sonar-scanner/` Dockerfile and
entrypoint that the pre-1.0 skill asked projects to copy: the official image
already reads `SONAR_HOST_URL` and `SONAR_TOKEN` from its environment, and the
copied directory was itself in `~/.gitignore_global`, which showed it never
belonged in a repository.
