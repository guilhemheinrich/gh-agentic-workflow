# Implementation Plan: Tag Frontmatter & Sync Script

**Branch**: `005-tag-frontmatter-sync-script` | **Date**: 2026-04-24 | **Spec**: [spec.md](./spec.md)

---

## Summary

Distribuer les tags dans le frontmatter de chaque asset (skills, rules, commands, agents), puis créer un script Node.js/TypeScript qui lit ces frontmatters récursivement et synchronise `asset-registry.schema.json` (x-tag-descriptions + enum) et `asset-registry.yml` (entrées). Le tout exécutable via Docker.

---

## Technical Context

| Champ | Valeur |
|-------|--------|
| **Language/Version** | Node.js 22 + TypeScript 5 |
| **Primary Dependencies** | `gray-matter` (frontmatter parsing), `js-yaml` (YAML read/write) |
| **Storage** | Fichiers locaux (schema JSON + registre YAML) |
| **Testing** | Pas de tests unitaires en v1 — validation manuelle via exécution |
| **Target Platform** | Docker container (node:22-alpine) |
| **Project Type** | CLI script (one-shot) |

---

## Architecture Decision

### Choix du langage : Node.js / TypeScript

- Les fichiers à parser sont du Markdown avec frontmatter YAML → `gray-matter` est la référence.
- L'écosystème du projet est déjà orienté TypeScript.
- Python aurait été viable (`python-frontmatter`) mais ajoute une stack supplémentaire.

### Mode opératoire du script

Le script fonctionne en **mode additif uniquement** :

1. **Lecture** : parcours récursif des dossiers, extraction des frontmatters
2. **Enrichissement schema** : ajout des tags inconnus dans `$defs.tag.enum`, `x-tag-descriptions`, et `required`
3. **Enrichissement registre** : ajout des entrées manquantes dans `asset-registry.yml`
4. **Intégrité** : warnings sur les incohérences (paths orphelins, fichiers sans tags, etc.)

Le script ne supprime jamais rien (ni du schema, ni du registre).

### Structure du script

Un seul fichier TypeScript `scripts/sync-asset-registry.ts` exécuté via `tsx` (TypeScript runtime) dans un container Docker.

---

## Détails techniques

### Parsing du frontmatter

Utilisation de `gray-matter` pour extraire le frontmatter de chaque fichier. Pour les fichiers `.mdc`, le parsing est identique (même format `---`...`---`).

### Détermination du type d'asset

| Dossier pattern | Type |
|----------------|------|
| `skills/*/SKILL.md`, `.agents/skills/*/SKILL.md` | `skill` |
| `commands/*.md`, `.cursor/commands/*.md`, `.specify/extensions/**/commands/*.md` | `command` |
| `rules/**/*.mdc`, `.cursor/rules/*.mdc` | `rule` |
| `agents/*.md` | `agent` |

### Détermination du path dans le registre

- **Skills** : chemin vers le dossier (ex. `skills/docker-expert/`) — conformément à la convention du schema existant.
- **Autres** : chemin vers le fichier (ex. `commands/commit.md`).

### Mise à jour du schema

Quand un tag inconnu est découvert :

1. Ajout à `$defs.tag.enum` (tri alphabétique)
2. Ajout à `properties` de `x-tag-descriptions` avec description par défaut `"[NEW] <tag>"`
3. Ajout au `required` array de `x-tag-descriptions`
4. Warning en console pour que le mainteneur complète la description

### Mise à jour du registre

- Le script charge le registre existant
- Pour chaque asset trouvé sur le filesystem, il cherche l'entrée par `path`
- Si l'entrée n'existe pas → ajout
- Si l'entrée existe → mise à jour des `tags` depuis le frontmatter (le frontmatter fait foi)
- Les entrées existantes dont le path n'a plus de fichier → warning (mais pas de suppression)

### Exécution Docker

```dockerfile
FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
CMD ["npx", "tsx", "scripts/sync-asset-registry.ts"]
```

Ajout d'un target dans le Makefile :

```makefile
sync-registry:
	docker run --rm -v $(PWD):/app -w /app node:22-alpine sh -c "npx --yes tsx scripts/sync-asset-registry.ts"
```

---

## Project Structure (nouveaux/modifiés)

```text
gh-agentic-workflow/
├── scripts/
│   └── sync-asset-registry.ts     # Script de synchronisation (NOUVEAU)
├── package.json                    # Dépendances gray-matter, js-yaml, tsx (NOUVEAU ou MODIFIÉ)
├── asset-registry.schema.json      # Mis à jour par le script (si nouveaux tags)
├── asset-registry.yml              # Mis à jour par le script
├── skills/*/SKILL.md               # Frontmatter enrichi avec `tags:`
├── .agents/skills/*/SKILL.md       # Frontmatter enrichi avec `tags:`
├── commands/*.md                   # Frontmatter enrichi avec `tags:`
├── .cursor/commands/*.md           # Frontmatter enrichi avec `tags:`
├── .specify/extensions/**/commands/*.md  # Frontmatter enrichi avec `tags:`
├── rules/**/*.mdc                  # Frontmatter enrichi avec `tags:`
├── .cursor/rules/*.mdc             # Frontmatter enrichi avec `tags:`
└── agents/*.md                     # Frontmatter enrichi avec `tags:`
```

---

## Implementation Strategy

### Phase 1: Backfill des frontmatters

Ajouter la clé `tags` dans le frontmatter de chaque asset existant, en se basant sur les tags déjà attribués dans `asset-registry.yml`. C'est un one-shot manuel (ou assisté par l'implémenteur).

### Phase 2: Script de synchronisation

1. Créer `package.json` avec les dépendances (`gray-matter`, `js-yaml`, `tsx`)
2. Écrire `scripts/sync-asset-registry.ts`
3. Implémenter le parsing récursif des dossiers
4. Implémenter la mise à jour du schema (nouveaux tags)
5. Implémenter la mise à jour du registre (nouvelles entrées / mise à jour des tags)
6. Implémenter le rapport d'intégrité

### Phase 3: Validation

1. Exécuter le script via Docker
2. Vérifier que le registre généré est cohérent avec les frontmatters
3. Vérifier l'idempotence (2e exécution = pas de changement)

---

## Dependencies

- `gray-matter` : parsing de frontmatter Markdown/MDC
- `js-yaml` : sérialisation YAML
- `tsx` : exécution TypeScript sans compilation
- `node:22-alpine` : image Docker pour l'exécution
