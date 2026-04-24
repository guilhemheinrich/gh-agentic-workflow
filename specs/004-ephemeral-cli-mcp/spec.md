# Feature Specification: Ephemeral CLI / MCP for Asset Discovery & Installation

**Feature Branch**: `004-ephemeral-cli-mcp`
**Created**: 2026-04-24
**Status**: Draft
**Input**: CLI/MCP éphémère installable via `uvx`, permettant la recherche et l'installation de skills/rules/commands/hooks depuis le registre tagué, avec auto-nettoyage.

---

## Contexte

Le projet `gh-agentic-workflow` dispose désormais (spec 003) d'un **registre tagué** (`asset-registry.yml`) validé par JSON Schema, recensant tous les assets AI (skills, commands, rules, agents, hooks) avec leurs tags thématiques.

Il manque un **outil de distribution** pour :

1. **Rechercher** les assets pertinents depuis n'importe quel environnement agent (Cursor, Pi, Claude Code, etc.)
2. **Installer** les assets sélectionnés dans le bon emplacement selon l'IDE cible
3. **Nettoyer** à la fin (le processus est éphémère — pas de résidu permanent)

L'approche retenue est un **CLI Python** distribuable via `uvx` (exécution sans installation permanente) qui **démarre un serveur MCP local** (stdio). L'agent appelant (via Cursor, Pi, etc.) peut alors interroger le MCP pour découvrir et installer des assets. Le CLI fournit aussi une interface terminal riche (Rich/Typer) pour une utilisation manuelle.

---

## User Scenarios & Testing

### User Story 1 — Rechercher des assets par interrogation naturelle (Priority: P0)

En tant qu'agent AI (ou utilisateur humain), je veux interroger le registre d'assets avec une description de besoin et des filtres optionnels, afin de découvrir les skills/rules/commands/hooks pertinents.

**Why this priority**: Sans recherche, aucune des autres fonctionnalités n'a de sens.
**Independent Test**: Appeler le tool MCP `search_assets` avec query="Docker" → obtenir les assets tagués docker.

**Acceptance Scenarios**:

1. **Given** le serveur MCP est démarré et le registre chargé, **When** l'agent appelle `search_assets` avec `query="typescript backend"`, **Then** les assets ayant les tags `typescript` et/ou `backend` sont retournés, triés par pertinence (nombre de tags matchés).
2. **Given** l'agent filtre par `asset_types=["skill"]`, **When** il cherche `query="docker"`, **Then** seuls les skills (pas les rules/commands) sont retournés.
3. **Given** l'agent filtre par `target_env="cursor"`, **When** il cherche `query="git"`, **Then** les résultats incluent les chemins d'installation adaptés à Cursor (`~/.cursor/skills/`, `.cursor/rules/`, etc.).
4. **Given** la query ne matche aucun tag, **When** l'agent cherche `query="blockchain"`, **Then** une liste vide est retournée avec un message explicatif.
5. **Given** l'agent passe `tags=["docker", "ci-cd"]` explicitement, **When** il appelle `search_assets`, **Then** les résultats correspondent à l'intersection ou l'union des tags (configurable via un paramètre `match_mode`).

### User Story 2 — Prompt guidé pour la découverte (Priority: P0)

En tant qu'agent AI, je veux disposer d'un prompt MCP qui me guide pour poser les bonnes questions à l'utilisateur, afin de construire une requête de recherche efficace.

**Why this priority**: L'agent ne connaît pas les tags disponibles ; le prompt est le point d'entrée naturel.
**Independent Test**: Appeler `get_prompt("discover_assets")` → recevoir un prompt structuré avec les tags disponibles et les questions à poser.

**Acceptance Scenarios**:

1. **Given** l'agent appelle le prompt MCP `discover_assets`, **When** le prompt est retourné, **Then** il contient la liste des tags disponibles avec descriptions, les types d'assets supportés, et des questions suggestives pour affiner la recherche.
2. **Given** l'agent fournit un paramètre `target_env="cursor"`, **When** le prompt est généré, **Then** il est adapté aux spécificités de Cursor (emplacements d'installation, types pertinents).

### User Story 3 — Installer les assets sélectionnés (Priority: P1)

En tant qu'agent AI ou utilisateur, je veux installer des assets du registre dans l'environnement cible, afin de les rendre disponibles dans mon IDE/agent.

**Why this priority**: L'installation est la finalité de la recherche.
**Independent Test**: Appeler `install_assets` avec une liste de paths → les fichiers sont copiés au bon emplacement.

**Acceptance Scenarios**:

1. **Given** l'agent a identifié des assets via `search_assets`, **When** il appelle `install_assets` avec `paths=["skills/docker-expert/SKILL.md"]` et `target_env="cursor"`, **Then** le fichier est copié dans `~/.cursor/skills/docker-expert/SKILL.md`.
2. **Given** l'asset est de type `rule`, **When** l'agent installe vers `target_env="cursor"`, **Then** le fichier est copié dans `~/.cursor/rules/` avec l'extension `.mdc` préservée.
3. **Given** un asset est déjà installé (même path, même contenu), **When** l'agent tente de le réinstaller, **Then** l'opération est un no-op avec un message indiquant "déjà à jour".
4. **Given** un asset est déjà installé avec un contenu différent, **When** l'agent tente de le réinstaller, **Then** l'ancien est mis à jour et un message indique la mise à jour.

### User Story 4 — Nettoyage éphémère (Priority: P1)

En tant qu'utilisateur, je veux pouvoir nettoyer toute trace du MCP et des assets installés, afin de garder mon environnement propre après une session.

**Why this priority**: Le caractère éphémère est un choix de design fondamental.
**Independent Test**: Appeler `cleanup` → les configs MCP ajoutées et les assets installés sont supprimés.

**Acceptance Scenarios**:

1. **Given** le CLI a installé des assets et configuré un MCP dans `~/.cursor/mcp.json` (ou équivalent), **When** l'utilisateur lance `ghaw cleanup`, **Then** les entrées MCP ajoutées par ghaw sont retirées du fichier de config et les assets installés sont supprimés.
2. **Given** le fichier de config MCP contenait déjà d'autres serveurs, **When** le cleanup s'exécute, **Then** seule l'entrée `ghaw` est retirée, les autres serveurs sont intacts.
3. **Given** aucun asset n'a été installé, **When** le cleanup s'exécute, **Then** un message indique "rien à nettoyer".

### User Story 5 — Démarrage du CLI / MCP (Priority: P0)

En tant qu'utilisateur, je veux lancer le CLI via `uvx ghaw` et obtenir une interface moderne, afin de gérer les assets via le terminal ou via un agent AI.

**Why this priority**: Le point d'entrée du système.
**Independent Test**: Exécuter `uvx ghaw --help` → affiche les commandes disponibles avec une interface Rich.

**Acceptance Scenarios**:

1. **Given** le package est publié sur PyPI, **When** l'utilisateur exécute `uvx ghaw`, **Then** le CLI s'affiche avec un menu d'aide stylé (Rich).
2. **Given** l'utilisateur lance `uvx ghaw serve`, **When** le serveur MCP démarre en mode stdio, **Then** il est prêt à recevoir des requêtes MCP.
3. **Given** l'utilisateur lance `uvx ghaw search "docker testing"`, **When** la recherche s'exécute, **Then** les résultats sont affichés dans un tableau Rich avec path, type, tags, et description.
4. **Given** l'utilisateur lance `uvx ghaw install --env cursor`, **When** une session interactive démarre, **Then** le prompt guide l'utilisateur dans le choix des assets à installer.

---

## Edge Cases

- Le registre `asset-registry.yml` n'existe pas dans le repo source → erreur explicite avec message indiquant où cloner le repo.
- Le registre est invalide (ne passe pas le JSON Schema) → erreur de validation avec détails au démarrage.
- L'emplacement cible n'existe pas (ex. `~/.cursor/` absent) → le CLI crée le répertoire.
- Permissions insuffisantes pour écrire dans le répertoire cible → erreur explicite avec suggestion (`sudo` ou changement de permissions).
- Le fichier MCP config cible (`mcp.json`) n'existe pas → le CLI le crée avec uniquement l'entrée `ghaw`.
- Le fichier MCP config cible est malformé → le CLI refuse de le modifier et affiche un warning.
- Plusieurs instances du CLI lancées en parallèle → le lockfile ou un mécanisme de vérification prévient les conflits d'écriture.
- Les chemins relatifs du registre contiennent des `..` ou des chemins absolus → rejet avec erreur.

---

## Requirements

### Functional Requirements

- **FR-001**: Le système DOIT être un package Python installable et exécutable via `uvx ghaw` (publication PyPI).
- **FR-002**: Le système DOIT implémenter un serveur MCP (protocole stdio) exposant au minimum un tool `search_assets` et un prompt `discover_assets`.
- **FR-003**: Le tool `search_assets` DOIT accepter les paramètres : `query` (texte libre), `tags` (liste optionnelle), `asset_types` (liste optionnelle parmi skill/command/rule/agent/hook), `target_env` (optionnel parmi cursor/pi/universal), `match_mode` (optionnel : `any` ou `all`, défaut `any`).
- **FR-004**: Le prompt `discover_assets` DOIT retourner un texte structuré contenant les tags disponibles avec descriptions, les types d'assets, les environnements cibles supportés, et des questions suggestives.
- **FR-005**: Le système DOIT fournir un tool `install_assets` acceptant une liste de paths d'assets et un `target_env`, copiant les fichiers aux emplacements appropriés.
- **FR-006**: Le système DOIT fournir une commande CLI `cleanup` qui retire les configurations MCP installées et supprime les assets copiés.
- **FR-007**: Le CLI DOIT maintenir un manifest local (`.ghaw-manifest.json`) traçant les assets installés et les modifications de config, afin de permettre un cleanup précis.
- **FR-008**: Le CLI DOIT fournir une interface terminal riche (tableaux, couleurs, formatage) pour l'utilisation manuelle.
- **FR-009**: Le système DOIT charger le registre depuis un repo Git distant (configurable) ou depuis un répertoire local.
- **FR-010**: Le tool `search_assets` DOIT retourner pour chaque résultat : `path`, `type`, `tags`, `description`, et le `content` (contenu du fichier) si demandé via un flag `include_content`.
- **FR-011**: Le système DOIT exposer une resource MCP `registry://tags` listant tous les tags disponibles avec descriptions.

### Non-Functional Requirements

- **NFR-001**: Le temps de démarrage du CLI (sans réseau) DOIT être inférieur à 2 secondes.
- **NFR-002**: La recherche dans le registre DOIT être quasi-instantanée (< 100ms pour un registre de < 1000 assets).
- **NFR-003**: Le package DOIT avoir un minimum de dépendances (MCP SDK, Typer, Rich, PyYAML, jsonschema).
- **NFR-004**: Le code DOIT être typé (mypy strict, pyright).

---

## Key Entities

- **AssetRegistry**: Le registre YAML chargé en mémoire — `{ version: str, assets: list[AssetEntry], tag_descriptions: dict[str, str] }`
- **AssetEntry**: `{ path: str, type: AssetType, tags: list[Tag], description: str | None }`
- **AssetType**: Enum `skill | command | rule | agent | hook`
- **Tag**: String validée contre l'enum du schema
- **SearchQuery**: `{ query: str, tags: list[Tag] | None, asset_types: list[AssetType] | None, target_env: TargetEnv | None, match_mode: "any" | "all", include_content: bool }`
- **SearchResult**: `{ assets: list[AssetEntry], total: int, query_tags_matched: list[Tag] }`
- **TargetEnv**: Enum `cursor | pi | universal` — détermine les chemins d'installation
- **InstallManifest**: `{ installed_at: datetime, assets: list[InstalledAsset], mcp_configs: list[McpConfigEntry] }`
- **InstalledAsset**: `{ source_path: str, target_path: str, checksum: str }`
- **McpConfigEntry**: `{ config_file: str, server_name: str }`

---

## Success Criteria

- **SC-001**: Un utilisateur peut exécuter `uvx ghaw search "docker"` sans installation préalable et obtenir les résultats en moins de 5 secondes (incluant le téléchargement).
- **SC-002**: Un agent Cursor peut configurer le MCP `ghaw`, appeler `search_assets`, et obtenir des résultats pertinents sans interaction humaine.
- **SC-003**: Après `ghaw cleanup`, aucun fichier ni configuration résiduelle de ghaw n'existe dans le répertoire utilisateur.
- **SC-004**: Le registre de 50+ assets est interrogeable par n'importe quelle combinaison de tags/types/query en moins de 100ms.
- **SC-005**: Le prompt `discover_assets` permet à un agent sans connaissance préalable du registre de formuler une requête `search_assets` pertinente en un seul échange.

---

## Assumptions

- Le package sera publié sur PyPI sous le nom `ghaw` (ou `gh-agentic-workflow`), permettant l'exécution via `uvx ghaw`.
- Le transport MCP utilisé est **stdio** (le plus universel, supporté par Cursor, Claude Desktop, etc.).
- La source du registre par défaut est le repo GitHub `gh-agentic-workflow` (clone/fetch à la demande).
- Le mapping des chemins d'installation par `target_env` est :
  - **cursor** : `~/.cursor/skills/`, `~/.cursor/rules/`, `~/.cursor/commands/`
  - **pi** : `~/.pi/skills/`, `~/.pi/rules/`, etc.
  - **universal** : `.agents/` dans le workspace courant (AGENTS.md compatible)
- Le CLI ne nécessite aucune authentification (le repo est public).
- Python >= 3.11 est requis (compatibilité MCP SDK).
