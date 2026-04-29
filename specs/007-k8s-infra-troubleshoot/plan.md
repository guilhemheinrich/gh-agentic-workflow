# Implementation Plan: K8s Infrastructure Troubleshoot

**Branch**: `007-k8s-infra-troubleshoot` | **Date**: 2026-04-28 | **Spec**: [spec.md](./spec.md)

## Summary

Créer une commande Cursor `/k8s-troubleshoot` et un skill associé permettant de diagnostiquer et résoudre des problèmes d'infrastructure Kubernetes via un conteneur Docker. Le scope est limité aux opérations autorisées par le service account `modelo-debug-only`. Les problèmes hors scope génèrent un rapport structuré pour l'équipe DevOps.

## Technical Context

**Language/Version**: Shell (Bash), Markdown
**Primary Dependencies**: Docker, kubectl (dans le conteneur), curl, jq
**Target Platform**: macOS / Linux (host développeur) + Docker container (alpine-based)
**Project Type**: Cursor skill + command + Dockerfile

## Architecture Decision

Le skill est structuré en 3 couches :

1. **Dockerfile** — Image légère avec kubectl, curl, jq pré-installés. Le kubeconfig est monté en volume, jamais copié dans l'image.
2. **Skill SKILL.md** — Documentation procédurale pour l'agent Cursor : comment utiliser kubectl via Docker, quelles opérations sont autorisées, comment diagnostiquer, comment générer un rapport DevOps.
3. **Command .cursor/commands/k8s-troubleshoot.md** — Orchestration du workflow : détection de problème → diagnostic → action (in-scope) ou rapport (hors scope).

## Technology Stack

| Component | Technology | Rationale |
| --- | --- | --- |
| Container runtime | Docker | Règle projet : jamais d'exécution sur le host |
| K8s CLI | kubectl (alpine/k8s image) | Outil standard pour interagir avec K8s |
| Base image | `bitnami/kubectl:latest` | Image minimale avec kubectl pré-installé |
| Utilitaires | curl, jq | Pour fetch de docs et parsing JSON |
| Skill format | Markdown (SKILL.md) | Convention du projet (.agents/skills/) |
| Command format | Markdown (.cursor/commands/) | Convention Cursor |

## Project Structure

```
.agents/skills/k8s-troubleshoot/
├── SKILL.md                          # Skill principal : kubectl via Docker
├── Dockerfile                        # Image Docker avec kubectl + utils
├── resources/
│   ├── kubeconfig-format.md          # Documentation du format kubeconfig
│   ├── scope-permissions.md          # Matrice des permissions autorisées/interdites
│   └── dashboard-docs.md             # Documentation fetchée du dashboard admin (placeholder si 503)
└── templates/
    └── devops-report.md              # Template du rapport DevOps

.cursor/commands/k8s-troubleshoot.md  # Commande /k8s-troubleshoot
```

## Implementation Strategy

### Phase 1: Foundation — Dockerfile et Skill

1. Créer le Dockerfile basé sur `bitnami/kubectl` avec curl et jq ajoutés.
2. Écrire le SKILL.md décrivant :
   - Le format du kubeconfig et comment le monter
   - Les opérations kubectl autorisées vs interdites
   - Les procédures de diagnostic par type d'erreur
   - La procédure de modification ConfigMap
   - Le workflow de génération de rapport DevOps

### Phase 2: Commande et Templates

3. Écrire la commande `/k8s-troubleshoot` qui orchestre :
   - Validation du kubeconfig
   - Build/run du conteneur Docker
   - Diagnostic automatique du namespace
   - Actions correctives ou génération de rapport
4. Créer le template de rapport DevOps
5. Créer les ressources de référence (scope, format kubeconfig)

### Phase 3: Documentation du Dashboard

6. Prévoir un mécanisme de fetch de la doc du dashboard admin (curl depuis le conteneur Docker)
7. Documenter le fallback si le site est inaccessible

## Dockerfile Specification

```dockerfile
FROM bitnami/kubectl:latest

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq && \
    rm -rf /var/lib/apt/lists/*
USER 1001

ENTRYPOINT ["kubectl"]
```

Usage depuis le skill :
```bash
docker build -t k8s-troubleshoot .agents/skills/k8s-troubleshoot/
docker run --rm \
  -v /path/to/kubeconfig.yaml:/home/.kube/config:ro \
  -e KUBECONFIG=/home/.kube/config \
  k8s-troubleshoot get pods -n <namespace>
```

## Rapport DevOps — Structure

```markdown
# Rapport DevOps — [Problème]

**Date**: [YYYY-MM-DD HH:MM]
**Namespace**: [namespace]
**Ressource**: [pod/deployment/service name]
**Priorité**: [Critique / Haute / Moyenne]

## Problème constaté

[Description factuelle du problème observé]

## Evidence (Logs & Events)

[Extraits de logs et events kubectl pertinents]

## Cause probable

[Analyse de la cause racine]

## Action demandée

[Ce que le DevOps doit faire, de manière spécifique et actionnable]

## Justification

[Pourquoi cette action est nécessaire, avec le lien cause → effet]
```

## Dependencies

- Docker installé sur le host
- Kubeconfig téléchargé depuis le dashboard admin
- Accès réseau au cluster K8s (`api-kube-compute-lat.septeo.fr`)
