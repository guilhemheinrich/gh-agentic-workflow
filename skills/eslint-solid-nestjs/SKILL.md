---
name: eslint-solid-nestjs
description: "ESLint Flat Config standard for TypeScript/NestJS monorepos — enforces SOLID principles, Clean Architecture layer boundaries, and best practices via static analysis."
risk: safe
date_added: "2026-04-12"
tags:
  - eslint
  - typescript
  - nestjs
  - solid
  - clean-architecture
  - boundaries
  - linting
  - monorepo
---

# ESLint SOLID & NestJS — Configuration Standard

Configuration ESLint (Flat Config v9+) de référence pour un monorepo TypeScript/NestJS.
Elle applique les principes SOLID et l'isolation des couches Clean Architecture par analyse statique.

## When to Use This Skill

- Quand tu bootstraps un nouveau projet ou package NestJS dans le monorepo
- Quand tu configures ou mets à jour ESLint pour un backend TypeScript
- Quand tu veux vérifier que l'architecture respecte les boundaries (controller → service → domain)
- Quand tu reviews du code et veux t'assurer du respect SOLID
- Quand tu ajoutes un nouveau module vertical-slice et dois vérifier l'isolation

## Stratégie Globale

### Pourquoi ces plugins ?

| Plugin | Rôle | Principe SOLID couvert |
|--------|------|------------------------|
| `@eslint/js` | Règles JS de base (recommended) | Baseline qualité |
| `typescript-eslint` | Règles TS strict + type-checked | SRP (complexité), LSP (types stricts) |
| `eslint-plugin-import-x` | Tri des imports, détection cycles, imports inutilisés | DIP (contrôle des dépendances) |
| `eslint-plugin-boundaries` | Isolation des couches architecturales | DIP + ISP (boundaries) |
| `eslint-plugin-promise` | Bonnes pratiques async/Promise | Fiabilité du code asynchrone |

### Mapping SOLID → Règles ESLint

#### S — Single Responsibility Principle (SRP)

L'analyse statique ne peut pas "comprendre" qu'une classe a deux responsabilités, mais on peut détecter les **symptômes** d'une violation SRP :

| Règle | Seuil | Justification |
|-------|-------|---------------|
| `complexity` | max 15 | Complexité cyclomatique élevée = trop de chemins logiques |
| `max-lines-per-function` | max 60 (hors blancs/commentaires) | Fonction trop longue = probablement multi-responsabilité |
| `max-lines` | max 300 par fichier | Fichier trop gros = module à découper |
| `max-params` | max 4 | Trop de paramètres = la fonction fait trop de choses |
| `max-depth` | max 4 | Imbrication profonde = logique à extraire |

> **Compromis pragmatique** : Ces seuils sont des garde-fous, pas des absolus. Les fichiers de configuration, les DTOs avec beaucoup de champs, ou les fichiers barrel (`index.ts`) peuvent légitimement dépasser. On utilise des overrides ciblés pour ces cas.

#### O — Open/Closed Principle (OCP)

Difficilement vérifiable par lint pur. On s'appuie sur :
- Le typage strict TypeScript (`noImplicitAny`, `strictNullChecks`) qui force à penser en termes d'interfaces extensibles.
- `@typescript-eslint/no-explicit-any` interdit `any` — pousse vers des types génériques.

#### L — Liskov Substitution Principle (LSP)

Couvert principalement par le compilateur TypeScript (`strict: true`). ESLint renforce avec :
- `@typescript-eslint/no-unsafe-*` (assignment, call, member-access, return) — empêche de contourner le système de types.
- `@typescript-eslint/consistent-type-assertions` — limite les casts dangereux.

#### I — Interface Segregation Principle (ISP)

Pas directement vérifiable par lint. On encourage via :
- `max-params` (limite la surface des contrats).
- Les boundaries qui forcent à exposer des interfaces étroites entre couches.

#### D — Dependency Inversion Principle (DIP)

Le principe le plus **actionnable** par ESLint :

1. **`eslint-plugin-boundaries`** : Définit les couches (`domain`, `application`, `infrastructure`, `shared`) et interdit les imports dans le mauvais sens.
2. **`no-restricted-imports`** : Interdit les imports directs de classes concrètes d'infrastructure depuis le domain.
3. **`import-x/no-cycle`** : Détecte les dépendances circulaires qui violent l'inversion.

### Architecture des couches et règles Boundaries

```text
┌─────────────────────────────────────────────────────┐
│                    infrastructure/                    │
│  (controllers, repositories, gateways, DTOs)         │
│  ✅ Peut importer : application, domain, shared      │
│  ❌ Controller ne peut PAS importer un Controller    │
├─────────────────────────────────────────────────────┤
│                    application/                       │
│  (use-cases, services d'orchestration)               │
│  ✅ Peut importer : domain, shared                   │
│  ❌ Ne peut PAS importer : infrastructure            │
├─────────────────────────────────────────────────────┤
│                    domain/                            │
│  (models, logic, ports/interfaces)                   │
│  ✅ Peut importer : shared/domain uniquement         │
│  ❌ Ne peut PAS importer : application, infra        │
├─────────────────────────────────────────────────────┤
│                    shared/                            │
│  (types cross-cutting, clients partagés)             │
│  ✅ Peut importer : shared uniquement                │
│  ❌ Ne peut PAS importer : modules spécifiques       │
└─────────────────────────────────────────────────────┘
```

### Limites honnêtes de l'approche

| Principe | Couverture ESLint | Commentaire |
|----------|-------------------|-------------|
| SRP | ⚠️ Partielle | Détecte les symptômes (taille, complexité), pas la sémantique |
| OCP | ❌ Faible | Le compilateur TS fait le gros du travail |
| LSP | ⚠️ Partielle | TS strict + no-unsafe-* couvrent les cas courants |
| ISP | ❌ Faible | Encouragé indirectement par max-params et boundaries |
| DIP | ✅ Bonne | Boundaries + no-restricted-imports + no-cycle |

## Fichiers de configuration de référence

### Configuration principale

Le fichier de configuration ESLint principal est dans :

📄 [`references/eslint.config.ts`](./references/eslint.config.ts)

C'est un fichier **ESLint Flat Config** (v9+) au format TypeScript. Il contient :
- La baseline TypeScript strict + type-checked
- Les règles SRP (complexité, tailles)
- Les règles d'import (tri, cycles, inutilisés)
- Les règles async/Promise
- La configuration `eslint-plugin-boundaries` pour l'isolation des couches
- Les overrides pour les fichiers spéciaux (tests, DTOs, config)

### Configuration Boundaries détaillée

Pour les projets qui veulent une configuration boundaries plus fine ou modulaire :

📄 [`references/boundaries.config.ts`](./references/boundaries.config.ts)

Ce fichier extrait la configuration `eslint-plugin-boundaries` dans un module séparé, réutilisable et documenté. Il définit :
- Les types d'éléments architecturaux (domain, application, infrastructure, shared)
- La matrice d'imports autorisés entre couches
- Les règles spécifiques NestJS (controller ↛ controller)

## Dépendances npm

```bash
npm install -D \
  eslint@^9.37.0 \
  @eslint/js \
  typescript-eslint \
  eslint-plugin-import-x \
  eslint-plugin-boundaries \
  eslint-plugin-promise \
  globals \
  jiti
```

> `jiti` est nécessaire si tu utilises `eslint.config.ts` (TypeScript) au lieu de `eslint.config.mjs`.
> Depuis ESLint v9.7+, le support natif de `.ts` config est expérimental via `--flag unstable_ts_config`, mais `jiti` reste la méthode la plus fiable.

### Versions testées

| Package | Version | Notes |
|---------|---------|-------|
| `eslint` | ^9.37.0 | Flat Config natif, support `.ts` config |
| `typescript-eslint` | ^8.x | API unifiée `tseslint.configs.*` |
| `eslint-plugin-import-x` | ^4.16.0 | Fork maintenu de `eslint-plugin-import`, flat config natif |
| `eslint-plugin-boundaries` | ^5.x | Flat config support |
| `eslint-plugin-promise` | ^7.x | Flat config support |
| `globals` | ^16.x | Définitions de globales (node, browser) |

## Workflow d'installation

### 1. Installer les dépendances

```bash
npm install -D eslint @eslint/js typescript-eslint eslint-plugin-import-x eslint-plugin-boundaries eslint-plugin-promise globals jiti
```

### 2. Copier la configuration

Copier `references/eslint.config.ts` à la racine du projet (ou du package dans un monorepo).

### 3. Ajouter les scripts npm

```json
{
  "scripts": {
    "lint": "eslint .",
    "lint:fix": "eslint . --fix"
  }
}
```

### 4. Configurer tsconfig pour le linting

S'assurer que `tsconfig.json` (ou un `tsconfig.eslint.json` dédié) inclut tous les fichiers à linter :

```json
{
  "extends": "./tsconfig.json",
  "include": ["src/**/*.ts", "test/**/*.ts", "eslint.config.ts"]
}
```

### 5. Adapter les boundaries à ton layout

Si ton projet utilise un layout différent du canonical (`src/modules/<feature>/{domain,application,infrastructure}`), adapter les patterns dans la section `boundaries/elements` de la config.

## Personnalisation

### Ajuster les seuils SRP

Si les seuils par défaut sont trop stricts pour ton équipe, commence par des valeurs plus permissives et resserre progressivement :

```typescript
// Phase 1 : adoption douce
rules: {
  'complexity': ['warn', { max: 20 }],           // warn au lieu de error
  'max-lines-per-function': ['warn', { max: 80 }],
  'max-lines': ['warn', { max: 400 }],
}

// Phase 2 : enforcement (après nettoyage)
rules: {
  'complexity': ['error', { max: 15 }],
  'max-lines-per-function': ['error', { max: 60 }],
  'max-lines': ['error', { max: 300 }],
}
```

### Ajouter un module vertical-slice

Quand tu ajoutes un nouveau module `src/modules/<new-feature>/`, aucune configuration supplémentaire n'est nécessaire : les patterns glob de `eslint-plugin-boundaries` matchent automatiquement la structure `modules/*/domain`, `modules/*/application`, etc.

### Monorepo avec plusieurs packages

Dans un monorepo (Nx, Turborepo), tu peux :
1. Mettre la config de base à la racine
2. Étendre dans chaque package avec des overrides spécifiques

```typescript
// packages/my-api/eslint.config.ts
import baseConfig from '../../eslint.config.ts';

export default [
  ...baseConfig,
  {
    // overrides spécifiques au package
  }
];
```

## Ressources et documentation

| Ressource | URL |
|-----------|-----|
| ESLint Flat Config (v9) | https://eslint.org/docs/latest/use/configure/configuration-files |
| typescript-eslint | https://typescript-eslint.io/ |
| typescript-eslint Shared Configs | https://typescript-eslint.io/users/configs/ |
| eslint-plugin-import-x | https://github.com/un-ts/eslint-plugin-import-x |
| eslint-plugin-boundaries | https://github.com/javierbrea/eslint-plugin-boundaries |
| eslint-plugin-promise | https://github.com/eslint-community/eslint-plugin-promise |
| ESLint complexity rule | https://eslint.org/docs/latest/rules/complexity |
| ESLint max-lines rule | https://eslint.org/docs/latest/rules/max-lines |
| ESLint no-restricted-imports | https://eslint.org/docs/latest/rules/no-restricted-imports |
