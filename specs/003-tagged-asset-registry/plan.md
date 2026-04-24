# Implementation Plan: Tagged Asset Registry

**Branch**: `003-tagged-asset-registry` | **Date**: 2026-04-23 | **Spec**: [spec.md](./spec.md)

---

## Summary

Créer un registre YAML centralisé (`asset-registry.yml`) associant chaque asset du workspace (skill, command, rule, agent, hook) à des tags thématiques, validé par un JSON Schema strict (`asset-registry.schema.json`). L'inventaire couvre ~100 assets répartis sur 6 répertoires du workspace.

---

## Technical Context

| Champ | Valeur |
|-------|--------|
| **Format registre** | YAML (éditable humainement, supporté par VS Code) |
| **Validation** | JSON Schema draft 2020-12 |
| **Compatibilité** | ajv, VS Code YAML extension (redhat.vscode-yaml), jsonschema (Python) |
| **Scope v1** | Workspace `gh-agentic-workflow` uniquement |

---

## Architecture Decision

### Fichier unique vs multi-fichiers

**Choix : fichier unique** `asset-registry.yml` à la racine.

- Avantage : un seul fichier à consulter, pas de merge cross-fichiers.
- Inconvénient : fichier long (~100 entrées) — acceptable car le YAML est lisible et triable.
- Évolution : si le fichier dépasse 500 entrées, on pourra splitter par `type` (un fichier par type) en gardant le même schema.

### Tags : enum dans le schema vs fichier séparé

**Choix : enum dans `$defs.tag`** du JSON Schema, avec un objet `x-tag-descriptions` à la racine du schema.

- Les tags sont centralisés dans un seul endroit.
- L'ajout d'un tag = modifier l'enum + ajouter la description.
- `x-tag-descriptions` est un champ d'extension JSON Schema (convention `x-`) pour stocker les descriptions humaines.

---

## Tag Taxonomy

Tags déduits de l'inventaire des assets existants sur la machine :

| Tag | Description |
|-----|-------------|
| `common` | Transverse, applicable à tout projet |
| `typescript` | TypeScript / JavaScript |
| `python` | Python |
| `nestjs` | NestJS framework |
| `fp-ts` | fp-ts / Effect functional programming |
| `vue` | Vue.js ecosystem |
| `nuxt` | Nuxt framework |
| `react` | React ecosystem |
| `docker` | Docker, Dockerfile, images |
| `docker-compose` | Docker Compose orchestration |
| `git` | Git, branching, commits |
| `github` | GitHub CLI, Actions, PRs |
| `bitbucket` | Bitbucket Pipelines |
| `ci-cd` | CI/CD pipelines, releases |
| `testing` | Tests unitaires, intégration |
| `e2e` | Tests end-to-end (Playwright, Cypress) |
| `eslint` | Linting, static analysis |
| `validation` | Validation (Zod, Effect Schema, io-ts) |
| `npm` | npm, registre privé, packages |
| `monorepo` | Turborepo, workspaces |
| `documentation` | Documentation, Diátaxis, JSDoc |
| `architecture` | Patterns d'architecture (hexagonal, DDD, vertical slices) |
| `backend` | Patterns backend génériques |
| `security` | Sécurité, hardening |
| `auth` | Authentification, SSO, Keycloak |
| `prisma` | Prisma ORM |
| `sentry` | Sentry observability |
| `sonarqube` | SonarQube quality |
| `kubernetes` | Kubernetes, Helm |
| `make` | Makefile patterns |
| `spec-kit` | SpecKit workflow |
| `cursor` | Cursor IDE skills, hooks, rules |
| `web-components` | Lit, Web Components |
| `css` | CSS, Tailwind, UX layout |
| `astro` | Astro / Starlight |
| `versioning` | Versioning, semantic-release |
| `debugging` | Debugging, investigation |
| `refactoring` | Refactoring, amélioration de code |
| `shell` | Shell scripts, CLI tools |

---

## JSON Schema Design

```jsonc
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "asset-registry.schema.json",
  "title": "Asset Registry",
  "description": "Schema for the tagged asset registry YAML file",
  "type": "object",
  "required": ["version", "assets"],
  "properties": {
    "version": { "type": "string", "pattern": "^\\d+\\.\\d+\\.\\d+$" },
    "assets": {
      "type": "array",
      "items": { "$ref": "#/$defs/assetEntry" }
    }
  },
  "x-tag-descriptions": { /* tag → description map */ },
  "$defs": {
    "tag": {
      "type": "string",
      "enum": [ /* voir Tag Taxonomy ci-dessus */ ]
    },
    "assetType": {
      "type": "string",
      "enum": ["skill", "command", "rule", "agent", "hook"]
    },
    "assetEntry": {
      "type": "object",
      "required": ["path", "type", "tags"],
      "properties": {
        "path": {
          "type": "string",
          "description": "Chemin relatif depuis la racine du workspace"
        },
        "type": { "$ref": "#/$defs/assetType" },
        "tags": {
          "type": "array",
          "items": { "$ref": "#/$defs/tag" },
          "minItems": 1,
          "uniqueItems": true
        },
        "description": {
          "type": "string",
          "description": "Description courte de l'asset"
        }
      },
      "additionalProperties": false
    }
  },
  "additionalProperties": false
}
```

---

## YAML Registry Design

```yaml
# yaml-language-server: $schema=./asset-registry.schema.json
version: "1.0.0"

assets:
  - path: skills/docker-expert/SKILL.md
    type: skill
    tags: [docker, common]
    description: "Advanced Docker containerization expert"

  - path: rules/02-programming-language/2-explicit-typing.mdc
    type: rule
    tags: [typescript]
    description: "Rule 1 — Explicit typing in domain code"

  # ... ~100 entrées
```

---

## Project Structure (nouveaux fichiers)

```text
gh-agentic-workflow/
├── asset-registry.schema.json    # JSON Schema (nouveau)
├── asset-registry.yml            # Registre YAML (nouveau)
└── specs/003-tagged-asset-registry/
    ├── prompt.md
    ├── spec.md
    ├── plan.md
    ├── tasks.md
    └── stats.md
```

---

## Implementation Strategy

### Phase 1: Foundation — Schema

1. Créer `asset-registry.schema.json` avec le design ci-dessus
2. Inclure tous les tags de la taxonomy
3. Inclure `x-tag-descriptions` pour chaque tag

### Phase 2: Core — Registre YAML

1. Inventorier tous les assets du workspace (skills, commands, rules, agents, hooks)
2. Attribuer les tags à chaque asset (basé sur l'inventaire de l'exploration)
3. Écrire `asset-registry.yml`
4. Ajouter le commentaire `yaml-language-server: $schema=` pour la validation in-IDE

### Phase 3: Validation

1. Valider le YAML contre le schema (via Docker + ajv-cli ou jsonschema Python)
2. Vérifier qu'aucun tag de l'enum n'est orphelin (utilisé par au moins un asset)
3. Vérifier que tous les paths référencés existent

---

## Dependencies

- Aucune dépendance runtime à installer
- Outils de validation disponibles via Docker si besoin (`ajv-cli`, `jsonschema`)
- VS Code YAML extension pour validation in-IDE (déjà supposée installée)
