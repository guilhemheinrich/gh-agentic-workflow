# Tasks: Rules Refactoring — Agnostic & Declarative

## Phase 1: Structure & Meta-rule (Shared Infrastructure)

**Purpose**: Mettre en place la taxonomie de dossiers et la rule auto-descriptive.

- [ ] T001 Créer les dossiers manquants : `rules/06-templates-and-models/`, `rules/08-domain-specific-rules/`, `rules/09-other/` (avec un `.gitkeep` dans chacun)
- [ ] T002 Renommer `rules/01-project-fundamentals-and-architecture/` → `rules/01-standards/`
- [ ] T003 Renommer `rules/02-programming-language/` → `rules/02-programming-languages/`
- [ ] T004 Créer `rules/00-architecture/0-rules-structure.mdc` — rule auto-descriptive sur la convention de structure `rules/` (catégories, nommage `{N}-{slug}.mdc`, frontmatter obligatoire, globs: `rules/**/*.mdc`)

**Checkpoint**: La structure de dossiers est conforme à la taxonomie à 10 catégories.

## Phase 2: Extraction vers Skills (Contenu procédural → Skills)

**Purpose**: Déplacer tout contenu "comment faire" des rules vers des skills.

- [ ] T005 [P] Créer `skills/makefile-conventions/SKILL.md` — extraire les templates Makefile complets (env vars, targets `up`/`down`/`test`/`setup`/`db-*`) depuis `rules/00-architecture/0-makefile-structure.mdc`
- [ ] T006 [P] Créer `skills/lit-web-components/SKILL.md` — extraire le cheatsheet Lit complet depuis `rules/03-frameworks-and-libraries/3-lit.mdc` (lifecycle, templates, events, overlay patterns, anti-patterns)
- [ ] T007 [P] Créer `skills/wc-live-demos-starlight/SKILL.md` — extraire le tutorial complet depuis `rules/03-frameworks-and-libraries/3-wc-live-demos-in-starlight.mdc` (architecture iframe, bidirectional sync, controlled pattern, build pipeline, Docker pitfalls)

**Checkpoint**: 3 nouveaux skills créés avec contenu procédural complet.

## Phase 3: Réécriture des Rules — Agnostiques (00-architecture)

**Purpose**: Rendre les rules d'architecture indépendantes de tout framework.

- [ ] T008 Réécrire `rules/00-architecture/0-hexagonal-ddd.mdc` — remplacer Hono/Prisma/Redis par des termes génériques (HTTPFramework, ORM, Cache). Exemples en pseudo-code/Go. Garder les invariants (direction des dépendances, pureté du domaine, patterns obligatoires).
- [ ] T009 Réécrire `rules/00-architecture/0-makefile-structure.mdc` — réduire aux invariants déclaratifs uniquement : "un Makefile DOIT avoir les cibles X, Y, Z", "les valeurs DOIVENT être configurables via variables". Supprimer tous les blocs de code template. Ajouter `@see skills/makefile-conventions/SKILL.md`.
- [ ] T010 Réécrire `rules/00-architecture/0-monorepo.mdc` — remplacer Bun 1.3/Turborepo 2.8 par des concepts agnostiques (workspace isolation, dependency graph, no circular deps). Exemples en pseudo-code.

**Checkpoint**: Les 3 rules de `00-architecture/` sont agnostiques.

## Phase 4: Scission et reclassification (01-standards, extrait de 01-project-fundamentals)

**Purpose**: Déplacer les rules reclassifiées dans les bons dossiers.

- [ ] T011 Scinder `rules/01-standards/1-architecture-overview.mdc` : extraire la partie agnostique (vertical slices, functional core / imperative shell, decision tree) → nouveau fichier `rules/00-architecture/0-vertical-slices.mdc` en pseudo-code/Go.
- [ ] T012 Créer `rules/03-frameworks-and-libraries/3-nestjs-architecture.mdc` — contenu NestJS/fp-ts extrait de `1-architecture-overview.mdc` (stack table, canonical layout NestJS, rule index R1-R7, skill links). Supprimer l'ancien `1-architecture-overview.mdc`.
- [ ] T013 Réécrire `rules/01-standards/1-code-documentation-for-indexing.mdc` — remplacer les exemples TypeScript/JSDoc par du pseudo-code. Le principe (documentation riche pour embeddings) reste.
- [ ] T014 Créer `rules/01-standards/1-pure-domain.mdc` — version agnostique de la règle pure domain : pas de side effects dans le domaine, erreurs typées comme valeurs (pas d'exceptions), pas d'I/O. Exemples en pseudo-code/Go. Différent de `02-*/2-pure-domain.mdc` qui reste spécifique fp-ts/TypeScript.

**Checkpoint**: `01-standards/` contient des rules agnostiques, les parties framework sont dans `03-*`.

## Phase 5: Réécriture des Rules — Frameworks (03-*)

**Purpose**: Réduire les rules framework à des invariants + ref vers skills.

- [ ] T015 Réécrire `rules/03-frameworks-and-libraries/3-lit.mdc` — réduire à une rule déclarative minimale : "un Web Component Lit DOIT suivre les patterns de réactivité et de lifecycle du framework". Le détail procédural est dans le skill. Ajouter `@see skills/lit-web-components/SKILL.md`.
- [ ] T016 Réécrire `rules/03-frameworks-and-libraries/3-wc-live-demos-in-starlight.mdc` — réduire aux invariants : iframe isolation obligatoire, bidirectional sync requis, vanilla WC pour le playground. Le détail → skill. Ajouter `@see skills/wc-live-demos-starlight/SKILL.md`.
- [ ] T017 [P] Vérifier et ajuster les globs de `3-flat-orchestration.mdc`, `3-module-isolation.mdc`, `3-typed-boundaries.mdc` — s'assurer qu'ils ciblent les bons paths NestJS.

**Checkpoint**: Les rules `03-*` sont des invariants avec refs vers skills.

## Phase 6: Réécriture des Rules — Tools & Workflows (04-*, 05-*)

**Purpose**: Nettoyer les rules d'outils et workflows.

- [ ] T018 [P] Nettoyer `rules/04-tools-and-configurations/4-npm-private-registry.mdc` — garder les conventions déclaratives (token flow, sécurité), déplacer les étapes step-by-step vers le skill existant `skills/npm-private-registry/SKILL.md`.
- [ ] T019 [P] Nettoyer `rules/05-workflows-and-processes/5-spec-driven-dev.mdc` — supprimer les références au roadmap Modelo (phases 0-5), garder uniquement le workflow SpecKit agnostique.
- [ ] T020 [P] Mettre à jour `rules/04-tools-and-configurations/4-specify-rules.mdc` — simplifier le meta-pointeur, retirer les refs NestJS spécifiques.

**Checkpoint**: Les rules 04-* et 05-* sont agnostiques.

## Phase 7: Réécriture — Quality Assurance (07-*)

**Purpose**: Scinder testing en agnostique + spécifique.

- [ ] T021 Réécrire `rules/07-quality-assurance/7-testing.mdc` — garder uniquement les principes TDD agnostiques (red-green-refactor, test pyramid, naming conventions, AAA pattern). Exemples en pseudo-code/Go. Déplacer les parties Vitest-spécifiques vers `rules/03-frameworks-and-libraries/3-vitest-conventions.mdc` ou directement dans un skill.

**Checkpoint**: `07-*` est agnostique.

## Phase 8: Mise à jour des globs et liens

**Purpose**: S'assurer que chaque rule est chargée au bon moment.

- [ ] T022 [P] Auditer et mettre à jour les `globs` de chaque fichier `.mdc` — vérifier que les globs matchent les fichiers visés, pas plus.
- [ ] T023 [P] Mettre à jour tous les liens internes (relatifs, `@see`) dans les rules et skills après les déplacements/renommages.
- [ ] T024 Mettre à jour `.cursor/rules/specify-rules.mdc` — refléter la nouvelle structure et retirer les refs NestJS spécifiques.

**Checkpoint**: Tous les globs sont corrects, tous les liens sont valides.

## Phase 9: Sync Registry & Validation finale

**Purpose**: Synchroniser le registry et valider la cohérence.

- [ ] T025 Exécuter `make sync-registry` dans un conteneur Docker et résoudre toutes les erreurs/warnings.
- [ ] T026 Valider manuellement : `ls rules/*/` montre les 10 catégories, chaque `.mdc` a un frontmatter complet, aucun contenu procédural dans les rules agnostiques.

**Checkpoint**: Registry synchronisé, 0 warnings, structure validée.

## Dependency Graph

```
Phase 1 (Structure) → Phase 2 (Skills) → Phase 3 (Rules 00-*) → Phase 4 (01-* scission) → Phase 5 (03-*) → Phase 6 (04-*, 05-*) → Phase 7 (07-*) → Phase 8 (Globs/Liens) → Phase 9 (Sync/Validation)
```

Phase 2 tasks sont parallélisables (T005, T006, T007).
Phase 6 tasks sont parallélisables (T018, T019, T020).
Phase 8 tasks sont parallélisables (T022, T023).

## Summary

- Total tasks: 26
- By priority: P0 (structure + reclassification) = 14, P1 (contenu + globs) = 12
- Estimated effort: ~3-4h agent, ~2j/h humain
