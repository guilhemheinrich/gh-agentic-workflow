---
name: npm-private-registry
description: "Integrate private npm packages in a Turborepo + bun + Docker monorepo. Use when adding a scoped private package (@org/pkg), configuring registry auth in Docker builds, or debugging NPM_TOKEN issues. Covers .npmrc, Dockerfile multi-stage, compose build args, and security cleanup."
---

# NPM Private Registry — Turborepo + Bun + Docker

Ce skill documente la procédure complète pour intégrer un package npm privé (scoped) dans un monorepo Turborepo + bun, avec des builds Docker multi-stage.

## Quand utiliser ce skill

- Ajout d'un nouveau package npm privé (ex: `@septeo-immo/calendar-wc`)
- Configuration initiale de l'accès à un registry privé
- Debugging d'erreurs `401 Unauthorized` ou `404 Not Found` lors de `bun install` dans Docker
- Ajout d'un nouveau scope npm privé (ex: `@autre-org/...`)
- Migration d'un package local (volume mount) vers un package publié sur un registry

## Prérequis

- Un token npm valide avec accès en lecture au scope privé
- Le token doit être dans `.env` (jamais commité)

## Architecture du flux d'authentification

```
.env (NPM_TOKEN=npm_xxxx)
    │
    ▼
compose.yaml ─── build.args.NPM_TOKEN: ${NPM_TOKEN:-}
    │
    ▼
Dockerfile ────── ARG NPM_TOKEN
                  ENV NPM_TOKEN=${NPM_TOKEN}
    │
    ▼
.npmrc ────────── //registry.npmjs.org/:_authToken=${NPM_TOKEN}
    │
    ▼
bun install ───── Authentification réussie
    │
    ▼
Nettoyage ─────── RUN rm -f .npmrc
                  ENV NPM_TOKEN=
```

## Procédure pas-à-pas

### Étape 1 — Configurer `.npmrc` à la racine du monorepo

Le `.npmrc` est **unique et à la racine** du monorepo. Bun le lit automatiquement.

```ini
# .npmrc (racine du monorepo)
@septeo-immo:registry=https://registry.npmjs.org/
//registry.npmjs.org/:_authToken=${NPM_TOKEN}
```

**Règles :**
- Un scope = une ligne `@scope:registry=...`
- Une ligne d'auth par registry `//registry.url/:_authToken=...`
- Utiliser `${NPM_TOKEN}` (interpolation d'env), jamais le token en dur
- **Pas de `.npmrc` dans les sous-packages** (`apps/`, `packages/`) — uniquement à la racine

Pour ajouter un second scope privé sur un registry différent :

```ini
# .npmrc
@septeo-immo:registry=https://registry.npmjs.org/
//registry.npmjs.org/:_authToken=${NPM_TOKEN}

@autre-org:registry=https://npm.pkg.github.com/
//npm.pkg.github.com/:_authToken=${GITHUB_TOKEN}
```

### Étape 2 — Déclarer `NPM_TOKEN` dans `.env.example`

```bash
# .env.example
# ─── NPM Private Registry ───────────────────────────────────
NPM_TOKEN=
```

Et dans `.env` (non commité) :

```bash
NPM_TOKEN=npm_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### Étape 3 — Configurer le Dockerfile (multi-stage)

Le pattern critique : le token n'existe que dans le stage de build, puis est supprimé.

```dockerfile
# Stage 1 — Installation des dépendances avec auth
FROM oven/bun:1.3-alpine AS deps

# ── Token pour le registry privé ──
ARG NPM_TOKEN
ENV NPM_TOKEN=${NPM_TOKEN}

WORKDIR /app

# ── Copier les fichiers nécessaires au résolution des dépendances ──
COPY package.json bun.lock* turbo.json ./
COPY apps/<service>/package.json apps/<service>/
# Si d'autres packages du monorepo sont des dépendances :
# COPY packages/shared/package.json packages/shared/
COPY .npmrc .npmrc

# ── Installer ──
RUN bun install --frozen-lockfile 2>/dev/null || bun install

# ── SÉCURITÉ : supprimer le token et le .npmrc ──
RUN rm -f .npmrc
ENV NPM_TOKEN=

# Stage 2 — Runtime (pas de token, pas de .npmrc)
FROM node:22-alpine
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY apps/<service>/ .
# ... reste de la config runtime
```

**Points critiques :**
- `ARG NPM_TOKEN` + `ENV NPM_TOKEN=${NPM_TOKEN}` : rend le token disponible pour `.npmrc`
- `COPY .npmrc .npmrc` : copié **avant** `bun install`
- `RUN rm -f .npmrc` + `ENV NPM_TOKEN=` : nettoyage **après** `bun install`
- Le stage 2 (`FROM node:22-alpine`) ne contient ni le token ni le `.npmrc`

### Étape 4 — Passer le token via `compose.yaml`

```yaml
services:
  frontend:
    build:
      context: .
      dockerfile: .docker/frontend/Dockerfile
      args:
        NPM_TOKEN: ${NPM_TOKEN:-}
```

**Règles :**
- `${NPM_TOKEN:-}` : valeur vide par défaut (pas d'erreur si absent)
- Le `context: .` doit être la racine du monorepo (pour accéder à `.npmrc`)
- Seuls les services qui dépendent de packages privés ont besoin du `build.args`

### Étape 5 — Ajouter la dépendance dans le bon `package.json`

```json
{
  "dependencies": {
    "@septeo-immo/calendar-wc": "*"
  }
}
```

Puis regénérer le lockfile :

```bash
# Via Docker (JAMAIS sur l'hôte)
docker compose exec <service> bun install
# Ou rebuild complet
docker compose up -d --build
```

## Checklist d'intégration d'un nouveau package privé

```
[ ] .npmrc : scope + auth configurés à la racine
[ ] .env.example : variable(s) de token documentée(s)
[ ] .env : token renseigné (non commité)
[ ] Dockerfile du service : ARG/ENV NPM_TOKEN, COPY .npmrc, cleanup post-install
[ ] compose.yaml : build.args.NPM_TOKEN passé au service
[ ] package.json : dépendance ajoutée dans le bon app/package
[ ] .dockerignore : .npmrc n'est PAS dans .dockerignore (nécessaire au build)
[ ] .gitignore : .env est ignoré (le token ne doit jamais être commité)
[ ] Test : docker compose up -d --build réussit
```

## Sécurité

### Ce qui est commité (safe)

| Fichier | Contenu sensible ? | Pourquoi c'est safe |
|---------|-------------------|---------------------|
| `.npmrc` | Non | Contient `${NPM_TOKEN}`, pas le token réel |
| `.env.example` | Non | Valeur vide `NPM_TOKEN=` |
| `Dockerfile` | Non | `ARG NPM_TOKEN` sans valeur par défaut |
| `compose.yaml` | Non | `${NPM_TOKEN:-}` référence `.env` |

### Ce qui n'est JAMAIS commité

| Fichier | Contenu | Protection |
|---------|---------|------------|
| `.env` | `NPM_TOKEN=npm_xxxx` | `.gitignore` |

### Protection dans l'image Docker

- Le token n'existe que dans le stage `deps` (stage 1)
- `RUN rm -f .npmrc` supprime le fichier de config
- `ENV NPM_TOKEN=` écrase la variable d'environnement
- Le stage 2 (`FROM node:22-alpine`) repart d'une image propre
- Seul `node_modules` est copié du stage 1 vers le stage 2

## Cas particuliers

### Service sans dépendance privée (ex: backend)

Pas besoin de `ARG NPM_TOKEN` ni de `COPY .npmrc` dans le Dockerfile :

```dockerfile
FROM oven/bun:1.3-alpine AS deps
WORKDIR /app
COPY package.json bun.lock* turbo.json ./
COPY apps/backend/package.json apps/backend/
COPY packages/shared/package.json packages/shared/
# Pas de COPY .npmrc, pas de ARG NPM_TOKEN
RUN bun install --frozen-lockfile 2>/dev/null || bun install
```

### Dev local avec volume mount (override du package)

Pour utiliser une version locale d'un package privé en développement :

```yaml
# compose.yaml
volumes:
  - ${CALENDAR_WC_PATH:-../calendar-wc}:/calendar-wc:ro
```

```sh
# entrypoint.sh
if [ -d "/calendar-wc" ] && [ -f "/calendar-wc/package.json" ]; then
  cd /calendar-wc && bun link 2>/dev/null || true
  cd /app && bun link @septeo-immo/calendar-wc 2>/dev/null || true
fi
```

### Plusieurs tokens pour plusieurs registries

```ini
# .npmrc
@septeo-immo:registry=https://registry.npmjs.org/
//registry.npmjs.org/:_authToken=${NPM_TOKEN}

@github-org:registry=https://npm.pkg.github.com/
//npm.pkg.github.com/:_authToken=${GITHUB_TOKEN}
```

```yaml
# compose.yaml
build:
  args:
    NPM_TOKEN: ${NPM_TOKEN:-}
    GITHUB_TOKEN: ${GITHUB_TOKEN:-}
```

```dockerfile
ARG NPM_TOKEN
ARG GITHUB_TOKEN
ENV NPM_TOKEN=${NPM_TOKEN}
ENV GITHUB_TOKEN=${GITHUB_TOKEN}
# ... bun install ...
RUN rm -f .npmrc
ENV NPM_TOKEN=
ENV GITHUB_TOKEN=
```

## Debugging

### Erreur `401 Unauthorized` pendant `bun install`

1. Vérifier que `NPM_TOKEN` est dans `.env`
2. Vérifier que `compose.yaml` passe `args.NPM_TOKEN`
3. Vérifier que le Dockerfile a `ARG NPM_TOKEN` + `ENV NPM_TOKEN`
4. Vérifier que `.npmrc` est copié **avant** `bun install`
5. Tester le token : `npm whoami --registry=https://registry.npmjs.org/`

### Erreur `404 Not Found` pour un package scoped

1. Vérifier le scope dans `.npmrc` : `@scope:registry=...`
2. Vérifier que le nom du package correspond au scope (ex: `@septeo-immo/calendar-wc`)
3. Vérifier que le package est publié sur le bon registry

### `bun install` fonctionne en local mais pas dans Docker

1. Vérifier que `.npmrc` n'est pas dans `.dockerignore`
2. Vérifier l'ordre des `COPY` : `.npmrc` doit être copié avant `RUN bun install`
3. Vérifier que le `context` du build est la racine du monorepo (pour accéder à `.npmrc`)

## Anti-patterns

- Mettre le token en dur dans `.npmrc` ou le Dockerfile
- Laisser `.npmrc` ou `NPM_TOKEN` dans l'image finale
- Créer des `.npmrc` par sous-package au lieu d'un seul à la racine
- Passer `NPM_TOKEN` dans `environment` au lieu de `build.args` (inutile au runtime)
- Ajouter `.npmrc` au `.dockerignore` (empêche le build)
- Exécuter `bun install` sur l'hôte pour résoudre les packages privés
