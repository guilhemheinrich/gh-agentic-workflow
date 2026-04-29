---
name: k8s-troubleshoot
description: >-
  Diagnose and resolve Kubernetes infrastructure issues using kubectl via Docker.
  Covers pod diagnostics, ConfigMap modifications, rollout management, and
  DevOps report generation for out-of-scope actions.
tags:
  - kubernetes
  - docker
  - devops
  - infrastructure
---

# Kubernetes — Diagnosis and Resolution via Docker (`kubectl`)

Procedure for analyzing cluster incidents using **only** `kubectl` executed inside a Docker container (never installed directly on the host). For the service account's effective scope, see the **scope-permissions** resource shipped alongside this skill. For kubeconfig format details, see the **kubeconfig-format** resource. For the full dashboard documentation, see the **dashboard-docs** resource.

## Prerequisites

1. **Docker** installed and working on the developer's machine.
2. A **valid kubeconfig** downloaded from the K8S Dashboard Septeo (see the **dashboard-docs** resource).
3. The file path on disk: often `./kubeconfig.yaml`, `../kubeconfig.yaml`, or a per-project path like `/Users/.../modelo-meet/kubeconfig.yaml`. Never assume a fixed path without checking.
4. The kubeconfig **must not** be committed to Git.

### Obtaining the kubeconfig

1. Connect to the [K8S Dashboard](https://modelo-dashboard-k8s-preprod.septeo.fr) via **Sign in with SSO** (Azure AD / Septeo account).
2. Select the target namespace from the home list (only namespaces assigned to your group are visible).
3. Click the **Kubeconfig** button in the namespace header bar.
4. Place the downloaded file at `~/.kube/config-dashboard` or in the project directory.

> Dashboard roles are **Dev**, **Tech Lead**, and **Admin** (superadmin). Namespace access is controlled by group — an admin must assign the user to a group on first login.

### Dashboard features (quick reference)

The K8S Dashboard also offers directly from the browser:
- **Logs**: last 200 lines or live streaming (LIVE badge)
- **Describe**: detailed description (events, conditions, volumes)
- **Shell**: interactive xterm terminal inside the pod via WebSocket (depends on group permissions)
- **Port-forward**: `:PORT` button copies the `kubectl port-forward` command to clipboard
- **KPIs**: total pods, pods in error, cumulative restarts, app version, last deploy, service count

These features complement the kubectl-based diagnosis described below.

## Docker Setup

### Building the image

From the repository root, build the Dockerfile shipped with this skill:

```bash
docker build -t k8s-troubleshoot <path-to-this-skill-directory>/
```

The Dockerfile copies the `kubectl` binary from the official **`bitnami/kubectl:latest`** image (dedicated stage) and installs `curl`, `jq`, and CA certificates on a **`debian:bookworm-slim`** layer. **No** kubeconfig is copied into the image — it is always mounted as a volume.

### Running `kubectl` in the container

Generic pattern (replace `<path>` with the actual kubeconfig):

```bash
docker run --rm \
  -v <path>/kubeconfig.yaml:/home/.kube/config:ro \
  -e KUBECONFIG=/home/.kube/config \
  k8s-troubleshoot \
  <kubectl arguments>
```

Example arguments: `get pods`, `describe pod my-pod`, `logs my-pod`, `auth can-i --list`.

### Alias / variable for reuse

Define a shell variable (adapt the absolute kubeconfig path):

```bash
K8S_CMD='docker run --rm -v /path/to/kubeconfig.yaml:/home/.kube/config:ro -e KUBECONFIG=/home/.kube/config k8s-troubleshoot'
```

Usage:

```bash
$K8S_CMD get pods
$K8S_CMD cluster-info
```

## Connectivity Validation (do this first)

1. **Cluster and API endpoint overview**

   ```bash
   $K8S_CMD cluster-info
   ```

2. **List effective permissions**

   ```bash
   $K8S_CMD auth can-i --list
   ```

3. **Degraded cases**

   - **Expired token / 401 / Unauthorized**: re-download the kubeconfig from the dashboard (Kubeconfig button).
   - **`The connection to the server was refused`**: invalid or expired kubeconfig — re-download from the dashboard.
   - **`error: You must be logged in to the server`**: same causes — new kubeconfig required.
   - **`Unable to connect to the server: dial tcp: lookup ...`**: the machine cannot reach the API server — check VPN / network connectivity.
   - **Unreachable cluster / timeout / i/o timeout**: VPN, firewall, or API unavailability; no in-cluster fix via this account.
   - **Wrong namespace / resource not found**: check `current-context` and `context.namespace` in the kubeconfig (`kubectl config get-contexts` via `$K8S_CMD`).

## Diagnostic Procedures

For each symptom type, chain the commands in the listed order and record excerpts from `events`, `describe`, and `logs` for a potential DevOps report.

### CrashLoopBackOff

1. `$K8S_CMD get pods` — identify the pod and its `RESTARTS`.
2. `$K8S_CMD describe pod <pod>` — events, exit code, probes.
3. `$K8S_CMD logs <pod>` and if needed `$K8S_CMD logs <pod> --previous`.
4. `$K8S_CMD get events --sort-by='.lastTimestamp'` — namespace-level correlation.
5. Deduce the cause (config, dependency, application bug); if the fix involves a Secret, image, limits, NetworkPolicy, etc., it is **out of scope** — generate a DevOps report.

### ImagePullBackOff / ErrImagePull

1. `$K8S_CMD describe pod <pod>` — `Failed` message / image / `imagePullSecrets`.
2. Verify the image name and the presence of expected `imagePullSecrets`.
3. If the issue is a missing registry secret or registry access policy: **out of scope** — DevOps report with `describe` excerpts.

### OOMKilled

1. `$K8S_CMD describe pod <pod>` — `Last State: Terminated`, `Reason: OOMKilled`, `Exit Code: 137`.
2. Note `limits` / `requests` memory.
3. `$K8S_CMD top pods` (if metrics-server is available).
4. If the fix involves increasing limits or changing the Helm chart: **out of scope** — DevOps report (see the report examples resource for tone/detail).

### Pending

1. `$K8S_CMD describe pod <pod>` — events (scheduling, affinity, node resources, PVC).
2. Check PVC and StorageClass if a volume message is present.
3. If the fix involves nodes, quotas, or cluster storage: **out of scope** — report.

### Error / Unknown (generic state)

1. `$K8S_CMD describe pod <pod>` then `$K8S_CMD logs <pod>` (+ `--previous` if restarts > 0).
2. `$K8S_CMD get events` filtered to the pod.
3. Systematic reasoning until classification (config, network, dependency, data).

### Unreachable Service

1. `$K8S_CMD get svc` — ports and selectors.
2. `$K8S_CMD get endpoints <service>` — targets behind the Service.
3. Verify readiness of target pods (`describe`, non-empty endpoints).
4. From an authorized pod: `$K8S_CMD exec <pod> -- curl` or equivalent to the internal URL (short DNS or FQDN `*.svc.cluster.local`).

## Corrective Actions (in scope)

Consult the **scope-permissions** resource before any modification.

### ConfigMap (data / variables)

1. Export current state: `$K8S_CMD get configmap <name> -o yaml`
2. Modify via merge patch:

   ```bash
   $K8S_CMD patch configmap <name> --type merge -p '{"data":{"KEY":"VALUE"}}'
   ```

### Apply changes to the deployment

```bash
$K8S_CMD rollout restart deployment/<name>
$K8S_CMD rollout status deployment/<name>
$K8S_CMD rollout history deployment/<name>
```

### Verify the new configuration at runtime

```bash
$K8S_CMD exec <pod> -- env | grep KEY
```

Any action listed as forbidden in the scope matrix (Secrets, Ingress, manual scale, pod deletion, image change, etc.) **must not** be attempted — produce a DevOps report instead.

## Port-forwarding (via Docker)

To access a database, API, or cache from the local machine:

```bash
docker run --rm --network host \
  -v /path/to/kubeconfig.yaml:/home/.kube/config:ro \
  -e KUBECONFIG=/home/.kube/config \
  k8s-troubleshoot \
  port-forward -n <namespace> pod/<pod-name> <local-port>:<remote-port>
```

Common ports: `5432` (PostgreSQL), `3306` (MySQL), `27017` (MongoDB), `6379` (Redis), `9200` (Elasticsearch), `8080`/`3000` (HTTP API).

If the local port is already taken: use an alternative port (e.g., `15432:5432`).

If the port-forward drops after a few minutes (inactivity):
```bash
while true; do
  docker run --rm --network host \
    -v /path/to/kubeconfig.yaml:/home/.kube/config:ro \
    -e KUBECONFIG=/home/.kube/config \
    k8s-troubleshoot \
    port-forward -n <namespace> pod/<pod-name> <local-port>:<remote-port>
  sleep 2
done
```

## DevOps Report Generation (out of scope)

When the fix exceeds the account's rights or the team's policy (Secrets, cluster networking, resources, GitOps, etc.):

1. Use the **devops-report template** shipped in this skill's `templates/` directory.
2. Include **real evidence**: excerpts from `kubectl get events`, `kubectl logs`, `kubectl describe` (filtered and readable).
3. Explain **why** the action is needed (cause → effect chain).
4. Save the file at the **project root** as:

   `DEVOPS_REPORT_<YYYY-MM-DD>_<short-problem-summary>.md`

Filled-in examples are available in the **devops-report-examples** file alongside the template.

## Reference

| Resource | Role |
|----------|------|
| `resources/scope-permissions.md` | Allowed / forbidden matrix + example commands |
| `resources/kubeconfig-format.md` | Kubeconfig structure and best practices |
| `resources/dashboard-docs.md` | Full K8S Dashboard Septeo documentation |
| `templates/devops-report.md` | Report template |
| `templates/devops-report-examples.md` | Examples (Secret, OOM, network/DNS) |
