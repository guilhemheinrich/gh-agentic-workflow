# Report template

Copy everything below the line into the report file and fill it. Rules that make the
report usable:

- **Every finding carries its evidence**: the command, the JSON path or `file:line`,
  and the observed value. "Missing security headers" is not a finding;
  "`H:security_headers.missing` = `["content-security-policy", …]` on
  `https://shop.example.com/` (2026-11-24)" is.
- **Four states**: `FAIL`, `PASS`, `UNKNOWN` (could not be answered: no access, out of
  scope, tool error; say which) and `N/A` (the technology is confirmed absent). An
  `UNKNOWN` is not a pass and not a defect: it goes to section 6.
- **A finding claims only its evidence rung**: *declared* (a file says so), *observed*
  (a probe from a stated vantage point), *impact* (confirmed by the owner). A repository
  alone never proves "reachable from the internet".
- **One finding per defect**, however many tools reported it.
- **Declared vs observed vs inferred** is stated for every topology statement.
- **No secret in the report**: quote the variable name and the file, never the value.
  Raw tool outputs can hold secrets (rendered Secrets, scanner excerpts): keep them in
  a scratch directory, never commit them, delete them or hand them over at the end.

Severity scale (evidence rung first, scanner rating second):

| Severity | Meaning | Example |
|---|---|---|
| Critical | Data or control **accessible without valid credentials**: content observed within scope, or confirmed by the owner | `/.env` served; an unauthenticated admin console answering; owner confirms the database accepts logins it should not |
| High | Data or control **exposed** (declared, or a listener observed) with no proof of access; or no isolation once inside | Datastore behind a `LoadBalancer` Service in the manifests; PostgreSQL port answering from outside; dangling CNAME to a claimable provider; no NetworkPolicy in a namespace; privileged container; wildcard RBAC; TLS 1.0 accepted on a login host |
| Medium | Weakens defence or resilience, needs another fault to matter | Single replica on the request path; `/metrics` public; unpinned images; no HSTS |
| Low | Hygiene, information disclosure | Version in `Server`; missing `Referrer-Policy`; no PodDisruptionBudget |
| Info | Observation with no defect | CDN vendor, TLS 1.3 supported, `security.txt` present |

---

# Infrastructure audit: `<system name>`

| | |
|---|---|
| Date | `<YYYY-MM-DD>` |
| Auditor | `<name / agent>` |
| Requested by | `<name>` |
| Commit audited (white-box) | `<repo>@<sha>` |
| Tool versions | see section 8 |

## 1. Scope and authorization

| Host or repository | Tier allowed | Confirmed by | When |
|---|---|---|---|
| `shop.example.com` | 2 light | `<user, in conversation>` | `<date>` |
| `api.example.com` | 3 active, window `<date, hours>` | | |
| `git@…/shop-deploy` @ `<sha>` | 0 offline | | |

Out of scope, and why: `<e.g. *.azurewebsites.net: provider infrastructure, not scanned>`

Hosts discovered but not tested (need confirmation): `<e.g. admin.example.com, seen in the certificate SAN>`

## 2. Summary

Three to five sentences a non-specialist can read: what the system is, the worst
thing found, the general state, the first thing to do.

| Severity | Count |
|---|---|
| Critical | |
| High | |
| Medium | |
| Low | |
| Unknown (checks not answerable) | |

Raw scanner hits before deduplication: `<n>` (`<tool: n, …>`).

## 3. Topology

```mermaid
flowchart LR
  %% paste the output of topology-from-manifests.py, then add the black-box layers
  %% (see references/topology-mapping.md)
```

Legend: solid = declared or observed, dashed = inferred from configuration, red border
= an entry point from outside is declared (write "observed" on the edge once probed).

| Layer | What | Evidence | Source |
|---|---|---|---|
| CDN | `<Cloudflare>` | `<cf-ray: …-CDG>` | observed |
| WAF | `<vendor hinted by a cookie; rules enforced: UNKNOWN>` | `<set-cookie: __cf_bm>` | observed header |
| Load balancer | `<at least 2 responders, sticky>` | `<x-served-by takes 2 values, pattern BABABABA>` | observed; count and algorithm inferred |
| Ingress | | `<deploy/ingress.yaml:12>` | declared |
| Services | | | declared |
| Data | | | declared |
| External dependencies | `<api.stripe.com>` | `<env STRIPE_API_BASE>` | inferred |

**Entry points from outside** (every one, including the unintended):

| Entry | Port / protocol | Reaches | Intended? |
|---|---|---|---|
| | | | |

**Mismatches between declared and observed**: `<none | list>`

## 4. Findings

One block per finding, ordered by severity.

### F-NN `<short title>`: `<severity>`

| | |
|---|---|
| Area | `<DNS / TLS / HTTP / exposure / Kubernetes / Compose / Terraform / CI / supply chain / resilience>` |
| Check | `<id from the references, e.g. K-17, B-26, T-03>` |
| Object | `<host, or file:line, or namespace/Kind/name>` |
| Status | FAIL |

**Evidence**

```
<command run, and the relevant excerpt of its output>
```

**Why it matters**: `<one or two sentences in plain language: what an attacker or an outage can do with this>`

**Fix**: `<the concrete change, with the field to set>`

**Verification after fix**: `<the same command, and the value expected>`

Filled example, from the lab fixtures:

### F-01 PostgreSQL declared exposed outside the cluster: High

| | |
|---|---|
| Area | exposure / Kubernetes |
| Check | K-17, K-18 |
| Object | `fixtures/k8s/shop.yaml` Service `shop/postgres` |
| Status | FAIL |

**Evidence**

```
$ python -I topology-from-manifests.py fixtures/k8s --markdown
internet -->|"LoadBalancer 5432"| svc_shop_postgres
| high | T-K8S-05 | shop/StatefulSet/postgres | datastore declared exposed outside the cluster through Service 'postgres': reachability is UNKNOWN until observed from an authorized vantage point or confirmed by the owner |
```

Evidence rung: **declared**. Not verified: whether the address is public (no
internal-LB annotation and no `loadBalancerSourceRanges` in the manifest, but a cloud
firewall may restrict it) and whether this manifest is what is deployed.

**Why it matters**: the Service asks the cloud for a load balancer in front of the
database, outside the ingress, TLS termination and any WAF. If that address is
public, anyone can attempt logins against PostgreSQL.

**Fix**: remove `type: LoadBalancer` from the Service (default `ClusterIP`). For
administration, use `kubectl port-forward` or a bastion.

**To move up the evidence ladder, or close**: the address belongs to a cloud load
balancer, so it is never scanned (SKILL.md Step 0: nmap behind a cloud LB probes the
provider). Ask the owner for `kubectl get svc -n shop postgres` (external address,
source ranges) and the cloud side: the load balancer's scheme (internet-facing or
internal), its listeners, and the security group or firewall rules on port 5432.
Owner evidence of an internet-facing listener with no source restriction makes the
exposure *confirmed by the owner*: still High, since a database that demands a password
grants nothing by answering. It is Critical only if the owner confirms it accepts
connections it should not. Without that evidence, reachability stays `UNKNOWN`. Never
try to log in to find out.

**Verification after fix**: the topology no longer contains an edge from `internet`
to `svc_shop_postgres`.

## 5. Check matrix

One line per area, so that silence is visible; counts must add up to the number of
checks. Under the table, list **every `FAIL` and `UNKNOWN` by check id** with its
object and, for an `UNKNOWN`, the reason (`K-15 shop: UNKNOWN, network plugin not
known`). An area whose technology is absent is `N/A` as a whole.

| Area | Checks | Fail | Pass | Unknown | N/A | Reference |
|---|---|---|---|---|---|---|
| DNS | B-01 to B-10 | | | | | blackbox-checks.md |
| TLS | B-11 to B-21 | | | | | blackbox-checks.md |
| HTTP behaviour | B-22 to B-30 | | | | | blackbox-checks.md |
| Load balancing | B-31 to B-35 | | | | | blackbox-checks.md |
| Ports, origin | B-36 to B-41 | | | | | blackbox-checks.md |
| Exposed endpoints | endpoints.tsv (24 paths) | | | | | blackbox-checks.md |
| Kubernetes | K-01 to K-38 | | | | | k8s-checks.md |
| Docker / Compose | D-01 to D-09, C-01 to C-10 | | | | | iac-checks.md |
| Terraform / CloudFormation | T-01 to T-16 | | | | | iac-checks.md |
| CI/CD | P-01 to P-10 | | | | | iac-checks.md |
| Supply chain | S-01 to S-07, image scans | | | | | supply-chain.md |
| Resilience and operations | R-01 to R-43 | | | | | resilience-checks.md |

## 6. Unknowns and questions for the owner

| # | Question | Why it could not be answered | Follow-up priority |
|---|---|---|---|
| U-01 | `<When was a backup last restored?>` | `<not in any repository>` | High |

## 7. Positive findings

What is done well, with evidence. It tells the owner what not to break.

## 8. Method and reproducibility

| Step | Command | Tool and version | Date |
|---|---|---|---|
| Headers | `collect-headers.sh --i-am-authorized <host> <url>` | curl `<version from report.collector>` | |
| Active scans | `active-scan.sh … nmap` / `nuclei`, `--probe-endpoints`, `--deep` | `<image tags; nuclei template set version>` | `<window agreed>` |
| DNS / TLS | `tls-and-dns.sh --i-am-authorized <host> <host>` | `<report.tools>` | |
| IaC | `scan-iac.sh --out "$OUT/iac" <path>` | `<summary.json .tools>` | |
| Topology | `topology-from-manifests.py <path>` | python 3.12 | |
| Images | `trivy image …`, `syft` + `grype` | `<versions>` | |

Requests sent to each host: `<n>` (tier `<n>`), from `<vantage point: network, address>`.
Raw outputs: `<deleted on <date> | handed to <owner contact>>`; never committed, never
attached to the report (they can hold secrets and cookies).

Limits of this audit: `<what was not looked at: runtime cluster state, cloud console
settings not in IaC, application-level security, anything behind authentication>`.
