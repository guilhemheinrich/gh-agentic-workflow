# Resilience and operations checks

Security answers "can someone get in"; this file answers "what happens when something
breaks, and will anyone notice". Each check names the evidence to look for and the
question to ask when the evidence cannot exist in a repository. An unanswered question
is reported as `UNKNOWN`, never as a pass and never as a proven defect: "nobody showed
me a restore test" is not "no restore was ever tested".

## Single points of failure

Walk the topology map from `Outside` to `Data` and ask of every node: "if this one
instance disappears, does a request still succeed?"

| # | Node | Evidence of redundancy | SPOF when |
|---|---|---|---|
| R-01 | DNS | NS records at two providers or one managed anycast provider | NS on a single self-hosted server |
| R-02 | Edge / LB | Managed LB, or two LB instances with a floating IP and health checks, shown by a file or confirmed by the owner. An address count proves nothing either way (B-05) | One VM running nginx or HAProxy in front of everything |
| R-03 | Ingress controller | `replicas >= 2`, spread over nodes | One replica (every request passes through it) |
| R-04 | Stateless service | `replicas >= 2` + PodDisruptionBudget + anti-affinity or `topologySpreadConstraints` | `replicas: 1` (topology `T-K8S-03`), or replicas all schedulable on one node |
| R-05 | Database | Managed multi-AZ, or primary plus replica with automatic failover | `multi_az = false` (checkov `CKV_AWS_157`), a single-replica StatefulSet, a Compose `db` service |
| R-06 | Cache / queue | Clustered or sentinel mode, quorum queues | One Redis holding sessions: its restart logs every user out |
| R-07 | Zone | Nodes and subnets in at least two zones | One subnet, one NAT gateway, one zone |
| R-08 | External dependency | Timeout, fallback or queue in front of each SaaS call | A synchronous call to a payment or mail API on the request path with no timeout |
| R-09 | People and credentials | Two people can deploy and can restore | One person holds the only admin access (ask) |

Concrete example, `fixtures/k8s`: `api x1` sits on the path of every `/api` request and
`postgres x1` under it. Both are reported as `T-K8S-03`. `web x2` is redundant on
paper, but has no PodDisruptionBudget (`T-K8S-07`) and no anti-affinity (kube-linter
`no-anti-affinity`): one node drain can still take both pods.

## Health checks

| # | Check | Evidence | Finding when |
|---|---|---|---|
| R-10 | Readiness | `readinessProbe` on every request-path container | Absent: traffic reaches pods that are starting or have lost their database |
| R-11 | Liveness | `livenessProbe`, distinct from readiness | Absent, or identical to readiness and checking a dependency: a database blip then restarts every pod at once (restart storm) |
| R-12 | Startup | `startupProbe` on slow starters (JVM, migrations) | A liveness probe with a short `initialDelaySeconds` kills the pod before it has started |
| R-13 | LB health check | Target group or upstream health check on an application path | Checks only that the TCP port is open: a process that answers 500 stays in rotation |
| R-14 | Depth | The health endpoint reports dependencies separately (`/ready` vs `/live`) | One `/health` that returns 200 unconditionally (made-up example: `return "OK"`) |
| R-15 | Exposure | The detailed health endpoint is not public | `/actuator/health` shows component details to the internet (`H:endpoints.exposed`) |

## Autoscaling and capacity

| # | Check | Evidence | Finding when |
|---|---|---|---|
| R-16 | Horizontal scaling | HPA / KEDA / ASG policy on request-path services | Fixed replica count on a service with variable load |
| R-17 | HPA prerequisites | `resources.requests` set (a CPU-percentage HPA is computed against requests) | HPA on CPU utilization with no CPU request: the HPA never scales |
| R-18 | Bounds | `minReplicas >= 2`, `maxReplicas` below what the database connection pool tolerates | `minReplicas: 1`; or `maxReplicas x pool size` exceeds the database `max_connections` |
| R-19 | Node capacity | Cluster autoscaler or spare capacity for one node loss | Sum of requests above the allocatable capacity of N-1 nodes |
| R-20 | Limits | Memory limit set, CPU limit a deliberate choice | No memory limit (noisy neighbour, node OOM) |

Worked example for R-18 (made-up numbers): `maxReplicas: 20`, each pod opens a pool of
10 connections, PostgreSQL `max_connections = 100`. At 11 pods the 101st connection is
refused: the autoscaler turns a traffic peak into a database outage.

## Backups and recovery

| # | Check | Evidence | Finding when |
|---|---|---|---|
| R-21 | Backups exist | `backup_retention_period > 0`, a backup CronJob, a Velero schedule, snapshot policies | None found (trivy `AWS-0077`, checkov `CKV_AWS_133` on the fixture: retention 0) |
| R-22 | Off-site and immutable | Copy in another region or account, object lock | Backups in the same account and region as the data: one compromised credential deletes both |
| R-23 | Restore tested | A dated restore exercise with its duration, that met the stated RPO/RTO, including access to the keys and dependencies it needs | Nobody can name the last restore. **An untested backup is a hypothesis**; a scheduled backup alone is not this evidence |
| R-24 | RPO / RTO stated | Target data loss and recovery time written down, backup frequency consistent with them | Daily backup against a stated RPO of 1 hour |
| R-25 | Deletion guards | `deletion_protection`, `skip_final_snapshot = false`, `prevent_destroy` | Absent on stateful resources (trivy `AWS-0177`) |
| R-26 | Infrastructure rebuild | Everything is in IaC; a new environment can be created from the repository | Resources created by hand that no file describes (the "unexplained listener" of the topology step) |

## Observability

Presence can be read from the repository; usefulness needs a question.

| # | Signal | Evidence in the repository | Black-box hint | Finding when |
|---|---|---|---|---|
| R-27 | Logs | A log shipper (Fluent Bit, Vector, Promtail, cloud agent), JSON logging config | none | Logs only on the node's disk: gone with the pod, unsearchable across replicas |
| R-28 | Metrics | Prometheus scrape config or annotations, ServiceMonitor, a metrics sidecar | `/metrics` answers (must not be public) | No metrics at all, or metrics public (see `blackbox-checks.md`) |
| R-29 | Traces | OpenTelemetry SDK or collector, `OTEL_EXPORTER_*` env vars | Responses carry `traceparent`, `x-amzn-trace-id`, `server-timing` | A multi-service request cannot be followed across services |
| R-30 | Alerting | Alert rules (PrometheusRule, CloudWatch alarms) with a receiver | none | Dashboards without alerts: someone must be watching |
| R-31 | Alert quality | Alerts on symptoms (error rate, latency, saturation), a paging route | none | Only cause-based alerts (CPU above 80 percent) that page for nothing and miss real outages |
| R-32 | Request correlation | A request id generated at the edge and logged by every service | `x-request-id` in responses | The id changes at each hop or is missing |
| R-33 | Audit logs | Kubernetes audit policy, CloudTrail, database audit | none | "Who changed this" cannot be answered |

## Rate limiting, timeouts and retries

| # | Check | Evidence | Finding when |
|---|---|---|---|
| R-34 | Edge rate limit | WAF rate rule, `limit_req` in nginx, ingress annotations `limit-rps`, gateway plugin | None anywhere on the path, in particular on login and other expensive endpoints |
| R-35 | Rate limit key | Limit keyed on the real client IP | Keyed on the proxy address because `X-Forwarded-For` is not trusted correctly: one user exhausts everyone's quota, or the limit never triggers |
| R-36 | Timeout chain | Each hop's timeout is shorter than the one in front of it | Inverted chain. Made-up example: ALB idle timeout 60 s, ingress `proxy-read-timeout` 120 s, application 300 s: the client gets a 504 while the work still runs to completion, three times if it retries |
| R-37 | Outbound timeouts | Explicit timeout on every HTTP and database client | Library defaults (often infinite): one slow dependency pins every worker |
| R-38 | Retry budget | Retries capped (for example 2), with backoff and jitter, only on idempotent calls | Retries at several layers multiply: 3 at the client x 3 at the gateway x 3 in the service = 27 attempts on a struggling database |
| R-39 | Circuit breaking | Outlier detection (Envoy), a breaker library, or a queue | A failing dependency is retried forever by every instance |
| R-40 | Graceful shutdown | `preStop` hook and SIGTERM handling, `terminationGracePeriodSeconds` above the longest request | 502 bursts at each deploy |
| R-41 | Body and header limits | `client_max_body_size`, header size limits at the edge | Unlimited upload size: disk and memory exhaustion from one request |
| R-42 | Certificate and credential renewal | Automated renewal (cert-manager, ACME, managed certificates) with an alert on failure; expiry dates of long-lived tokens tracked | A certificate renewed by hand, or `D:tls.certificate.expires_within_14_days` with no automation in sight |
| R-43 | Disk and storage exhaustion | `ephemeral-storage` limits, volume usage alerts, log rotation | A full disk on a database or a node is found by the outage |

Black-box probes for this section are deliberately absent from the scripts: measuring
a rate limit means trying to exceed it. Do it only with the owner present, in an agreed
window, and record the request count sent.

## Questions to ask when no file can answer

1. When was a backup last restored, by whom, and how long did it take?
2. What is the last incident, and which signal revealed it: an alert or a customer?
3. Who is paged at 3 a.m., and through what?
4. What happens to in-flight requests during a deploy?
5. Which dependency, if it slows down by 10 seconds, takes the site down?
6. Can the whole environment be recreated from the repository alone?

Each "we don't know" is an `UNKNOWN` in section 6 of the report, with a follow-up
priority: high for backups (R-21 to R-24) and paging, medium otherwise. It becomes a
`FAIL` only when the owner answers that the control does not exist.
