---
name: k8s-troubleshoot
description: >-
  Diagnose and resolve Kubernetes incidents (CrashLoopBackOff, ImagePullBackOff,
  OOMKilled, Pending, unreachable service) using kubectl run inside Docker with
  a restricted kubeconfig. Applies in-scope fixes (ConfigMap patch, rollout
  restart) and writes a DevOps report for anything out of scope.
tags:
  - kubernetes
  - docker
  - devops
  - infrastructure
---

# Kubernetes troubleshooting via Docker `kubectl`

`kubectl` runs **only** inside a container, never on the host. Allowed and forbidden actions: `resources/scope-permissions.md`. Kubeconfig layout: `resources/kubeconfig-format.md`.

## Prerequisites

- Docker, and a kubeconfig downloaded from your organization's Kubernetes dashboard (namespace page, Kubeconfig button). Check the actual path (`./kubeconfig.yaml`, `~/.kube/config-dashboard`, ...); never assume one. Never commit it.
- Image, built from this skill's directory. The Dockerfile pins `kubectl` through `KUBECTL_VERSION` (match the cluster, within one minor version; never a floating `latest`):

```bash
docker build -t k8s-troubleshoot --build-arg KUBECTL_VERSION=v1.31.4 <skill-dir>/
K8S_CMD='docker run --rm -v /abs/path/kubeconfig.yaml:/home/.kube/config:ro -e KUBECONFIG=/home/.kube/config k8s-troubleshoot'
```

The kubeconfig is always mounted, never copied into the image.

## Connectivity check (first)

```bash
$K8S_CMD cluster-info
$K8S_CMD auth can-i --list
$K8S_CMD config get-contexts
```

- `401` / `You must be logged in` / `connection refused`: expired or invalid kubeconfig, download a new one.
- `dial tcp: lookup ...` / `i/o timeout`: VPN or network; nothing to fix in-cluster.
- Resource not found: check `current-context` and its namespace.

## Diagnostics

Record excerpts of `events`, `describe` and `logs` for a possible report.

| Symptom | Chain | Typical out-of-scope fix |
|:---|:---|:---|
| CrashLoopBackOff | `get pods`, `describe pod`, `logs` (+ `--previous`), `get events --sort-by='.lastTimestamp'` | Secret, image, limits, NetworkPolicy |
| ImagePullBackOff | `describe pod`: image name, `imagePullSecrets` | Registry secret or access policy |
| OOMKilled | `describe pod` (`Reason: OOMKilled`, exit 137), memory limits, `top pods` | Raise limits / Helm chart |
| Pending | `describe pod` events (scheduling, affinity, PVC), StorageClass | Nodes, quotas, cluster storage |
| Error / Unknown | `describe`, `logs`, filtered `get events` | by classification |
| Unreachable service | `get svc`, `get endpoints <svc>`, pod readiness, `exec <pod> -- curl <svc>.<ns>.svc.cluster.local` | NetworkPolicy, DNS |

## In-scope corrections

```bash
$K8S_CMD get configmap <name> -o yaml                       # back up first
$K8S_CMD patch configmap <name> --type merge -p '{"data":{"KEY":"VALUE"}}'
$K8S_CMD rollout restart deployment/<name>
$K8S_CMD rollout status deployment/<name>
$K8S_CMD exec <pod> -- env | grep KEY                        # verify at runtime
```

Anything forbidden by the scope matrix (Secrets, Ingress, scale, pod deletion, image change) is **not** attempted: write a report.

## Port-forward

```bash
docker run --rm --network host -v /abs/path/kubeconfig.yaml:/home/.kube/config:ro \
  -e KUBECONFIG=/home/.kube/config k8s-troubleshoot \
  port-forward -n <namespace> pod/<pod> <local-port>:<remote-port>
```

Use another local port if taken (`15432:5432`). Wrap in `while true; do ...; sleep 2; done` if it drops on inactivity.

## DevOps report (out of scope)

Fill `templates/devops-report.md` (examples: `templates/devops-report-examples.md`) with real evidence (events, logs, describe) and the cause-to-effect chain. Save at the project root as `DEVOPS_REPORT_<YYYY-MM-DD>_<short-summary>.md`.
