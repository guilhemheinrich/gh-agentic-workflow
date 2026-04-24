# Tasks: Tag Frontmatter & Sync Script

## Phase 1: Backfill des frontmatters

**Purpose**: Ajouter la clé `tags` dans le frontmatter de chaque asset existant, basé sur les tags de `asset-registry.yml`.

- [x] T001 [P] Ajouter `tags:` dans le frontmatter de chaque fichier `skills/*/SKILL.md` (basé sur le registre existant)
- [x] T002 [P] Ajouter `tags:` dans le frontmatter de chaque fichier `.agents/skills/*/SKILL.md`
- [x] T003 [P] Ajouter `tags:` dans le frontmatter de chaque fichier `commands/*.md`
- [x] T004 [P] Ajouter `tags:` dans le frontmatter de chaque fichier `.cursor/commands/*.md`
- [x] T005 [P] Ajouter `tags:` dans le frontmatter de chaque fichier `.specify/extensions/**/commands/*.md`
- [x] T006 [P] Ajouter `tags:` dans le frontmatter de chaque fichier `rules/**/*.mdc` et `.cursor/rules/*.mdc`
- [x] T007 [P] Ajouter `tags:` dans le frontmatter de chaque fichier `agents/*.md`

**Checkpoint**: Tous les assets avec frontmatter ont une clé `tags`. Vérification par grep.

## Phase 2: Script de synchronisation

**Purpose**: Créer le script TypeScript qui lit les frontmatters et synchronise schema + registre.

- [x] T008 Créer `package.json` avec les dépendances (`gray-matter`, `js-yaml`, `tsx`, `glob`)
- [x] T009 Implémenter le module de scan récursif des dossiers dans `scripts/sync-asset-registry.ts`
- [x] T010 Implémenter le parsing du frontmatter avec `gray-matter` (support .md et .mdc)
- [x] T011 Implémenter la logique de détermination du type d'asset (`skill`, `command`, `rule`, `agent`) selon le dossier
- [x] T012 Implémenter la mise à jour du schema (`$defs.tag.enum`, `x-tag-descriptions.properties`, `x-tag-descriptions.required`)
- [x] T013 Implémenter la mise à jour du registre YAML (ajout + mise à jour des tags, mode additif)
- [x] T014 Implémenter le rapport d'intégrité (warnings : paths orphelins, fichiers sans tags, tags inconnus)
- [x] T015 Implémenter la sortie console structurée (résumé : assets scannés, ajoutés, mis à jour, warnings)

**Checkpoint**: Le script s'exécute et produit un résultat cohérent.

## Phase 3: Intégration Docker

**Purpose**: Rendre le script exécutable via Docker conformément à la règle projet.

- [x] T016 Ajouter un target `sync-registry` dans le Makefile (ou créer le Makefile si absent)
- [x] T017 Vérifier l'exécution complète via Docker (`make sync-registry`)

**Checkpoint**: Le script tourne via Docker et le registre est à jour.

## Phase 4: Validation

**Purpose**: Vérifier la cohérence du résultat et l'idempotence.

- [x] T018 Exécuter le script et vérifier que `asset-registry.yml` est cohérent avec les frontmatters
- [x] T019 Ré-exécuter le script et vérifier qu'aucune modification n'est produite (idempotence)
- [x] T020 Valider `asset-registry.yml` contre `asset-registry.schema.json`

**Checkpoint**: Registre valide, cohérent, et script idempotent.

## Dependency Graph

```
Phase 1 (T001–T007) → Phase 2 (T008–T015) → Phase 3 (T016–T017) → Phase 4 (T018–T020)
```

Note : Phase 1 et Phase 2 (T008) peuvent démarrer en parallèle, mais le test du script (T018+) nécessite que les frontmatters soient en place.

## Summary

- Total tasks: 20
- Parallelisable: T001–T007 (backfill par type), T008 (package.json)
- Estimated effort: ~1j/h humain, ~20min AI
