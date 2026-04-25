# Implementation Plan: Rules Refactoring — Agnostic & Declarative

**Branch**: `006-rules-refactoring-agnostic` | **Date**: 2026-04-24 | **Spec**: [spec.md](./spec.md)

## Summary

Refactorer les 21 fichiers `.mdc` existants pour qu'ils décrivent exclusivement un état souhaitable (invariants, contraintes), extraire le contenu procédural vers des skills, reclassifier dans la taxonomie à 10 catégories, et généraliser les exemples en pseudo-code/Go.

## Technical Context

**Scope**: Fichiers `.mdc` (rules) et `SKILL.md` (skills) — aucun code applicatif.
**Outil de sync**: `make sync-registry` (Docker + Node 22 + tsx)
**Aucune dépendance nouvelle** — restructuration de fichiers markdown uniquement.

## Audit des Rules Actuelles — Diagnostic par Fichier

### Catégorie 00-architecture (RESTE — renforcer l'agnosticisme)

| Fichier actuel | Diagnostic | Action |
|---|---|---|
| `0-hexagonal-ddd.mdc` | Mentionne Hono, Prisma, Redis, @nestjs — trop spécifique | Réécrire en hexagonal agnostique (pseudo-code/Go). Déplacer les patterns Hono dans `03-frameworks-and-libraries/` ou un skill. |
| `0-makefile-structure.mdc` | Contient ~100 lignes de templates Makefile copier-coller | Garder uniquement les invariants (cibles obligatoires, conventions). Extraire les templates vers `skills/makefile-conventions/SKILL.md`. |
| `0-monorepo.mdc` | Spécifique Bun 1.3 + Turborepo 2.8 | Réécrire le principe agnostique (workspace isolation, dependency graph). Parties Bun/Turbo → `03-frameworks-and-libraries/` ou skill. |

### Catégorie 01 — Reclassification (01-project-fundamentals → 01-standards)

| Fichier actuel | Diagnostic | Action |
|---|---|---|
| `1-architecture-overview.mdc` | Mélange overview agnostique + stack NestJS/fp-ts | Scinder: partie agnostique (vertical slices, functional core) → `00-architecture/`. Partie NestJS → `03-frameworks-and-libraries/`. |
| `1-code-documentation-for-indexing.mdc` | Principe agnostique + exemples TypeScript | Réécrire avec pseudo-code. Garder dans `01-standards/` (c'est une norme de documentation). |

### Catégorie 02 — Renommage (02-programming-language → 02-programming-languages)

| Fichier actuel | Diagnostic | Action |
|---|---|---|
| `2-explicit-typing.mdc` | Bon — spécifique TypeScript, cohérent pour 02-* | Garder, globs OK (`**/domain/**/*.ts`) |
| `2-semantic-jsdoc.mdc` | Bon — spécifique TypeScript | Garder, globs OK |
| `2-anti-currying.mdc` | Bon — spécifique fp-ts/TypeScript | Garder, globs OK |
| `2-pure-domain.mdc` | Principe universel + exemples fp-ts | Partie universelle (pure domain, no throw) → `01-standards/` ou `00-architecture/` en pseudo-code. Partie fp-ts → rester dans `02-*` |

### Catégorie 03-frameworks-and-libraries (OK — enrichir avec contenu déplacé)

| Fichier actuel | Diagnostic | Action |
|---|---|---|
| `3-flat-orchestration.mdc` | NestJS spécifique — bon pour 03-* | Garder, vérifier globs |
| `3-lit.mdc` | Cheatsheet procédural pur | Contenu → `skills/lit-web-components/SKILL.md`. Rule résiduelle minimale ou suppression. |
| `3-module-isolation.mdc` | Principe bon + exemples NestJS | Garder — exemples spécifiques au framework sont OK en 03-* |
| `3-typed-boundaries.mdc` | NestJS/Zod spécifique — bon pour 03-* | Garder, vérifier globs |
| `3-wc-live-demos-in-starlight.mdc` | 186 lignes de tutorial — 100% procédural | Tout → `skills/wc-live-demos-starlight/SKILL.md`. Rule résiduelle: invariants seulement (iframe isolation, bidirectional sync required). |

### Catégorie 04-tools-and-configurations (OK)

| Fichier actuel | Diagnostic | Action |
|---|---|---|
| `4-npm-private-registry.mdc` | Bon mix conventions + anti-patterns | Légèrement retravailler — les étapes Docker step-by-step → skill existant `npm-private-registry/SKILL.md` |
| `4-semantic-commits.mdc` | Bon — déclaratif et agnostique | Garder tel quel |
| `4-specify-rules.mdc` | Meta-pointeur — alwaysApply | Garder, simplifier |

### Catégorie 05-workflows-and-processes (OK)

| Fichier actuel | Diagnostic | Action |
|---|---|---|
| `5-spec-driven-dev.mdc` | Bon — workflow description | Garder, rendre plus agnostique (enlever les references au roadmap Modelo) |
| `5-spec-indexing.mdc` | Mix déclaratif + algorithme procédural | Garder l'algorithme en pseudo-code (c'est une règle formelle sur la séquence). |

### Catégorie 07-quality-assurance

| Fichier actuel | Diagnostic | Action |
|---|---|---|
| `7-testing.mdc` | Mix TDD agnostique + Vitest spécifique | Scinder: principes TDD → `07-*` en pseudo-code. Config Vitest → `03-*` ou skill. |

### Fichier .cursor/rules/specify-rules.mdc

| Diagnostic | Action |
|---|---|
| Meta-pointeur avec refs NestJS | Simplifier, garder comme pointeur |

## Nouveaux Fichiers à Créer

### Rules

1. **`rules/00-architecture/0-rules-structure.mdc`** — Convention sur la structure `rules/` elle-même (catégories, nommage, frontmatter, globs: `rules/**/*.mdc`)
2. **`rules/00-architecture/0-vertical-slices.mdc`** — Extraction de la partie agnostique de `1-architecture-overview.mdc` (vertical slices, functional core / imperative shell)
3. **`rules/01-standards/1-pure-domain.mdc`** — Version agnostique de la règle pure domain (pas de throw, pas d'I/O dans le domaine) — en pseudo-code/Go
4. **`rules/03-frameworks-and-libraries/3-nestjs-architecture.mdc`** — Contenu NestJS extrait de `1-architecture-overview.mdc`
5. **`rules/03-frameworks-and-libraries/3-vitest-conventions.mdc`** ou intégré dans les existants — Config Vitest extraite de `7-testing.mdc`

### Skills (nouveaux ou enrichis)

1. **`skills/makefile-conventions/SKILL.md`** — Templates Makefile extraits de `0-makefile-structure.mdc`
2. **`skills/lit-web-components/SKILL.md`** — Cheatsheet Lit extrait de `3-lit.mdc` (ou fusionner avec un skill existant)
3. **`skills/wc-live-demos-starlight/SKILL.md`** — Tutorial complet extrait de `3-wc-live-demos-in-starlight.mdc`

## Project Structure (après refactoring)

```
rules/
├── 00-architecture/
│   ├── 0-hexagonal-ddd.mdc          # Réécriture agnostique
│   ├── 0-makefile-structure.mdc      # Réduit aux invariants
│   ├── 0-monorepo.mdc               # Réécriture agnostique
│   ├── 0-rules-structure.mdc        # NOUVEAU — auto-description
│   └── 0-vertical-slices.mdc        # NOUVEAU — extrait de 1-architecture-overview
├── 01-standards/
│   ├── 1-code-documentation-for-indexing.mdc  # Réécriture pseudo-code
│   └── 1-pure-domain.mdc            # NOUVEAU — version agnostique
├── 02-programming-languages/         # Renommé depuis 02-programming-language
│   ├── 2-anti-currying.mdc
│   ├── 2-explicit-typing.mdc
│   ├── 2-pure-domain.mdc            # Garde la version TypeScript/fp-ts
│   └── 2-semantic-jsdoc.mdc
├── 03-frameworks-and-libraries/
│   ├── 3-flat-orchestration.mdc
│   ├── 3-lit.mdc                     # Réduit aux invariants (ou supprimé)
│   ├── 3-module-isolation.mdc
│   ├── 3-nestjs-architecture.mdc     # NOUVEAU — extrait de 1-architecture-overview
│   ├── 3-typed-boundaries.mdc
│   └── 3-wc-live-demos-in-starlight.mdc  # Réduit aux invariants
├── 04-tools-and-configurations/
│   ├── 4-npm-private-registry.mdc
│   ├── 4-semantic-commits.mdc
│   └── 4-specify-rules.mdc
├── 05-workflows-and-processes/
│   ├── 5-spec-driven-dev.mdc
│   └── 5-spec-indexing.mdc
├── 06-templates-and-models/           # Vide (réservé)
├── 07-quality-assurance/
│   └── 7-testing.mdc                  # Réduit aux principes TDD agnostiques
├── 08-domain-specific-rules/          # Vide (réservé)
└── 09-other/                          # Vide (réservé)
```

## Implementation Strategy

### Phase 1: Structure & Meta-rule

1. Créer les dossiers manquants (`06-*`, `08-*`, `09-*`)
2. Renommer `01-project-fundamentals-and-architecture/` → `01-standards/`
3. Renommer `02-programming-language/` → `02-programming-languages/`
4. Créer la rule `0-rules-structure.mdc`

### Phase 2: Extraction vers Skills

1. Extraire templates Makefile → `skills/makefile-conventions/SKILL.md`
2. Extraire Lit cheatsheet → `skills/lit-web-components/SKILL.md`
3. Extraire WC-in-Starlight tutorial → `skills/wc-live-demos-starlight/SKILL.md`

### Phase 3: Réécriture des Rules

1. Réécrire `0-hexagonal-ddd.mdc` en agnostique
2. Réduire `0-makefile-structure.mdc` aux invariants
3. Réécrire `0-monorepo.mdc` en agnostique
4. Scinder `1-architecture-overview.mdc` → `0-vertical-slices.mdc` + `3-nestjs-architecture.mdc`
5. Réécrire `1-code-documentation-for-indexing.mdc` en pseudo-code
6. Créer `1-pure-domain.mdc` (version agnostique)
7. Réduire `3-lit.mdc` aux invariants
8. Réduire `3-wc-live-demos-in-starlight.mdc` aux invariants
9. Nettoyer `4-npm-private-registry.mdc`
10. Scinder `7-testing.mdc` → agnostique + parties framework
11. Nettoyer `5-spec-driven-dev.mdc` (enlever refs roadmap)
12. Mettre à jour les globs de chaque fichier

### Phase 4: Nettoyage & Sync

1. Supprimer le dossier `01-project-fundamentals-and-architecture/` (vide après moves)
2. Mettre à jour tous les liens internes
3. Mettre à jour `.cursor/rules/specify-rules.mdc`
4. Exécuter `make sync-registry` et résoudre les erreurs
5. Vérifier la cohérence finale

## Dependencies

- `make sync-registry` fonctionne (Docker + Node 22)
- Les skills existants sont intacts et enrichissables
