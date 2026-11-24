# Tooling matrix: image tags, digests and exact commands

Every tool runs in a container; nothing is installed on the host. Tags below were
pulled and run on 2026-11-24 (linux/arm64) unless the "Verified" column says otherwise.
The scripts use **version tags**, which a publisher can re-push; only a digest is
immutable. For a reproducible audit, export the image variable with the digest below
(`AUDIT_INFRA_TRIVY_IMAGE=aquasec/trivy@sha256:8f6b…`). Vulnerability databases and
nuclei templates are downloaded at run time and move daily whatever the image: record
their version or date in the report.

"Ran against the lab" is the only kind of verification this skill relies on. Nothing
here is a reason to run a tool against a host nobody asked you to audit.

## Matrix

| Purpose | Tool | Image | Tier | Verified |
|---|---|---|---|---|
| Headers, redirects, cookies, CORS, LB detection | curl + jq | `audit-infra-toolbox:1` (built from `scripts/Dockerfile`, `alpine:3.20`; curl 8.14.1, jq 1.7.1, OpenSSL 3.3.7, dig 9.18.49) | 2 | ran against the lab |
| DNS records, CNAME chain, takeover leads | dig | toolbox | 1 | ran against the lab resolver |
| TLS versions, certificate, HSTS | openssl | toolbox | 2 | ran against the lab |
| Full TLS assessment (ciphers, known attacks) | testssl.sh | `drwetter/testssl.sh:3.2` (amd64 only: emulated on arm64) | 3, both gates | ran against the lab as a non-root user: about 2 min |
| Open ports and service versions | nmap | `instrumentisto/nmap:7.98-r2` | 3, both gates | ran against the lab through `active-scan.sh` |
| Known misconfigurations and exposures | nuclei | `projectdiscovery/nuclei:v3.11.1` | 3, both gates | ran against the lab through `active-scan.sh`: 4905 requests, 244 s |
| Bulk DNS resolution | dnsx | `projectdiscovery/dnsx:v1.2.2` | 1 | ran against the lab resolver |
| Bulk HTTP probing, tech detection | httpx | `projectdiscovery/httpx:v1.12.0` | 2 | ran against the lab |
| IaC misconfiguration, secrets, image CVEs | trivy | `aquasec/trivy:0.76.2` | 0 | ran (`config`, `fs`, `image`) |
| Kubernetes and Helm lint | kube-linter | `stackrox/kube-linter:v0.8.3` | 0 | ran on the fixtures |
| Dockerfile lint | hadolint | `hadolint/hadolint:v2.15.1` | 0 | ran on the fixtures |
| IaC graph checks (IAM, NetworkPolicy, secrets) | checkov | `bridgecrew/checkov:3.4.9` | 0 | ran on the fixtures |
| SBOM | syft | `anchore/syft:v1.57.2` | 0 | ran on `redis:7-alpine` |
| CVE matching on an SBOM | grype | `anchore/grype:v0.122.1` | 0 | ran on that SBOM |
| Topology graph | python stdlib | `python:3.12-slim` | 0 | ran on the fixtures |
| Render Mermaid to SVG/PNG | mermaid-cli | `minlag/mermaid-cli:12.0.1` | 0 | rendered the generated graph |
| Kubernetes posture frameworks (NSA, CIS) | kubescape | `quay.io/kubescape/kubescape-cli` | 0 | **not verified**: no tag was pulled; pick and test one before use |
| Render Helm charts | helm | `alpine/helm:4.3.2` | 0 | ran `helm template` on a throwaway chart |
| Render Kustomize overlays | kustomize | `registry.k8s.io/kustomize/kustomize:v5.8.1` | 0 | ran `kustomize build` on a throwaway overlay |

Digests of the images as pulled (use `image@sha256:…` in CI for a truly fixed tool):

```
drwetter/testssl.sh@sha256:64bab3c1fd8eee440f68d5e020dd633c1f2d375fe0ae593bdfec2725110a7e29
instrumentisto/nmap@sha256:96f6ed194519b62421a1a1c57809e65a7f94d2aa1c8c25676f247e5e148c0827
projectdiscovery/nuclei@sha256:582d5546902e67052097cb2d07296c642d50a1afc5e44623cb038845df9a32eb
aquasec/trivy@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb
stackrox/kube-linter@sha256:f2bfce7879206d32f69ab6572c376f916643f54ca291ac38cf7d01ef591ff3f9
hadolint/hadolint@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d
bridgecrew/checkov@sha256:2d9a9852371cdd83e35c0d275449d50e9b97aa9ea4263405abb546eb0ad97e98
anchore/syft@sha256:e97e20b6e6d1699c60296b66ab337941724f9bd06ac279d893eda89601fc4b2a
anchore/grype@sha256:661583704a253c0448ed63998b5ea2cd9d5a76ee71eedc4aed439b8ce3e93a1c
projectdiscovery/dnsx@sha256:8fced0bedf3655e06c9f1805f6277d60d4988a4b13209e24b3d7cde7baa656ec
projectdiscovery/httpx@sha256:f8275a7c6aaec187249df9eaf4ad9196f4677adfc6a51a47b4aaa1d4db4f8ffc
python@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b
minlag/mermaid-cli@sha256:18938e53497376d524e04b1fc0bf7b6d61a491ce9ff7032bb2855d57155acb10
alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
alpine/helm@sha256:a3b9d617c0c30a6c488cebb429c4ba83995a26dc2184599af5fd408a361b2e67
registry.k8s.io/kustomize/kustomize@sha256:899fcd3bc898160e62bcaf82932b0cb29ba38d16272353db2e7acbba82129429
```

Sizes worth knowing before a first run: nuclei 866 MB, httpx 661 MB, checkov 581 MB,
mermaid-cli 1.4 GB; everything else is under 200 MB.

The scripts read their image from an environment variable, so a newer tag can be
tried without editing them: `AUDIT_INFRA_TRIVY_IMAGE`, `AUDIT_INFRA_HADOLINT_IMAGE`,
`AUDIT_INFRA_KUBELINTER_IMAGE`, `AUDIT_INFRA_CHECKOV_IMAGE`,
`AUDIT_INFRA_TESTSSL_IMAGE`, `AUDIT_INFRA_NMAP_IMAGE`, `AUDIT_INFRA_NUCLEI_IMAGE`,
`AUDIT_INFRA_TOOLBOX`.

## Active scans (tier 3): through the scripts only

`$HOST` is a host for which the user wrote both that it is theirs and that active
scans are agreed, with a window (see `scripts/AUTHORIZATION.md`). nmap, nuclei and
testssl are reached through `active-scan.sh` and `tls-and-dns.sh --deep`, which refuse
(exit 77) without `--i-am-authorized $HOST --active-scans-agreed $HOST`. Do not run
their images by hand against a remote host: that is the way around the gates.

### nmap

```bash
$S/active-scan.sh --i-am-authorized $HOST --active-scans-agreed $HOST \
  [--ports 22,443,5432] [--ipv6] --out out nmap $HOST        # writes out/nmap.xml
```

It runs `-Pn -sT -sV -T3 --max-rate 50` with `--top-ports 1000`, or `-p LIST`:

| Flag | Why |
|---|---|
| `-sT` | TCP connect scan: needs no raw-socket privilege in the container, and is the least surprising scan type |
| `-Pn` | Skip the ping: hosts that drop ICMP are still scanned |
| `-sV` | Identify the service and version behind each open port |
| `--top-ports 1000`, `-T3`, `--max-rate 50` | Bounded and slow on purpose. A full `-p-` scan is 65 535 probes: not offered. `--max-rate` caps port-scan probes only (nmap: "they only affect port scans and host discovery scans"): `-sV` then sends its own probes to each open port, uncapped. Announce both; if the owner needs a hard traffic ceiling, do not run it |
| `--ipv6` (`-6`) | nmap scans the **first address** of a name and one address family per run: when the host has AAAA records, run a second pass, IPv6 firewall rules are often forgotten |

The wrapper offers no UDP scan, no `--script`, no faster timing. Do not scan an address
that belongs to a CDN, PaaS or cloud load balancer: nmap would be scanning the
provider. State the vantage
point in the report: "open from the office VPN" is not "open from the internet".

Lab output (`--ports 80,443,8080,8443,9443,5432`): 80, 443, 8080, 8443, 9443 `open`
(`nginx 1.31.10`), `5432 closed`. An earlier run with the default `--top-ports 1000`
found 8080 and 8443 but **not 9443**: a top-ports scan is a sample, so pass `--ports`
with every port the manifests or security groups mention.

### nuclei

```bash
$S/active-scan.sh --i-am-authorized $HOST --active-scans-agreed $HOST --out out nuclei https://$HOST/
```

What the wrapper passes, and why:

| Flag | Why |
|---|---|
| `-pt http -tags exposure,misconfig,tech` | HTTP detection templates: exposed files, misconfigurations, technology fingerprints |
| `-exclude-tags dos,fuzz,intrusive,bruteforce,default-login,cve,rce,sqli,xss,ssrf,lfi,takeover,oast,injection,file-upload,auth-bypass,bypass,headless,code` | nuclei ORs the `-tags`: a template tagged `misconfig,default-login` is selected unless an exclusion names it |
| `-exclude-templates http/vulnerabilities/,http/cves/,http/cnvd/,http/iot/,http/default-logins/,http/fuzzing/` | Whole directories of exploit-shaped templates |
| `-severity info,low,medium,high` | Critical templates are mostly exploit checks: left out. That is a blind spot, say so in the report |
| `-rate-limit 20 -concurrency 5` | At most 20 requests per second |
| `-no-interactsh` | Disables nuclei's out-of-band callback server. Not a promise that no template names a third-party URL |

**This selection is a reduction of risk, not a guarantee.** Tags and paths are community
metadata on a template set that changes daily and is not pinned by the image. Measured
on template set v10.5.2 (2026-11-24, `nuclei -tl`): the first-pass selection (tags and
four exclusions only) contained 28 default-login templates, 201 CVE templates and 53
templates of `http/vulnerabilities` (auth bypass, file download, user creation); the
selection above runs 2715 templates, none from those directories. Record the
template set version, and tell the owner that this is what "nuclei" means here.

Measured on the lab: 2715 templates run, **4905 requests in 4 min 04 s** at 20 requests
per second, 20 matches. Say that number to the owner before running it. Reported:
`x-backend-server-header-detect`, `nginx-version`, `cookies-without-secure`,
`cookies-without-httponly`, `missing-cookie-samesite-strict`, `default-nginx-page`, ten
`http-missing-security-headers`. Cautions from the same run:

- one **false positive**: `fingerprinthub-web-fingerprints:splunk` on a plain nginx.
  Confirm every hit by hand before it becomes a finding;
- **misses**: the lab's `/.git/HEAD`, `/metrics` and `/server-status`, which
  `collect-headers.sh --probe-endpoints` finds with 24 requests, and the CORS reflection
  (its template lives in the excluded `http/vulnerabilities`), which
  `collect-headers.sh` reports as `cors.dangerous`. The two tools are complementary.

### testssl.sh

`tls-and-dns.sh --i-am-authorized $HOST --active-scans-agreed $HOST --deep out/ $HOST`
runs it as the calling user (no root in the container) and writes `out/testssl.json`.
Read **every** section by severity, not only protocols and vulnerabilities:

```bash
jq -r '.scanResult[0] | [.protocols, .ciphers, .fs, .serverPreferences, .serverDefaults,
  .headerResponse, .vulnerabilities] | map(. // []) | add | .[]
  | select(.severity | IN("OK", "INFO", "DEBUG") | not) | [.id, .severity, .finding] | @tsv' out/testssl.json
```

(Run jq in the toolbox: `docker run --rm -i audit-infra-toolbox:1 jq … < out/testssl.json`.)
Lab `:8443`: `TLS1 LOW`, `TLS1_1 LOW`, `cipherlist_aNULL CRITICAL`,
`cipher_order-tls1 CRITICAL`, `BEAST_CBC_TLS1 MEDIUM`, `LUCKY13 LOW`. The two
`CRITICAL` lines sit in `ciphers` and `serverPreferences`: a filter limited to
`protocols` and `vulnerabilities` misses them.

### Zone transfer (B-10)

```bash
docker run --rm audit-infra-toolbox:1 dig +noall +answer +comments AXFR example.com @ns1.example.com
```

One TCP query to a name server, which is a host of its own: only when the owner runs
that server (or its operator allows the test) and active scans are agreed. Not wrapped,
so the agent rule of `AUTHORIZATION.md` is the only gate: quote the user's agreement.
Lab: `status: REFUSED`, "Transfer failed." (the expected, passing answer).

### dnsx and httpx (bulk variants of the collectors)

```bash
# resolve a list of names (A and CNAME), one per line on stdin
docker run --rm -i projectdiscovery/dnsx:v1.2.2 -a -cname -resp -silent -nc < hosts.txt   # add -r <ip>:53 for a given resolver
# probe a list of URLs: status, title, server, detected technologies
docker run --rm -i projectdiscovery/httpx:v1.12.0 -title -tech-detect -status-code -web-server -json -silent < urls.txt
```

Use them when the scope has dozens of hosts; for one host the bundled scripts say more.
These two have no technical gate: every line of `hosts.txt` and `urls.txt` must be a
host the user confirmed, copied from the scope table and not from a discovery step.

### trivy on a live cluster (optional, read-only identity)

`trivy k8s` is **not** read-only by default: on trivy 0.76.2, `trivy k8s --help` says
it runs a node-collector Job (namespace `trivy-temp`, image
`ghcr.io/aquasecurity/node-collector`) unless `--disable-node-collector` is given. A
kubeconfig mounted read-only limits nothing: what the cluster lets trivy do is decided
by the identity inside it. So both, always:

- `--disable-node-collector` (node checks then become `UNKNOWN: node collector
  disabled`), and `--skip-images` unless image pulls from the cluster were agreed;
- an identity granted `get`, `list`, `watch` only, without `secrets` (check it first
  with `kubectl auth can-i --list`): never borrow an admin kubeconfig. A check that
  needs more is `UNKNOWN`, never a reason to widen the identity.

Mount the kubeconfig read-only and never copy it. The live-cluster command itself was
not run against a cluster while writing this skill: confirm the flags with
`trivy k8s --help` on the pinned version before the first run.

## Optional online references (third parties)

Two different things, both of which hand a name to a third party:

- **Scanners** (Observatory, SSL Labs, securityheaders.com) probe the host themselves
  and may keep or publish the result. An agreement to active scans by the auditor does
  not cover that. They are **not part of the agent workflow**: never submit a host;
  tell the owner the service exists and let them run it.
- **Lookups** (crt.sh, hstspreload.org) read a public list and send nothing to the
  host, but still learn the name: only for a host in scope. OSV receives a package
  name and version only: never send an internal package name.

Only API shape and availability were checked (2026-11-24); re-check before use.

| Service | What it adds | Checked how | Result that day |
|---|---|---|---|
| Mozilla HTTP Observatory (MDN) | A grade for HTTP security headers | `POST https://observatory-api.mdn.mozilla.net/api/v2/scan?host=<host>` (owner only) | answers `200` with JSON (`grade`, `score`, `tests_failed`) |
| Qualys SSL Labs | A widely recognised TLS grade | `GET https://api.ssllabs.com/api/v3/info` and `/api/v4/info` | both `200`, engine 2.4.3. Only `/info` was called: no assessment was started, so the `analyze` call, its registration requirement (v4) and its `publish` option are **not verified** here. Read the current API documentation before use |
| hstspreload.org | Whether a domain is in the browser preload list | `GET https://hstspreload.org/api/v2/status?domain=<domain>` (a list lookup, no scan) | `200`, JSON with `status` |
| crt.sh (certificate transparency) | Every certificate ever issued for a domain: forgotten subdomains | `GET https://crt.sh/?q=<domain>&output=json` (a log lookup, no scan) | **`502`** that day. The service is often overloaded: retry later, do not conclude "no certificates" |
| OSV | Vulnerabilities by package and version | `POST https://api.osv.dev/v1/query` | `200` |
| securityheaders.com | Header grade, browser use | home page fetched | `200`; no API was tested |

A grade from one of these is a second opinion, not evidence: quote the underlying
observation from the local collectors in the report.

## Overlap with other skills

| Need | Use |
|---|---|
| Browser-level audits (Lighthouse, accessibility, CSP directive reference) | `testing-and-debugging:web-analysis` (`resources/security-headers.md`) |
| A live cluster that misbehaves | `docker-and-k8s:k8s-troubleshoot` |
| Writing a good Dockerfile, rather than auditing one | `docker-and-k8s:dockerfile` |
| Compose port collisions between projects | `docker-and-k8s:compose-env-ports` |
| Designing the pipeline that should run these scans | `git-and-delivery:devops-pipeline-design` |
| Code-quality gate | `git-and-delivery:sonarqube-config` |
