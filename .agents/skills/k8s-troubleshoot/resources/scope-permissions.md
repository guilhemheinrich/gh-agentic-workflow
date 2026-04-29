# Scope Matrix — `modelo-debug-only` service account

This document summarizes what the service account delivered via the dashboard kubeconfig **can** and **cannot** do. Out-of-scope actions must be escalated via a **DevOps report** (see the report template in this skill's `templates/` directory).

All commands below assume the container described in the skill's SKILL.md: the `K8S_CMD` variable points to `docker run ... k8s-troubleshoot` with the kubeconfig mounted.

---

## Allowed (in scope)

### Read — `get`

| Resource | Example command |
|----------|----------------|
| Pods | `$K8S_CMD get pods` |
| Deployments | `$K8S_CMD get deployments` |
| Services | `$K8S_CMD get svc` |
| ConfigMaps | `$K8S_CMD get configmaps` |
| Events | `$K8S_CMD get events` |
| ReplicaSets | `$K8S_CMD get replicasets` |
| Jobs | `$K8S_CMD get jobs` |
| CronJobs | `$K8S_CMD get cronjobs` |
| Ingress (read-only) | `$K8S_CMD get ingress` |
| HPA | `$K8S_CMD get hpa` |

### Inspect — `describe`

For all resources listed above:

```bash
$K8S_CMD describe pod <name>
$K8S_CMD describe deployment <name>
$K8S_CMD describe service <name>
$K8S_CMD describe configmap <name>
# etc.
```

### Logs

```bash
$K8S_CMD logs <pod>
$K8S_CMD logs <pod> --previous
$K8S_CMD logs <pod> -c <container>
```

### Exec into a pod (non-destructive diagnosis)

```bash
$K8S_CMD exec -it <pod> -- sh
$K8S_CMD exec <pod> -- env
$K8S_CMD exec <pod> -- curl -sS http://<service>.<ns>.svc.cluster.local/health
```

### ConfigMap — modification (environment variables)

```bash
$K8S_CMD get configmap <name> -o yaml
$K8S_CMD edit configmap <name>
$K8S_CMD patch configmap <name> --type merge -p '{"data":{"KEY":"VALUE"}}'
```

### Deployments — rollout (applying ConfigMap changes, etc.)

```bash
$K8S_CMD rollout restart deployment/<name>
$K8S_CMD rollout status deployment/<name>
$K8S_CMD rollout history deployment/<name>
```

### Metrics

```bash
$K8S_CMD top pods
$K8S_CMD top nodes
```

---

## Forbidden (out of scope — DevOps report required)

| Domain | Examples of forbidden actions |
|--------|------------------------------|
| Secrets | Create, modify, or delete `Secret` resources |
| Ingress | Create or modify `Ingress` resources |
| Cluster / cluster RBAC | Create or modify `Namespace`, `ClusterRole`, `ClusterRoleBinding` |
| Infrastructure managed elsewhere | Databases, caches, brokers (direct cluster modification) |
| Pod resources | Modify `limits` / `requests` (typically changed via Helm chart) |
| Images | Change a `Deployment` image (managed by CI/CD / Argo CD) |
| Destruction | Delete `Pod` or `Deployment` (except restart via `rollout restart`, which does not delete the deployment resource) |
| Replicas / manual scale | `kubectl scale` — sizing is managed by HPA or Helm values |

If the fix requires any of these actions, document the need, evidence (events, logs, describe), and suggested commands for the DevOps team in a `DEVOPS_REPORT_<date>_<issue>.md` file at the project root.
