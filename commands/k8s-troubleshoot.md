---
name: k8s-troubleshoot
description: >-
  Diagnose and resolve Kubernetes infrastructure issues. Identifies pod errors,
  applies in-scope fixes (ConfigMap, rollout), and generates DevOps reports
  for out-of-scope problems. All kubectl commands run inside Docker.
tags:
  - kubernetes
  - devops
  - infrastructure
---

# `/k8s-troubleshoot` — Diagnostic et résolution d'incidents Kubernetes

## Objectif

Identifier et résoudre les problèmes d'infrastructure Kubernetes dans le périmètre autorisé par le compte de service. Pour les problèmes hors scope, générer un rapport DevOps structuré et actionnable.

## Usage

```
/k8s-troubleshoot [kubeconfig-path] [options]
/k8s-troubleshoot ./kubeconfig.yaml
/k8s-troubleshoot /Users/me/code/MODELO_HUB/modelo-meet/kubeconfig.yaml
/k8s-troubleshoot ./kubeconfig.yaml mon-pod-abc123
/k8s-troubleshoot --report-only
```

| Argument | Description | Défaut |
|---|---|---|
| `kubeconfig-path` | Chemin vers le fichier kubeconfig | `./kubeconfig.yaml` (racine du projet courant) |
| `pod-name` | Nom d'un pod spécifique à diagnostiquer | _(namespace complet)_ |
| `--report-only` | Diagnostic seul, aucune modification appliquée | _(corrections proposées)_ |

---

## Prérequis — Lire le skill

**OBLIGATOIRE** : Lire et appliquer le skill `.agents/skills/k8s-troubleshoot/SKILL.md` avant toute action. Il contient les procédures détaillées, les commandes, et les limitations du compte.

Consulter aussi :
- `.agents/skills/k8s-troubleshoot/resources/scope-permissions.md` — matrice des actions autorisées/interdites
- `.agents/skills/k8s-troubleshoot/resources/dashboard-docs.md` — documentation du K8S Dashboard Septeo

---

## Step 1 — Résoudre le chemin du kubeconfig

1. Si l'utilisateur a fourni un chemin, l'utiliser.
2. Sinon, chercher dans cet ordre :
   - `./kubeconfig.yaml` (racine du projet courant)
   - `../kubeconfig.yaml` (parent)
   - `~/.kube/config-dashboard`
3. Si aucun fichier trouvé, **demander le chemin à l'utilisateur**. Expliquer :
   > Le kubeconfig se télécharge depuis le K8S Dashboard Septeo (https://modelo-dashboard-k8s-preprod.septeo.fr) → se connecter via SSO → sélectionner un namespace → bouton **Kubeconfig** dans la barre d'en-tête.

Stocker le chemin absolu résolu dans une variable `KUBECONFIG_PATH` pour la suite.

---

## Step 2 — Build de l'image Docker

```bash
docker build -t k8s-troubleshoot .agents/skills/k8s-troubleshoot/
```

Si l'image est déjà buildée (vérifiable avec `docker images k8s-troubleshoot`), sauter cette étape.

Définir la variable de commande :

```bash
K8S_CMD="docker run --rm -v ${KUBECONFIG_PATH}:/home/.kube/config:ro -e KUBECONFIG=/home/.kube/config k8s-troubleshoot"
```

**CRITIQUE** : Toute commande `kubectl` DOIT passer par `$K8S_CMD`. Jamais de `kubectl` exécuté directement sur le host.

---

## Step 3 — Validation de la connectivité

```bash
$K8S_CMD cluster-info
$K8S_CMD auth can-i --list
$K8S_CMD config get-contexts
```

### Si échec de connectivité

| Erreur | Diagnostic | Action |
|---|---|---|
| `401 Unauthorized` / `You must be logged in` | Token expiré | Demander à l'utilisateur de retélécharger le kubeconfig depuis le dashboard |
| `connection refused` | Kubeconfig invalide | Retélécharger le kubeconfig |
| `dial tcp: lookup ...` / `i/o timeout` | Réseau / VPN | Vérifier que l'utilisateur est connecté au VPN Septeo |
| `namespace not found` | Mauvais contexte | Vérifier `current-context` dans le kubeconfig |

**STOP** si la connectivité échoue — ne pas continuer le diagnostic.

---

## Step 4 — Scan du namespace

Exécuter les commandes suivantes et afficher un résumé :

```bash
$K8S_CMD get pods -o wide
$K8S_CMD get events --sort-by='.lastTimestamp' --field-selector type=Warning
$K8S_CMD get deployments
$K8S_CMD get svc
```

### Classifier les anomalies détectées

Pour chaque pod non-Ready, identifier le statut :
- **CrashLoopBackOff** → procédure CrashLoop du skill
- **ImagePullBackOff / ErrImagePull** → procédure ImagePull du skill
- **OOMKilled** (visible dans describe) → procédure OOM du skill
- **Pending** → procédure Pending du skill
- **Error / Unknown** → procédure générique du skill

Pour les events Warning récents :
- Corréler avec les pods affectés
- Identifier les patterns récurrents (scheduling, probes, volumes)

Si un pod spécifique a été demandé par l'utilisateur, **prioriser** ce pod mais ne pas ignorer les autres anomalies du namespace.

Afficher un **tableau résumé** :

```
| Pod | Status | Restarts | Age | Problème identifié |
|-----|--------|----------|-----|--------------------|
| ... | ...    | ...      | ... | ...                |
```

---

## Step 5 — Diagnostic détaillé (pour chaque anomalie)

Pour chaque problème identifié, suivre la procédure correspondante du skill (section "Diagnostic Procedures").

**Toujours collecter** :
1. `$K8S_CMD describe pod <pod>` — events, conditions, exit codes
2. `$K8S_CMD logs <pod>` (et `--previous` si restarts > 0)
3. Events corrélés

Après diagnostic, **classifier chaque problème** :

### Problème IN-SCOPE (corrigeable)

Actions possibles :
- Modifier un ConfigMap : `$K8S_CMD patch configmap <name> --type merge -p '{"data":{"KEY":"VALUE"}}'`
- Relancer un déploiement : `$K8S_CMD rollout restart deployment/<name>`
- Vérifier un rollout : `$K8S_CMD rollout status deployment/<name>`

### Problème OUT-OF-SCOPE (rapport DevOps)

Problèmes nécessitant une escalade :
- Secret manquant ou incorrect
- Image Docker introuvable ou registry inaccessible
- Resource limits/requests insuffisants (OOMKilled)
- Networking / NetworkPolicy
- Ingress / TLS
- Scaling (HPA, replicas)
- Infrastructure (database, cache, broker)

---

## Step 6 — Appliquer les corrections (si pas `--report-only`)

Pour chaque correction in-scope identifiée :

1. **Expliquer** clairement ce qui va être modifié et pourquoi
2. **Montrer** la commande exacte qui sera exécutée
3. **Demander confirmation** explicite à l'utilisateur avant d'appliquer
4. **Exécuter** la correction
5. **Vérifier** le résultat :
   - `$K8S_CMD rollout status deployment/<name>` après un rollout restart
   - `$K8S_CMD get pods` pour confirmer que les pods redémarrent correctement
   - `$K8S_CMD exec <new-pod> -- env | grep KEY` pour valider une variable d'env modifiée

---

## Step 7 — Générer le(s) rapport(s) DevOps (si problèmes hors scope)

Pour chaque problème identifié comme hors périmètre :

1. Utiliser le template `.agents/skills/k8s-troubleshoot/templates/devops-report.md`
2. Consulter les exemples `.agents/skills/k8s-troubleshoot/templates/devops-report-examples.md` pour le ton et le niveau de détail
3. **OBLIGATOIRE dans le rapport** :
   - Description factuelle du problème
   - **Evidence réelle** : extraits de `kubectl describe`, `kubectl logs`, `kubectl get events` (pas d'exemple fictif — des vraies sorties du diagnostic)
   - Cause probable avec raisonnement
   - Action demandée au DevOps (commande suggérée si possible)
   - **Justification** : pourquoi le DevOps doit agir (le DevOps doit comprendre le "pourquoi" sans contexte additionnel)
   - Impact si non résolu
4. Écrire le fichier à la racine du projet : `DEVOPS_REPORT_<YYYY-MM-DD>_<résumé-court>.md`

---

## Step 8 — Résumé final

Afficher un résumé structuré à l'utilisateur :

```
## Résultat du diagnostic

### Namespace : <namespace>
### Cluster : <cluster>

### Problèmes détectés : N

| # | Ressource | Problème | Statut | Action |
|---|-----------|----------|--------|--------|
| 1 | pod/xxx   | CrashLoop (config manquante) | ✅ Corrigé | ConfigMap patché + rollout restart |
| 2 | pod/yyy   | OOMKilled | 📄 Rapport | DEVOPS_REPORT_2026-04-28_oom-search-indexer.md |
| 3 | pod/zzz   | ImagePullBackOff | 📄 Rapport | DEVOPS_REPORT_2026-04-28_image-pull-api.md |

### Fichiers générés :
- DEVOPS_REPORT_2026-04-28_oom-search-indexer.md
- DEVOPS_REPORT_2026-04-28_image-pull-api.md
```

---

## Règles critiques

- **JAMAIS** exécuter `kubectl` directement sur le host → toujours via le conteneur Docker
- **JAMAIS** modifier des Secrets, Ingress, Namespace, ClusterRole, images, ou scale
- **TOUJOURS** demander confirmation avant d'appliquer une modification in-scope
- **TOUJOURS** inclure des logs/events réels dans les rapports DevOps (pas de placeholders)
- Si le kubeconfig est expiré ou invalide, **guider** l'utilisateur vers le K8S Dashboard pour en télécharger un nouveau
