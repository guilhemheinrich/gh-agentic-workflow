# 🚀 Comment utiliser l'Orchestrator PI

Dans votre structure `.pi/`, voici **les 3 manières** d'appeler l'orchestrator :

---

## 1️⃣ Via la CLI `pi` (le plus courant)

### Démarrer une orchestration

```bash
# Démarrer tous les tasks en attente
pi orchestrator start

# Démarrer pour une zone spécifique
pi orchestrator start development

# Démarrer pour un dossier
pi orchestrator start src/

# Démarrer avec un prompt
pi orchestrator start "Implement user authentication"
```

### Contrôler l'exécution

```bash
# Voir le statut
pi orchestrator status

# Mettre en pause
pi orchestrator pause

# Reprendre
pi orchestrator resume

# Arrêter
pi orchestrator abort

# Arrêt forcé
pi orchestrator abort --hard
```

### Gérer les tâches

```bash
# Retenter une tâche échouée
pi orchestrator retry TP-001

# Sauter une tâche
pi orchestrator skip TP-002
```

### Agents

```bash
# Lister les agents actifs
pi orchestrator list

# Voir le statut d'une lane
pi orchestrator status 1

# Voir les logs
pi orchestrator logs 1

# Lire les messages
pi orchestrator read-messages
```

### Envoyer des messages

```bash
# Message à tous les agents
pi orchestrator message "Task deadline is tomorrow"

# Message à une lane spécifique
pi orchestrator message --to lane-1-worker "Focus on this"
```

### Worktrees

```bash
# Travaux isolés
pi orchestrator start --worktree feature/user-auth
```

### Force merge (pour les échecs)

```bash
# Forcer fusion d'un wave
pi orchestrator force-merge 0
```

---

## 2️⃣ Via l'API du code (Node.js/TypeScript)

Si vous codez avec l'orchestrator :

```typescript
// Importer l'orchestrator
const orch = require("@taskplane/orchestrator");

// Vérifier le statut
const status = await orch.status();
console.log(status);
// { status: 'running', wave: 2/3, tasks: 5/12, elapsed: '02:15' }

// Démarrer
await orch.start("development");
await orch.start("Implement feature X");

// Pause/Resume
await orch.pause();
await orch.resume();
await orch.resume({ force: true });

// Arrêter
await orch.abort();
await orch.abort({ hard: true });

// Gestion des tâches
await orch.retryTask("TP-001");
await orch.skipTask("TP-002");

// Message à un agent
await orch.sendAgentMessage({
  to: "lane-1-worker",
  content: "Please focus on this",
});

// Message à tous
await orch.broadcastMessage({
  content: "Important update!",
});

// Lire les messages d'un agent
const messages = await orch.readAgentReplies({
  from: "lane-1-worker",
});

// Lire les logs d'une lane
const logs = await orch.readLaneLogs({ lane: 1 });

// Force merge
await orch.forceMerge({ waveIndex: 0 });
```

---

## 3️⃣ Dans VS Code (UI)

### Command Palette (Cmd+Shift+P)

```
Pi Orchestrator:
├─ Start Batch              → Démarrer
├─ Pause                    → Mettre en pause
├─ Resume                   → Reprendre
├─ Abort                    → Arrêter
├─ Show Status            → Voir le status
├─ Tasks                    → Voir les tâches
├─ Agents                 → Voir les agents
└─ Settings               → Configuration
```

### Barre de statut

En bas à droite de VS Code :

- 🟢 Vert : Running
- 🟡 Jaune : Paused
- 🔴 Rouge : Aborted
- ⚪ Gris : Idle

Cliquez pour les actions rapides !

---

## 🎯 Les plus courants

### Workflow typique

```bash
# 1. Démarrer
pi orchestrator start "Review PR #42"

# 2. Monitorer
pi orchestrator status

# 3. Si besoin, envoyer un message
pi orchestrator message --to lane-1 "Great work!"

# 4. Arrêter quand fini
pi orchestrator abort
```

### Debug

```bash
# Statut
pi orchestrator status

# Logs
pi orchestrator logs 1

# Agent spécifique
pi orchestrator message --to lane-1-worker "What are you doing?"
```

---

## 📋 Exemples complets

### Exemple 1 : Feature développement

```bash
# Planifier
pi orchestrator start planner "Plan auth Feature"

# Implémenter
pi orchestrator start worker "Implement login"

# Revue
pi orchestrator start reviewer "Review changes"

# Tester
pi orchestrator start testing "Run tests"
```

### Exemple 2 : Chaîne automatisée

```bash
# Code Review Chain
pi orchestrator start code_review_chain "Review PR #55"

# Analyse Chain
pi orchestrator start analysis_chain "Implement dark mode"
```

### Exemple 3 : Monitoring

```bash
# Voir le statut
pi orchestrator status

# Voir les tâches
pi orchestrator tasks --all

# Voir les agents
pi orchestrator agents --verbose

# Logs
pi orchestrator logs 2
```

---

## 🛠️ Configuration dynamique

Vous pouvez modifier la config `.pi/config.yaml` :

```bash
# Modifier le model
# Éditer .pi/config.yaml → changer qwen3.5:35b-a3b-coding-nvfp4

# Changer les parameters
# max_parallel_agents → 2
# timeout_seconds → 7200

# Redémarrer
pi orchestrator restart
```

---

## ⚡ Commandes rapides par catégorie

### Démarrage

- `pi orchestrator start`
- `pi orchestrator start development`
- `pi orchestrator start "my task"`

### Contrôle

- `pi orchestrator status`
- `pi orchestrator pause`
- `pi orchestrator resume`
- `pi orchestrator abort`

### Gestion

- `pi orchestrator retry TP-001`
- `pi orchestrator skip TP-002`
- `pi orchestrator force-merge 0`

### Agents

- `pi orchestrator list`
- `pi orchestrator status 1`
- `pi orchestrator logs 1`

### Messages

- `pi orchestrator message "Hello"`
- `pi orchestrator message --to lane-1 "Focus"`

---

## 📚 En résumé

**Le CLI `pi orchestrator`** est votre interface principale :

```
pi orchestrator start <cible>     # Lancer
pi orchestrator status            # Monitorer
pi orchestrator message "text"    # Communiquer
pi orchestrator abort             # Arrêter
```

**L'API Node.js** pour les intégrations :

```javascript
await orch.start("dev");
await orch.pause();
await orch.message("message");
```

**VS Code UI** pour l'usage quotidien :

```
Cmd+Shift+P → Pi Orchestrator: Start
Clic statut → Actions rapides
```

---

_Guide créé le 27 avril 2025_
