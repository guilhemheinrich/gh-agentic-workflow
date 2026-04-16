---
name: index
description: >-
  Vérifie et corrige l'indexation des specs et fixes.
  Détecte les conflits d'index (doublons, sauts) causés par le travail
  parallèle sur plusieurs branches, et ré-indexe tout en séquence continue.
  Délègue la ré-indexation au script ~/.cursor/commands/index.reindex.sh.
model: claude-4.6-opus-max-thinking
---

# `/index` — Vérification et Correction de l'Indexation

## Prérequis

**SI ELLE EXISTE**, lire la règle d'indexation du projet avant toute action :

```
.cursor/rules/05-workflows-and-processes/5-spec-indexing.mdc
```

Si cette règle n'existe pas dans le projet courant, cette commande est autonome.
La logique de ré-indexation est implémentée dans le script `~/.cursor/commands/index.reindex.sh` (colocalisé par convention de nommage `{command}.{script}.sh`).

---

## Étape 1 : Diagnostic (dry-run)

Exécuter le script en mode dry-run depuis la **racine du projet** pour obtenir l'inventaire et le plan de ré-indexation sans rien modifier :

```bash
bash ~/.cursor/commands/index.reindex.sh --dry-run
```

Le script va :
1. Scanner `specs/`, `fixes/`, `specs/archive/`, `specs/Archive/`
2. Collecter les dates de création (`stats.md` > `spec.md`)
3. Vérifier la présence sur `main` et `staging` via git
4. Détecter doublons, trous, et erreurs de format
5. Calculer l'ordre de priorité (cascade P1→P6 + tie-break alphabétique)
6. Afficher le plan de ré-indexation

**Si le script affiche "Indexation OK"** → rien à faire, **STOP**.

**Si des anomalies sont détectées** → passer à l'Étape 2.

### Présenter le Rapport à l'Utilisateur

Afficher le rapport du dry-run de manière lisible :

```markdown
## Rapport d'Indexation

### Anomalies Détectées
[Copier les anomalies du script]

### Plan de Ré-indexation
[Copier le plan du script : ancien index → nouvel index]
```

---

## Étape 2 : Exécution

Après validation de l'utilisateur, exécuter le script en mode réel :

```bash
bash ~/.cursor/commands/index.reindex.sh
```

Le script va :
1. Demander confirmation (`[y/N]`)
2. Renommer les dossiers via un staging temporaire (`.tmp-reindex-*`) pour éviter toute collision en cascade
3. Mettre à jour les fichiers internes (`spec.md`, `plan.md`, `stats.md`, `tasks.md`, `prompt.md`, `review.md`)
4. Corriger les références croisées entre specs/fixes
5. Valider la séquence finale
6. Afficher le rapport final

### Options du Script

| Option         | Description                                      |
| -------------- | ------------------------------------------------ |
| `--dry-run`    | Affiche le plan sans rien modifier               |
| `--no-confirm` | Saute la confirmation interactive                |
| `--no-git`     | Ignore les vérifications git (P3-P6)             |

### Exécution via Docker

Si le projet utilise Docker, exécuter le script dans un conteneur ayant accès au workspace et au repo git :

```bash
docker run --rm -v "$(pwd):/workspace" -v "$HOME/.cursor/commands:/scripts:ro" -w /workspace alpine/git bash /scripts/index.reindex.sh
```

---

## Étape 3 : Vérification Post-Exécution

Après l'exécution du script, vérifier manuellement :

1. **Le rapport final du script** indique "sequence is continuous and valid"
2. **Aucune branche git n'a été renommée** (le script ne touche jamais aux branches)
3. **Les fichiers internes** référencent le bon index (spot-check sur 2-3 dossiers renommés)

### Si des erreurs subsistent

Relancer le script :

```bash
bash ~/.cursor/commands/index.reindex.sh --dry-run
```

Si le script détecte encore des anomalies, les corriger manuellement et relancer.

---

## Algorithme du Script (référence)

Le script `reindex.sh` implémente l'algorithme suivant :

```
1. SCAN: Lister tous les dossiers {NNN}-* dans specs/, fixes/, specs/archive/
2. COLLECT: Pour chaque dossier, extraire :
   - Index numérique (préfixe)
   - Date de création (stats.md > spec.md)
   - Présence sur main, staging (git ls-tree)
   - Date du premier commit (git log --diff-filter=A)
3. DETECT: Identifier doublons, trous, erreurs de format
4. SORT: Trier par clé composite :
   - Index original (stabilité)
   - Date de création (P1/P2)
   - Présence main (P3), staging (P4)
   - Premier commit (P5/P6)
   - Nom alphabétique (tie-break)
5. PLAN: Assigner les index [001..N] séquentiellement dans l'ordre trié
6. RENAME (2 phases pour éviter les collisions en cascade) :
   a. Phase A : Tous les dossiers à renommer → noms temporaires (.tmp-reindex-*)
   b. Phase B : Noms temporaires → noms finaux
7. UPDATE: Mettre à jour les références dans les fichiers internes
8. XREF: Corriger les références croisées dans tout le périmètre
9. VALIDATE: Vérifier la séquence finale [001..N] sans trou ni doublon
```

L'approche en 2 phases (Step 6) est la clé : elle élimine complètement le problème
de collision en cascade (ex: 004→005 qui entre en conflit avec le 005 existant).

---

## Cas Particuliers

### Projet sans git

Utiliser `--no-git` pour ignorer les vérifications de branches :

```bash
bash ~/.cursor/commands/index.reindex.sh --dry-run --no-git
```

Le tri se basera uniquement sur les dates dans les fichiers (P1/P2) et le tie-break alphabétique.

### CI/CD (non-interactif)

Utiliser `--no-confirm` pour sauter la confirmation :

```bash
bash ~/.cursor/commands/index.reindex.sh --no-confirm
```

### Dossier avec Format d'Index Invalide

Le script détecte les formats non conformes (ex: `12-feature` au lieu de `012-feature`)
et les intègre dans la séquence à leur position numérique.

---

## Règles Critiques

- **TOUJOURS** exécuter `--dry-run` d'abord et présenter le plan à l'utilisateur
- **TOUJOURS** obtenir la confirmation de l'utilisateur avant l'exécution réelle
- **JAMAIS** modifier le script pendant l'exécution de `/index`
- **JAMAIS** renommer les branches git — le script ne le fait pas, et toi non plus
- **JAMAIS** modifier le contenu fonctionnel des specs — uniquement les références d'index
- **JAMAIS** exécuter directement sur l'hôte si le projet utilise Docker
