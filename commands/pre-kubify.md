---
name: pre-kubify
description: >-
  Scans a project to produce a concise infrastructure readiness report for the
  DevOps team before running /kubify. Detects env vars, secrets, build-time vs
  runtime config, services topology, and generates ASCII architecture diagrams
  for pprod and prod environments.
tags:
  - devops
  - kubernetes
  - infrastructure
---

# `/pre-kubify` — Infrastructure Readiness Report

Produce a concise Markdown report (`PRE_KUBIFY_REPORT.md`) that gives the DevOps team everything they need to prepare the Kubernetes infrastructure before running `/kubify`.

## Usage

```
/pre-kubify
/pre-kubify --output path/to/report.md
```

## Execution Pipeline

```
┌────────────┐   ┌────────────┐   ┌────────────┐   ┌────────────┐   ┌────────────┐
│  Step 1    │──▶│  Step 2    │──▶│  Step 3    │──▶│  Step 4    │──▶│  Step 5    │
│ Project    │   │ Env Vars   │   │ Services   │   │ Infra      │   │ Report     │
│ Discovery  │   │ & Secrets  │   │ Topology   │   │ Diagrams   │   │ Generation │
└────────────┘   └────────────┘   └────────────┘   └────────────┘   └────────────┘
```

---

## Step 1: Project Discovery

Scan the project to determine its structure and tech stack.

### 1.1 Tech Stack Detection

| What to detect | Where to look |
|---|---|
| Language / runtime | `package.json`, `go.mod`, `requirements.txt`, `Cargo.toml`, `pom.xml`, `build.gradle` |
| Framework | Dependencies, import patterns, config files |
| Database | ORM config, migration dirs, connection strings |
| Cache / broker | Redis, RabbitMQ, Kafka references |
| Build tool | Makefile, Dockerfile, compose files |

### 1.2 Project Structure

Identify:

- Monorepo vs single service (`apps/`, `packages/`, `services/`, `libs/`)
- Dockerfiles location (`.docker/*/Dockerfile`, root `Dockerfile`, `*/Dockerfile`)
- Compose files (`compose.yml`, `docker-compose.yml`)
- Existing CI/CD configuration (`bitbucket-pipelines.yml`, `.github/workflows/`, `.gitlab-ci.yml`)
- Existing Kubernetes/Helm artifacts (`helm/`, `k8s/`, `kustomize.yaml`)

### 1.3 Service Inventory

For each detected service, record:

| Property | Source |
|---|---|
| Name | Directory or compose service name |
| Type | `app-backend`, `app-frontend`, `app-worker`, `infra-database`, `infra-cache`, `infra-broker` |
| Port | `EXPOSE`, compose `ports`, `.env` |
| Dockerfile | Path if exists |
| Health endpoint | Source code scan (`/health`, `/api/health`, `/healthz`) |
| Migration tool | Prisma, TypeORM, Alembic, Flyway, etc. |

Classify as **application** (to deploy via Helm) or **infrastructure** (external dependency managed separately).

---

## Step 2: Environment Variables & Secrets Analysis

This is the core of the report. Cross-reference **all** sources to build a complete variable map.

### 2.1 Sources to Scan

| Source | Priority | What to extract |
|---|---|---|
| `compose.yml` / `docker-compose.yml` | 1 | `environment:` blocks per service, `build.args:` blocks |
| `.env.example` / `.env.hub.example` | 2 | Variable names, placeholder values |
| `.env` / `.env.*` (if readable) | 3 | Actual development values (for type inference) |
| `Dockerfile` / `Dockerfile.*` | 4 | `ARG` and `ENV` instructions |
| Source code | 5 | `process.env.*`, `os.environ`, `os.Getenv`, config files |
| `package.json` scripts | 6 | Env vars referenced in scripts |

### 2.2 Classification Matrix

For each variable, determine:

| Dimension | Values | How to determine |
|---|---|---|
| **Sensitivity** | `secret` / `config` | Name contains PASSWORD, SECRET, TOKEN, KEY, URL with credentials, DSN → secret. Otherwise → config |
| **Injection time** | `build-time` / `runtime` | Dockerfile `ARG`, Vite `VITE_*`, Next `NEXT_PUBLIC_*`, CRA `REACT_APP_*` → build-time. Everything else → runtime |
| **Scope** | `shared` / `per-service` | Same source `.env` var used by multiple services → shared. Prefixed mapping (e.g. `AUTH_DATABASE_URL` → `DATABASE_URL`) → per-service |
| **K8s target** | `ConfigMap` / `Secret` / `build-arg` | secret + runtime → K8s Secret. config + runtime → ConfigMap. build-time → Docker build-arg in pipeline |
| **Env-varies** | `yes` / `no` | Value differs between pprod and prod (URLs, domains, feature flags) → yes. Otherwise → no |

### 2.3 Build-Time Variables (Special Attention)

Build-time variables require **separate Docker builds per environment** (pprod vs prod). Flag them prominently:

- Frontend framework prefixes: `VITE_*`, `NEXT_PUBLIC_*`, `REACT_APP_*`
- Dockerfile `ARG` instructions
- `build.args` in compose files

For each build-time variable, record:

| Variable | Framework | pprod value hint | prod value hint |
|---|---|---|---|
| `VITE_API_URL` | Vite | `https://api.pprod.example.com` | `https://api.example.com` |

### 2.4 Cross-Service Secret Mapping

Detect the compose prefix mapping pattern:

```
compose service "api":    DATABASE_URL: ${AUTH_DATABASE_URL}
compose service "worker": DATABASE_URL: ${WORKER_DATABASE_URL}
```

→ Same K8s variable name (`DATABASE_URL`) but different values per service → per-service Secret, not shared.

---

## Step 3: Services Topology

### 3.1 Inter-Service Communication

Scan compose files and source code for:

| Pattern | What it reveals |
|---|---|
| Compose `depends_on` | Startup dependency |
| Compose `networks` | Network isolation |
| HTTP calls to other service hostnames | Sync communication |
| Queue/broker references | Async communication |
| Shared database references | Data coupling |

### 3.2 External Dependencies

Identify services that depend on external systems not in the compose file:

- External APIs (third-party SaaS, partner services)
- Shared infrastructure (Hub, SSO, identity provider)
- CDN, object storage (S3, MinIO)
- Monitoring / observability endpoints

### 3.3 Exposure Requirements

For each application service, determine:

| Service | Externally exposed? | Protocol | Why |
|---|---|---|---|
| api | Yes | HTTPS | Public API |
| web | Yes | HTTPS | Frontend SPA |
| worker | No | — | Internal only (queue consumer) |

---

## Step 4: Infrastructure Diagrams

Generate **ASCII diagrams** showing the infrastructure topology. Produce **two** diagrams: one for pprod (pre-production) and one for prod (production).

### 4.1 Diagram Requirements

Each diagram must show:

- All application services (with replica count)
- All infrastructure dependencies (database, cache, broker) — shown as external
- Communication protocols between entities (HTTP, gRPC, AMQP, Redis protocol, PostgreSQL wire protocol)
- Service exposure (LoadBalancer vs ClusterIP)
- ArgoCD sync source
- Docker registry

### 4.2 pprod Diagram Template

```
┌─────────────────────────────────────────────────────────────────────┐
│  NAMESPACE: modelo-<project>-pprod                                  │
│  Source: staging branch → ArgoCD sync                               │
│  Image tags: rc-<build-number>                                      │
│                                                                     │
│  ┌─────────────────┐         ┌─────────────────┐                    │
│  │  <service-1>    │  HTTP   │  <service-2>    │                    │
│  │  backend ×2     │◄───────▶│  frontend ×2    │                    │
│  │  port 3000      │         │  port 80        │                    │
│  │  ClusterIP/LB   │         │  ClusterIP/LB   │                    │
│  └────────┬────────┘         └─────────────────┘                    │
│           │                                                         │
│           │ TCP:5432                                                 │
│           ▼                                                         │
│  ┌─────────────────┐                                                │
│  │  PostgreSQL      │ (external — infra repo)                       │
│  └─────────────────┘                                                │
│                                                                     │
│           │ TCP:6379                                                 │
│           ▼                                                         │
│  ┌─────────────────┐                                                │
│  │  Redis           │ (external — infra repo)                       │
│  └─────────────────┘                                                │
└─────────────────────────────────────────────────────────────────────┘

         ▲ ArgoCD sync (staging branch)
         │
┌────────┴────────┐       ┌──────────────────────────┐
│  Git repository  │       │  modelo-registry.septeo.fr│
│  (Bitbucket)     │       │  Docker images            │
└──────────────────┘       └──────────────────────────┘
```

### 4.3 prod Diagram Template

Same structure but with production values:
- Higher replica counts (×3 nominal, ×10 peak HPA)
- Image tags: semver (`1.2.3`)
- Triggered by semver Git tag

### 4.4 Adaptation Rules

- Adjust services, replica counts, and connections based on actual project scan
- Show actual protocol on each arrow (HTTP, TCP:port, AMQP, etc.)
- If workers exist, show queue-based async communication
- If frontend has build-time env vars, annotate that separate builds are required per env
- Keep diagrams compact — ASCII width should not exceed 80 chars if possible

---

## Step 5: Report Generation

Generate `PRE_KUBIFY_REPORT.md` at the project root (or at `--output` path if specified).

### Report Structure

```markdown
# Pre-Kubify Infrastructure Report

> Generated: [date]
> Project: [project name]
> Tech stack: [language, framework, db, cache]

## 1. Project Overview

| Property | Value |
|---|---|
| Structure | Monorepo / Single service |
| Services (app) | N |
| Services (infra) | M (external) |
| CI/CD | Bitbucket Pipelines / GitHub Actions / None |
| Existing K8s | Yes (partial) / No |

## 2. Services

### Application Services (to deploy)

| Service | Type | Port | Health | Migration | Dockerfile |
|---|---|---|---|---|---|
| ... | ... | ... | ... | ... | ... |

### Infrastructure Dependencies (external)

| Service | Type | Used by | Connection variable |
|---|---|---|---|
| ... | ... | ... | ... |

## 3. Environment Variables

### 3.1 Runtime Secrets (→ K8s Secrets)

#### Shared Secrets

| Variable | Used by | Compose origin | Env-varies |
|---|---|---|---|
| ... | ... | ... | ... |

#### Per-Service Secrets

| Service | Variable | Compose origin | Env-varies |
|---|---|---|---|
| ... | ... | ... | ... |

### 3.2 Runtime Config (→ K8s ConfigMap)

| Variable | Value / Pattern | Used by | Env-varies |
|---|---|---|---|
| ... | ... | ... | ... |

### 3.3 Build-Time Variables (→ Docker build-arg)

⚠ These require **separate Docker builds per environment** (pprod vs prod).

| Variable | Framework | Service | pprod hint | prod hint |
|---|---|---|---|---|
| ... | ... | ... | ... | ... |

### 3.4 Pipeline Variables (→ Bitbucket repo vars, NOT K8s)

| Variable | Description | Secured |
|---|---|---|
| REGISTRY_USER | Docker registry username | No |
| REGISTRY_PASSWORD | Docker registry password | Yes |
| BB_TOKEN | Git push token for GitOps | Yes |

## 4. Infrastructure Diagrams

### pprod (Pre-Production)

[ASCII diagram]

### prod (Production)

[ASCII diagram]

## 5. DevOps Checklist

Before running `/kubify`:

- [ ] Confirm namespace names with infra team (convention: `modelo-<project>-<env>`)
- [ ] Provision databases listed in §2 Infrastructure Dependencies
- [ ] Provision cache/broker instances listed in §2
- [ ] Prepare connection strings for each environment (pprod / prod)
- [ ] Request namespace resource quotas (estimate provided in diagrams)
- [ ] Configure Bitbucket repo variables (§3.4)
- [ ] Review build-time variables (§3.3) — these need env-specific Docker builds

After running `/kubify`:

- [ ] Create K8s shared secrets in both namespaces
- [ ] Create K8s per-service secrets in both namespaces
- [ ] Configure ArgoCD application(s)
- [ ] Verify first deployment on pprod
```

---

## Critical Rules

- **Read-only**: This command does NOT modify project files. It only generates the report.
- **Concise**: The report must be actionable and scannable. No verbose prose — use tables everywhere.
- **Accurate**: Cross-reference ALL sources (compose, .env, Dockerfile, source code). Do not guess.
- **ASCII diagrams are mandatory**: The DevOps team needs visual topology.
- **Build-time vs runtime**: This distinction is critical for the pipeline architecture. Flag build-time variables prominently.
- **Shared vs per-service secrets**: Use the compose prefix mapping as discriminator, not just the K8s variable name.
- **ALWAYS run commands via Docker** if the project uses Docker — NEVER on the host.
- **Follow `.cursor/rules/`** and `AGENTS.md` for project conventions.
- **Use Context7 MCP** when needing documentation on frameworks/libraries.
