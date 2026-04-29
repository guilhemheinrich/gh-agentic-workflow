# DevOps Report Examples (filled in)

Three realistic examples with anonymized `kubectl` output. Use as a reference for tone and level of detail.

---

## Example 1 — Missing Kubernetes Secret

# DevOps Report — Deployment Blocked by Missing Secret

**Date**: 2026-04-28 09:41
**Namespace**: modelo-management-pprod
**Affected resource**: deployment/api-gateway
**Priority**: RED Critical
**Cluster**: modelo-pprod

## 1. Observed Problem

The `api-gateway` deployment creates no functional ReplicaSet: pods remain absent or in error after creation. The `Replicas` field shows 0/1 available for over 15 minutes.

## 2. Evidence (Logs & Events)

### Kubernetes Events

```
LAST SEEN   TYPE      REASON                   OBJECT                            MESSAGE
4m22s       Warning   FailedCreate             replicaset/api-gateway-bad7f9bf   Error creating: pods "api-gateway-bad7f9bf-xxxxx" is forbidden: [...] secrets "svc-api-gateway-tls" not found
```

### Pod Logs

```
(no Ready pod — no application logs)
```

### Resource Description

```
Name:                   api-gateway
Replicas:               1 desired | 0 updated | 0 available
Conditions:
  Available             False ... MinimumReplicasUnavailable
Events:
  Warning  FailedCreate  replicaset failed: Secret "svc-api-gateway-tls" missing
```

## 3. Probable Cause

The Deployment references a TLS volume or a variable resolved via a Secret named **`svc-api-gateway-tls`**. This Secret does not exist in the namespace. The debug RBAC account cannot create Secrets: unblocking requires DevOps / security team action.

## 4. Requested Action

Create the `svc-api-gateway-tls` Secret in `modelo-management-pprod`, or fix the references in the Helm chart / manifests to point to an existing Secret.

**Suggested command(s)** (if applicable):

```bash
kubectl get secret svc-api-gateway-tls -n modelo-management-pprod
# If absent after validating the exact name in the Deployment:
kubectl create secret tls svc-api-gateway-tls --cert=file.crt --key=file.key -n modelo-management-pprod
```

(adaptation required based on the team's certificate strategy)

## 5. Justification

Without the Secret, Kubernetes refuses to create pods: no business processing possible. The fix is exclusively out of scope for the debug account (see scope permissions matrix).

## 6. Impact if Left Unresolved

API service unavailable; mobile clients and dependent backends receive 502/504 errors at the frontend.

---

## Example 2 — OOMKilled (memory limits too low)

# DevOps Report — Insufficient Pod Memory (OOMKill)

**Date**: 2026-04-27 22:06
**Namespace**: modelo-management-pprod
**Affected resource**: pod/search-indexer-847b7d6f6d-m7kqz
**Priority**: ORANGE High
**Cluster**: modelo-pprod

## 1. Observed Problem

The `search-indexer` deployment pod enters CrashLoop then briefly `Running`, with previous status `OOMKilled` on the `indexer` container.

## 2. Evidence (Logs & Events)

### Kubernetes Events

```
LAST SEEN   TYPE    REASON     OBJECT                                       MESSAGE
2m41s       Normal  Pulled     pod/search-indexer-847b7d6f6d-m7kqz          Successfully pulled image
1m52s       Warning BackOff    pod/search-indexer-847b7d6f6d-m7kqz          restarting failed container indexer
```

### Pod Logs

```
{"level":"info","msg":"starting bulk reindex","batch":5000}
(then abrupt stop — no application error)
```

### Resource Description

```
Containers:
  indexer:
    State:          Waiting
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
    Limits:
      memory:  512Mi
    Requests:
      memory:  256Mi
```

### Metrics (top)

```
NAME                                  CPU(cores)   MEMORY(bytes)
search-indexer-847b7d6f6d-m7kqz      890m         508Mi
```

## 3. Probable Cause

Peak memory consumption during reindexing exceeds the `512Mi` limit. The kernel kills the process (exit 137). Increasing `limits`/`requests` or reducing batch size is the responsibility of the platform team / Helm chart, not the debug account.

## 4. Requested Action

Increase the `indexer` container's memory limit (e.g., `1Gi` or a value validated by perf testing) via the Argo chart / values, or adjust the workload (batch size, partial index).

**Suggested command(s)** (if applicable):

```bash
# Illustration — apply via the project's actual Helm/GitOps
helm upgrade search-indexer chart/search-indexer --set indexer.resources.limits.memory=1Gi ...
```

## 5. Justification

As long as the limit is below the observed need (>500 Mi under load), OOM kills will repeat; no ConfigMap modification within scope resolves a workload resource constraint.

## 6. Impact if Left Unresolved

Stale search index, very high user search latency, internal SLA risk for business teams.

---

## Example 3 — Network / DNS (service unreachable from a pod)

# DevOps Report — Inter-service Dependency Unreachable (DNS or NetworkPolicy)

**Date**: 2026-04-26 11:17
**Namespace**: modelo-management-pprod
**Affected resource**: deployment/meet-notification-worker + internal service `catalog-api`
**Priority**: YELLOW Medium
**Cluster**: modelo-pprod

## 1. Observed Problem

The notification worker consistently returns HTTP timeouts to `http://catalog-api:8080` while the catalog pods are Ready and the Services exposed in the same namespace are reachable externally (ingress OK).

## 2. Evidence (Logs & Events)

### Kubernetes Events

```
No Warning events on catalog or worker pods other than a failed probe on the worker side.
```

### Pod Logs

```
2026-04-26T11:14:03Z WARN  http-client  GET http://catalog-api:8080/v1/feature-flags timed out after 3000 ms
Caused by: java.net.UnknownHostException: catalog-api
```

### Resource Description

```
Service/catalog-api exists, ClusterIP 10.x.y.z, Ports 8080/TCP -> Endpoints: 3 IPs
pod/meet-notification-worker: env CATALOG_HOST=catalog-api (correct short DNS)
NetworkPolicy/catalog-ingress present (Ingress allowed from namespace ingress-nginx only for other pods — not yet verified for East-West)
```

### Test via exec (diagnosis)

```
$ kubectl exec -it meet-notification-worker-aaaa-bbbb -- wget -qO- http://catalog-api.modelo-management-pprod.svc.cluster.local:8080/v1/health --timeout=2
wget: can't connect to remote host (10.x.y.z): Connection timed out

$ kubectl exec -it meet-notification-worker-aaaa-bbbb -- nslookup catalog-api
;; connection timed out; no servers could be reached
```

## 3. Probable Cause

DNS resolution or east-west traffic prevents the worker from reaching the CoreDNS cluster or opening the flow to the Service (missing NetworkPolicy allowing the namespace to reach `catalog-api`, or dnsPolicy / sidecar issue). Modifying NetworkPolicy / CoreDNS is outside the debug account's scope.

## 4. Requested Action

Check **NetworkPolicy** rules between `meet-notification-worker` and the `catalog-api` Service; allow TCP 8080 traffic within the namespace or adjust `dnsPolicy`/`dnsConfig` on the pod if the cluster enforces a custom resolver.

**Suggested command(s)** (if applicable):

```bash
kubectl get networkpolicy -n modelo-management-pprod -o wide
kubectl describe networkpolicy <name> -n modelo-management-pprod
# Then apply a policy allowing egress to the catalog deployment's label
```

## 5. Justification

Logs show `UnknownHostException` or DNS timeout depending on the run; exec confirms the absence of resolution or layer 3/4 connectivity. Without a cluster network fix, the worker cannot load feature flags.

## 6. Impact if Left Unresolved

Notifications partially sent or queue blocked; inconsistent user experience (no feature toggling driven by the catalog).
