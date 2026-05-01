# Implementation Plan: Skill Relevance Proxy

**Branch** : `008-skill-relevance-proxy` | **Date** : 2026-04-29 | **Spec** : [spec.md](./spec.md)

## Summary

Proxy HTTP local transparent qui intercepte les requêtes OpenAI-compatibles émises par Cursor, les transmet à l'API upstream en streaming, et déclenche en arrière-plan un audit de pertinence des skills via un modèle local (Ollama). Les résultats sont loggés en JSONL et agrégés via un endpoint dédié.

## Technical Context

| Composant         | Choix                | Rationale                                                    |
| ----------------- | -------------------- | ------------------------------------------------------------ |
| **Langage**       | Python 3.12+         | Cohérent avec les outils existants du repo (ghaw, speckit)   |
| **Framework HTTP**| FastAPI + uvicorn    | Support natif async/SSE, idéal pour le passthrough streaming |
| **Client HTTP**   | httpx (async)        | Supporte le streaming async nativement                       |
| **Modèle local**  | Ollama (Llama 3 8B)  | API OpenAI-compatible, facile à Dockeriser                   |
| **Storage**       | JSONL fichier local  | Simple, append-only, pas de BDD à maintenir                  |
| **Tests**         | pytest + pytest-asyncio | Standard du repo                                          |
| **Conteneurisation** | Docker Compose    | Proxy + Ollama dans le même réseau                           |

## Architecture Decision

```
┌──────────┐     ┌──────────────────┐     ┌───────────────┐
│  Cursor   │────▶│  Proxy (FastAPI)  │────▶│  API Upstream  │
│  (client) │◀────│  :8741/v1         │◀────│  (OpenAI/etc)  │
└──────────┘     └────────┬─────────┘     └───────────────┘
                          │ async (post-hoc)
                          ▼
                 ┌──────────────────┐
                 │  Ollama (Judge)   │
                 │  :11434           │
                 └────────┬─────────┘
                          │
                          ▼
                 ┌──────────────────┐
                 │  JSONL Reports    │
                 │  /data/audits.jsonl│
                 └──────────────────┘
```

### Pourquoi FastAPI et pas Node.js ?

- Le repo utilise déjà Python (ghaw, tools CLI).
- FastAPI supporte nativement `StreamingResponse` + `httpx` async.
- La librairie `openai` Python facilite la validation des payloads.

### Pourquoi un audit asynchrone et pas synchrone ?

Le prompt original impliquait un audit synchrone (attendre le jugement avant de répondre). C'est une erreur :

- Latence inacceptable (5-30s pour un modèle local 8B).
- L'UX de Cursor dépend du streaming temps réel.
- L'audit est une observation post-hoc, pas un gate.

Le proxy capture la réponse complète en arrière-plan (en tee-ant le flux SSE), puis lance l'audit dans une `asyncio.Task` indépendante.

### Pourquoi JSONL et pas SQLite ?

- JSONL est append-only, sans schéma, facile à lire (`jq`), facile à versionner.
- Pas de dépendance supplémentaire.
- Pour la v1, l'agrégation se fait en chargeant tout le fichier en mémoire (acceptable pour des milliers de lignes).

### Pourquoi le port 8741 ?

Port non standard peu susceptible de conflits. Mnémotechnique : 8741 ≈ "SRPA" (Skill Relevance Proxy Audit) sur un clavier téléphone.

## Project Structure

```
.agents/tools/skill-relevance-proxy/
├── Dockerfile                     # Image Python 3.12 + deps
├── docker-compose.yml             # Proxy + Ollama
├── pyproject.toml                 # Dépendances + config
├── src/
│   ├── __init__.py
│   ├── main.py                    # Point d'entrée FastAPI
│   ├── config.py                  # Modèle de configuration (Pydantic)
│   ├── proxy/
│   │   ├── __init__.py
│   │   ├── router.py              # Route POST /v1/chat/completions
│   │   ├── streaming.py           # Logique passthrough SSE + capture
│   │   └── upstream.py            # Client httpx vers l'API upstream
│   ├── extractor/
│   │   ├── __init__.py
│   │   └── skill_extractor.py     # Extraction de SkillBlocks du prompt
│   ├── judge/
│   │   ├── __init__.py
│   │   ├── client.py              # Client Ollama (OpenAI-compatible)
│   │   ├── prompt.py              # System prompt du juge
│   │   └── evaluator.py           # Orchestration de l'audit async
│   ├── reports/
│   │   ├── __init__.py
│   │   ├── logger.py              # Écriture JSONL
│   │   ├── aggregator.py          # Agrégation des scores
│   │   └── router.py              # Route GET /reports/summary
│   └── models/
│       ├── __init__.py
│       ├── skill.py               # SkillBlock, SkillVerdict
│       ├── audit.py               # AuditReport
│       └── config.py              # ProxyConfig
├── tests/
│   ├── __init__.py
│   ├── test_streaming.py          # Tests passthrough SSE
│   ├── test_extractor.py          # Tests extraction de skills
│   ├── test_evaluator.py          # Tests audit (mock Ollama)
│   └── test_aggregator.py         # Tests agrégation
└── data/                          # Volume Docker — rapports
    └── .gitkeep
```

## Implementation Strategy

### Phase 1 : Foundation — Proxy Passthrough

**Objectif** : Un proxy transparent qui transmet les requêtes sans les modifier.

1. Scaffold du projet Python (pyproject.toml, Dockerfile, docker-compose)
2. Route `POST /v1/chat/completions` → passthrough vers upstream
3. Support streaming SSE (tee du flux : forward + capture)
4. Support non-streaming (cas trivial)
5. Health check `GET /health`
6. Tests : vérifier transparence sur requête streaming + non-streaming

### Phase 2 : Extraction des Skills

**Objectif** : Identifier les blocs de skills dans les messages du prompt.

1. Parser les messages du body JSON (role: system, user)
2. Pattern matching multi-stratégie :
   - Balises XML explicites : `<skill id="...">...</skill>`
   - Marqueurs Cursor détectés : `<agent_skill fullPath="...">` ou `<available_skills>`
   - Fallback : blocs de code avec commentaires d'identification
3. Modèle `SkillBlock` (id, content, source_path, extraction_method)
4. Tests unitaires avec des prompts réalistes

### Phase 3 : Juge Local (LLM-as-a-Judge)

**Objectif** : Évaluer la pertinence de chaque skill via Ollama.

1. System prompt du juge (voir section dédiée)
2. Client OpenAI-compatible vers Ollama
3. Parsing de la réponse JSON du juge
4. Modèle `SkillVerdict` + `AuditReport`
5. Task asyncio lancée après capture complète de la réponse
6. Mode dégradé : si Ollama timeout ou indisponible → log warning, skip audit
7. Tests avec mock du modèle local

### Phase 4 : Reporting

**Objectif** : Logger et agréger les résultats.

1. Logger JSONL (append-only, rotation optionnelle)
2. Endpoint `GET /reports/summary` — agrégation en mémoire
3. Endpoint `GET /reports/raw?limit=N` — derniers N rapports bruts
4. Tests sur l'agrégation

### Phase 5 : Docker Compose + Documentation

**Objectif** : Packaging et activation facile.

1. Docker Compose avec proxy + Ollama (pull automatique du modèle)
2. Makefile targets : `make up`, `make down`, `make logs`, `make summary`
3. Documentation : quickstart, configuration Cursor, troubleshooting
4. Validation end-to-end

## System Prompt du Juge

```text
You are a Relevance Auditor. Your task is to evaluate whether each "skill" 
(a piece of documentation or code injected into an AI assistant's context) 
was actually useful for generating the given response.

For each skill provided, you MUST return a JSON object with:
- "skill_id": the identifier of the skill
- "relevance_score": integer 0-10 where:
    0 = completely irrelevant, wasted context
    1-3 = tangentially related but not used
    4-6 = somewhat relevant, minor influence
    7-9 = clearly used in the response
    10 = critical, response would fail without it
- "justification": 1-2 sentences explaining your score
- "citation": exact quote from the response that demonstrates usage (null if not used)

IMPORTANT:
- Be strict. A skill is relevant ONLY if the response demonstrates knowledge 
  that likely came FROM that skill rather than the model's training data.
- If the model could have answered identically without the skill, score ≤ 3.
- Look for specific terminology, patterns, file paths, or API signatures 
  that match the skill content.

Return a JSON array of verdicts. No commentary outside the JSON.
```

## Schéma des Données

### AuditReport (JSONL)

```json
{
  "request_id": "uuid-v4",
  "timestamp": "2026-04-29T12:34:56Z",
  "model": "gpt-4o",
  "prompt_tokens": 12500,
  "completion_tokens": 850,
  "skills_found": 5,
  "skills_evaluated": 5,
  "judge_model": "llama3:8b",
  "judge_duration_ms": 4200,
  "verdicts": [
    {
      "skill_id": "k8s-troubleshoot",
      "relevance_score": 9,
      "justification": "Response uses exact kubectl commands and Docker pattern from this skill.",
      "citation": "docker run --rm -v ~/.kube:/root/.kube bitnami/kubectl ..."
    },
    {
      "skill_id": "docker-expert",
      "relevance_score": 2,
      "justification": "Generic Docker knowledge; response doesn't use advanced patterns from this skill.",
      "citation": null
    }
  ]
}
```

### Summary Aggregation

```json
{
  "period": "2026-04-29 to 2026-05-06",
  "total_audits": 47,
  "skills": [
    {
      "skill_id": "docker-expert",
      "appearances": 32,
      "avg_score": 2.1,
      "max_score": 5,
      "recommendation": "REMOVE — chronically low relevance"
    },
    {
      "skill_id": "k8s-troubleshoot",
      "appearances": 12,
      "avg_score": 8.4,
      "max_score": 10,
      "recommendation": "KEEP — consistently valuable"
    }
  ]
}
```

## Dependencies

### Runtime

| Package  | Version | Usage                         |
| -------- | ------- | ----------------------------- |
| fastapi  | ≥0.115  | Framework HTTP async          |
| uvicorn  | ≥0.34   | Serveur ASGI                  |
| httpx    | ≥0.28   | Client HTTP async + streaming |
| pydantic | ≥2.10   | Validation des modèles        |
| openai   | ≥1.60   | Client Ollama (compatible)    |

### Dev

| Package         | Version | Usage            |
| --------------- | ------- | ---------------- |
| pytest          | ≥8.0    | Tests            |
| pytest-asyncio  | ≥0.24   | Tests async      |
| pytest-httpx    | ≥0.35   | Mock httpx       |
| ruff            | ≥0.8    | Linting/format   |
| mypy            | ≥1.13   | Type checking    |

### Infrastructure

| Service | Image             | Usage              |
| ------- | ----------------- | ------------------ |
| Proxy   | python:3.12-slim  | Image de base      |
| Ollama  | ollama/ollama     | Modèle local juge  |

## Configuration Cursor

Pour activer le proxy, l'utilisateur doit :

1. **Cursor Settings → Models → OpenAI**
   - Entrer sa clé API OpenAI
   - Activer "Override OpenAI Base URL"
   - Mettre `http://localhost:8741/v1`

2. **Sélectionner un modèle OpenAI** (gpt-4o, gpt-4o-mini, etc.) dans le chat Cursor.

3. **Alternative : modèle custom**
   - Ajouter un modèle custom nommé (ex: "gpt-4o-audited")
   - Base URL : `http://localhost:8741/v1`

Pour désactiver : supprimer l'override base URL ou arrêter le conteneur.

**Limitation connue** : cette approche ne fonctionne **pas** avec les modèles Claude intégrés à l'abonnement Cursor. Seuls les modèles utilisant le chemin OpenAI-compatible sont interceptables.
