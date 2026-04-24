# Implementation Plan: Ephemeral CLI / MCP for Asset Discovery & Installation

**Branch**: `004-ephemeral-cli-mcp` | **Date**: 2026-04-24 | **Spec**: [spec.md](./spec.md)

---

## Summary

Créer un package Python `ghaw` distribuable via `uvx`, combinant un **CLI Typer/Rich** et un **serveur MCP FastMCP** (stdio) qui interroge le `asset-registry.yml` pour rechercher, installer, et nettoyer des assets AI (skills, rules, commands, hooks, agents) dans différents environnements (Cursor, Pi, universel).

---

## Technical Context

| Champ              | Valeur                                       |
| ------------------ | -------------------------------------------- |
| **Language**        | Python >= 3.11                               |
| **Build system**    | Hatchling (PEP 621)                          |
| **CLI framework**   | Typer + Rich                                 |
| **MCP framework**   | `mcp` (FastMCP / MCPServer, Python SDK >= 1.12) |
| **YAML parsing**    | PyYAML                                       |
| **Schema validation** | jsonschema                                 |
| **Typing**          | mypy strict / pyright                        |
| **Testing**         | pytest + pytest-asyncio                      |
| **Distribution**    | PyPI via `uvx ghaw`                          |
| **Transport MCP**   | stdio (universel)                            |
| **Target Platform** | macOS, Linux, Windows (via uv/uvx)           |
| **Project Type**    | CLI tool + MCP server (package Python)       |

---

## Architecture Decision

### Approche : Package Python unique CLI + MCP intégré

Le CLI est le point d'entrée principal. Deux modes d'exécution :

1. **Mode CLI interactif** (`ghaw search`, `ghaw install`, `ghaw cleanup`) — interface Rich pour les humains.
2. **Mode MCP serveur** (`ghaw serve`) — transport stdio, consommé par les agents AI.

Les deux modes partagent le même **core domain** (chargement registre, recherche, installation, cleanup). Seule la couche de présentation diffère (Rich vs MCP protocol).

```
┌──────────────────────────────────────────────────┐
│                    ghaw CLI                       │
│  ┌────────────┐  ┌──────────────┐  ┌──────────┐ │
│  │ typer cmds │  │  MCP server  │  │   Rich   │ │
│  │ (search,   │  │  (FastMCP    │  │ (display)│ │
│  │  install,  │  │   stdio)     │  │          │ │
│  │  cleanup)  │  │              │  │          │ │
│  └─────┬──────┘  └──────┬───────┘  └────┬─────┘ │
│        │                │               │        │
│        └────────┬───────┘               │        │
│                 ▼                        │        │
│  ┌──────────────────────────────┐       │        │
│  │        Core Domain           │◄──────┘        │
│  │  ┌──────────┐ ┌───────────┐ │                 │
│  │  │ Registry │ │ Installer │ │                 │
│  │  │ Loader   │ │           │ │                 │
│  │  └────┬─────┘ └─────┬─────┘ │                 │
│  │       │              │       │                 │
│  │  ┌────▼──────────────▼────┐  │                 │
│  │  │     Search Engine      │  │                 │
│  │  └────────────────────────┘  │                 │
│  └──────────────────────────────┘                 │
│                 │                                  │
│    ┌────────────▼────────────┐                    │
│    │  asset-registry.yml     │                    │
│    │  (local clone or fetch) │                    │
│    └─────────────────────────┘                    │
└──────────────────────────────────────────────────┘
```

### Pourquoi FastMCP plutôt que MCPServer brut ?

FastMCP offre des décorateurs `@mcp.tool()` et `@mcp.prompt()` qui simplifient considérablement la déclaration. Le SDK Python MCP >= 1.12 recommande FastMCP pour les nouveaux projets.

### Pourquoi Hatchling ?

Standard PEP 621, léger, compatible `uvx` nativement. Alternative à setuptools, plus moderne.

---

## Technology Stack

| Composant          | Technologie               | Rationale                                                                 |
| ------------------ | ------------------------- | ------------------------------------------------------------------------- |
| CLI framework      | Typer 0.15+               | API déclarative, autocomplétion, intégration Rich native                  |
| Terminal UI        | Rich 14+                  | Tableaux, couleurs, panels, progress bars — UX moderne                    |
| MCP server         | mcp (FastMCP) >= 1.12     | SDK officiel, décorateurs, stdio transport                                |
| YAML parsing       | PyYAML >= 6.0             | Standard, rapide, fiable                                                  |
| JSON Schema        | jsonschema >= 4.20        | Validation du registre au chargement                                      |
| Build system       | Hatchling                 | PEP 621, `[project.scripts]` pour entry points                           |
| Typing             | mypy / pyright            | Qualité du code, CI                                                       |
| Testing            | pytest + pytest-asyncio   | Tests du core + tests async pour le serveur MCP                           |
| Git fetch          | subprocess (git)          | Clone/pull du repo source, pas de dépendance supplémentaire               |
| Checksums          | hashlib (stdlib)          | SHA256 pour détecter les mises à jour d'assets                            |

---

## Project Structure

```
ghaw/
├── pyproject.toml              # PEP 621, Hatchling, entry points
├── README.md                   # Documentation utilisateur
├── LICENSE                     # MIT
├── src/
│   └── ghaw/
│       ├── __init__.py         # Version, metadata
│       ├── __main__.py         # `python -m ghaw` support
│       ├── cli/
│       │   ├── __init__.py
│       │   ├── app.py          # Typer app principale
│       │   ├── search_cmd.py   # Commande `search`
│       │   ├── install_cmd.py  # Commande `install`
│       │   ├── cleanup_cmd.py  # Commande `cleanup`
│       │   ├── serve_cmd.py    # Commande `serve` (lance MCP)
│       │   └── display.py      # Helpers Rich (tableaux, panels)
│       ├── mcp_server/
│       │   ├── __init__.py
│       │   ├── server.py       # FastMCP server, tools, prompts
│       │   └── prompts.py      # Texte du prompt discover_assets
│       ├── core/
│       │   ├── __init__.py
│       │   ├── registry.py     # Chargement + validation du registre
│       │   ├── search.py       # Moteur de recherche (tags, query, filtres)
│       │   ├── installer.py    # Copie des assets + manifest
│       │   ├── cleanup.py      # Suppression assets + config MCP
│       │   ├── manifest.py     # Lecture/écriture .ghaw-manifest.json
│       │   └── models.py       # Dataclasses / Pydantic models
│       └── config/
│           ├── __init__.py
│           ├── environments.py # Mapping target_env → chemins
│           └── defaults.py     # Constantes (repo URL, noms de fichiers)
├── tests/
│   ├── __init__.py
│   ├── conftest.py             # Fixtures (registre mock, tmpdir)
│   ├── test_registry.py        # Tests chargement/validation
│   ├── test_search.py          # Tests moteur de recherche
│   ├── test_installer.py       # Tests installation
│   ├── test_cleanup.py         # Tests nettoyage
│   ├── test_manifest.py        # Tests manifest
│   └── test_mcp_server.py      # Tests MCP tools/prompts
└── .github/
    └── workflows/
        └── ci.yml              # Lint, type-check, tests, publish
```

---

## Implementation Strategy

### Phase 1: Foundation (Setup)

- Initialiser le projet Python avec `pyproject.toml` (Hatchling)
- Configurer les entry points : `ghaw` CLI et `ghaw-mcp` serveur
- Mettre en place la structure de répertoires
- Configurer mypy, pytest, ruff (linter)

### Phase 2: Core Domain

- **Models** : Définir les dataclasses/Pydantic pour AssetEntry, SearchQuery, SearchResult, InstallManifest, etc.
- **Registry Loader** : Charger `asset-registry.yml`, valider contre le JSON Schema, parser en objets typés
- **Search Engine** : Recherche par tags (intersection/union), filtrage par type/env, matching de query texte libre (tokenisation des tags + descriptions)
- **Installer** : Copie des fichiers sources vers la destination selon le target_env, calcul de checksum, mise à jour du manifest
- **Cleanup** : Lecture du manifest, suppression des fichiers installés, nettoyage de la config MCP

### Phase 3: MCP Server

- Implémenter le serveur FastMCP avec :
  - **Tool `search_assets`** : Proxy vers le core Search Engine
  - **Tool `install_assets`** : Proxy vers le core Installer
  - **Tool `cleanup`** : Proxy vers le core Cleanup
  - **Prompt `discover_assets`** : Génère le prompt de découverte guidée
  - **Resource `registry://tags`** : Liste les tags disponibles

### Phase 4: CLI Interface

- Commandes Typer : `search`, `install`, `cleanup`, `serve`
- Affichage Rich : tableaux de résultats, panels d'info, progress bars pour l'installation
- Mode interactif pour `install` (sélection des assets via prompt)

### Phase 5: Distribution & Ephemeral Setup

- Commande `ghaw setup` qui injecte la config MCP dans le fichier de l'IDE cible
- Commande `ghaw cleanup` qui retire la config et les assets
- Publication sur PyPI pour `uvx ghaw`
- CI/CD via GitHub Actions

---

## Dependencies

| Dépendance         | Version      | Usage                          |
| ------------------ | ------------ | ------------------------------ |
| `mcp`              | >= 1.12      | FastMCP server (tools, prompts)|
| `typer`            | >= 0.15      | CLI framework                  |
| `rich`             | >= 14.0      | Terminal UI                    |
| `pyyaml`           | >= 6.0       | Parsing YAML                   |
| `jsonschema`       | >= 4.20      | Validation du registre         |
| `pydantic`         | >= 2.0       | Models typés (via MCP SDK)     |

### Dev Dependencies

| Dépendance         | Version      | Usage                          |
| ------------------ | ------------ | ------------------------------ |
| `pytest`           | >= 8.0       | Tests                          |
| `pytest-asyncio`   | >= 0.24      | Tests async MCP                |
| `mypy`             | >= 1.10      | Type checking                  |
| `ruff`             | >= 0.8       | Linting + formatting           |

---

## Mapping des environnements cibles

| Target Env | Asset Type | Destination                          |
| ---------- | ---------- | ------------------------------------ |
| `cursor`   | skill      | `~/.cursor/skills/{name}/SKILL.md`   |
| `cursor`   | rule       | `~/.cursor/rules/{name}.mdc`         |
| `cursor`   | command    | `.cursor/commands/{name}.md`         |
| `cursor`   | hook       | `.cursor/hooks.json` (merge)         |
| `cursor`   | agent      | `.cursor/agents/{name}.md`           |
| `pi`       | skill      | `~/.pi/skills/{name}/SKILL.md`       |
| `pi`       | rule       | `~/.pi/rules/{name}.mdc`            |
| `pi`       | command    | `.pi/commands/{name}.md`             |
| `universal`| *          | `.agents/{type}s/{name}/`            |

---

## MCP Server Interface

### Tool: `search_assets`

```json
{
  "name": "search_assets",
  "description": "Search the asset registry for skills, rules, commands, hooks, and agents matching your needs",
  "parameters": {
    "query": { "type": "string", "description": "Natural language description of what you need" },
    "tags": { "type": "array", "items": { "type": "string" }, "description": "Explicit tags to filter by" },
    "asset_types": { "type": "array", "items": { "type": "string", "enum": ["skill", "command", "rule", "agent", "hook"] } },
    "target_env": { "type": "string", "enum": ["cursor", "pi", "universal"] },
    "match_mode": { "type": "string", "enum": ["any", "all"], "default": "any" },
    "include_content": { "type": "boolean", "default": false }
  },
  "required": ["query"]
}
```

### Tool: `install_assets`

```json
{
  "name": "install_assets",
  "description": "Install selected assets into the target environment",
  "parameters": {
    "asset_paths": { "type": "array", "items": { "type": "string" } },
    "target_env": { "type": "string", "enum": ["cursor", "pi", "universal"], "default": "cursor" }
  },
  "required": ["asset_paths"]
}
```

### Prompt: `discover_assets`

```json
{
  "name": "discover_assets",
  "description": "Guided discovery prompt to help agents find relevant assets",
  "parameters": {
    "target_env": { "type": "string", "enum": ["cursor", "pi", "universal"], "description": "Target IDE/agent environment" }
  }
}
```

### Resource: `registry://tags`

Retourne la liste complète des tags avec descriptions, issue de `x-tag-descriptions` du registre.

---

## Algorithme de recherche

1. **Tokeniser la query** : extraire les mots-clés, normaliser (lowercase, strip)
2. **Matcher les tags** : pour chaque token, vérifier s'il correspond à un tag (exact match ou substring)
3. **Fusionner avec les tags explicites** : si `tags` est fourni, les combiner
4. **Filtrer** par `asset_types` et `target_env`
5. **Scorer** : nombre de tags matchés par asset + bonus si la description contient des tokens de la query
6. **Trier** par score décroissant
7. **Retourner** les résultats avec métadonnées

---

## Config MCP injectée (Cursor)

```json
{
  "mcpServers": {
    "ghaw": {
      "command": "uvx",
      "args": ["ghaw", "serve"],
      "env": {}
    }
  }
}
```

Le CLI merge cette entrée dans `~/.cursor/mcp.json` (ou `.cursor/mcp.json` dans le workspace) lors du `setup`, et la retire lors du `cleanup`.
