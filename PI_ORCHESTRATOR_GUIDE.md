# 🤖 Guide - PI Orchestrator / Pi Agent

Guide complet pour utiliser l'orchestration PI (Project Intelligence) dans votre projet.

---

## 📋 Table des Matières

1. [Concepts de base](#conceptes-de-base)
2. [Configuration](#configuration)
3. [Démarrage](#démarrage)
4. [Workflows courants](#workflows-courants)
5. [Commandes CLI](#commandes-cli)
6. [API Orchestrator](#api-orchestrator)
7. [Exemples pratiques](#exemples-pratiques)
8. [Dépannage](#dépannage)

---

## Concepts de base

### Qu'est-ce que PI Orchestrator ?

PI Orchestrator est un système d'agents IA autonomes qui peuvent :

- Analyser votre codebase
- Exécuter des tâches programmées
- Collaborer entre eux (worker, reviewer, planner)
- Gérer les workflows complexes via des chaînes

### Les agents disponibles

| Agent        | Rôle                                       | Modèle                       |
| ------------ | ------------------------------------------ | ---------------------------- |
| **worker**   | Exécute le code, fait du debugging         | qwen3.5:35b-a3b-coding-nvfp4 |
| **reviewer** | Revient le code et les tests               | qwen3.5:35b-a3b-coding-nvfp4 |
| **planner**  | Planifie et décompose les tâches complexes | qwen3.5:35b-a3b-coding-nvfp4 |

### Zones de tâches (Task Areas)

```yaml
task_areas:
  - development # Priorité 1
  - code_review # Priorité 2
  - testing # Priorité 3
```

---

## Configuration

### Fichier `pi/config.yaml`

```yaml
orchestrator:
  enabled: true
  max_parallel_agents: 4 # Nombre maximal d'agents parallèles
  timeout_seconds: 3600 # Timeout global (1 heure)

agents:
  - name: worker
    model: qwen3.5:35b-a3b-coding-nvfp4
    skills: [code, testing, debugging, analysis]
    max_subagent_depth: 2 # Profondeur max des sous-agents

  - name: reviewer
    model: qwen3.5:35b-a3b-coding-nvfp4
    skills: [code_review, testing, validation]
    max_subagent_depth: 1

  - name: planner
    model: qwen3.5:35b-a3b-coding-nvfp4
    skills: [planning, analysis, decomposition]
    max_subagent_depth: 2
```

### Sklls disponibles

Chaque agent possède des compétences :

- **code** : Lire, écrire, modifier du code
- **testing** : Écrire et exécuter des tests
- **debugging** : Débugger et corriger
- **analysis** : Analyser la codebase
- **planning** : Planifier et décomposer
- **code_review** : Réviewer le code

### Chains (Chaînes de travail)

Exemple de workflow automatisé :

```yaml
chains:
  - name: code_review_chain
    description: Workflow complet de revue
    steps:
      - agent: worker
        task: "Analyze {task}"
      - agent: reviewer
        task: "Review changes in {previous}"

  - name: analysis_chain
    description: Analyse puis implémentation
    steps:
      - agent: planner
        task: "Analyze and decompose {task}"
      - agent: worker
        task: "Implement {previous}"
```

---

## Démarrage

### 1. Initialiser PI

```bash
# Si ce n'est pas déjà fait
pi init
```

### 2. Lancer une orchestration

```bash
# Orchestrer TOUS les tasks en attente
pi orchestrator start

# Démarrer pour une zone spécifique
pi orchestrator start development

# Démarrer sur un dossier spécifique
pi orchestrator start src/

# Démarrer avec un prompt spécifique
pi orchestrator start "Migrate to TypeScript"
```

### 3. Dans VS Code

```
✧ Command Palette (Cmd+Shift+P) ✧

→ PI Orchestrator: Start
→ PI Orchestrator: Pause
→ PI Orchestrator: Resume
→ PI Orchestrator: Abort
→ PI Orchestrator: Show Status (dans la barre de statut)
```

---

## Workflows courants

### 🔧 Développement

```bash
# Créer une nouvelle feature
pi orchestrator start development "Implement user authentication"

# Refactoring
pi orchestrator start development "Refactor authentication module"
```

### 📝 Code Review

```bash
# Revue de code
pi orchestrator start code_review "Review PR #42 changes"

# Validation
pi orchestrator start code_review "Validate API documentation"
```

### ✅ Testing

```bash
# Exécuter tests
pi orchestrator start testing "Run all tests"

# Ajouter tests
pi orchestrator start testing "Add tests for auth module"
```

### 🧠 Analyse

```bash
# Analyse complète
pi orchestrator start "Analyze codebase architecture"

# Dépendances
pi orchestrator start "Analyze dependency tree"
```

### 📋 Workflows personnalisés

```bash
# Code Review Chain
pi orchestrator start analysis_chain "Code review for feature X"

# Analysis Chain
pi orchestrator start analysis_chain "Implement new feature"
```

---

## Commandes CLI

### Démarrage et contrôle

| Commande                         | Description                    |
| -------------------------------- | ------------------------------ |
| `pi orchestrator start`          | Démarrer l'orchestration       |
| `pi orchestrator start <target>` | Démarrer pour cible spécifique |
| `pi orchestrator status`         | Afficher le statut actuel      |
| `pi orchestrator pause`          | Mettre en pause                |
| `pi orchestrator resume`         | Reprendre                      |
| `pi orchestrator abort`          | Annuler et arrêter             |

### Gestion des tâches

| Commande                             | Description                |
| ------------------------------------ | -------------------------- |
| `pi orchestrator retry <taskId>`     | Retenter une tâche échouée |
| `pi orchestrator skip <taskId>`      | Sauter une tâche           |
| `pi orchestrator force-merge <wave>` | Forcer fusion d'un wave    |

### Agents

| Commande                        | Description              |
| ------------------------------- | ------------------------ |
| `pi orchestrator list`          | Lister les agents actifs |
| `pi orchestrator status <lane>` | Statut d'une lane        |
| `pi orchestrator logs <lane>`   | Logs d'une lane          |

### Messages

| Commande                                         | Description                |
| ------------------------------------------------ | -------------------------- |
| `pi orchestrator message <content>`              | Message à tous             |
| `pi orchestrator message --to <agent> <content>` | Message à agent spécifique |

---

## API Orchestrator

### Fonctions disponibles

```javascript
// Vérifier le statut
orch_status();
// { status: 'running', wave: 2/3, tasks: 5/12, elapsed: '02:15' }

// Pause/Resume
orch_pause();
orch_resume((force = false));

// Abort
orch_abort((hard = false));

// Gestion tâches
orch_retry_task(taskId);
orch_skip_task(taskId);

// Force merge
orch_force_merge(waveIndex, (skipFailed = false));

// Messages
send_agent_message((to = "lane-1-worker"), (content = "Message"));
broadcast_message((content = "Notification"));
read_agent_replies((from = "lane-1-worker"));

// Logue
read_lane_logs((lane = 1));
```

---

## Exemples pratiques

### 🎯 Exemple 1 : Feature complète

```bash
# 1. Planifier
pi orchestrator start planner "Plan user login feature"

# 2. Implémenter
pi orchestrator start worker "Implement login feature"

# 3. Revue
pi orchestrator start reviewer "Review login implementation"

# 4. Tester
pi orchestrator start testing "Test login feature"
```

### 🎯 Exemple 2 : Debug complexe

```bash
# Analyser le problème
pi orchestrator start planner "Debug API timeout issue"

# Implémenter fix
pi orchestrator start worker "Fix API timeout"

# Valider
pi orchestrator start reviewer "Validate timeout fix"
```

### 🎯 Exemple 3 : Refactoring

```bash
# Comprendre la codebase
pi orchestrator start "Analyze auth module"

# Planifier refactoring
pi orchestrator start planner "Refactor auth module"

# Implémenter
pi orchestrator start worker "Refactor authentication"

# Revue
pi orchestrator start code_review "Review refactoring"
```

### 🎯 Exemple 4 : Analyse et implémentation (chaîne)

```bash
# Une seule commande pour le workflow complet
pi orchestrator start analysis_chain "Implement dark mode feature"
```

---

## Exemples avancés

### Worktree pour parallélisation

```bash
# Travaux isolés pour chaque branche
pi orchestrator start --worktree feature/login
pi orchestrator start --worktree feature/profile
pi orchestrator start --worktree feature/settings
```

### Messages aux agents

```bash
# Message à un agent spécifique
pi orchestrator message --to lane-1-worker "Focus on performance"

# Message à tous
pi orchestrator message --all "Deadline: tomorrow 5PM"
```

### Supervision

```bash
# Vérifier statut en temps réel
pi orchestrator status

# Voir logs d'une lane
pi orchestrator logs 1

# Voir les messages
pi orchestrator read-messages
```

---

## Dépannage

### Agent bloqué

```bash
# Vérifier statut
pi orchestrator status

# Voir logs
pi orchestrator logs <lane>

# Envoyer message de clarification
pi orchestrator message --to lane-X "Please clarify the task"

# Forcer wrap-up
pi trigger_wrap_up <lane>
```

### Task échoué

```bash
# Voir le status
pi orchestrator status

# Retenter
pi orchestrator retry TP-001

# Ou sauter
pi orchestrator skip TP-001
```

### Orchestration plantée

```bash
# Forcer abort
pi orchestrator abort --hard

# Reset et recommencer
pi orchestrator start
```

### Problèmes de model

```bash
# Vérifier config
cat .pi/config.yaml

# Modifier model
# Éditer .pi/config.yaml

# Redémarrer
pi orchestrator restart
```

---

## Checklist de démarrage rapide

```bash
# ✅ Vérifier que .pi existe
ls .pi/

# ✅ Configurer les agents
cat .pi/config.yaml

# ✅ Démarrer l'orchestration
pi orchestrator start

# ✅ Monitorer
pi orchestrator status

# ✅ Interagir si besoin
pi orchestrator message --to lane-1 "Great progress!"
```

---

## 📚 Ressources

- **Docs officiels** : [taskplane.dev](https://taskplane.dev)
- **GitHub** : [`github.com/taskplane`](https://github.com/taskplane)
- **Issue Tracker** : [`github.com/taskplane/issues`](https://github.com/taskplane/issues)
- **Slack Community** : [Invitation via GitHub]

---

## 🎉 Bon courage !

Vous avez maintenant toutes les clés pour utiliser PI Orchestrator efficacement. N'hésitez pas à jouer avec les configurations et à créer vos propres workflows !

---

_Last updated: April 27, 2025_
