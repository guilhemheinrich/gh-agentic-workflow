# Supply chain of the infrastructure

The infrastructure runs other people's code: base images, system packages, Helm
charts, Terraform modules, CI actions. This file covers what is deployed (images and
their contents); what builds it is in `iac-checks.md` (CI/CD rows P-01 to P-10).

The commands never touch the audited hosts, but they pull each image from the registry
its name points to. An image name found in a repository is untrusted input: scan
public images and the owner's registry only, and ask before pulling from a registry
you were not told about. Tool tags are in `tooling-matrix.md`.

## Step 1: inventory the images actually referenced

The list comes from the manifests, not from memory. `topology-from-manifests.py --json`
does not export images; grep them:

```bash
grep -rhoE '^[[:space:]]*(- )?image:[[:space:]]*[^[:space:]]+' deploy/ \
  | sed -E 's/.*image:[[:space:]]*//' | tr -d "\"'" | sort -u
```

(POSIX classes on purpose: `\s` returns nothing with the BSD grep of macOS.) Run it on
the rendered manifests, so that init containers and Jobs are included. On
`scripts/fixtures` this returns, among others, `postgres:17-alpine`,
`redis:7-alpine`, `registry.example.test/shop/api:latest`, `traefik:latest`.

For each image, record three facts before scanning anything:

| Fact | Finding when | Example |
|---|---|---|
| Pinning | no tag, `latest`, or a moving tag (`17-alpine`) on production | `traefik:latest`: the deployed version is whatever was current at pull time |
| Origin | public registry image from an unknown publisher; private image whose Dockerfile is not in scope | `portainer/portainer-ce:latest` in the Compose fixture |
| Age | base image older than its distribution's support window | made-up example: `node:14` (end of life April 2023) |

A digest (`image@sha256:…`) is the only immutable reference. A tag such as
`17-alpine` is a deliberate middle ground: patch updates arrive, but two nodes can run
different builds. So a scan of a tag describes **the tag as resolved today**, not
necessarily what runs: when the owner can give the running digest (`imageID` of the
pod), scan `repo@sha256:…`; otherwise say so next to the counts.

## Step 2: scan for known vulnerabilities, with two scanners

```bash
# trivy: pulls the image from its registry (no Docker socket needed)
docker run --rm -v audit-infra-trivy-cache:/root/.cache aquasec/trivy:0.76.2 \
  image --quiet --scanners vuln --platform linux/amd64 --format json redis:7-alpine > trivy-image.json

# syft: SBOM once, then grype matches the SBOM (repeatable without re-pulling)
docker run --rm anchore/syft:v1.57.2 redis:7-alpine --platform linux/amd64 -o cyclonedx-json -q > sbom.json
docker run --rm -v "$PWD":/w:ro anchore/grype:v0.122.1 sbom:/w/sbom.json -o json -q > grype.json
```

`--platform` must be the cluster's architecture: without it both tools scan the
auditor's own (arm64 on an Apple Silicon laptop), which can be another image. Add
`secret` to `--scanners` to look for credentials baked into layers (`iac-checks.md`
D-08).

A private image: ask the owner for a saved archive (`docker save img -o img.tar`) and
scan it with `trivy image --input /w/img.tar` (mount the folder read-only). Do not
mount the operator's `~/.docker/config.json`: it hands every registry login to the
container, and with a credential helper (`credsStore`, the Docker Desktop default)
it does not even work.

**The two scanners do not agree, and that is the lesson.** Measured on
`redis:7-alpine` on 2026-11-24 with that day's databases:

| Scanner | Total | Critical | High | Medium | Low |
|---|---|---|---|---|---|
| trivy 0.76.2 | 11 | 0 | 0 | 7 | 4 |
| grype v0.122.1 (on the syft SBOM, 710 components) | 30 | 1 | 18 | 9 | 2 |

What the two outputs show: trivy reported the Alpine packages only; grype counted
the same OpenSSL CVEs once under `libcrypto3` and once under `libssl3` (12 each), rated
a `zlib` CVE critical, and also matched the `redis-server` binary itself. The usual
explanation (not verified here CVE by CVE) is that trivy follows the distribution's
own advisories and severities while grype also uses NVD data. Neither is "the truth".
Consequences for the report:

1. Name the scanner, its version and the date next to every count.
2. Never write "0 critical vulnerabilities" from one tool.
3. Count by CVE id, but keep for each row the package, the installed and the fixed
   version: one CVE can sit in several packages with different fixes. Then judge each
   critical or high by hand.

## Step 3: triage each vulnerability by reachability

A CVE count is not a risk. For each critical or high:

| Question | Where to look | Outcome |
|---|---|---|
| Is a fix available? | `FixedVersion` (trivy), `fix.versions` (grype) | No fix: record, watch, consider another base image. Fix exists: it is a patching delay, state how old |
| Is the component used at run time? | Is the package a library the process loads, or a leftover (`curl`, a compiler)? | Leftover: remove it (smaller image) rather than patch it |
| Is the vulnerable path reachable from outside? | The topology map: is this workload on a path from `Outside`? | Reachable + fix available = top of the list |
| Is it known to be exploited? | CISA KEV catalogue (exploited somewhere), EPSS score (a probability). `trivy` and `grype` can show both; check the flag in the pinned version's `--help` | In KEV **and** the package is really present and used here: top of the list whatever the CVSS |

Made-up example of a triaged line: "CVE-2099-0001 (critical, zlib): no fixed version
in Alpine, the affected function is not called by redis-server, workload has no path
from outside. Accepted, re-check monthly."

## Step 4: SBOM and OSV for what scanners do not see

An SBOM (software bill of materials) is the list of every component inside an image.
Keep the one produced in step 2 with the report: it lets the owner answer "are we
affected by tomorrow's CVE" without re-scanning.

OSV (`osv.dev`) is a public vulnerability database queried by package and version.
The API answered `200` when this skill was written. It is useful for application
dependencies and for a single component check:

```bash
docker run --rm audit-infra-toolbox:1 curl -s -X POST https://api.osv.dev/v1/query \
  -d '{"package":{"name":"lodash","ecosystem":"npm"},"version":"4.17.20"}'
```

This sends a package name and version to a third party; it reveals nothing about the
host, but do not send internal package names.

## Step 5: provenance and admission

| # | Check | Evidence | Finding when |
|---|---|---|---|
| S-01 | Signatures | `cosign verify <image>` succeeds with the organisation's key or identity | Images are not signed, or signatures are never verified |
| S-02 | Build provenance | SLSA provenance or `docker buildx --provenance` attestation attached | Nobody can link an image to a commit and a pipeline run |
| S-03 | Admission control | Kyverno, Gatekeeper or a ValidatingAdmissionPolicy restricting registries and requiring digests or signatures | Any image from any registry can be deployed |
| S-04 | Pull credentials | `imagePullSecrets` scoped per namespace, read-only | One registry token with push rights shared by cluster and CI |
| S-05 | Charts and modules | Helm chart versions and Terraform module sources pinned to a version or commit | `version: "*"`, a module from a branch |
| S-06 | Base image refresh | A scheduled rebuild, or Renovate/Dependabot on Dockerfiles | Images rebuilt only when the application changes: base CVEs age silently |
| S-07 | Scan in the pipeline | Image scan step that fails the build above a threshold | No scan, or `continue-on-error: true` |

`cosign` was not run while writing this skill; take its exact flags from the version
you pin.
