---
name: dockerfile-dev-prod
description: >-
  Write Dockerfiles with multi-stage builds for development and production. Use
  when creating a Dockerfile, configuring dev vs production builds, handling
  lockfile generation via make lock, or debugging dependency install issues in
  Docker.
tags:
  - ci-cd
  - docker
---

# Dockerfile — Multi-stage Development / Production

Universal pattern for writing Dockerfiles that support two dependency installation modes via **named multi-stage builds** instead of build arguments.

## Core Principle

| Target stage | Behavior |
|:---|:---|
| `development` | Copies `package.json` (no lockfile required), runs a free `install`, generates the lockfile inside the image. Retrieved on host via `make lock`. |
| `production` | Copies `package.json` **and** the committed lockfile, runs a strict frozen install (`--frozen-lockfile`, `--ci`, etc.). |

## Essential Rules

> **Never launch an ephemeral container (`docker run --rm …`) to generate the lockfile.**
>
> The lockfile is produced as a side-effect of the `development` stage build, then retrieved on host via `make lock` (`docker compose cp`).

> **The lockfile is always committed in the repo.** Production builds depend on it.

## Dockerfile Pattern (multi-stage)

```dockerfile
# ── Stage: development ──────────────────────────────────
FROM <base-image> AS development

WORKDIR /app

COPY package.json ./

RUN <pkg-manager> install

# ── Stage: production ───────────────────────────────────
FROM <base-image> AS production

WORKDIR /app

COPY package.json ./
COPY <lockfile> ./

RUN <pkg-manager> install --frozen-lockfile
```

### Ecosystem Examples

**Node.js (bun)**

```dockerfile
FROM oven/bun:1 AS development
WORKDIR /app
COPY package.json ./
RUN bun install

FROM oven/bun:1 AS production
WORKDIR /app
COPY package.json ./
COPY bun.lock ./
RUN bun install --frozen-lockfile
```

**Node.js (npm)**

```dockerfile
FROM node:22-slim AS development
WORKDIR /app
COPY package.json ./
RUN npm install

FROM node:22-slim AS production
WORKDIR /app
COPY package.json ./
COPY package-lock.json ./
RUN npm ci
```

**Node.js (pnpm)**

```dockerfile
FROM node:22-slim AS development
RUN corepack enable
WORKDIR /app
COPY package.json ./
RUN pnpm install --no-frozen-lockfile

FROM node:22-slim AS production
RUN corepack enable
WORKDIR /app
COPY package.json ./
COPY pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
```

**Python (pip)**

```dockerfile
FROM python:3.12-slim AS development
WORKDIR /app
COPY requirements.in ./
RUN pip-compile requirements.in -o requirements.txt && \
    pip install -r requirements.txt

FROM python:3.12-slim AS production
WORKDIR /app
COPY requirements.in ./
COPY requirements.txt ./
RUN pip install -r requirements.txt
```

**PHP (composer)**

```dockerfile
FROM php:8.3-fpm AS development
WORKDIR /app
COPY composer.json ./
RUN composer install

FROM php:8.3-fpm AS production
WORKDIR /app
COPY composer.json ./
COPY composer.lock ./
RUN composer install --no-dev --no-scripts --prefer-dist
```

## compose.yaml (local / dev)

```yaml
services:
  my-service:
    build:
      context: .
      dockerfile: Dockerfile
      target: development
```

Le compose cible **toujours** le stage `development`. Le stage `production` n'est jamais buildé via compose — il est construit par la couche infra (AWS task definition, Kubernetes manifest, pipeline CI, etc.) avec `--target production`.

## Makefile — `make lock`

`make lock` builde via compose (qui cible déjà `development`), lance le service, copie le lockfile généré vers l'host, puis arrête le service.

```makefile
SERVICE_NAME := my-service
LOCKFILE     := <lockfile>

lock:
	docker compose build $(SERVICE_NAME)
	docker compose up -d $(SERVICE_NAME)
	docker compose cp $(SERVICE_NAME):/app/$(LOCKFILE) ./$(LOCKFILE)
	docker compose down
```

### Examples

```makefile
# Node.js (bun)
lock:
	docker compose build frontend
	docker compose up -d frontend
	docker compose cp frontend:/app/bun.lock ./bun.lock
	docker compose down

# Node.js (npm)
lock:
	docker compose build frontend
	docker compose up -d frontend
	docker compose cp frontend:/app/package-lock.json ./package-lock.json
	docker compose down

# Python
lock:
	docker compose build api
	docker compose up -d api
	docker compose cp api:/app/requirements.txt ./requirements.txt
	docker compose down

# PHP
lock:
	docker compose build api
	docker compose up -d api
	docker compose cp api:/app/composer.lock ./composer.lock
	docker compose down
```

## Complete Workflow

```bash
# 1. Modifier package.json (ajouter/supprimer une dépendance)
vim package.json

# 2. Générer le lockfile via le stage development
make lock

# 3. Committer le lockfile
git add <lockfile>
git commit -m "chore: update lockfile"

# 4. En CI / production, l'infra build le stage production directement
docker build --target production -t my-service .
```

## Checklist

```
[ ] Dockerfile: stage `development` — COPY package.json uniquement, install libre
[ ] Dockerfile: stage `production` — COPY package.json + lockfile, install strict
[ ] compose.yaml: `target: development` (toujours, pas de variable)
[ ] Makefile: cible `lock` qui build, up, cp lockfile, down (via compose)
[ ] Lockfile commité dans le repo
[ ] Aucun `docker run --rm` pour la génération du lockfile
[ ] CI/production: build `--target production` hors compose (infra)
```

## Anti-patterns

- Utiliser un `ARG` conditionnel (`if/else`) au lieu de stages séparés → deux stages nommés sont plus lisibles et cachent mieux
- Utiliser une variable `${DOCKER_TARGET}` dans le compose → le compose est toujours `development`, la production est gérée par l'infra
- Lancer `docker run --rm <image> cat <lockfile> > <lockfile>` → utiliser `docker compose cp`
- Installer sans lockfile en production → toujours `--frozen-lockfile` / `--ci`
- Ne pas committer le lockfile → il fait partie du code source
- Copier le lockfile dans le stage `development` → il n'existe pas encore, et ce stage sert justement à le générer
- Oublier `docker compose down` dans `make lock` → laisse des containers orphelins
- Builder le stage `production` via compose en local → compose = dev, infra = prod

## Skills connexes

| Skill | Quand la consulter |
|:---|:---|
| [docker-hotreload-volume](../docker-hotreload-volume/SKILL.md) | Configurer le hot-reload avec volumes isolés (`node_modules`) dans un monorepo — pattern 3-layer volume stack + entrypoint de cache |
| [docker-compose-orchestration](../docker-compose-orchestration/SKILL.md) | Orchestrer plusieurs services (DB, cache, reverse proxy), gérer les réseaux, volumes et health checks |
| [docker-containerization](../docker-containerization/SKILL.md) | Bonnes pratiques générales de containerisation : sécurité, `.dockerignore`, images minimales |
| [multi-stage-dockerfile](../multi-stage-dockerfile/SKILL.md) | Guide générique multi-stage : choix d'images de base, optimisation des layers, sécurité |
| [docker-expert](../docker-expert/SKILL.md) | Expertise avancée : hardening sécurité, images distroless, cross-platform builds, diagnostics |
| [e2e-playwright](../e2e-playwright/SKILL.md) | Tests E2E via Docker Compose avec Playwright — profil `e2e`, compose override, parallélisme |
| [npm-private-registry](../npm-private-registry/SKILL.md) | Intégrer un registre npm privé dans un build Docker multi-stage (`.npmrc`, `NPM_TOKEN`, cleanup) |
