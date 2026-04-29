# Feature Specification: Skill Relevance Proxy

**Feature Branch** : `008-skill-relevance-proxy`
**Created** : 2026-04-29
**Status** : Draft
**Input** : Prompt IA grand public — demande de monitoring de pertinence des skills injectés dans le contexte Cursor, via un proxy local + LLM-as-a-Judge.

## Contexte

Ce dépôt accumule un nombre croissant de **skills** (`.agents/skills/`, `~/.cursor/skills/`) et de **rules** (`.cursor/rules/`). Cursor les injecte automatiquement dans le contexte des requêtes LLM selon les globs et tags. Le problème : **on ne sait pas lesquels sont réellement utiles à la génération de la réponse**. Un skill qui "pollue" le contexte consomme des tokens, augmente le coût, et peut dégrader la qualité des réponses.

Le prompt original propose un proxy HTTP local interceptant les requêtes Cursor → LLM, puis un modèle local "juge" qui évalue a posteriori quels skills ont influencé la réponse.

## Analyse Critique du Prompt Original

Le prompt provient d'une IA grand public hors contexte. Voici les hypothèses vérifiées et les écarts constatés :

### Hypothèse 1 : "Cursor peut pointer vers localhost au lieu de l'API officielle"

**Partiellement vrai.** Cursor supporte un **Override OpenAI Base URL** pour les modèles OpenAI-compatibles. Cependant :

- Les **modèles intégrés** (Claude via abonnement Cursor) passent par les serveurs Cursor, **pas directement par l'API Anthropic**. On ne peut pas les rediriger.
- Le **BYOK Anthropic** (Bring Your Own Key) n'a **pas** d'override de base URL documenté — contrairement à OpenAI.
- Le proxy ne fonctionne donc que si on configure un **modèle custom OpenAI-compatible** pointant vers `localhost`.

**Impact** : L'architecture doit cibler le chemin **OpenAI-compatible override** ou un **modèle custom**, pas un remplacement transparent de Claude intégré.

### Hypothèse 2 : "Regex ou détection de blocs de code pour extraire les skills"

**Fragile.** Les skills Cursor sont injectés dans le prompt système avec un format structuré mais non garanti :

- Le format d'injection peut changer entre versions de Cursor.
- Les skills ne sont pas toujours balisés de manière uniforme.

**Impact** : Il faut un extracteur résilient avec fallback, pas un simple regex. Et idéalement, on marque nos propres skills avec des balises explicites.

### Hypothèse 3 : "Un modèle local peut juger la pertinence"

**Vrai avec réserves.** Un petit modèle local (Llama 3 8B via Ollama) peut effectuer ce type d'évaluation, mais :

- La qualité du jugement est inférieure à un modèle frontier.
- L'audit doit être **asynchrone** (post-hoc) pour ne pas ajouter de latence à l'UX.
- Le coût-bénéfice est discutable : un modèle local consomme des ressources GPU/CPU.

### Hypothèse 4 : "Le proxy doit supporter le streaming"

**Correct et critique.** Le streaming SSE est essentiel pour l'UX Cursor. Le proxy doit être un **passthrough transparent** qui capture les chunks en arrière-plan sans bloquer le flux.

### Hypothèse non mentionnée : l'alternative MCP

Le prompt original ignore l'architecture **MCP** (Model Context Protocol) déjà présente dans Cursor. Un serveur MCP local pourrait offrir une approche moins invasive pour le reporting, sans intercepter les requêtes.

## User Scenarios & Testing (mandatory)

### User Story 1 — Audit post-hoc de pertinence des skills (Priority: P0)

En tant que développeur utilisant Cursor avec de nombreux skills, je veux savoir quels skills injectés dans mon contexte ont réellement influencé la réponse du LLM, afin de pouvoir désactiver ceux qui polluent inutilement.

**Why this priority** : C'est le besoin fondamental — sans audit, pas d'optimisation.
**Independent Test** : Envoyer une requête via le proxy avec 5 skills injectés, dont 2 manifestement hors sujet, et vérifier que le rapport les identifie comme non pertinents.

**Acceptance Scenarios** :

1. **Given** une requête Cursor contenant 5 skills balisés, **When** le LLM répond, **Then** le proxy génère un rapport JSON listant chaque skill avec un score de pertinence (0-10) et une justification.
2. **Given** une requête dont aucun skill n'est pertinent, **When** le LLM répond sans s'appuyer sur aucun skill, **Then** le rapport attribue un score ≤ 2 à tous les skills.
3. **Given** une requête fortement liée à un skill spécifique, **When** le LLM utilise clairement ce skill, **Then** le rapport attribue un score ≥ 8 avec citation de la partie de la réponse concernée.

### User Story 2 — Transparence du proxy en mode passthrough (Priority: P0)

En tant que développeur, je veux que le proxy soit invisible pour mon workflow quotidien : pas de latence perceptible, pas de coupure du streaming, pas de modification des réponses.

**Why this priority** : Un proxy qui dégrade l'UX sera immédiatement abandonné.
**Independent Test** : Comparer le temps de réponse (TTFB et streaming complet) avec et sans proxy sur 10 requêtes identiques. L'écart doit être < 100ms.

**Acceptance Scenarios** :

1. **Given** le proxy actif, **When** Cursor envoie une requête streaming, **Then** les tokens arrivent en streaming sans interruption et le TTFB augmente de < 50ms par rapport au direct.
2. **Given** le proxy actif, **When** une erreur survient côté LLM (429, 500), **Then** le proxy transmet l'erreur telle quelle à Cursor sans la masquer.
3. **Given** le proxy inactif (crash), **When** Cursor tente une requête, **Then** l'erreur de connexion est claire et l'utilisateur peut reconfigurer Cursor vers l'API directe.

### User Story 3 — Dashboard de pertinence cumulée (Priority: P1)

En tant que développeur, je veux visualiser les scores de pertinence agrégés sur plusieurs sessions pour identifier les skills chroniquement inutiles.

**Why this priority** : L'agrégation transforme des données ponctuelles en décisions actionnables.
**Independent Test** : Après 20 requêtes loggées, l'agrégation montre les 3 skills les moins pertinents avec leur score moyen.

**Acceptance Scenarios** :

1. **Given** 20+ rapports individuels loggés, **When** je consulte le dashboard, **Then** je vois le score moyen par skill, trié du moins au plus pertinent.
2. **Given** un skill jamais référencé dans aucune réponse sur 10+ requêtes, **When** je consulte le dashboard, **Then** ce skill est flaggé comme candidat à la suppression.

### User Story 4 — Configuration Cursor minimale (Priority: P1)

En tant que développeur, je veux pouvoir activer/désactiver le proxy en un changement de configuration, sans modifier mes skills ni mes rules.

**Why this priority** : L'adoption dépend de la facilité d'activation.
**Independent Test** : Activer le proxy = modifier une seule ligne dans les settings Cursor. Le désactiver = revenir en arrière.

**Acceptance Scenarios** :

1. **Given** Cursor configuré normalement, **When** je change le base URL OpenAI vers `http://localhost:8741/v1`, **Then** toutes mes requêtes passent par le proxy.
2. **Given** le proxy actif, **When** je reviens au base URL par défaut, **Then** Cursor fonctionne normalement sans trace du proxy.

### Edge Cases

- Que se passe-t-il si le modèle local (Ollama) n'est pas disponible ? → L'audit est silencieusement ignoré, le proxy continue en passthrough.
- Que se passe-t-il avec des requêtes très longues (> 100k tokens) ? → L'audit est différé ou limité aux N premiers skills.
- Que se passe-t-il si Cursor change son format d'injection de skills ? → L'extracteur a un fallback qui logge le prompt brut pour analyse manuelle.
- Que se passe-t-il avec des requêtes multi-turn / agent ? → Chaque requête individuelle est auditée indépendamment.

## Requirements (mandatory)

### Functional Requirements

- **FR-001** : Le système DOIT intercepter les requêtes OpenAI-compatibles (POST `/v1/chat/completions`) et les transmettre à l'API upstream configurée.
- **FR-002** : Le système DOIT supporter le streaming SSE (Server-Sent Events) en mode passthrough : les tokens sont transmis en temps réel au client pendant que la réponse complète est capturée en arrière-plan.
- **FR-003** : Le système DOIT extraire les skills identifiables du prompt système (messages `role: system` ou `role: user` balisés).
- **FR-004** : Le système DOIT envoyer de manière asynchrone le prompt (skills extraits) + la réponse complète à un modèle local pour évaluation.
- **FR-005** : Le modèle local DOIT retourner un JSON structuré contenant : skill ID, score de pertinence (0-10), justification textuelle, citation optionnelle de la réponse.
- **FR-006** : Le système DOIT logger chaque rapport d'audit dans un fichier JSONL (une ligne par audit).
- **FR-007** : Le système DOIT exposer un endpoint `/reports/summary` retournant l'agrégation des scores par skill.
- **FR-008** : Le système DOIT fonctionner en mode dégradé (passthrough pur) si le modèle local est indisponible.

### Non-Functional Requirements

- **NFR-001** : Le proxy DOIT ajouter < 50ms au TTFB (Time To First Byte) par rapport à un appel direct.
- **NFR-002** : Le proxy DOIT être exécuté via Docker (jamais directement sur l'hôte).
- **NFR-003** : L'audit LLM-as-a-Judge DOIT être asynchrone — aucune latence ajoutée au streaming de la réponse.
- **NFR-004** : Le système DOIT fonctionner avec Python 3.12+ (FastAPI) pour la cohérence avec les outils existants du repo.
- **NFR-005** : Les rapports DOIT être lisibles par un humain (JSONL indenté) et parsables programmatiquement.
- **NFR-006** : Le proxy NE DOIT PAS modifier, filtrer ou enrichir les requêtes/réponses transmises — pur passthrough.

### Key Entities

- **SkillBlock** : Un fragment de contexte identifiable dans le prompt (ID, contenu textuel, source — fichier d'origine).
- **AuditReport** : Résultat de l'évaluation par le juge local (request_id, timestamp, skills évalués, réponse générée, verdicts).
- **SkillVerdict** : Évaluation d'un skill individuel (skill_id, relevance_score, justification, citation).
- **ProxyConfig** : Configuration du proxy (upstream_url, local_judge_url, log_path, port).

### Scope Boundaries

**Autorisé** :
- Proxy passthrough HTTP/SSE
- Extraction de skills par pattern matching
- Audit asynchrone via modèle local
- Logging JSONL et agrégation basique

**Hors scope** :
- Modification des requêtes/réponses en transit
- Interception des modèles intégrés Cursor (abonnement)
- Remplacement de l'API Anthropic (BYOK sans override)
- Interface graphique riche (un endpoint JSON suffit pour la v1)
- Suppression automatique de skills (l'humain décide)

## Success Criteria (mandatory)

- **SC-001** : Le proxy est transparent — 95% des requêtes ont un overhead TTFB < 50ms mesuré sur 100 requêtes.
- **SC-002** : Le juge local identifie correctement les skills non pertinents avec un taux de concordance ≥ 70% par rapport à une évaluation humaine sur un échantillon de 20 requêtes.
- **SC-003** : L'activation du proxy nécessite ≤ 2 changements de configuration Cursor.
- **SC-004** : Après 1 semaine d'usage, le développeur peut identifier les 3 skills les moins utiles dans son workflow via le rapport agrégé.
- **SC-005** : Le proxy reste fonctionnel (mode passthrough) même si le modèle local est arrêté.

## Assumptions

- L'utilisateur dispose d'une clé API OpenAI ou d'un provider OpenAI-compatible (le proxy ne fonctionne pas avec les modèles intégrés Cursor sans clé propre).
- Ollama (ou équivalent) est installable via Docker sur la machine de développement.
- La machine de développement dispose de suffisamment de RAM (≥ 16 Go) pour faire tourner un modèle local 8B en parallèle de Cursor.
- Le format d'injection de skills par Cursor dans le prompt est suffisamment stable pour permettre l'extraction par pattern matching, avec un fallback sur le dump brut.
