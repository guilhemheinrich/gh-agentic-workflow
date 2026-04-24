# Feature Specification: Tag Frontmatter & Sync Script

**Feature Branch**: `005-tag-frontmatter-sync-script`
**Created**: 2026-04-24
**Status**: Draft
**Input**: Distribuer les tags dans chaque frontmatter (skills/rules/commands) et fournir un script de synchronisation vers le registre centralisé.

---

## Contexte

Le registre `asset-registry.yml` (spec 003) centralise les tags de tous les assets. Cependant, les tags vivent uniquement dans ce fichier centralisé — ils ne sont pas co-localisés avec l'asset lui-même. Cela crée deux problèmes :

1. **Découvrabilité** : quand on ouvre un SKILL.md ou une rule .mdc, on ne sait pas à quels tags il appartient sans consulter le registre.
2. **Maintenance** : ajouter un nouvel asset nécessite de toucher deux endroits (le fichier + le registre), ce qui favorise la désynchronisation.

L'objectif est de faire du frontmatter de chaque asset la **source de vérité** pour ses tags, et de générer automatiquement le registre à partir de cette source.

---

## User Scenarios & Testing

### User Story 1 — Tags co-localisés dans le frontmatter (Priority: P1)

En tant que développeur, je veux voir les tags d'un asset directement dans son frontmatter, afin de savoir immédiatement à quelles catégories il appartient sans consulter un fichier externe.

**Why this priority**: Fondation de l'approche "source of truth distribuée".
**Independent Test**: Ouvrir n'importe quel SKILL.md / .mdc / command .md → le frontmatter contient une clé `tags` avec un tableau de strings.

**Acceptance Scenarios**:

1. **Given** un fichier SKILL.md existant avec frontmatter, **When** je l'ouvre, **Then** il contient une clé `tags` (tableau YAML) dont les valeurs sont des tags valides du schema.
2. **Given** un fichier .mdc rule avec frontmatter, **When** je l'ouvre, **Then** il contient une clé `tags`.
3. **Given** un fichier command .md avec frontmatter, **When** je l'ouvre, **Then** il contient une clé `tags`.
4. **Given** un fichier sans frontmatter existant (cas minoritaire), **When** le script tourne, **Then** il ajoute un bloc frontmatter avec au minimum la clé `tags`.

### User Story 2 — Script de synchronisation (Priority: P1)

En tant que mainteneur, je veux un script qui lit récursivement les dossiers d'assets et génère/met à jour `asset-registry.yml`, afin de garder le registre synchronisé sans édition manuelle.

**Why this priority**: Sans automatisation, la synchronisation manuelle n'est pas viable.
**Independent Test**: Lancer le script → le `asset-registry.yml` est mis à jour avec les entrées correspondant aux frontmatters.

**Acceptance Scenarios**:

1. **Given** des fichiers avec frontmatter `tags`, **When** le script s'exécute, **Then** chaque asset apparaît dans `asset-registry.yml` avec ses tags corrects.
2. **Given** un nouvel asset ajouté avec un tag inédit (ex. `rust`), **When** le script s'exécute, **Then** le tag est ajouté dans `x-tag-descriptions` de `asset-registry.schema.json` ET dans l'enum `$defs.tag`.
3. **Given** le script détecte un tag dans un frontmatter qui n'est pas dans le schema, **When** il s'exécute, **Then** il ajoute le tag au schema avec une description par défaut et un avertissement.

### User Story 3 — Vérification d'intégrité (Priority: P1)

En tant que mainteneur, je veux que le script vérifie la cohérence entre frontmatters et registre, afin de détecter les désynchronisations.

**Why this priority**: L'intégrité est critique pour la confiance dans le registre.
**Independent Test**: Introduire une incohérence volontaire → le script la signale.

**Acceptance Scenarios**:

1. **Given** un asset dans le registre mais dont le fichier n'existe plus, **When** le script s'exécute, **Then** un warning est émis (l'entrée n'est PAS supprimée automatiquement).
2. **Given** un fichier avec des tags dans son frontmatter, **When** le registre a des tags différents pour ce path, **Then** le frontmatter fait foi et le registre est mis à jour.
3. **Given** un fichier sans clé `tags` dans son frontmatter, **When** le script s'exécute, **Then** un warning est émis pour cet asset.

---

## Edge Cases

- Un fichier SKILL.md sans frontmatter du tout (ex. `skills/hub-documentation/SKILL.md`, `skills/scroll-mastery/SKILL.md`) → le script émet un avertissement mais ne crash pas ; il n'ajoute PAS de frontmatter automatiquement (hors scope — le frontmatter est ajouté manuellement dans la phase d'implémentation).
- Un fichier `.agents/skills/git-commit/SKILL.md` avec contenu invalide → le script le skip avec un warning.
- Des tags en doublon dans un frontmatter → le script déduplique silencieusement.
- Le script est ré-exécuté sur un registre déjà à jour → aucune modification (idempotence).

---

## Requirements

### Functional Requirements

- **FR-001**: Chaque fichier SKILL.md, .mdc rule, et command .md existant DOIT avoir une clé `tags` dans son frontmatter YAML.
- **FR-002**: Le script DOIT lire récursivement les dossiers : `skills/`, `.agents/skills/`, `commands/`, `.cursor/commands/`, `.specify/extensions/**/commands/`, `rules/`, `.cursor/rules/`, `agents/`.
- **FR-003**: Le script DOIT mettre à jour `x-tag-descriptions` dans `asset-registry.schema.json` si de nouveaux tags sont découverts.
- **FR-004**: Le script DOIT mettre à jour (ajouter des entrées) dans `asset-registry.yml`.
- **FR-005**: Le script NE DOIT PAS supprimer des entrées existantes du registre (mode additif uniquement).
- **FR-006**: Le script DOIT vérifier l'intégrité : avertir sur les paths orphelins, les fichiers sans tags, les tags inconnus.
- **FR-007**: Le script DOIT être idempotent — deux exécutions consécutives produisent le même résultat.
- **FR-008**: Le script DOIT être exécutable via Docker (conformément à la règle projet "jamais sur l'host").
- **FR-009**: Le script DOIT aussi mettre à jour l'enum `$defs.tag` et le `required` array de `x-tag-descriptions` dans le schema quand un nouveau tag est découvert.

### Non-Functional Requirements

- **NFR-001**: Le script DOIT être écrit en Node.js (TypeScript) ou Python — le choix sera déterminé dans le plan.
- **NFR-002**: Le script DOIT tourner en moins de 10 secondes pour ~100 assets.
- **NFR-003**: Le script DOIT avoir une sortie console lisible (couleurs, sections, résumé final).

---

## Key Entities

- **FrontmatterTags**: clé `tags: string[]` dans le YAML frontmatter de chaque asset
- **SyncScript**: script qui lit les frontmatters → met à jour le schema + le registre
- **IntegrityReport**: sortie du script listant warnings et erreurs

---

## Success Criteria

- **SC-001**: 100% des assets du workspace avec frontmatter ont une clé `tags` dans leur frontmatter.
- **SC-002**: Le script génère un `asset-registry.yml` identique (à l'ordre près) au fichier existant quand les frontmatters correspondent.
- **SC-003**: L'ajout d'un nouvel asset avec un nouveau tag est détecté et propagé dans le schema + le registre en une seule exécution du script.
- **SC-004**: Le script tourne via Docker et s'exécute en < 10s.

---

## Assumptions

- Les tags existants dans `asset-registry.yml` sont corrects et servent de base pour le backfill initial des frontmatters.
- Le format frontmatter YAML (`---`...`---`) est compatible avec tous les consommateurs existants (Cursor rules, skills loader, SpecKit) — confirmé par l'exploration technique.
- Les fichiers `.mdc` utilisent le même format de frontmatter que les `.md`.

---

## Contraintes

- Le script se contente de **mettre à jour** `x-tag-descriptions` et `$defs.tag` dans le schema, et d'**ajouter** des entrées dans le registre. Il ne supprime jamais rien.
- L'exécution se fait via Docker, jamais sur l'host.
