# Feature Specification: Rules Refactoring — Agnostic & Declarative

**Feature Branch**: `006-rules-refactoring-agnostic`
**Created**: 2026-04-24
**Status**: Draft
**Input**: Refactoring des rules pour les rendre déclaratives (état souhaitable) et agnostiques, migration du contenu procédural vers des skills

---

## User Scenarios & Testing

### User Story 1 — Toutes les rules décrivent un état souhaitable (Priority: P0)

Un développeur ou un agent IA consulte une rule et y trouve uniquement une **description de l'état souhaité** (invariants, contraintes, propriétés), jamais des instructions procédurales ("fais ceci, puis cela"). Les exemples utilisent du pseudo-code ou Go, pas un langage de framework spécifique.

**Why this priority**: C'est le cœur de la demande — sans cela, les rules restent des tutorials déguisés.
**Independent Test**: Relire chaque `.mdc` ; aucun ne contient de verbe impératif procédural (sauf dans des exemples).

**Acceptance Scenarios**:

1. **Given** la rule `0-makefile-structure.mdc`, **When** un agent la lit, **Then** elle décrit les propriétés attendues d'un Makefile (cibles obligatoires, conventions de nommage) sans fournir de template copier-coller.
2. **Given** la rule `3-lit.mdc`, **When** un agent la lit, **Then** elle est remplacée par une rule déclarative sur les Web Components ou déplacée intégralement en skill.
3. **Given** la rule `3-wc-live-demos-in-starlight.mdc`, **When** un agent la lit, **Then** le contenu procédural (pipeline de build, wiring d'events) est dans un skill, la rule ne retient que les invariants (isolation iframe, sync bidirectionnelle requise).

### User Story 2 — Classification des rules dans la bonne catégorie (Priority: P0)

Chaque rule est rangée dans le bon sous-dossier `rules/XX-category/` selon la taxonomie :
- `00-architecture` : structure filesystem, patterns d'architecture (agnostique)
- `01-standards` : normes de code, documentation, naming (agnostique)
- `02-programming-languages` : règles spécifiques à un langage (globs sur extensions)
- `03-frameworks-and-libraries` : règles spécifiques à un framework (globs sur paths)
- `04-tools-and-configurations` : outils (git, npm, docker…)
- `05-workflows-and-processes` : processus (spec-driven dev, indexation)
- `06-templates-and-models` : (vide pour l'instant, réservé)
- `07-quality-assurance` : testing, qualité
- `08-domain-specific-rules` : (vide pour l'instant, réservé)
- `09-other` : (vide pour l'instant, réservé)

**Why this priority**: La classification détermine le scope des globs et la pertinence RAG.
**Independent Test**: `ls rules/*/` montre uniquement les sous-dossiers attendus, chaque fichier `.mdc` est dans la bonne catégorie.

**Acceptance Scenarios**:

1. **Given** la rule `1-architecture-overview.mdc` (actuellement dans `01-project-fundamentals-and-architecture/`), **When** on la reclassifie, **Then** les parties agnostiques vont dans `00-architecture/` et les parties NestJS-spécifiques dans `03-frameworks-and-libraries/`.
2. **Given** les rules `2-explicit-typing.mdc` et `2-semantic-jsdoc.mdc`, **When** on les reclassifie, **Then** elles sont dans `02-programming-languages/` avec des globs ciblant `**/*.ts`.
3. **Given** `4-semantic-commits.mdc`, **When** on la lit, **Then** elle est dans `04-tools-and-configurations/` et reste agnostique (aucune mention de framework).

### User Story 3 — Globs cohérents et scoped (Priority: P1)

Chaque rule a un champ `globs` dans son frontmatter qui correspond exactement aux fichiers qu'elle concerne. Les rules d'architecture (`00-*`) ont des globs larges (`**/*` ou filesystem-level). Les rules de langage (`02-*`) ciblent les extensions. Les rules de framework (`03-*`) ciblent les paths spécifiques.

**Why this priority**: Sans globs corrects, les rules ne sont jamais chargées au bon moment.
**Independent Test**: Pour chaque rule, vérifier que le `globs` match les fichiers qu'elle est censée couvrir.

**Acceptance Scenarios**:

1. **Given** une rule sur la structure de dossier rules elle-même, **When** un agent édite `rules/**/*.mdc`, **Then** cette rule est chargée et rappelle la convention de nommage/structure.
2. **Given** la rule `3-flat-orchestration.mdc` (NestJS), **When** un agent édite un fichier `**/*.module.ts` ou `**/use-cases/**`, **Then** la rule est chargée via son glob.

### User Story 4 — Contenu procédural migré vers des skills (Priority: P1)

Tout contenu "comment faire" identifié dans les rules est extrait et placé dans un skill existant ou nouveau sous `skills/`. La rule conserve un lien `@see` vers le skill correspondant.

**Why this priority**: Séparer "quoi" (rule) de "comment" (skill) est le principe fondamental.
**Independent Test**: Aucune rule ne contient plus de 10 lignes de code consécutives servant de template/tutorial.

**Acceptance Scenarios**:

1. **Given** `0-makefile-structure.mdc` contient des templates Makefile complets, **When** on refactore, **Then** les templates sont dans un skill `makefile-conventions/SKILL.md`, la rule dit "un Makefile DOIT avoir les cibles `up`, `down`, `test`, `setup`" sans le code.
2. **Given** `3-wc-live-demos-in-starlight.mdc` est un tutorial complet, **When** on refactore, **Then** un skill `wc-live-demos-starlight/SKILL.md` contient le détail, la rule ne retient que les invariants.
3. **Given** `3-lit.mdc` est un cheatsheet, **When** on refactore, **Then** le contenu va dans le skill existant ou un nouveau skill `lit-web-components/SKILL.md`.

### User Story 5 — Exemples en pseudo-code / Go plutôt qu'en langage spécifique (Priority: P1)

Les rules des catégories agnostiques (`00-*`, `01-*`, `04-*`, `05-*`, `07-*`) utilisent du pseudo-code ou du Go pour les exemples, jamais un langage spécifique au projet.

**Why this priority**: Assure la réutilisabilité cross-projet.
**Independent Test**: Aucun exemple dans les rules `00-*` à `01-*` n'utilise de syntaxe TypeScript/NestJS/fp-ts.

**Acceptance Scenarios**:

1. **Given** la rule `0-hexagonal-ddd.mdc` mentionne `hono`, `prisma`, `ioredis`, **When** on refactore, **Then** ces mentions sont remplacées par des termes génériques (HTTPFramework, ORM, Cache).
2. **Given** la rule sur le testing mentionne Vitest, **When** on refactore, **Then** la partie agnostique (TDD, test pyramid) est en `07-*` avec pseudo-code, la partie Vitest-spécifique est en `03-*` ou skill.

### User Story 6 — Rule auto-descriptive sur la structure rules/ (Priority: P1)

Une nouvelle rule existe qui décrit la convention de la structure `rules/` elle-même : nommage des catégories, format des fichiers `.mdc`, frontmatter obligatoire, et nommage `{N}-{slug}.mdc`.

**Why this priority**: Le repo doit être auto-documenté sur ses propres conventions.
**Independent Test**: Un fichier `rules/00-architecture/0-rules-structure.mdc` existe et est appliqué quand on édite `rules/**/*.mdc`.

**Acceptance Scenarios**:

1. **Given** un agent crée une nouvelle rule, **When** il édite `rules/**/*.mdc`, **Then** la rule de structure est chargée et lui rappelle les conventions (catégories, frontmatter, globs).

### User Story 7 — Registry synchronisé (Priority: P0)

Après toutes les modifications, `make sync-registry` s'exécute sans erreur et le `asset-registry.yml` reflète l'état réel des fichiers.

**Why this priority**: Le registry est la source de vérité pour la découverte d'assets.
**Independent Test**: `make sync-registry` retourne 0 warnings.

**Acceptance Scenarios**:

1. **Given** des rules ont été renommées/déplacées, **When** on lance `make sync-registry`, **Then** les anciennes entrées sont supprimées et les nouvelles sont ajoutées.
2. **Given** de nouveaux skills ont été créés, **When** on lance `make sync-registry`, **Then** ils apparaissent dans le registry avec les bons tags.

### Edge Cases

- Une rule est à cheval entre deux catégories → la scinder en deux fichiers distincts.
- Un skill existe déjà pour le contenu extrait → enrichir le skill existant plutôt que d'en créer un nouveau.
- Les liens internes (`@see`, liens relatifs) dans les rules/skills doivent être mis à jour après les déplacements.
- Le fichier `.cursor/rules/specify-rules.mdc` et `rules/04-tools-and-configurations/4-specify-rules.mdc` doivent rester cohérents.

---

## Requirements

### Functional Requirements

- **FR-001**: Chaque fichier `.mdc` dans `rules/` DOIT contenir uniquement des déclarations d'état souhaitable (invariants, contraintes, propriétés), jamais des instructions procédurales ("fais X puis Y").
- **FR-002**: La structure `rules/` DOIT respecter la taxonomie à 10 catégories (00 à 09) avec les noms exacts spécifiés.
- **FR-003**: Chaque fichier `.mdc` DOIT avoir un frontmatter YAML avec au minimum : `description`, `globs`, `alwaysApply`, `tags`.
- **FR-004**: Les rules des catégories agnostiques (00, 01, 04, 05, 07) NE DOIVENT PAS contenir de syntaxe spécifique à un framework/langage dans leurs exemples — utiliser pseudo-code ou Go.
- **FR-005**: Tout contenu procédural ("comment faire") extrait d'une rule DOIT être placé dans un skill sous `skills/` avec un lien retour depuis la rule.
- **FR-006**: Une rule auto-descriptive DOIT exister pour décrire la convention de structure de `rules/` elle-même, appliquée via globs sur `rules/**/*.mdc`.
- **FR-007**: Les globs de chaque rule DOIVENT correspondre précisément aux fichiers qu'elle couvre (pas de globs trop larges ni trop restrictifs).
- **FR-008**: Le `asset-registry.yml` DOIT être synchronisé après toutes les modifications via `make sync-registry` sans erreur.
- **FR-009**: Les liens internes (relatifs et `@see`) DOIVENT rester valides après les déplacements/renommages.
- **FR-010**: Le dossier `01-project-fundamentals-and-architecture/` DOIT être renommé en `01-standards/`, et `02-programming-language/` en `02-programming-languages/`.

### Key Entities

- **Rule** (`.mdc`): fichier de convention déclarative avec frontmatter YAML
- **Skill** (`SKILL.md`): fichier de procédure/tutorial/how-to avec frontmatter YAML
- **Asset Registry** (`asset-registry.yml`): catalogue de tous les assets avec tags

---

## Success Criteria

- **SC-001**: 100% des fichiers `.mdc` passent un audit déclaratif : aucun verbe impératif procédural hors exemples.
- **SC-002**: `ls rules/` retourne exactement les 10 sous-dossiers de la taxonomie, rien d'autre.
- **SC-003**: `make sync-registry` s'exécute avec 0 avertissements et 0 erreurs.
- **SC-004**: Aucune rule agnostique (00, 01, 04, 05, 07) ne contient d'import/syntaxe TypeScript, NestJS, fp-ts, Zod, Vitest ou autre framework spécifique dans ses exemples.
- **SC-005**: Chaque rule `.mdc` a un `globs` non-vide qui cible correctement les fichiers pertinents.
- **SC-006**: Le nombre de skills a augmenté d'au moins 3 (contenu procédural extrait des rules).
- **SC-007**: Tous les liens internes dans les rules et skills sont valides (pas de 404).

---

## Assumptions

- Les catégories 06, 08, 09 sont créées vides (réservées pour l'avenir).
- Les exemples en Go ou pseudo-code sont suffisants pour illustrer les concepts sans perdre de précision.
- Le script `sync-asset-registry.ts` supporte déjà les nouvelles catégories de dossiers (il scanne `rules/**/*.mdc`).
