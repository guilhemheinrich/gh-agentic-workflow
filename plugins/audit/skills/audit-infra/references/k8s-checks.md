# Kubernetes and Helm checks

Each row is a falsifiable statement about a manifest: the field to read, the value that
fails, why it matters, and which tool reports it. "Tool" ids were observed by running
`scripts/scan-iac.sh --with-checkov scripts/fixtures` (trivy 0.76.2, kube-linter
v0.8.3, checkov 3.4.9); `topology` means `scripts/topology-from-manifests.py`.
`manual` means no tool flagged it on the fixture: read the field yourself.

A row describes a **declared** state. Whether it is what runs (admission controllers
mutate pods, the cluster may differ from the repository) is `UNKNOWN` from files.

Render Helm and Kustomize before reading (commands in `topology-mapping.md`): the
audit is about what is applied, not about templates. kube-linter and trivy render Helm
charts themselves; the topology generator does not.

For a live cluster, complement with dockerized `kubectl` under an identity limited to
`get`, `list`, `watch` (a read-only file mount restricts nothing; see `trivy` in
`tooling-matrix.md`): manifests say what was intended, the cluster says what runs.

## Pod and container security

| # | Check | Fails when | Why | Tool |
|---|---|---|---|---|
| K-01 | `securityContext.privileged` | `true` | The container has every capability and sees host devices: container escape is one `mount` away | trivy `KSV-0017`, kube-linter `privileged-container`, checkov `CKV_K8S_16` |
| K-02 | `securityContext.allowPrivilegeEscalation` | absent or `true` | A setuid binary can regain root inside the container | trivy `KSV-0001`, checkov `CKV_K8S_20` |
| K-03 | `runAsNonRoot` / `runAsUser` | absent, `false`, or uid 0 | Nothing guarantees a non-root process: it runs as the image's `USER`, which is root unless the image sets one. Check the image before writing "runs as root" | trivy `KSV-0012`, kube-linter `run-as-non-root` |
| K-04 | `readOnlyRootFilesystem` | absent or `false` | An attacker can drop and run tools, or tamper with the application | trivy `KSV-0014`, kube-linter `no-read-only-root-fs` |
| K-05 | `capabilities.drop` | does not contain `ALL` | Default capabilities include `NET_RAW` (ARP spoofing inside the pod network) | trivy `KSV-0003`, checkov `CKV_K8S_28` |
| K-06 | `seccompProfile.type` | absent or `Unconfined` | The full syscall surface of the node kernel is reachable | trivy `KSV-0104`, `KSV-0030` |
| K-07 | `hostNetwork`, `hostPID`, `hostIPC`, `hostPath` volumes | any of the three set to `true`, or a `hostPath` volume | The pod shares the node's network or process namespace, or reads node files (`/var/run/docker.sock`, `/etc`) | trivy `KSV-0009` (network), `KSV-0010` (PID), `KSV-0008` (IPC), `KSV-0023` (hostPath), `KSV-0006` (docker.sock); verified on a throwaway Pod manifest, where `hostPID: false` raised nothing |
| K-08 | `resources.requests` and `limits.memory` | absent | No request: the scheduler overcommits the node. No memory limit: one leak evicts the neighbours | trivy `KSV-0016`, `KSV-0018`, kube-linter `unset-memory-requirements` |
| K-09 | `readinessProbe`, `livenessProbe` | absent | Without readiness, traffic reaches pods that are still starting; without liveness, a deadlocked pod stays in rotation | kube-linter `no-readiness-probe`, `no-liveness-probe` (opt-in checks, enabled by `scan-iac.sh`) |
| K-10 | Probe port | the probed port is not a declared `containerPort` | A lint **hint**, not a defect: Kubernetes does not require the port to be declared. Check that the probe targets the application's own listener (a copy-paste error probes another process) | kube-linter `readiness-port`, `liveness-port` (seen on `fixtures/k8s/payments.yaml`) |
| K-37 | `hostPort` | set on a container | Binds a port on the node's own address, bypassing Services, Ingress and some network plugins' policies | trivy `KSV-0024`, checkov `CKV_K8S_26` (seen on a throwaway Pod) |
| K-38 | Pod Security Admission | the Namespace has no `pod-security.kubernetes.io/enforce` label (`baseline` or `restricted`) | Nothing in the cluster refuses a privileged pod, unless another admission controller does (Kyverno, Gatekeeper: ask) | manual: no scanner flagged it on a throwaway Namespace |

Concrete example, `fixtures/k8s/shop.yaml` line 100: the `api` container sets
`securityContext: {privileged: true}`. Reported three times by three tools:
`KSV-0017`, `privileged-container`, `CKV_K8S_16`. In the report this is one finding,
not three.

## Images and supply chain

| # | Check | Fails when | Why | Tool |
|---|---|---|---|---|
| K-11 | `image` tag | no tag, or `:latest` | Two pods of one ReplicaSet can run different code; a rollback rolls back nothing | trivy `KSV-0013`, kube-linter `latest-tag`, topology `T-K8S-08` |
| K-12 | `image` digest | no `@sha256:` on production workloads | A tag is mutable: the registry owner (or a thief of its credentials) can replace it | checkov `CKV_K8S_43` |
| K-13 | Registry | image pulled from a registry outside the allow-list | Unreviewed public images in production | trivy `KSV-0125` (it flags any registry it does not know, including private ones: confirm by hand) |
| K-14 | `imagePullPolicy` with a mutable tag | `IfNotPresent` + mutable tag | Nodes keep whatever version they pulled first | checkov `CKV_K8S_15` |

## Network exposure and segmentation

| # | Check | Fails when | Why | Tool |
|---|---|---|---|---|
| K-15 | NetworkPolicy presence | a namespace with workloads has none | Kubernetes networking is flat by default: any pod reaches any pod on any port. One compromised pod reaches the database directly. With policies present, read each sensitive flow in both directions (source egress, destination ingress). Enforcement depends on the network plugin, which a manifest does not show: `UNKNOWN` without the cluster | topology `T-K8S-01`, kube-linter `non-isolated-pod` (opt-in, enabled by `scan-iac.sh`), checkov `CKV2_K8S_6`; not reported by trivy |
| K-16 | Default-deny | no policy with `podSelector: {}`, `policyTypes: [Ingress, Egress]` and no rules | Policies are additive allow-lists: without a default-deny, an unselected pod stays wide open. Without `policyTypes`, a policy with no `egress` rules covers **ingress only** and blocks no outgoing traffic | manual |
| K-17 | `Service.spec.type` | `LoadBalancer` or `NodePort` on anything but the ingress controller | Declares an entry point outside the cluster that bypasses Ingress, TLS termination and WAF. Who can reach it is not in the manifest (K-21, cloud firewall): declared, not observed | topology `T-K8S-02`, kube-linter `exposed-services` (opt-in, enabled by `scan-iac.sh`); not reported by trivy or checkov |
| K-18 | Datastore exposure | a `LoadBalancer` / `NodePort` Service or an Ingress backend selects a database, cache or queue | The data layer is declared exposed outside the cluster: high. A port observed open from outside keeps it high (observed); critical only when the owner confirms it accepts connections without valid credentials. Never attempt a login | topology `T-K8S-05` (fixture: `postgres` behind a LoadBalancer) |
| K-19 | Ingress TLS | `spec.tls` absent | No certificate is declared for these hosts. What is served then depends on the controller (clear text, or its default certificate) and on what terminates TLS upstream: say which, or leave the protocol `UNKNOWN`. Gateway API: `HTTPRoute` is drawn with `protocol UNKNOWN` (the Gateway listener decides); `Gateway`, `TCPRoute`, `TLSRoute` and `GRPCRoute` are not drawn: read them by hand | topology `T-K8S-04`; **no scanner flagged it** |
| K-20 | Ingress annotations | `ssl-redirect: "false"`, `whitelist-source-range: 0.0.0.0/0`, `configuration-snippet` / `server-snippet` present, `enable-cors: "true"` with `cors-allow-origin: "*"` | Snippet annotations inject raw nginx config (CVE-2021-25742 class); the others disable a protection | manual; grep `nginx.ingress.kubernetes.io/` |
| K-21 | `externalIPs`, `loadBalancerSourceRanges`, internal-LB annotation | `externalIPs` set; a LoadBalancer with neither `loadBalancerSourceRanges` nor an internal-load-balancer annotation | Traffic interception (CVE-2020-8554) and unrestricted source | topology appends ` (restricted?)` to the edge when one is present (seen on a throwaway Service); otherwise manual |
| K-22 | Dangling Service | selector matches no pod | Dead entry point, or a workload deployed from elsewhere that the audit has not seen | kube-linter `dangling-service`, topology `T-K8S-06` |

## Secrets and identity

| # | Check | Fails when | Why | Tool |
|---|---|---|---|---|
| K-23 | Credentials in `env[].value` or ConfigMap `data` | a password, token or a URL with `user:password@` | Readable by anyone with `get pods`/`get configmaps`, stored in Git and in every `kubectl describe` | checkov `CKV_SECRET_4` caught the URL form only; **the bare `POSTGRES_PASSWORD` value was caught by no tool**: list the env **names** only, `grep -rnoIiE 'name: *"?[a-z0-9_]*(password|secret|token|key)[a-z0-9_]*' <dir>` (`-o` prints the name, never the value on the same line), then quote name and file, not the value |
| K-24 | Secrets as env vars | `valueFrom.secretKeyRef` | Env vars leak into crash dumps and child processes; mounted files are safer and can rotate | checkov `CKV_K8S_35` (advisory) |
| K-25 | `kind: Secret` committed | any Secret with real `data` in Git | base64 is not encryption. In the cluster, Secrets are also plain in etcd unless encryption at rest is configured: cluster-side, ask | trivy secret scanner, manual |
| K-26 | `serviceAccountName` | absent (uses `default`) | Every pod of the namespace shares one identity; any RoleBinding to `default` applies to all | checkov `CKV_K8S_42`, kube-linter `default-service-account` (opt-in, enabled by `scan-iac.sh`) |
| K-27 | `automountServiceAccountToken` | `false` neither on the pod nor on its ServiceAccount, for pods that never call the API | A stolen token is a foothold in the API server | checkov `CKV_K8S_38` (reads the pod only: check the ServiceAccount before reporting) |
| K-28 | RBAC wildcards and Secret reads | a role with `verbs: ["*"]`, `resources: ["*"]`, or `get`/`list`/`watch` on `secrets`, **that a binding grants to a subject** | Grade by effective rights, with K-29's trace (subject -> binding -> role -> resources, verbs, scope): `*` on `*` in every API group through a `ClusterRoleBinding` is cluster-admin equivalent (fixture `rbac.yaml`); `secrets` read through a `ClusterRoleBinding` is cluster-wide Secret disclosure, serious but not administrative control; the same role through a `RoleBinding` is limited to that namespace; `verbs: ["*"]` on `configmaps` grants neither Secrets nor admin. An unbound role grants nothing: note it as latent, not `FAIL`. Report the effective verbs, resources and scope, never "cluster-admin" without the binding | trivy `KSV-0044`, `KSV-0046`, checkov `CKV_K8S_49`, `CKV2_K8S_5` (they read the role alone: confirm the binding) |
| K-29 | Escalation verbs | `escalate`, `bind`, `impersonate`; `create` on `pods/exec`, `serviceaccounts/token` or `pods`; `patch` on workloads; write on webhook configurations; certificate approval = `update` on `certificatesigningrequests/approval` **and** `approve` on `signers` (group `certificates.k8s.io`, often limited by `resourceNames`) | Each widens the holder's rights, up to cluster-admin when granted cluster-wide. Trace subject -> binding -> role -> resource and scope: a namespaced `pods/exec` is serious but is not cluster-admin; an approver is dangerous for the signers it covers | checkov `CKV_K8S_157`, `CKV_K8S_158`, `CKV2_K8S_2`, `CKV2_K8S_3` |
| K-30 | `ClusterRoleBinding` subject | `system:authenticated`, `system:unauthenticated`, or a `default` ServiceAccount | Grants to everyone, or to every pod of a namespace | checkov `CKV2_K8S_1` (fixture `rbac.yaml`) |

## Availability (see also resilience-checks.md)

| # | Check | Fails when | Why | Tool |
|---|---|---|---|---|
| K-31 | `replicas` | 1 on a request-path workload, with no HPA | One pod loss, node drain or rollout is an outage | topology `T-K8S-03` |
| K-32 | PodDisruptionBudget | absent for a workload with `replicas > 1` | A node drain may evict every replica at once | topology `T-K8S-07` |
| K-33 | Anti-affinity / `topologySpreadConstraints` | absent with `replicas > 1` | All replicas may land on one node or one zone | kube-linter `no-anti-affinity` |
| K-34 | PDB `maxUnavailable: 0` or `minAvailable` = replicas | set | Node drains block forever: upgrades stall | kube-linter `pdb-max-unavailable`, `pdb-min-available` |
| K-35 | `strategy.rollingUpdate` | `maxUnavailable: 100%` or `Recreate` on a request-path workload | Every deploy is a downtime | manual |
| K-36 | `terminationGracePeriodSeconds` and `preStop` | no `preStop` sleep and the app does not handle SIGTERM | In-flight requests are cut on every rollout (502 bursts) | manual |

## What each scanner saw (measured on the fixtures)

Defects planted in `scripts/fixtures`, and who reported them. "kube-linter +" is its
default set plus the opt-in checks `scan-iac.sh` passes with `--include`.

| Planted defect | trivy | kube-linter default | kube-linter + | checkov | topology |
|---|---|---|---|---|---|
| PostgreSQL behind a `LoadBalancer` Service (K-17, K-18) | no | no | `exposed-services` | no | `T-K8S-02`, `T-K8S-05` |
| Ingress without TLS (K-19) | no | no | no | no | `T-K8S-04` |
| Namespace without NetworkPolicy (K-15) | no | no | `non-isolated-pod` | `CKV2_K8S_6` | `T-K8S-01` |
| `postgres://user:password@` in an env value (K-23) | no | no | no | `CKV_SECRET_4` | no |
| `POSTGRES_PASSWORD: <plain value>` (K-23) | no | no | no | no | no |
| Wildcard ClusterRole bound to `default` (K-28, K-30) | `KSV-0044`, `KSV-0046` | no | `wildcard-in-rules`, `access-to-secrets` | `CKV_K8S_49` and 10 more | no |
| Privileged container (K-01) | `KSV-0017` | `privileged-container` | same | `CKV_K8S_16` | no |

Three lessons. A clean run of one scanner is not a clean audit: no single tool saw
more than four of the seven. Graph-level defects (exposure, segmentation) need a tool
that reads several objects together. And a plain-text password under an innocuous
variable name is invisible to all of them: read the env names yourself.
