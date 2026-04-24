# Tasks: Tagged Asset Registry

## Phase 1: Setup

**Purpose**: Créer les fichiers de base et la structure du schema.

- [ ] T001 Créer `asset-registry.schema.json` avec la structure racine (`version`, `assets`, `$defs`)
- [ ] T002 Définir l'enum `$defs.tag` avec les ~38 tags de la taxonomy
- [ ] T003 Définir l'enum `$defs.assetType` (`skill`, `command`, `rule`, `agent`, `hook`)
- [ ] T004 Définir `$defs.assetEntry` avec `path`, `type`, `tags`, `description?`
- [ ] T005 Ajouter `x-tag-descriptions` à la racine du schema (description humaine de chaque tag)

**Checkpoint**: Le JSON Schema est complet et auto-cohérent.

## Phase 2: Registre YAML — Remplissage

**Purpose**: Inventorier et taguer tous les assets du workspace.

- [ ] T006 Créer `asset-registry.yml` avec l'en-tête (`yaml-language-server: $schema=`, `version: "1.0.0"`)
- [ ] T007 [P] Enregistrer tous les skills (`skills/*/SKILL.md`) avec leurs tags
- [ ] T008 [P] Enregistrer tous les skills agents (`.agents/skills/*/SKILL.md`) avec leurs tags
- [ ] T009 [P] Enregistrer tous les commands (`commands/*.md`) avec leurs tags
- [ ] T010 [P] Enregistrer tous les commands Cursor (`.cursor/commands/*.md`) avec leurs tags
- [ ] T011 [P] Enregistrer tous les commands SpecKit extensions (`.specify/extensions/*/commands/*.md`) avec leurs tags
- [ ] T012 [P] Enregistrer toutes les rules (`rules/**/*.mdc`) avec leurs tags
- [ ] T013 [P] Enregistrer la rule Cursor (`.cursor/rules/specify-rules.mdc`) avec ses tags
- [ ] T014 [P] Enregistrer tous les agents (`agents/*.md`) avec leurs tags

**Checkpoint**: Tous les assets du workspace sont dans le registre YAML.

## Phase 3: Validation

**Purpose**: Vérifier la conformité du registre et la cohérence des données.

- [ ] T015 Valider `asset-registry.yml` contre `asset-registry.schema.json` (via Docker ajv-cli ou jsonschema)
- [ ] T016 Vérifier que chaque path référencé dans le YAML existe sur le filesystem
- [ ] T017 Vérifier qu'aucun tag de l'enum n'est orphelin (au moins un asset par tag — ou documenter les tags sans asset)

**Checkpoint**: Le registre est valide, complet et cohérent.

## Dependency Graph

```
Phase 1 (T001–T005) → Phase 2 (T006–T014) → Phase 3 (T015–T017)
```

## Summary

- Total tasks: 17
- By priority: P1=17
- Parallelisable: T007–T014 (remplissage par type d'asset)
- Estimated effort: ~2h humain, ~15min AI
