---
name: qa-specify
description: >-
  Commande de spécification E2E pilotée par l'analyse du projet. Scanne
  toutes les specs existantes pour apprendre les conventions, identifie les
  lacunes E2E, et produit directement des specs complètes (spec.md, plan.md,
  tasks.md) alignées sur la qualité et les patterns du projet.
  Contrairement au qa-tester (analyse seule), cette commande produit les livrables.
model: claude-4.6-opus-max-thinking
---

# `/qa-specify` — Spécification E2E Pilotée par l'Analyse

Cette commande combine l'analyse approfondie du projet avec la production directe de spécifications E2E complètes. Elle ne se contente pas de trouver les lacunes — elle les comble.

## Usage

```
/qa-specify [description optionnelle de périmètre]
```

**Exemples** :

- `/qa-specify` — analyse complète, produit des specs pour toutes les lacunes E2E
- `/qa-specify auth flows` — cible uniquement les flux d'authentification
- `/qa-specify specs/047-*` — cible une spec précise

## Différence avec `/specify` et le qa-tester

| Aspect | `/specify` | qa-tester (agent) | `/qa-specify` |
|--------|-----------|-------------------|---------------|
| Input | Description de feature | Aucun (scan total) | Périmètre optionnel |
| Analyse préalable | Non | Oui (gap analysis) | Oui (deep context + gap) |
| Apprentissage des conventions | Non | Partiel | **Total** |
| Output | 1 spec isolée | Prompts `/specify` | **Specs complètes directes** |
| Connaissance du projet | Limitée au prompt | Scan des user stories | **Immersion totale** |

---

## Phase 0 : Immersion Projet (OBLIGATOIRE)

**Objectif** : Construire un modèle mental complet du projet avant de produire quoi que ce soit.

### 0.1 Inventaire Exhaustif

Scanner **tout** l'arbre de spécification :

```
specs/
specs/archive/
specs/Archive/
```

Pour chaque dossier spec, enregistrer :
- Nom du dossier (ex: `001-bootstrap-dx`, `047-bug-report`)
- Statut : actif / archivé
- Fichiers présents : `spec.md`, `plan.md`, `tasks.md`, `review.md`, `stats.md`
- Taille approximative du `spec.md` (nombre de lignes)

### 0.2 Analyse des Patterns de Spécification

Lire **chaque** `spec.md` du projet (pas un échantillon — **tous**). Pour chaque spec, extraire :

| Dimension | Ce qu'il faut extraire |
|-----------|----------------------|
| **Structure** | Titres de sections, profondeur de sous-sections, ordre |
| **Format User Story** | Style utilisé (As a.../Given-When-Then/narratif/tableau) |
| **Critères d'acceptation** | Nombre moyen par story, niveau de détail, cas limites |
| **Format des exigences** | Numérotation (FR-XXX, etc.), catégorisation |
| **Critères de succès** | Mesurabilité, granularité |
| **Cas limites** | Exhaustivité de la documentation des edge cases |
| **Références croisées** | Comment les specs se référencent entre elles |
| **Vocabulaire** | Terminologie métier récurrente |
| **Patterns techniques** | Composants UI partagés, patterns de routing, state management |

Stocker comme `$SPEC_PATTERNS`.

### 0.3 Identification des Specs Exemplaires

Identifier les **3 à 5 meilleures specs** du projet selon :
- Complétude (toutes les sections remplies, pas de placeholders)
- Profondeur (critères d'acceptation exhaustifs, edge cases)
- Clarté (langage non-ambigu, critères mesurables)
- Cohérence (structure régulière, conventions respectées)

Stocker comme `$BENCHMARK_SPECS`. Ces specs servent de **modèle de qualité** pour tout ce qui sera produit.

### 0.4 Analyse des Plans et Tâches

Lire `plan.md` et `tasks.md` des specs exemplaires. Enregistrer :

| Dimension | Ce qu'il faut extraire |
|-----------|----------------------|
| **Structure du plan** | Sections, format stack technique, format décisions archi |
| **Format des tâches** | Style checkbox, format ID, marqueurs parallélisme |
| **Granularité des tâches** | Nombre moyen par spec, détail par tâche |
| **Organisation en phases** | Groupement, conventions de checkpoints |

Stocker comme `$TASK_PATTERNS`.

### 0.5 Cartographie UI

Construire une carte légère de l'architecture UI :
- Structure des composants (arborescence)
- Structure des routes/pages
- Bibliothèque UI utilisée (shadcn, Radix, custom, etc.)
- Patterns de gestion d'état
- Web components custom (shadow DOM, etc.)

Stocker comme `$UI_MAP`.

### 0.6 Détection de l'Infrastructure E2E Existante

Identifier ce qui existe déjà :
- Framework de test (Playwright, Cypress, etc.)
- Fichiers de configuration (playwright.config.ts, etc.)
- Fixtures et helpers existants
- Tests E2E déjà écrits (dossier, nombre, patterns)
- Scripts npm/make pour les tests

Stocker comme `$E2E_INFRA`.

### 0.7 Synthèse Contextuelle

Produire un document interne `$PROJECT_CONTEXT` :

```
Projet : [nom]
Total Specs : [count] (actives: [N], archivées: [N])
Specs Exemplaires : [liste avec justification]
Stack UI : [détection]
Infra E2E : [framework, config, N tests existants]
Convention Spec :
  - Format User Story : [format]
  - Critères d'Acceptation moyens/story : [N]
  - Format Exigences : [format]
  - Format Tâches : [format]
  - Tâches moyennes/spec : [N]
Vocabulaire Métier : [termes clés]
```

---

## Phase 1 : Extraction et Analyse des Lacunes

### 1.1 Extraction des User Stories UI

Pour chaque `spec.md` actif, extraire toutes les user stories impliquant une interaction UI :
- Interaction écran, formulaire, bouton, dialog, page, vue
- Navigation (page, lien, menu)
- Feedback visuel (message, notification, loading, erreur)
- Affichage de données (liste, tableau, dashboard, vue détail)
- Action d'input (saisie, sélection, upload, drag)

**Exclure** les stories purement :
- Backend (API-to-API, cron, migrations)
- Infrastructure (déploiement, CI/CD, monitoring)
- DX (tooling, CLI, documentation)

Pour chaque story extraite, enregistrer :

| Champ | Description |
|-------|-------------|
| `id` | Identifiant unique : `US-[dossier-spec]-[N]` |
| `spec_source` | Nom du dossier spec |
| `summary` | Texte complet de la user story |
| `acceptance_criteria` | Critères d'acceptation **verbatim** (pas de résumé) |
| `ui_elements` | Éléments UI impliqués |
| `related_specs` | Autres specs partageant des composants/flux UI |
| `complexity` | Complexité E2E estimée : Simple / Medium / Complex |

### 1.2 Détection de Couverture E2E Existante

Chercher la couverture existante :
1. Fichiers de test E2E (`*.spec.ts`, `*.e2e.ts`, dossiers e2e/)
2. Specs ciblant les tests E2E (dossiers ou contenu mentionnant "e2e", "end-to-end", "playwright")
3. Tâches dans les `tasks.md` liées aux tests E2E

### 1.3 Calcul du Gap

```
$UNCOVERED = $UI_STORIES \ $COVERED
```

Grouper par source spec. Enrichir chaque story non couverte avec :
- **Stories couvertes similaires** (templates potentiels)
- **Composants UI partagés** avec des stories couvertes
- **Chaînes de dépendance** (prérequis pour tester)

### 1.4 Priorisation

Classer les lacunes par priorité :

| Priorité | Critères |
|----------|----------|
| **P0 — Critique** | Flux utilisateur principaux (auth, CRUD primaire, actions business critiques) |
| **P1 — Haute** | Flux secondaires importants (settings, préférences, gestion d'erreurs UI) |
| **P2 — Moyenne** | Flux complémentaires (cosmétique, interactions non-critiques) |

---

## Phase 2 : Regroupement en Specs E2E

### 2.1 Stratégie de Regroupement

Ne pas créer une spec par user story. Regrouper intelligemment :

| Stratégie | Quand l'appliquer |
|-----------|-------------------|
| **Par flux utilisateur** | Stories qui forment un parcours complet (ex: inscription → vérification → première connexion) |
| **Par composant partagé** | Stories qui testent le même composant dans différents contextes |
| **Par spec source** | Stories qui viennent de la même spec et sont cohérentes ensemble |
| **Par complexité** | Isoler les stories complexes qui méritent une spec dédiée |

### 2.2 Plan de Specs à Produire

Pour chaque groupe, définir :

```
Spec E2E #[N] : [titre descriptif]
  Source(s) : [dossier(s) spec d'origine]
  Stories couvertes : [US-XXX-N, US-XXX-M, ...]
  Priorité : P0 / P1 / P2
  Complexité : Simple / Medium / Complex
  Dépendances : [specs E2E prérequises, ou aucune]
```

Présenter le plan à l'utilisateur pour validation avant de produire les specs.

---

## Phase 3 : Production des Specs (pour chaque groupe validé)

### 3.1 Numérotation

**OBLIGATOIRE** : Appliquer les règles d'indexation définies dans `.cursor/rules/05-workflows-and-processes/5-spec-indexing.mdc` (section 4 — Calcul du Prochain Index Disponible).

En résumé :
1. Scanner `specs/`, `fixes/`, et `specs/archive/` (si existant)
2. Trouver `MAX(NNN)` parmi tous les dossiers indexés
3. Prochain index = `MAX + 1`, format 3-digit zero-padded
4. Si un conflit d'index est détecté → exécuter `/index` avant de continuer

Convention de nommage du dossier :
```
specs/[NNN]-e2e-[description-courte]/
```

### 3.2 Créer la Branche Git

```bash
git checkout -b feature/[NNN]-e2e-[description]
```

### 3.3 Sauvegarder le Prompt

Créer `specs/[NNN]-e2e-[description]/prompt.md` avec :
- La commande `/qa-specify` invoquée
- Le contexte d'analyse (résumé du gap identifié)
- Les user stories ciblées

### 3.4 Produire `spec.md`

**CRITIQUE** : Le spec.md produit DOIT :
1. **Suivre exactement** la structure observée dans `$BENCHMARK_SPECS`
2. **Utiliser le format de user story** du projet (`$SPEC_PATTERNS`)
3. **Atteindre ou dépasser** la profondeur moyenne du projet
4. **Utiliser le vocabulaire métier** identifié en Phase 0
5. **Référencer les specs source** et les composants partagés
6. **Inclure des edge cases** au même niveau de détail que les benchmark specs

Structure minimale (adaptée aux conventions du projet) :

```markdown
# E2E Test Specification: [Titre]

**Feature Branch**: `[NNN]-e2e-[description]`
**Created**: [YYYY-MM-DD]
**Status**: Draft
**Source Specs**: [liste des specs source]
**E2E Framework**: [Playwright/Cypress — from $E2E_INFRA]

## Context

[Pourquoi ces tests E2E sont nécessaires. Référence aux specs source.
Description des flux utilisateur couverts.]

## User Scenarios & Testing

### User Story 1 — [Titre] (Priority: [P0/P1/P2])

[Texte complet de la user story, adapté au contexte E2E]

**Source**: specs/[XXX-feature]/spec.md
**Why this priority**: [Justification]
**Independent Test**: [Comment tester cette story seule]

**Acceptance Scenarios**:

1. **Given** [contexte], **When** [action], **Then** [résultat]
2. **Given** [contexte], **When** [action], **Then** [résultat]
[... autant que nécessaire — au moins autant que la spec source]

**Edge Cases**:
- [Condition limite 1] → [comportement attendu]
- [Condition limite 2] → [comportement attendu]

### User Story 2 — [Titre] (Priority: [P0/P1/P2])
[... même structure ...]

## Requirements

### Functional Requirements

- **FR-001**: Le test E2E DOIT [exigence testable]
- **FR-002**: Le test E2E DOIT [exigence testable]
[... suivre le format de numérotation du projet]

### Technical Requirements

- **TR-001**: Les tests DOIVENT utiliser `data-testid` pour la sélection d'éléments
- **TR-002**: Les tests DOIVENT utiliser `test.step()` pour décomposer les scénarios
- **TR-003**: Les tests DOIVENT être indépendants (pas d'état partagé entre tests)

### Data-TestID Requirements

| Composant | Attribut `data-testid` | Raison |
|-----------|----------------------|--------|
| [composant] | `[testid-proposé]` | [utilisé dans quel test] |

## Source Code Policy (CRITICAL)

L'application source NE DOIT PAS être modifiée, sauf pour ajouter des
attributs `data-testid` aux composants UI existants listés ci-dessus.
Aucune modification de la logique, des styles, de la structure ou du comportement.

## Success Criteria

- **SC-001**: [Critère mesurable et technology-agnostic]
- **SC-002**: [Critère mesurable et technology-agnostic]
```

### 3.5 Produire `plan.md`

Suivre la structure de `$TASK_PATTERNS`. Inclure :
- Approche technique (framework, configuration, fixtures)
- Architecture des tests (dossiers, helpers partagés)
- Stratégie d'exécution (parallélisme, CI, reporting)
- Référence aux tests existants (`$E2E_INFRA`) comme base

### 3.6 Produire `tasks.md`

Suivre strictement le format de `$TASK_PATTERNS` :

```text
- [ ] TXXX [P?] [USN?] Description avec chemin de fichier
```

Organisation en phases :

```markdown
# Tasks: E2E [description]

## Phase 1: Setup (Infrastructure partagée)

- [ ] T001 Configurer les fixtures Playwright pour [contexte]
- [ ] T002 [P] Créer les helpers partagés dans tests/e2e/helpers/

## Phase 2: Data-TestID (Seule modification app autorisée)

- [ ] T003 [P] Ajouter data-testid à [composant] dans [chemin]
- [ ] T004 [P] Ajouter data-testid à [composant] dans [chemin]

**Checkpoint**: Tous les data-testid en place, app inchangée par ailleurs

## Phase 3: Tests E2E — [User Story 1]

- [ ] T010 [US1] Créer test fichier tests/e2e/[nom].spec.ts
- [ ] T011 [US1] Implémenter scénario [titre]
- [ ] T012 [US1] Implémenter edge case [titre]

**Checkpoint**: User Story 1 testée de bout en bout

## Phase N: Validation Finale

- [ ] TXXX Exécuter la suite E2E complète
- [ ] TXXX Vérifier la non-régression des tests existants
- [ ] TXXX Mettre à jour la documentation de test

## Summary

- Total tasks: [count]
- By priority: P0=[count], P1=[count], P2=[count]
```

### 3.7 Initialiser `stats.md`

Suivre le format `stats.md` du projet (observé dans `$BENCHMARK_SPECS`).

---

## Phase 4 : Rapport de Synthèse

Après production de toutes les specs, présenter :

```markdown
## Rapport /qa-specify

### Analyse du Projet

| Métrique | Valeur |
|----------|--------|
| Specs analysées | X |
| Specs exemplaires identifiées | N |
| User stories UI extraites | X |
| Déjà couvertes par E2E | X |
| **Lacunes identifiées** | **X** |

### Specs E2E Produites

| # | Dossier | Stories couvertes | Priorité | Tâches |
|---|---------|-------------------|----------|--------|
| 1 | `NNN-e2e-description` | US-XXX-1, US-XXX-2 | P0 | X tasks |

### Qualité & Conformité

| Critère | Statut |
|---------|--------|
| Structure alignée sur $BENCHMARK_SPECS | OK / Déviation: [raison] |
| Format user story conforme | OK |
| Profondeur critères d'acceptation | OK / [N] vs moyenne projet [M] |
| Format tâches conforme | OK |
| Références croisées incluses | OK |
| Source code policy explicite | OK |

### Prochaines Étapes

1. Revoir les specs produites
2. Pour chaque spec, déléguer à l'implémenteur :
   ```
   Use the implementer subagent to: /implement [NNN]
   ```
3. Après implémentation, exécuter la review :
   ```
   /review-implemented [NNN]
   ```
```

---

## Règles Critiques

- **JAMAIS produire une spec sans avoir lu TOUTES les specs existantes** en Phase 0
- **JAMAIS résumer les critères d'acceptation** — les copier verbatim depuis les specs source
- **TOUJOURS identifier les benchmark specs** et s'aligner sur leur qualité
- **TOUJOURS respecter les conventions de format** observées dans le projet
- **TOUJOURS inclure les références croisées** vers les specs source et specs liées
- **TOUJOURS inclure la source code policy** dans chaque spec.md
- **L'application source NE DOIT PAS être modifiée** sauf ajout de `data-testid`
- **Créer une branche Git** avant de commencer à écrire
- **Exécuter TOUTES les commandes via Docker** si le projet utilise Docker — JAMAIS sur l'hôte
- **Respecter `.cursor/rules/`** et `AGENTS.md` pour les conventions du projet
- **Utiliser Context7 MCP** pour la documentation Playwright et Spec-Kit

## Model Requirement

| Priorité | Modèle | ID |
|----------|--------|----|
| **Préféré** | Claude 4.6 Opus Max Thinking | `claude-opus-4-6-max-thinking` |
| **Fallback (sans Max Mode)** | Claude 4.6 Opus Thinking | `claude-opus-4-6-thinking` |

La capacité de raisonnement étendu est essentielle pour l'analyse exhaustive de 50+ specs, l'identification fiable des patterns, et la production de specs de qualité benchmark.
