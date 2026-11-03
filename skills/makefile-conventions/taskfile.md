# Taskfile — conventions et template (variante Task)

[Task](https://taskfile.dev) (`Taskfile.yml`, v3) remplit le même rôle qu'un
Makefile racine : interface unique de développement local, Docker-first,
configurée par `.env`. Les principes du [SKILL.md](SKILL.md) s'appliquent à
l'identique ; ce fichier donne la traduction et un template complet.

Un projet choisit **un seul pilote** : pas de Makefile et de Taskfile côte à
côte (deux interfaces divergent toujours).

---

## Correspondance Make → Task

| Makefile | Taskfile.yml |
|---|---|
| `-include .env` + `export` | `dotenv: ['.env']` (fichier absent toléré ; n'écrase pas une variable déjà définie dans l'environnement) |
| `APP_PORT ?= 3000` | dans les commandes : `${APP_PORT:-3000}` (shell) ; ou `vars:` avec `{{.APP_PORT \| default "3000"}}` |
| `.PHONY` | inutile : une tâche n'est jamais confondue avec un fichier |
| `help` + `## commentaire` | `desc:` sur chaque tâche + tâche `default` qui lance `task --list` |
| `$(call print_resource,…)` | tâche `resources` (`silent: true`) avec `printf` |
| `$(MAKE) --no-print-directory copy-lock` | `- task: copy-lock` dans `cmds` |
| `make test-e2e TAGS=a,b` | `task test-e2e -- a,b` → `{{.CLI_ARGS}}` |
| `@` (commande muette) | `silent: true` (tâche ou commande) |
| `cd apps/mobile && …` | `dir: apps/mobile` |
| confirmation manuelle | `prompt: "Supprimer les volumes ?"` |
| shell interactif (`exec … sh`) | `interactive: true` |
| cible fichier / dépendances | `sources:` / `generates:` (cache par empreinte) |
| `$$` pour échapper `$` | `$` direct ; `{{ }}` est réservé aux templates Task |

> **Shell** : Task exécute les commandes avec un interpréteur POSIX intégré
> (`mvdan/sh`), identique sur Linux, macOS et Windows. Pas de bashismes
> (`[[ ]]`, tableaux) : écrire du POSIX, ou appeler explicitement `bash -c`.

---

## Template

```yaml
# Pilote unique du développement local : `task --list` pour l'inventaire.
version: '3'

dotenv: ['.env']

vars:
  COMPOSE: docker compose
  EXEC_BACKEND: docker compose exec -T backend
  RUN_BACKEND: docker compose run --rm backend
  APP_URL: http://localhost:${APP_PORT:-3000}
  API_URL: http://localhost:${API_PORT:-8080}

tasks:
  default:
    desc: Liste les tâches disponibles
    silent: true
    cmds:
      - task --list

  setup:
    desc: Prépare l'environnement local (idempotent)
    cmds:
      - test -f .env || cp .env.example .env
      - '{{.COMPOSE}} build'

  up:
    desc: Démarre la stack et affiche les ressources exposées
    cmds:
      - '{{.COMPOSE}} up -d --build --remove-orphans --wait'
      - task: resources

  resources:
    desc: Affiche les URLs des services exposés
    silent: true
    cmds:
      - |
        line="\033[90m──────────────────────────────────────────────────\033[0m"
        printf "\n$line\n\033[1;32m  Stack is up\033[0m\n$line\n"
        printf "  \033[36m%-18s\033[0m %s\n" "App" "{{.APP_URL}}"
        printf "  \033[36m%-18s\033[0m %s\n" "API" "{{.API_URL}}"
        printf "  \033[36m%-18s\033[0m %s\n" "API Docs" "{{.API_URL}}/api"
        printf "$line\n  \033[33mLogs\033[0m  task logs     \033[33mStop\033[0m  task down\n\n"

  down:
    desc: Arrête tous les services
    cmds:
      - '{{.COMPOSE}} down --remove-orphans'

  destroy:
    desc: Arrête la stack et supprime les volumes
    prompt: Supprimer toutes les données locales ?
    cmds:
      - '{{.COMPOSE}} down -v --remove-orphans'

  logs:
    desc: 'Suit les logs (ex. task logs -- backend)'
    cmds:
      - '{{.COMPOSE}} logs -f {{.CLI_ARGS}}'

  shell:
    desc: 'Shell dans un service (défaut : backend)'
    interactive: true
    cmds:
      - '{{.COMPOSE}} exec {{.CLI_ARGS | default "backend"}} sh'

  copy-vendors:
    desc: Copie node_modules des conteneurs vers l'hôte (IDE)
    cmds:
      - rm -rf ./node_modules
      - '{{.COMPOSE}} cp backend:/app/node_modules ./node_modules'

  lock:
    desc: Régénère le lockfile dans l'image (stage development) et le copie sur l'hôte
    cmds:
      - '{{.COMPOSE}} build backend'
      - '{{.COMPOSE}} up -d backend'
      - '{{.COMPOSE}} cp backend:/app/pnpm-lock.yaml ./pnpm-lock.yaml'

  test:
    desc: Tests unitaires
    cmds:
      - '{{.EXEC_BACKEND}} pnpm test'

  test-e2e:
    desc: 'Tests E2E Playwright (ex. task test-e2e -- --grep @smoke)'
    vars:
      E2E: '{{.COMPOSE}} -f compose.yml -f compose.e2e.yml'
    cmds:
      - '{{.E2E}} --profile e2e up -d --build --wait'
      - |
        e2e_exit=0
        {{.E2E}} --profile e2e run --rm playwright npx playwright test {{.CLI_ARGS}} || e2e_exit=$?
        rm -rf playwright-report
        cp -r apps/e2e/playwright-report playwright-report 2>/dev/null || true
        printf "\n📊 Rapport E2E : playwright-report/index.html\n"
        exit $e2e_exit

  db:migrate:
    desc: Applique les migrations
    cmds:
      - '{{.COMPOSE}} up -d --wait db'
      - '{{.RUN_BACKEND}} pnpm db:migrate'
```

Points d'attention :

- `--wait` sur `docker compose up` remplace la boucle de healthcheck du
  Makefile, à condition que chaque service déclare un `healthcheck`.
- Les commandes contenant `{{ }}` ou `:` sont entre quotes YAML.
- Un bloc multi-ligne (`|`) s'exécute dans **un seul** shell : c'est là que se
  placent les variables locales et la propagation du code de sortie.
- Les tâches qui doivent tourner hors Docker (ex. Metro / build natif d'une app
  mobile) sont regroupées sous un préfixe (`mobile:*`) et l'exception est
  documentée dans le `CLAUDE.md` / `AGENTS.md` du projet.
- Nommer les tâches en `kebab-case`, et grouper par domaine avec `:`
  (`db:migrate`, `mobile:android`).

---

## Anti-patterns spécifiques à Task

| Anti-pattern | Correction |
|---|---|
| Makefile et Taskfile côte à côte | Un seul pilote ; supprimer l'autre |
| Tâche sans `desc:` | Invisible dans `task --list` : toujours décrire |
| `{{.CLI_ARGS}}` utilisé pour un chemin non quoté | Quoter, ou passer par une variable nommée |
| Bashismes dans `cmds` | POSIX, ou `bash -c '…'` explicite |
| Ports en dur dans les URLs | `${APP_PORT:-3000}` depuis `.env` |
| `docker compose up -d` sans `--wait` puis action immédiate | `--wait` + healthchecks |
| Installation sur l'hôte (`pnpm install`) pour un service conteneurisé | `{{.RUN_BACKEND}} pnpm …` ; l'hôte n'installe que pour les exceptions documentées |

## Installation de Task

- Poste : <https://taskfile.dev/installation/> (`brew install go-task`, `snap`,
  binaire, ou `go install github.com/go-task/task/v3/cmd/task@latest`).
- GitHub Actions : `arduino/setup-task@v2` (`version: 3.x`).
