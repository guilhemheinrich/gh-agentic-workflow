# Tasks: Skill Relevance Proxy

## Phase 1: Setup (Shared Infrastructure)

**Purpose** : Scaffold du projet, Dockerisation, CI minimale.

- [ ] T001 Créer la structure de dossiers `.agents/tools/skill-relevance-proxy/` avec `src/`, `tests/`, `data/`
- [ ] T002 Écrire `pyproject.toml` avec les dépendances runtime et dev (fastapi, httpx, pydantic, openai, pytest, ruff, mypy)
- [ ] T003 [P] Écrire le `Dockerfile` multi-stage (build + runtime) basé sur `python:3.12-slim`
- [ ] T004 [P] Écrire `docker-compose.yml` avec services `proxy` (port 8741) + `ollama` (port 11434) + volume `data/`
- [ ] T005 [P] Écrire `Makefile` avec targets : `up`, `down`, `logs`, `test`, `summary`, `lint`
- [ ] T006 Écrire `src/config.py` — modèle Pydantic `ProxyConfig` (upstream_url, judge_url, log_path, port, judge_model)

**Checkpoint** : `make up` lance le proxy + Ollama, `make test` exécute les tests (vides).

## Phase 2: Foundational — Proxy Passthrough (Blocking)

**Purpose** : Proxy transparent fonctionnel — aucune logique d'audit.

- [ ] T007 Écrire `src/main.py` — application FastAPI avec routes montées
- [ ] T008 Écrire `src/proxy/upstream.py` — client httpx async vers upstream (streaming + non-streaming)
- [ ] T009 Écrire `src/proxy/streaming.py` — logique de tee SSE : forward chunks au client + capture en mémoire
- [ ] T010 Écrire `src/proxy/router.py` — route `POST /v1/chat/completions` : dispatch streaming vs non-streaming
- [ ] T011 [P] Ajouter route `GET /health` avec statut upstream + Ollama
- [ ] T012 Écrire `tests/test_streaming.py` — tests passthrough : non-streaming, streaming, erreurs upstream (429, 500)

**Checkpoint** : Le proxy transmet fidèlement les requêtes Cursor vers l'API upstream, streaming compris. Aucune modification des payloads.

## Phase 3: User Story 1 — Extraction de Skills (Priority: P0)

**Goal** : Identifier et structurer les SkillBlocks dans les prompts interceptés.
**Independent Test** : Un prompt contenant 3 skills balisés produit 3 `SkillBlock` avec le bon ID.

- [ ] T013 Écrire `src/models/skill.py` — dataclass `SkillBlock` (id, content, source_path, extraction_method)
- [ ] T014 Écrire `src/extractor/skill_extractor.py` — extraction multi-stratégie :
  - Balises XML `<skill id="...">...</skill>`
  - Marqueurs Cursor `<agent_skill fullPath="...">`
  - Fallback : blocs annotés `<!-- skill:ID -->`
- [ ] T015 Écrire `tests/test_extractor.py` — tests avec prompts réalistes (balises XML, marqueurs Cursor, mixte, aucun skill, prompt vide)

**Checkpoint** : L'extracteur identifie correctement les skills dans des prompts Cursor réels.

## Phase 4: User Story 1 — Juge Local LLM-as-a-Judge (Priority: P0)

**Goal** : Audit asynchrone de pertinence via Ollama.
**Independent Test** : Avec un mock Ollama, l'évaluateur produit un `AuditReport` valide.

- [ ] T016 Écrire `src/models/audit.py` — dataclass `SkillVerdict` (skill_id, relevance_score, justification, citation) et `AuditReport` (request_id, timestamp, model, verdicts, etc.)
- [ ] T017 Écrire `src/judge/prompt.py` — system prompt du juge + construction du prompt utilisateur (skills + réponse)
- [ ] T018 Écrire `src/judge/client.py` — client OpenAI-compatible vers Ollama, avec timeout et retry
- [ ] T019 Écrire `src/judge/evaluator.py` — orchestration : réception (skills, response) → appel juge → parsing JSON → AuditReport. Mode dégradé si Ollama down.
- [ ] T020 Écrire `tests/test_evaluator.py` — tests avec mock : réponse valide, JSON malformé, Ollama timeout, Ollama indisponible

**Checkpoint** : L'évaluateur produit des rapports structurés, gère les erreurs gracieusement.

## Phase 5: Intégration Proxy + Audit

**Purpose** : Connecter le passthrough au pipeline d'audit.

- [ ] T021 Modifier `src/proxy/router.py` — après capture complète de la réponse, lancer `asyncio.create_task(evaluate(...))` avec les skills extraits et la réponse
- [ ] T022 Écrire `src/reports/logger.py` — écriture append JSONL dans `data/audits.jsonl` (thread-safe via asyncio lock)
- [ ] T023 Connecter `evaluator.py` → `logger.py` : après audit, persister le rapport
- [ ] T024 Écrire test d'intégration : requête complète → passthrough + audit JSONL produit

**Checkpoint** : Une requête via le proxy produit à la fois une réponse streaming ET un rapport JSONL.

## Phase 6: User Story 3 — Dashboard et Agrégation (Priority: P1)

**Goal** : Endpoints d'agrégation des scores.
**Independent Test** : 10 rapports JSONL → summary JSON trié par score moyen.

- [ ] T025 Écrire `src/reports/aggregator.py` — chargement JSONL + agrégation par skill_id (avg, max, appearances, recommendation)
- [ ] T026 Écrire `src/reports/router.py` — routes `GET /reports/summary` et `GET /reports/raw?limit=N`
- [ ] T027 Monter le router reports dans `src/main.py`
- [ ] T028 Écrire `tests/test_aggregator.py` — tests agrégation : fichier vide, 1 rapport, 20 rapports, skills mixtes

**Checkpoint** : Le endpoint `/reports/summary` retourne des recommandations actionnables.

## Phase 7: Polish & Documentation

**Purpose** : Documentation, configuration, robustesse.

- [ ] T029 [P] Écrire `quickstart.md` dans le dossier spec — guide d'activation pas-à-pas (Docker, Cursor config, vérification)
- [ ] T030 [P] Ajouter un script `ollama-pull.sh` dans le Dockerfile ou l'entrypoint pour pull automatique du modèle juge
- [ ] T031 [P] Ajouter logging structuré (Python `logging` avec format JSON) dans le proxy
- [ ] T032 Tester end-to-end : `make up` → requête Cursor → rapport JSONL → `make summary`
- [ ] T033 Valider le mode dégradé : arrêter Ollama → vérifier que le proxy fonctionne toujours

## Dependency Graph

```
Setup (Phase 1)
  └─▶ Passthrough (Phase 2) ─────────────────────────┐
        └─▶ Extraction (Phase 3) ──┐                  │
              └─▶ Juge (Phase 4) ──┤                  │
                    └─▶ Intégration (Phase 5) ◀───────┘
                          └─▶ Dashboard (Phase 6)
                                └─▶ Polish (Phase 7)
```

Phases 3 et 4 peuvent être développées en parallèle car elles n'ont pas de dépendance croisée (l'intégration en Phase 5 les connecte).

## Summary

- **Total tasks** : 33
- **By priority** : P0=24 (Phases 1-5), P1=4 (Phase 6), P2=5 (Phase 7)
- **Parallelizable** : 8 tâches marquées `[P]`
- **Estimated effort** : ~2-3 j/h (senior dev)
