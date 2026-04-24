# Feature Specification: Tagged Asset Registry

**Feature Branch**: `003-tagged-asset-registry`
**Created**: 2026-04-23
**Status**: Draft
**Input**: Grouper skills/commands/rules/hooks par module thématique via un fichier YAML tagué, validé par JSON Schema.

---

## Contexte

Le projet `gh-agentic-workflow` accumule des **assets AI** (skills, commands, rules, agents, hooks) répartis sur plusieurs emplacements :

- Workspace : `skills/`, `.agents/skills/`, `commands/`, `.cursor/commands/`, `rules/`, `.cursor/rules/`, `agents/`
- User-level : `~/.cursor/skills/`, `~/.cursor/rules/`, `~/.cursor/skills-cursor/`, `~/.cursor/hooks.json`
- Plugin cache : `~/.cursor/plugins/cache/*/`

Il n'existe aucun mécanisme pour **filtrer** ces assets par thème (ex. "donne-moi tout ce qui concerne Docker", "quelles rules s'appliquent au TypeScript ?"). Le besoin est un **registre tagué** : un fichier YAML centralisé associant chaque asset à un ou plusieurs tags, validé par un JSON Schema strict.

---

## User Scenarios & Testing

### User Story 1 — Consulter les assets par thème (Priority: P1)

En tant qu'utilisateur du workflow agentic, je veux pouvoir lister tous les skills / commands / rules / agents / hooks rattachés à un tag donné, afin de charger dynamiquement le contexte pertinent pour une tâche.

**Why this priority**: C'est le cas d'usage fondamental ; sans lui le registre n'a aucune utilité.
**Independent Test**: Lire le YAML, filtrer par tag `docker` → obtenir la liste attendue de paths.

**Acceptance Scenarios**:

1. **Given** le fichier `asset-registry.yml` existe et contient des entrées taguées, **When** je filtre par tag `typescript`, **Then** j'obtiens tous les assets ayant le tag `typescript` (skills fp-ts-*, rules R1-R4, etc.)
2. **Given** un asset possède les tags `[docker, ci-cd]`, **When** je filtre par `docker`, **Then** cet asset apparaît. **When** je filtre par `ci-cd`, **Then** il apparaît aussi.
3. **Given** je filtre par un tag qui n'existe pas dans le schema, **When** la validation JSON Schema s'exécute, **Then** une erreur de validation est levée.

### User Story 2 — Maintenir le registre (Priority: P1)

En tant que mainteneur, je veux que le format YAML soit validable par un JSON Schema, afin de garantir la cohérence des tags et la structure du fichier.

**Why this priority**: Sans validation, le registre divergera rapidement (typos dans les tags, format cassé).
**Independent Test**: Valider le YAML contre le JSON Schema avec un outil standard (ajv, yamllint + jsonschema).

**Acceptance Scenarios**:

1. **Given** le fichier YAML, **When** je le valide contre `asset-registry.schema.json`, **Then** aucune erreur si le fichier est conforme.
2. **Given** un tag non listé dans l'enum du schema, **When** je valide, **Then** une erreur indique le tag invalide.
3. **Given** une entrée sans le champ `tags`, **When** je valide, **Then** une erreur indique le champ manquant.

### User Story 3 — Découvrir les tags disponibles (Priority: P2)

En tant qu'utilisateur, je veux connaître l'ensemble des tags possibles et leur description, afin de savoir comment classifier un nouvel asset.

**Why this priority**: Facilite l'onboarding et l'extension du registre.
**Independent Test**: Lire la section `$defs.tag` du JSON Schema → les tags et descriptions sont listés.

**Acceptance Scenarios**:

1. **Given** le JSON Schema, **When** je lis `$defs.tag.enum`, **Then** j'obtiens la liste exhaustive des tags autorisés.
2. **Given** le JSON Schema, **When** je lis `$defs.tag.x-descriptions`, **Then** chaque tag a une description human-readable.

---

## Edge Cases

- Un path référencé dans le YAML n'existe pas sur le filesystem → le schema ne valide pas l'existence (responsabilité d'un outil externe, hors scope v1).
- Un asset est dans le registre workspace ET dans le registre user-level → chaque registre est indépendant (un par scope). Pas de merge automatique en v1.
- Le fichier YAML est vide ou absent → le schema autorise un objet `assets` vide (`minItems: 0`).

---

## Requirements

### Functional Requirements

- **FR-001**: Le système DOIT fournir un fichier `asset-registry.yml` à la racine du projet, contenant une liste d'entrées `{ path, type, tags, description? }`.
- **FR-002**: Le système DOIT fournir un fichier `asset-registry.schema.json` (JSON Schema draft 2020-12) validant la structure du YAML.
- **FR-003**: Le JSON Schema DOIT définir un enum centralisé de tags autorisés, extensible par ajout à l'enum.
- **FR-004**: Chaque entrée du registre DOIT avoir un `type` parmi : `skill`, `command`, `rule`, `agent`, `hook`.
- **FR-005**: Chaque entrée DOIT avoir au moins un tag.
- **FR-006**: Le JSON Schema DOIT accepter un champ optionnel `description` par entrée.
- **FR-007**: Le JSON Schema DOIT inclure un champ `$schema` et `version` au niveau racine pour tracer l'évolution du format.
- **FR-008**: Le registre DOIT couvrir les assets du workspace (`skills/`, `commands/`, `rules/`, `agents/`, `.cursor/commands/`, `.agents/skills/`).

### Non-Functional Requirements

- **NFR-001**: Le YAML DOIT être lisible et éditable manuellement (pas de génération binaire).
- **NFR-002**: Le JSON Schema DOIT être compatible avec les validateurs standard (ajv, jsonschema, VS Code YAML extension).

---

## Key Entities

- **AssetEntry**: `{ path: string, type: AssetType, tags: Tag[], description?: string }`
- **AssetType**: enum `skill | command | rule | agent | hook`
- **Tag**: enum centralisé dans le schema (voir plan.md pour la liste déduite de l'inventaire)
- **AssetRegistry**: `{ $schema: string, version: string, assets: AssetEntry[] }`

---

## Success Criteria

- **SC-001**: 100% des assets existants du workspace sont référencés dans `asset-registry.yml`.
- **SC-002**: Le fichier YAML passe la validation JSON Schema sans erreur.
- **SC-003**: Le filtrage par n'importe quel tag retourne au moins un asset (aucun tag orphelin dans le schema).
- **SC-004**: L'ajout d'un nouveau tag nécessite uniquement la modification de l'enum dans le schema + l'ajout de la description.

---

## Assumptions

- Le scope v1 ne couvre que le workspace `gh-agentic-workflow`, pas les assets user-level (`~/.cursor/`). L'extension aux scopes user/plugin est prévue dans une itération future.
- Les paths sont relatifs à la racine du workspace.
- Aucun outillage CLI de query n'est dans le scope de cette spec (prévu comme étape suivante).
