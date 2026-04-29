# Feature Specification: K8s Infrastructure Troubleshoot

**Feature Branch**: `007-k8s-infra-troubleshoot`
**Created**: 2026-04-28
**Status**: Draft
**Input**: User description: "Commande réutilisable pour identifier et régler des problèmes d'infra K8s, avec skills kubectl dockerisé et rapport devops pour les actions hors scope"

## User Scenarios & Testing

### User Story 1 — Diagnostic d'un pod en erreur (Priority: P0)

En tant que développeur, je veux diagnostiquer pourquoi un pod est en erreur (CrashLoopBackOff, ImagePullBackOff, OOMKilled, etc.) pour comprendre la cause racine et agir.

**Why this priority**: C'est le cas d'usage le plus fréquent — un pod ne démarre pas ou crash.
**Independent Test**: Exécuter la commande sur un namespace contenant un pod en erreur, vérifier que le diagnostic identifie la cause.

**Acceptance Scenarios**:

1. **Given** un pod en CrashLoopBackOff dans le namespace, **When** l'utilisateur lance `/k8s-troubleshoot`, **Then** le skill récupère les logs, events, et describe du pod et identifie la cause probable.
2. **Given** un pod en ImagePullBackOff, **When** l'utilisateur lance la commande, **Then** le diagnostic indique clairement que l'image n'existe pas ou que le pull secret est manquant.
3. **Given** un pod OOMKilled, **When** l'utilisateur lance la commande, **Then** le diagnostic indique les limites mémoire actuelles et recommande un ajustement.

### User Story 2 — Modification de variables d'environnement (Priority: P0)

En tant que développeur, je veux pouvoir modifier des variables d'environnement (ConfigMaps) d'un déploiement pour corriger une mauvaise configuration.

**Why this priority**: Action corrective la plus courante dans le scope autorisé.
**Independent Test**: Modifier une variable d'env d'un ConfigMap et vérifier que le pod redémarre avec la nouvelle valeur.

**Acceptance Scenarios**:

1. **Given** un déploiement avec une variable d'env incorrecte dans un ConfigMap, **When** l'utilisateur demande à corriger via le skill, **Then** le ConfigMap est patché et le déploiement est relancé (rollout restart).
2. **Given** un changement de ConfigMap appliqué, **When** le pod redémarre, **Then** la nouvelle valeur est confirmée via `kubectl exec` ou describe.

### User Story 3 — Rapport DevOps pour actions hors scope (Priority: P1)

En tant que développeur, je veux qu'un rapport structuré soit généré lorsque le problème identifié nécessite une intervention DevOps (secrets, infrastructure, networking), afin de communiquer clairement la demande.

**Why this priority**: Essentiel pour la collaboration DevOps sans accès direct.
**Independent Test**: Déclencher un problème nécessitant un secret manquant, vérifier que le rapport est généré avec logs et recommandations.

**Acceptance Scenarios**:

1. **Given** un pod qui crash car un secret K8s est manquant, **When** le skill diagnostique le problème, **Then** un rapport Markdown est généré avec : description du problème, logs pertinents, action demandée, et justification.
2. **Given** un problème de networking (service unreachable), **When** le diagnostic détecte que le fix est hors scope, **Then** le rapport inclut un diagramme de la connectivité attendue vs observée.

### User Story 4 — Exécution 100% dockerisée (Priority: P0)

En tant que développeur, je veux que toutes les commandes kubectl soient exécutées via Docker, sans installation locale de kubectl.

**Why this priority**: Règle projet — jamais d'exécution directe sur le host.
**Independent Test**: Vérifier que la commande fonctionne sans kubectl installé localement, uniquement avec Docker.

**Acceptance Scenarios**:

1. **Given** un host sans kubectl installé, **When** l'utilisateur lance la commande, **Then** un conteneur Docker avec kubectl est utilisé pour toutes les opérations.
2. **Given** un kubeconfig local (artefact du dashboard admin), **When** le conteneur est lancé, **Then** le kubeconfig est monté en volume read-only dans le conteneur.

### Edge Cases

- Que se passe-t-il si le kubeconfig est expiré ou invalide ?
- Que se passe-t-il si le cluster est injoignable (réseau) ?
- Que se passe-t-il si le namespace n'existe pas ou si le service account n'a pas les droits ?
- Comment gérer un timeout sur une commande kubectl ?
- Que se passe-t-il si plusieurs pods du même déploiement ont des statuts différents ?

## Requirements

### Functional Requirements

- **FR-001**: Le système DOIT fournir un Dockerfile contenant kubectl, curl, et jq pour exécuter toutes les opérations K8s.
- **FR-002**: Le système DOIT monter le kubeconfig en volume read-only dans le conteneur Docker.
- **FR-003**: Le système DOIT diagnostiquer les causes de pods en erreur (CrashLoopBackOff, ImagePullBackOff, OOMKilled, Pending, Error, ErrImagePull).
- **FR-004**: Le système DOIT permettre la modification de ConfigMaps et le redémarrage de déploiements (rollout restart).
- **FR-005**: Le système NE DOIT PAS tenter de modifier des Secrets, Ingress, Namespace, ClusterRole, ou ressources d'infrastructure.
- **FR-006**: Le système DOIT générer un rapport Markdown structuré quand un problème identifié nécessite une action hors scope.
- **FR-007**: Le rapport DevOps DOIT contenir : description du problème, logs/events concrets, action demandée, justification technique.
- **FR-008**: Le système DOIT fournir un skill Cursor décrivant le kubeconfig et les opérations kubectl autorisées.
- **FR-009**: Le système DOIT fournir une commande Cursor (`/k8s-troubleshoot`) orchestrant le diagnostic.
- **FR-010**: Le système DOIT fetch et intégrer la documentation du dashboard admin (https://modelo-dashboard-k8s-preprod.septeo.fr/docs) comme référence dans le skill.
- **FR-011**: Le système DOIT valider la connectivité au cluster avant d'exécuter des opérations.

### Non-Functional Requirements

- **NFR-001**: Toutes les commandes kubectl DOIVENT être exécutées dans un conteneur Docker, jamais sur le host.
- **NFR-002**: Le Dockerfile DOIT utiliser une image minimale (alpine-based).
- **NFR-003**: Le kubeconfig NE DOIT JAMAIS être copié dans l'image Docker (volume mount uniquement).
- **NFR-004**: Le rapport DevOps DOIT être lisible et actionnable en moins de 2 minutes de lecture.

### Scope Boundaries (What this service account CAN and CANNOT do)

**Autorisé (dans le scope)**:
- `kubectl get` sur pods, deployments, services, configmaps, events, replicasets, jobs
- `kubectl describe` sur toutes les ressources ci-dessus
- `kubectl logs` sur les pods
- `kubectl exec` pour diagnostic (non-destructif)
- `kubectl edit/patch configmap` pour modifier des variables d'env
- `kubectl rollout restart deployment` pour appliquer des changements
- `kubectl rollout status` pour vérifier un déploiement
- `kubectl top pods/nodes` pour les métriques de ressources

**Interdit (hors scope → rapport DevOps)**:
- Créer/modifier des Secrets
- Créer/modifier des Ingress
- Créer/modifier des Namespaces, ClusterRoles, ClusterRoleBindings
- Modifier des ressources d'infrastructure (databases, caches, brokers)
- Modifier les resource limits/requests (nécessite un changement Helm)
- Modifier les images des déploiements (géré par CI/CD ArgoCD)
- Supprimer des pods/déploiements (sauf restart)

### Key Entities

- **Kubeconfig**: Fichier YAML d'authentification au cluster K8s, fourni par le dashboard admin. Contient cluster, user (service account token), context, namespace.
- **DiagnosticResult**: Résultat structuré d'un diagnostic (status, cause, evidence, recommendation, in_scope: boolean).
- **DevOpsReport**: Document Markdown généré quand une action hors scope est requise.

## Success Criteria

- **SC-001**: Un développeur peut diagnostiquer un pod en erreur en moins de 30 secondes après lancement de la commande.
- **SC-002**: Un ConfigMap peut être modifié et appliqué (rollout restart) en une seule session de commande.
- **SC-003**: 100% des commandes kubectl sont exécutées dans Docker, 0 exécution sur le host.
- **SC-004**: Le rapport DevOps contient systématiquement des logs/events concrets et une recommandation claire.
- **SC-005**: Le skill est réutilisable sur n'importe quel projet Modelo ayant un kubeconfig du même format.

## Assumptions

- Le kubeconfig est téléchargé manuellement depuis le dashboard admin et placé dans le projet.
- Le service account `modelo-debug-only` a les permissions de lecture sur la plupart des ressources et d'écriture sur les ConfigMaps.
- Docker est installé et fonctionnel sur le host du développeur.
- Le dashboard admin (https://modelo-dashboard-k8s-preprod.septeo.fr) peut être accessible depuis le conteneur Docker si le réseau le permet.
