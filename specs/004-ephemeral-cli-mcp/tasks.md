# Tasks: Ephemeral CLI / MCP for Asset Discovery & Installation

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Initialisation du projet Python, structure de répertoires, configuration des outils.

- [ ] T001 Créer `ghaw/pyproject.toml` avec Hatchling, entry points `ghaw` CLI et metadata PEP 621
- [ ] T002 Créer la structure de répertoires : `src/ghaw/`, `src/ghaw/cli/`, `src/ghaw/mcp_server/`, `src/ghaw/core/`, `src/ghaw/config/`, `tests/`
- [ ] T003 [P] Créer `src/ghaw/__init__.py` avec `__version__` et `src/ghaw/__main__.py`
- [ ] T004 [P] Configurer ruff (linting), mypy (typing strict) dans `pyproject.toml`
- [ ] T005 [P] Créer `tests/conftest.py` avec fixtures de base (registre mock YAML, tmpdir)

**Checkpoint**: Projet installable avec `pip install -e .`, `ghaw --help` retourne un placeholder.

---

## Phase 2: Foundational (Core Domain — Blocking Prerequisites)

**Purpose**: Modèles de données, chargement du registre, moteur de recherche. Aucune user story ne peut commencer sans cette base.

- [ ] T006 Créer `src/ghaw/core/models.py` — Pydantic models : `AssetEntry`, `AssetType`, `Tag`, `SearchQuery`, `SearchResult`, `TargetEnv`, `InstalledAsset`, `InstallManifest`, `McpConfigEntry`
- [ ] T007 Créer `src/ghaw/config/defaults.py` — Constantes : repo URL, noms de fichiers (registry, schema, manifest)
- [ ] T008 [P] Créer `src/ghaw/config/environments.py` — Mapping `TargetEnv` → chemins d'installation par type d'asset
- [ ] T009 Créer `src/ghaw/core/registry.py` — Chargement `asset-registry.yml`, validation JSON Schema, parsing en `list[AssetEntry]`
- [ ] T010 Écrire `tests/test_registry.py` — Tests chargement valide, registre invalide (schema), registre vide
- [ ] T011 Créer `src/ghaw/core/search.py` — Moteur de recherche : tokenisation query, matching tags, filtrage types/env, scoring, tri
- [ ] T012 Écrire `tests/test_search.py` — Tests recherche par tag, par query texte, combinaison, match_mode any/all, filtres types

**Checkpoint**: Le core peut charger un registre YAML et retourner des résultats de recherche filtrés. Aucune UI nécessaire pour valider.

---

## Phase 3: User Story 1 — Rechercher des assets (Priority: P0) — MVP

**Goal**: Le tool MCP `search_assets` et la commande CLI `search` fonctionnent de bout en bout.
**Independent Test**: `ghaw search "docker"` affiche un tableau Rich avec les assets Docker.

- [ ] T013 Créer `src/ghaw/cli/app.py` — App Typer principale avec callback global (source registry option)
- [ ] T014 Créer `src/ghaw/cli/display.py` — Helpers Rich : `display_search_results` (tableau), `display_tags` (panel)
- [ ] T015 Créer `src/ghaw/cli/search_cmd.py` — Commande `search` : paramètres query, --tags, --types, --env, --match-mode
- [ ] T016 Écrire test d'intégration `search` CLI (subprocess ou invoke Typer.testing.CliRunner)

**Checkpoint**: User Story 1 complètement fonctionnelle et testable via CLI.

---

## Phase 4: User Story 2 — Prompt guidé (Priority: P0)

**Goal**: Le prompt MCP `discover_assets` est disponible et retourne un texte structuré.
**Independent Test**: Le prompt retourne les tags, types, et questions guidées.

- [ ] T017 Créer `src/ghaw/mcp_server/prompts.py` — Génération du prompt `discover_assets` à partir du registre chargé
- [ ] T018 Créer `src/ghaw/mcp_server/server.py` — FastMCP server avec tool `search_assets` et prompt `discover_assets`
- [ ] T019 Créer `src/ghaw/cli/serve_cmd.py` — Commande `serve` : démarre le serveur MCP stdio
- [ ] T020 Écrire `tests/test_mcp_server.py` — Tests tool search_assets et prompt discover_assets via MCP client mock
- [ ] T021 Ajouter la resource MCP `registry://tags` dans le server

**Checkpoint**: User Story 2 complètement fonctionnelle. Un agent peut appeler le MCP.

---

## Phase 5: User Story 3 — Installer des assets (Priority: P1)

**Goal**: L'agent ou l'utilisateur peut installer des assets dans l'environnement cible.
**Independent Test**: `ghaw install skills/docker-expert/SKILL.md --env cursor` copie le fichier.

- [ ] T022 Créer `src/ghaw/core/manifest.py` — Lecture/écriture du `.ghaw-manifest.json`, ajout/suppression d'entrées
- [ ] T023 Créer `src/ghaw/core/installer.py` — Copie des fichiers source → destination, calcul checksum SHA256, mise à jour manifest
- [ ] T024 Écrire `tests/test_installer.py` — Tests installation neuve, mise à jour, déjà à jour (idempotence)
- [ ] T025 Écrire `tests/test_manifest.py` — Tests lecture/écriture/merge du manifest
- [ ] T026 Créer `src/ghaw/cli/install_cmd.py` — Commande `install` : paramètres paths, --env, mode interactif
- [ ] T027 Ajouter tool `install_assets` dans `src/ghaw/mcp_server/server.py`

**Checkpoint**: User Story 3 complètement fonctionnelle et testable.

---

## Phase 6: User Story 4 — Nettoyage éphémère (Priority: P1)

**Goal**: Suppression des assets installés et de la configuration MCP.
**Independent Test**: `ghaw cleanup` retire tous les fichiers et configs ghaw.

- [ ] T028 Créer `src/ghaw/core/cleanup.py` — Lecture manifest, suppression fichiers installés, nettoyage config MCP (merge JSON)
- [ ] T029 Écrire `tests/test_cleanup.py` — Tests cleanup complet, cleanup partiel, config MCP avec d'autres serveurs
- [ ] T030 Créer `src/ghaw/cli/cleanup_cmd.py` — Commande `cleanup` avec confirmation Rich
- [ ] T031 Ajouter tool `cleanup` dans `src/ghaw/mcp_server/server.py`

**Checkpoint**: User Story 4 complètement fonctionnelle.

---

## Phase 7: User Story 5 — Setup éphémère du MCP (Priority: P0)

**Goal**: Le CLI peut injecter/retirer sa config dans le fichier MCP de l'IDE cible.
**Independent Test**: `ghaw setup --env cursor` ajoute l'entrée dans `~/.cursor/mcp.json`.

- [ ] T032 Créer `src/ghaw/core/mcp_config.py` — Lecture/écriture/merge du fichier mcp.json de l'IDE cible
- [ ] T033 Créer `src/ghaw/cli/setup_cmd.py` — Commande `setup` : injecte config MCP dans l'IDE cible
- [ ] T034 Écrire tests pour mcp_config.py — Création, merge, idempotence, fichier malformé

**Checkpoint**: Le workflow complet `setup → use → cleanup` est fonctionnel.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [ ] T035 [P] Ajouter gestion du repo source distant (clone/pull via subprocess git)
- [ ] T036 [P] Ajouter `--version` au CLI, banner Rich au démarrage
- [ ] T037 [P] Créer `README.md` du package avec exemples d'utilisation
- [ ] T038 [P] Créer `.github/workflows/ci.yml` — lint, type-check, tests, build
- [ ] T039 [P] Ajouter entry point `[project.scripts]` dans pyproject.toml pour `ghaw-mcp` (alias de `ghaw serve`)
- [ ] T040 Validation de bout en bout : exécuter le quickstart (setup → search → install → cleanup) manuellement

---

## Dependency Graph

```
Setup (Phase 1) → Core Domain (Phase 2) → Search CLI + MCP Server (Phases 3-4) → Install (Phase 5) → Cleanup (Phase 6) → Setup MCP (Phase 7) → Polish (Phase 8)

Phases 3 et 4 peuvent se paralléliser après Phase 2.
Phases 5 et 6 dépendent de Phase 2 (manifest/installer) mais sont indépendantes entre elles.
Phase 7 dépend de Phase 6 (cleanup intégré au setup).
Phase 8 est parallélisable dès que les phases précédentes sont stables.
```

---

## Summary

- **Total tasks**: 40
- **By priority**: P0=20 (Phases 1-4, 7), P1=14 (Phases 5-6), P2=6 (Phase 8)
- **Estimated effort**: ~3-4 j/h (senior developer)
- **Parallelizable tasks**: 12 (marquées `[P]`)
