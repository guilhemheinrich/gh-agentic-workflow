# Tasks: K8s Infrastructure Troubleshoot

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Structure du skill et Dockerfile

- [ ] T001 Créer le répertoire `.agents/skills/k8s-troubleshoot/` avec sous-dossiers `resources/` et `templates/`
- [ ] T002 Écrire le Dockerfile dans `.agents/skills/k8s-troubleshoot/Dockerfile`
- [ ] T003 [P] Écrire `.agents/skills/k8s-troubleshoot/resources/kubeconfig-format.md` — doc du format kubeconfig Modelo

## Phase 2: Foundational (Skill principal)

**Purpose**: Le SKILL.md qui décrit COMMENT utiliser kubectl via Docker

- [ ] T004 Écrire `.agents/skills/k8s-troubleshoot/resources/scope-permissions.md` — matrice complète des permissions autorisées/interdites avec exemples kubectl
- [ ] T005 Écrire `.agents/skills/k8s-troubleshoot/SKILL.md` — skill principal couvrant : prérequis Docker, montage kubeconfig, diagnostic par type d'erreur, modification ConfigMap, rollout restart, workflow rapport DevOps
- [ ] T006 [P] Écrire `.agents/skills/k8s-troubleshoot/resources/dashboard-docs.md` — placeholder avec instructions de fetch depuis Docker + structure attendue de la doc

**Checkpoint**: Skill utilisable manuellement par l'agent Cursor

## Phase 3: Templates et Rapport DevOps

**Purpose**: Template de rapport et exemples

- [ ] T007 Écrire `.agents/skills/k8s-troubleshoot/templates/devops-report.md` — template Markdown du rapport DevOps avec sections : problème, evidence, cause, action, justification
- [ ] T008 [P] Écrire `.agents/skills/k8s-troubleshoot/templates/devops-report-examples.md` — 3 exemples concrets de rapports (secret manquant, OOM, networking)

**Checkpoint**: Templates de rapport prêts et exemplifiés

## Phase 4: Commande Cursor

**Purpose**: La commande `/k8s-troubleshoot` qui orchestre le workflow

- [ ] T009 Écrire `.cursor/commands/k8s-troubleshoot.md` — commande Cursor orchestrant : localisation kubeconfig, build Docker, diagnostic namespace, actions correctives ou rapport DevOps

**Checkpoint**: Commande `/k8s-troubleshoot` fonctionnelle de bout en bout

## Dependency Graph

```
Phase 1 (T001-T003) → Phase 2 (T004-T006) → Phase 3 (T007-T008) → Phase 4 (T009)
                                                                         ↑
                                              T005 (SKILL.md) ──────────┘
```

## Summary

- Total tasks: 9
- By priority: P0=7, P1=2
- Estimated effort: ~0.5 j/h (3-4 heures humain)
