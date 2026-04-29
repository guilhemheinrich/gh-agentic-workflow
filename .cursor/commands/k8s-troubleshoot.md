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

# `/k8s-troubleshoot` — Kubernetes Infrastructure Troubleshooting

## Goal

Identify and resolve Kubernetes infrastructure problems within the scope allowed by the service account. For out-of-scope problems, generate a structured, actionable DevOps report.

## Usage

```
/k8s-troubleshoot [kubeconfig-path] [options]
/k8s-troubleshoot ./kubeconfig.yaml
/k8s-troubleshoot /Users/me/code/MODELO_HUB/modelo-meet/kubeconfig.yaml
/k8s-troubleshoot ./kubeconfig.yaml my-pod-abc123
/k8s-troubleshoot --report-only
```

| Argument | Description | Default |
|---|---|---|
| `kubeconfig-path` | Path to the kubeconfig file | `./kubeconfig.yaml` (project root) |
| `pod-name` | Specific pod to diagnose | _(full namespace scan)_ |
| `--report-only` | Diagnosis only, no modifications applied | _(fixes proposed)_ |

---

## Prerequisites — Read the skill

**MANDATORY**: Find and read the **k8s-troubleshoot** skill before taking any action. It contains detailed procedures, commands, the scope permissions matrix, and the DevOps report template/examples.

The skill also ships a **Dockerfile** that must be used for all kubectl operations — never run kubectl on the host.

---

## Step 1 — Resolve the kubeconfig path

1. If the user provided a path, use it.
2. Otherwise, search in this order:
   - `./kubeconfig.yaml` (current project root)
   - `../kubeconfig.yaml` (parent)
   - `~/.kube/config-dashboard`
3. If no file is found, **ask the user for the path**. Explain:
   > The kubeconfig is downloaded from the K8S Dashboard Septeo (https://modelo-dashboard-k8s-preprod.septeo.fr) — sign in via SSO — select a namespace — click the **Kubeconfig** button in the header bar.

Store the resolved absolute path as `KUBECONFIG_PATH` for subsequent steps.

---

## Step 2 — Build the Docker image

Build the image from the Dockerfile shipped alongside the skill:

```bash
docker build -t k8s-troubleshoot <path-to-skill-dockerfile-directory>/
```

If the image is already built (check with `docker images k8s-troubleshoot`), skip this step.

Define the command variable:

```bash
K8S_CMD="docker run --rm -v ${KUBECONFIG_PATH}:/home/.kube/config:ro -e KUBECONFIG=/home/.kube/config k8s-troubleshoot"
```

**CRITICAL**: Every `kubectl` command MUST go through `$K8S_CMD`. Never run `kubectl` directly on the host.

---

## Step 3 — Validate connectivity

```bash
$K8S_CMD cluster-info
$K8S_CMD auth can-i --list
$K8S_CMD config get-contexts
```

### If connectivity fails

| Error | Diagnosis | Action |
|---|---|---|
| `401 Unauthorized` / `You must be logged in` | Expired token | Ask user to re-download kubeconfig from dashboard |
| `connection refused` | Invalid kubeconfig | Re-download kubeconfig |
| `dial tcp: lookup ...` / `i/o timeout` | Network / VPN | Verify the user is connected to the Septeo VPN |
| `namespace not found` | Wrong context | Check `current-context` in the kubeconfig |

**STOP** if connectivity fails — do not continue the diagnosis.

---

## Step 4 — Scan the namespace

Run the following commands and display a summary:

```bash
$K8S_CMD get pods -o wide
$K8S_CMD get events --sort-by='.lastTimestamp' --field-selector type=Warning
$K8S_CMD get deployments
$K8S_CMD get svc
```

### Classify detected anomalies

For each non-Ready pod, identify the status:
- **CrashLoopBackOff** — follow the CrashLoop procedure from the skill
- **ImagePullBackOff / ErrImagePull** — follow the ImagePull procedure
- **OOMKilled** (visible in describe) — follow the OOM procedure
- **Pending** — follow the Pending procedure
- **Error / Unknown** — follow the generic procedure

For recent Warning events:
- Correlate with affected pods
- Identify recurring patterns (scheduling, probes, volumes)

If the user requested a specific pod, **prioritize** that pod but do not ignore other namespace anomalies.

Display a **summary table**:

```
| Pod | Status | Restarts | Age | Identified Problem |
|-----|--------|----------|-----|--------------------|
| ... | ...    | ...      | ... | ...                |
```

---

## Step 5 — Detailed diagnosis (for each anomaly)

For each identified problem, follow the corresponding procedure from the skill (Diagnostic Procedures section).

**Always collect**:
1. `$K8S_CMD describe pod <pod>` — events, conditions, exit codes
2. `$K8S_CMD logs <pod>` (and `--previous` if restarts > 0)
3. Correlated events

After diagnosis, **classify each problem**:

### IN-SCOPE problem (fixable)

Possible actions:
- Modify a ConfigMap: `$K8S_CMD patch configmap <name> --type merge -p '{"data":{"KEY":"VALUE"}}'`
- Restart a deployment: `$K8S_CMD rollout restart deployment/<name>`
- Verify a rollout: `$K8S_CMD rollout status deployment/<name>`

### OUT-OF-SCOPE problem (DevOps report)

Problems requiring escalation:
- Missing or incorrect Secret
- Docker image not found or registry inaccessible
- Insufficient resource limits/requests (OOMKilled)
- Networking / NetworkPolicy
- Ingress / TLS
- Scaling (HPA, replicas)
- Infrastructure (database, cache, broker)

---

## Step 6 — Apply fixes (unless `--report-only`)

For each identified in-scope fix:

1. **Explain** clearly what will be modified and why
2. **Show** the exact command that will be executed
3. **Ask for explicit confirmation** from the user before applying
4. **Execute** the fix
5. **Verify** the result:
   - `$K8S_CMD rollout status deployment/<name>` after a rollout restart
   - `$K8S_CMD get pods` to confirm pods are restarting correctly
   - `$K8S_CMD exec <new-pod> -- env | grep KEY` to validate a modified env var

---

## Step 7 — Generate DevOps report(s) (if out-of-scope problems exist)

For each problem identified as out-of-scope:

1. Use the DevOps report template shipped with the skill
2. Consult the report examples shipped with the skill for tone and level of detail
3. **MANDATORY in the report**:
   - Factual problem description
   - **Real evidence**: actual excerpts from `kubectl describe`, `kubectl logs`, `kubectl get events` (no fake output — real diagnostic output only)
   - Root cause analysis with reasoning
   - Requested action for DevOps (suggested command if possible)
   - **Justification**: why the DevOps must act (they must understand the "why" without additional context)
   - Impact if left unresolved
4. Write the file at the project root: `DEVOPS_REPORT_<YYYY-MM-DD>_<short-summary>.md`

---

## Step 8 — Final summary

Display a structured summary to the user:

```
## Diagnosis Result

### Namespace: <namespace>
### Cluster: <cluster>

### Problems detected: N

| # | Resource | Problem | Status | Action |
|---|----------|---------|--------|--------|
| 1 | pod/xxx  | CrashLoop (missing config) | ✅ Fixed | ConfigMap patched + rollout restart |
| 2 | pod/yyy  | OOMKilled | 📄 Report | DEVOPS_REPORT_2026-04-28_oom-search-indexer.md |
| 3 | pod/zzz  | ImagePullBackOff | 📄 Report | DEVOPS_REPORT_2026-04-28_image-pull-api.md |

### Generated files:
- DEVOPS_REPORT_2026-04-28_oom-search-indexer.md
- DEVOPS_REPORT_2026-04-28_image-pull-api.md
```

---

## Critical rules

- **NEVER** run `kubectl` directly on the host — always via the Docker container
- **NEVER** modify Secrets, Ingress, Namespace, ClusterRole, images, or scale
- **ALWAYS** ask for confirmation before applying an in-scope modification
- **ALWAYS** include real logs/events in DevOps reports (no placeholders)
- If the kubeconfig is expired or invalid, **guide** the user to the K8S Dashboard to download a fresh one
