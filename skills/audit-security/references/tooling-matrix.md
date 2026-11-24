# Tooling matrix

Every tool runs in a container. The images the scripts use carry an exact
version tag, pulled and run on 2026-11-24. Three do not, and are marked
"floating": `python:3.12-slim`, `golang:1.25`, `rust:1-slim` follow patch
releases. Advisory data, EPSS, KEV and semgrep rules are live feeds: two
audits of the same commit can differ, so record the run date and versions
in the report.

For a stricter pin, resolve the digest once and use it:
`docker inspect --format '{{index .RepoDigests 0}}' semgrep/semgrep:1.186.0`.

## Images

| Tool | Image | Purpose | Run here |
|---|---|---|---|
| osv-scanner | `ghcr.io/google/osv-scanner:v2.7.1` | Dependencies, all ecosystems, from lockfiles | yes, via `scan-deps.sh` |
| jq | `ghcr.io/jqlang/jq:1.8.2` | JSON shaping in every script | yes |
| curl | `curlimages/curl:8.23.0` | OSV API fallback | yes |
| Python | `python:3.12-slim` (floating) | `enrich-kev-epss.py`, stdlib only, `-I` | yes |
| gitleaks | `zricethezav/gitleaks:v8.30.1` | Secrets, worktree and history | yes, via `scan-secrets.sh` |
| trufflehog | `trufflesecurity/trufflehog:3.100.1` | Secrets, with optional live verification | yes |
| semgrep | `semgrep/semgrep:1.186.0` | SAST | yes, via `scan-sast.sh` |
| syft | `anchore/syft:v1.57.2` | SBOM (CycloneDX, SPDX) | yes |
| grype | `anchore/grype:v0.122.1` | Vulnerabilities from an SBOM or a directory | yes |
| trivy | `aquasec/trivy:0.76.2` | Vulnerabilities, secrets, licenses, misconfig | yes |
| npm | `node:22.23.5-alpine` | `npm audit` | yes |
| pip-audit | `python:3.12-slim` + `pip install pip-audit==2.10.1` | Python dependencies | yes, on a one-line pinned file |
| govulncheck | `golang:1.25` (floating) + `govulncheck@v1.10.0` | Go, call-graph aware | no |
| cargo-audit | `rust:1-slim` (floating) + `cargo install cargo-audit --version 0.23.0 --locked` | Rust dependencies | no |

"no" means the command below is the documented invocation but was not
executed while writing this skill. Check the first run.

## Commands

`$PWD` is the audited repository, always mounted read-only (`:ro`). `$OUT`
is the output directory made once with `OUT=$(mktemp -d)`, outside the
checkout: a `>` redirect is opened by the host shell before Docker starts
and follows a symlink the repository may ship. No command below installs
or builds the audited project. Raw trufflehog is not
listed on purpose: unlike the wrapper, it **verifies credentials against
their provider by default**; only `--no-verification` keeps it offline, and
`--results=verified` filters the output without disabling the calls.

```bash
# Dependencies
<skill>/scripts/scan-deps.sh --out "$OUT" .
docker run --rm -v "$PWD":/src:ro ghcr.io/google/osv-scanner:v2.7.1 scan source -r --format json /src
# Ecosystem tools: run on COPIES, never with the repo as working directory
# (a committed .npmrc with registry=http://127.0.0.1:9/ made npm audit query
# that host; rust-toolchain.toml "path" runs a repo binary as cargo) and never
# with -v "$PWD/<file>": Docker follows a symlinked bind source on the host
# (a requirements.txt -> host file was handed over) and creates a missing one
# as a directory in the checkout. stage-inputs.sh copies regular in-repo files
# only and prints "not scanned" for the others (tested on all three cases).
<skill>/scripts/stage-inputs.sh --out "$OUT" package.json package-lock.json requirements.txt
docker run --rm -v "$OUT/inputs":/in:ro -w /in node:22.23.5-alpine npm audit --json
# Pinned requirements only. Without the two flags, pip-audit resolves like
# "pip install -r" and can run a package's build code (its README says so).
docker run --rm -v "$OUT/inputs":/in:ro python:3.12-slim sh -c 'pip install -q pip-audit==2.10.1 && pip-audit --no-deps --disable-pip -r /in/requirements.txt -f json'
# No "pnpm audit" here (corepack, above): osv-scanner reads pnpm-lock.yaml directly.
# Documented invocations, not executed while writing this skill:
docker run --rm -v "$OUT/inputs":/in:ro rust:1-slim sh -c 'cargo install cargo-audit --version 0.23.0 --locked && cargo audit --json --file /in/Cargo.lock'
# govulncheck must load the source: owner's yes, as for Rust call analysis.
docker run --rm -v "$PWD":/w:ro -e GOTOOLCHAIN=local -e CGO_ENABLED=0 -e GOFLAGS=-mod=readonly golang:1.25 sh -c 'go install golang.org/x/vuln/cmd/govulncheck@v1.10.0 && cd /w && govulncheck ./...'

# SBOM, then scan the SBOM
docker run --rm -v "$PWD":/src:ro anchore/syft:v1.57.2 scan dir:/src -o cyclonedx-json > "$OUT/sbom.cdx.json"
docker run --rm -v "$OUT":/in:ro anchore/grype:v0.122.1 sbom:/in/sbom.cdx.json -o json > "$OUT/grype.json"
# vuln and license only: secrets go through scan-secrets.sh, which redacts
docker run --rm -v "$PWD":/src:ro aquasec/trivy:0.76.2 fs --scanners vuln,license --format json /src > "$OUT/trivy.json"

# Secrets
<skill>/scripts/scan-secrets.sh --out "$OUT" .
<skill>/scripts/scan-secrets.sh --out "$OUT" --trufflehog .

# SAST
<skill>/scripts/scan-sast.sh --out "$OUT" .
<skill>/scripts/scan-sast.sh --out "$OUT" --config p/jwt --config p/xss --config p/sql-injection .
```

## Choosing a dependency scanner

| Tool | Reads | Strength | Blind spot |
|---|---|---|---|
| osv-scanner | Lockfiles of about every ecosystem, SBOMs | One tool for a polyglot repo; OSV data includes `MAL-` ids | Needs a lockfile; call analysis only for Go and Rust |
| `npm audit` | The lockfile, through the registry's advisory API | Knows `npm audit fix` paths | **Counts packages, not advisories**: on the fixture it prints `critical: 2, total: 2` where osv-scanner lists 11 advisories for the same 2 packages. Needs the registry |
| pip-audit | `requirements.txt`, installed env | PyPA data, can resolve unpinned requirements | Resolution may differ from production if not pinned |
| govulncheck | Go source + modules | Reports only vulnerabilities whose symbol is called | Go only; reflection and cgo |
| cargo audit | `Cargo.lock` | RustSec data, also flags unmaintained and yanked crates | Rust only |
| syft + grype | Directories, images, archives | Works without a lockfile; grype output carries EPSS, KEV and a risk score | Guesses from files found: more false positives on vendored code |
| trivy | Directories, images, IaC | One binary for vuln + secret + license | Its secret scanner found nothing on the fixture's generic token |

GitHub Advisory Database is the source behind most `GHSA-` ids. Query it
directly only to cross-check: `https://api.github.com/advisories?ecosystem=npm&affects=<name>@<version>`
(unauthenticated: 60 requests per hour; returns withdrawn advisories too,
see `osv-api.md`).

## Semgrep rulesets

All names below answered HTTP 200 on `https://semgrep.dev/c/p/<name>` (a
made-up name returns 404, so the check is meaningful).

| Ruleset | When |
|---|---|
| `p/default`, `p/owasp-top-ten`, `p/security-audit` | Always (set by `scan-sast.sh`) |
| `p/javascript`, `p/nodejs`, `p/typescript`, `p/react` | Added when `.js`/`.ts`/`.jsx`/`.tsx` files exist |
| `p/python`, `p/golang`, `p/java`, `p/php` | Added when such files exist |
| `p/expressjs`, `p/nextjs`, `p/django`, `p/flask` | Add by hand for the framework in use |
| `p/jwt`, `p/xss`, `p/sql-injection`, `p/command-injection` | Add by hand to dig one class |
| `p/secrets` | Add by hand for a third opinion on secrets |
| `p/cwe-top-25` | Add by hand when the report must speak CWE Top 25 |

Rules are downloaded from semgrep.dev at each run, so two runs weeks apart
can differ even with a pinned image. Record the run date. The scripts pass
`--metrics=off`. Cross-file taint analysis is a paid feature: the open-source
engine follows data inside one file only, which is why a controller that
passes input to a vulnerable helper in another file is missed.

## What the fixture proves

`scripts/fixtures/vulnerable-app` plants 2 vulnerable packages, 2 fake
secrets and 11 code flaws. Measured on 2026-11-24:

| Planted | Where | Detected by | Result |
|---|---|---|---|
| lodash 4.17.4, minimist 0.0.8 | `package-lock.json` | osv-scanner, OSV API, grype, trivy | 11 advisories, identical across the four |
| AWS documentation key pair | `config/fake-credentials.env:4-5` | nobody | **Allowlisted by design** in gitleaks and trufflehog |
| Generic 32-character token | `config/fake-credentials.env:9` | gitleaks `generic-api-key`, semgrep `detected-generic-secret` | Found; missed by trufflehog and trivy (no generic detector) |
| Same token deleted in a later commit | temporary repo | gitleaks history scan | Found in history, absent from the worktree scan |
| `eval(req.query.expr)` | `src/app.js:12` | semgrep | Found, CWE-95 |
| `exec('ping ' + host)` | `src/app.js:18` | semgrep | Found, CWE-78 |
| Reflected XSS | `src/app.js:23` | semgrep | Found, CWE-79 |
| Open redirect | `src/app.js:28` | semgrep | Found, CWE-601 |
| MD5 for a password | `src/app.js:33` | semgrep | Found, labelled CWE-327 |
| `postMessage` without origin check | `src/widget.js:10` | semgrep | Found, labelled CWE-345 |
| `Math.random()` reset token | `src/app.js:38` | nobody | **Missed** |
| IDOR on `/invoices/:id` | `src/app.js:43` | nobody | **Missed**: nothing to match, the check is absent |
| `location.hash`, decoded at line 5, into `innerHTML` | `src/widget.js:6` | nobody | **Missed** |
| Token in `localStorage` | `src/widget.js:16` | nobody | **Missed** |
| Reachable `_.defaultsDeep(req.body)` | `src/app.js:50` | nobody | Out of reach of SAST: needs the advisory and the code together |

Semgrep also reports two leads that are not planted flaws: `src/app.js:8`
(no CSRF middleware, INFO) and `src/app.js:13` (`res.send` of a computed
value). Six of eleven code flaws found, zero of the access-control ones.
That ratio is the argument for step 6 of the workflow.

A gap you can describe as a pattern can be closed with a local rule passed
through `--config`. Verified: a five-line rule with `pattern: Math.random()`
and `languages: [javascript]` makes `scan-sast.sh --config rule.yml` report
`src/app.js:38`. A gap that is an *absence* (the IDOR) cannot.

## Network access each step needs

| Step | Reaches | What leaves the machine |
|---|---|---|
| `scan-deps.sh` | `api.osv.dev` (osv-scanner also uses `api.deps.dev` to resolve manifests) | Package names and versions, **including private package names** |
| `npm audit` | the npm registry (`registry.npmjs.org` unless configured) | The whole staged lockfile: names, versions |
| `pip-audit` | `pypi.org` (default service), and PyPI to install itself | Names and versions from `requirements.txt` |
| `enrich-kev-epss.sh` | `www.cisa.gov`, `api.first.org` | The CVE ids found |
| `scan-secrets.sh` | nothing | Nothing. With `--verify`: each candidate credential, sent to its provider |
| `scan-sast.sh` | `semgrep.dev` | Nothing: rules are downloaded, `--metrics=off` |

No step uploads source code, but package names are metadata the owner may
not want disclosed: get the yes at step 1, per destination in this table. If it is a no, osv-scanner can
work from a local copy of the database (`--offline-vulnerabilities
--download-offline-databases`; flags present in v2.7.1, not run here);
otherwise report dependencies as "not scanned".

`--verify` is an option of the `scan-secrets.sh` wrapper, not of
trufflehog. It lets trufflehog send candidate credentials to their provider
to test them: that is a login attempt with someone's secret, so it needs
the owner's explicit yes.
