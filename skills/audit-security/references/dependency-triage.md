# Dependency triage

A scanner returns a list. An audit returns an order: what to fix today, what
this sprint, what never. This file is how to get from one to the other.

## 1. Why not sort by CVSS

CVSS measures how bad a vulnerability would be **if** exploited, in the worst
deployment. It says nothing about whether anyone exploits it. Two real rows
from the fixture (`scripts/fixtures/vulnerable-app`, data of 2026-11-24):

| Package | CVE | CVSS | EPSS | Sorted by CVSS | Sorted by this skill |
|---|---|---|---|---|---|
| lodash 4.17.4 | CVE-2020-8203 | 7.4 | 0.052 | first | P2 |
| lodash 4.17.4 | CVE-2021-23337 | 7.2 | 0.202 | second | **P1** |

CVE-2021-23337 has the lower CVSS and four times the forecast probability
of exploitation. And neither is in KEV, while Log4Shell (CVE-2021-44228) is, with
"ransomware use: Known". Three signals, three different questions:

| Signal | Question it answers | Source | Shape |
|---|---|---|---|
| CVSS base | How bad in the worst case? | advisory | 0.0 to 10.0 |
| EPSS | How likely is exploitation activity against this CVE, anywhere, in the next 30 days? | FIRST.org | probability 0 to 1, plus a percentile |
| KEV | Is there reliable evidence it has been exploited in the wild? | CISA | in the list or not |

None of the three knows this application: EPSS and KEV are about the CVE
worldwide, not about whether this deployment is exposed. That is section 3.

EPSS trap: read the **score**, not the percentile. CVE-2020-28500 (lodash
ReDoS) sits at the 95th percentile with a score of 0.074: "worse than 95% of
CVEs" still means a 7% probability, because most CVEs score near zero.

## 2. The rule

`scripts/enrich-kev-epss.py` applies it; first match wins.

| Priority | Condition | Deadline to propose |
|---|---|---|
| **P0** | In CISA KEV, or a malicious package (`MAL-` id, or summary starting with "Malicious") | Now. For a malicious package: incident, not upgrade |
| **P1** | EPSS >= 0.10, or CVSS >= 9.0 | This week |
| **P2** | CVSS 7.0 to 8.9 without exploitation evidence, or no usable score | This sprint |
| **P3** | The rest | With the next routine upgrade |

When the advisory has no CVSS v3 vector (CVSS v4 only, or none), the script
falls back to GitHub's label: CRITICAL counts as 9.0, HIGH as 7.0, MODERATE
as 4.0. Example: `GHSA-4xc9-xhrj-v574` (lodash, CVE-2018-16487) has only
the label HIGH and lands in P2.

The 0.10 EPSS threshold is this skill's convention, not a FIRST standard.
FIRST publishes no official cut-off. 0.10 keeps roughly the top 4% of all
CVEs (on 2026-11-23, 0.074 was the 95th percentile and 0.202 the 98th); lower it to 0.01 for an internet-facing system that handles
payments or health data, and say so in the report.

If KEV or EPSS cannot be fetched, the script exits `2` and writes nothing.
Do not fall back to CVSS silently: say "exploitation data unavailable".

## 3. Adjust for context

The script knows nothing about the application. Apply these by hand, and
write the reason next to each change.

| Fact | Effect | Example |
|---|---|---|
| Dependency only in `devDependencies`, never shipped | Down one level | A ReDoS in a test runner |
| Vulnerable function proven not called: a call-graph tool says so, or a precondition of the advisory is excluded (section 4) | Down one level | govulncheck reports the module but not the symbol; a server-side flaw in a package that only ships in the browser bundle |
| Runs in the browser only, vulnerability is server-side | Down, often to "not affected" | A path traversal in a package used only in the SPA bundle |
| Reachable from an unauthenticated endpoint | Up one level | `_.defaultsDeep(req.body)` on a public route |
| No fixed version exists (`fixed: []`) | Same priority, different action | Replace the package or add a guard; say which |
| KEV entry | Critical; never lowered without a written proof of non-reachability | Reachability unknown stays Critical |

Never delete a row. A finding judged not exploitable stays in the report as
"not affected" with its justification, so that the next audit does not redo
the analysis. A grep that returns nothing is a lead, not a proof (section 4
lists what it misses): it never earns "not affected" or a lower priority.
Example of the honest wording: "CVE-2021-23337, lodash `template`: no
direct call found (`<skill>/scripts/leads.sh "\.template\(" src/`: 0 lines; the lockfile
shows the app as lodash's only dependant). Not checked: aliases,
destructured imports, dynamic access `_[name]`. Reachability unknown,
priority kept". "Not affected" is for an excluded precondition: "the
advisory needs attacker-controlled template options; the package is only
in `devDependencies` and absent from the production image".

## 4. Reachability: is the vulnerable function actually called?

A vulnerable package is not a vulnerable application. The lodash prototype
pollution CVE-2019-10744 lives in `defaultsDeep`; an app that only uses
`_.debounce` is not exposed. In the fixture, `src/app.js:50` calls
`_.defaultsDeep({}, req.body)`: reachable, with attacker-controlled input.

How to check, by decreasing reliability:

| Method | Works for | Trust it? |
|---|---|---|
| `govulncheck ./...` | Go | Yes for static calls: it builds the call graph and reports only called symbols. Blind to reflection and to calls through `plugin` or cgo |
| `osv-scanner scan source --call-analysis=go` | Go | Same idea, same limits. `--call-analysis=rust` **runs the project's build scripts**: not part of a read-only audit (`SKILL.md`, rule 1), only with the owner's yes, in a throwaway copy, with no credentials mounted |
| Read the advisory for the function name, then search the code | Any | Good for "is it imported and called at all" |
| Reason about the data flow by reading | Any | Only as good as the reading |

For JavaScript, TypeScript, Python, PHP and Java there is no open-source
tool here that answers this reliably. Do it by hand:

1. Open the advisory (`https://osv.dev/vulnerability/<id>`) and find the
   vulnerable **function** and the **input** that triggers it.
2. Who pulls the package? Read the lockfile; nothing is installed. For
   npm: `docker run --rm -i ghcr.io/jqlang/jq:1.8.2 -r --arg p lodash
   '.packages | to_entries[] | select([.value.dependencies,
   .value.devDependencies, .value.optionalDependencies,
   .value.peerDependencies] | map(. // {} | has($p)) | any) | .key'
   < package-lock.json` (an empty key is the app itself; run on the
   fixture: the app only). For other ecosystems search the name
   in `pnpm-lock.yaml`, `poetry.lock`, `uv.lock`. `npm explain`, `pnpm why`
   and `pip show` read installed packages: on a clean checkout they answer
   "not found", and installing to make them work breaks rule 1.
3. Search for the import and the function:
   `<skill>/scripts/leads.sh "defaultsDeep|zipObjectDeep" src/`.
4. If called: can an attacker influence the argument? Follow it back to a
   request body, query string, header, file upload or message queue.

Limits to state honestly in the report:

- A **transitive** dependency can call the vulnerable function for you. Not
  finding `defaultsDeep` in `src/` says nothing about `node_modules/`.
  Example: an HTTP framework that deep-merges its config with user options
  through lodash.
- Dynamic access defeats grep: `_[name](...)`, `require(variable)`,
  `getattr(module, name)`.
- Some vulnerabilities need no call: a malicious install script runs at
  `npm install`, a prototype pollution gadget may sit in any parser on the
  request path.

So "not reachable" is a judgement with a stated method, never a fact. When
in doubt, keep the priority and upgrade: bumping lodash to 4.17.21 costs
less than the proof.

## 5. Malicious and typosquatted packages

No database lists a package published an hour ago. Heuristics, all checkable
from the manifest and the registry metadata:

| Signal | How to see it | Why it matters |
|---|---|---|
| Install scripts | `deps-hygiene.json`, check `install-script` | `preinstall`/`postinstall` run arbitrary code on every developer and CI machine |
| Name one edit away from a popular package | Read the dependency list: `loadsh`, `reqeusts`, `expres` | Typosquatting |
| Scope missing on an internal name | `@acme/utils` in one place, `utils-acme` in another | Dependency confusion: a public package shadows a private one |
| Very recent first publication, or a version published days ago after years of silence | `npm view <pkg> time --json` in Docker | Account takeover, as in the event-stream incident |
| Maintainer changed recently | `npm view <pkg> maintainers` | Same |
| Source repository missing or unrelated | `npm view <pkg> repository.url` | Nothing to review |
| Resolved from somewhere else than the registry | `deps-hygiene.json`, checks `non-registry-source` and `non-default-registry` | Bypasses advisories and integrity |
| Obfuscated code, network or `child_process` calls in an install script | Read the package's `package.json` scripts | Direct evidence |

Made-up example of a report line: "`colorsjs@1.4.2` (direct dependency,
`package.json:18`): first published 9 days ago, single maintainer, declares
a `postinstall` running `node setup.js`, name is one character away from
`colors`. Not in OSV. Treat as suspect: remove, and check which machines ran
`npm install` since `2026-11-15`."

If a package is confirmed malicious, this is an incident, not a finding:
every secret reachable from the machines that installed it must be rotated.

The vulnerability scan of `scan-deps.sh` covers every ecosystem; its
hygiene checks (`deps-hygiene.json`) cover npm only. For the others, read
the manifest:

| Ecosystem | Look for | Why |
|---|---|---|
| Python | `--extra-index-url` in `requirements.txt` or `pip.conf` | pip takes the highest version from **any** index: a public package can shadow an internal name |
| PHP | `scripts` in `composer.json` (`post-install-cmd`) | Runs at install, like npm install scripts |
| Go | `replace` directives in `go.mod` pointing to a fork or a local path | The code built is not the code the advisory database knows |
| Java | `<repository>` entries in `pom.xml`, `repositories {}` in Gradle, over `http://` or unknown hosts | Artifacts resolved from an untrusted source |

## 6. Lockfile integrity and pinning

| Check | Bad | Good |
|---|---|---|
| A lockfile is committed | `package.json` alone | `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `poetry.lock`, `uv.lock`, `Cargo.lock`; for Go, `go.mod` (the versions) with `go.sum` (the checksums) |
| CI installs from the lockfile | `npm install` | `npm ci`, `pnpm install --frozen-lockfile`, `pip install --require-hashes -r requirements.txt` |
| npm: every entry has an integrity hash | `"resolved"` without `"integrity"` | `"integrity": "sha512-..."` |
| Entries resolve to the expected registry | `"resolved": "http://198.51.100.7/lodash.tgz"` (made-up) | `https://registry.npmjs.org/...` or the company registry |
| Lockfile matches the manifest | Manifest edited, lockfile untouched | The dry-run below exits 1 and names the package; nothing is installed |
| Python requirements are pinned | `requests>=2` | `requests==2.32.3 --hash=sha256:...` |
| Docker base images are pinned | `FROM node:latest` | `FROM node:22.11.0-alpine@sha256:...` (owned by audit-infra; mention it) |
| GitHub Actions are pinned | `uses: some/action@main` | `uses: some/action@<full commit sha>` |

The mismatch check, verified on the fixture (exit 0) and on a copy whose
`package.json` asked for another lodash (exit 1). A plain `npm ci` would
run every install script of the tree: never use it on an audited repo.

```bash
docker run --rm --network none -v "$PWD":/w:ro -w /w node:22.23.5-alpine npm ci --ignore-scripts --dry-run
```

`go.sum` is not a list of what is built: it keeps checksums of versions
that were only considered. Do not report a Go module as shipped because it
appears there; read `go.mod` or run govulncheck.

A version range in `package.json` (`^4.17.4`) is normal and not a finding on
its own: the lockfile is what pins. It becomes one when there is no lockfile
or when CI ignores it.

## 7. SBOM

An SBOM (software bill of materials) is the inventory: every component, its
version, its license. Produce one when there is no lockfile to scan (a built
image, a vendored `node_modules`), or when the client asks for one.

```bash
docker run --rm -v "$PWD":/src:ro anchore/syft:v1.57.2 scan dir:/src -o cyclonedx-json > "$OUT/sbom.cdx.json"
docker run --rm -v "$OUT":/in:ro anchore/grype:v0.122.1 sbom:/in/sbom.cdx.json -o json > "$OUT/grype.json"
```

On the fixture, syft lists `lodash@4.17.4` and `minimist@0.0.8` (CycloneDX
1.7), and grype reports the same 11 matches as osv-scanner. Grype's JSON
already carries `vulnerability.epss[]`, `vulnerability.knownExploited` and a
combined `vulnerability.risk` score, which makes it a good cross-check of
`enrich-kev-epss.py`.

## 8. Licenses (optional)

Only when the audit scope says so. `osv-scanner scan source
--licenses=MIT,Apache-2.0,BSD-3-Clause,ISC` lists what is outside that
allowlist. `trivy fs --scanners license` does something else: it classifies
each license by risk level, with no allowlist (`--ignored-licenses` removes
entries). The classic risk: a strong-copyleft library
(GPL, AGPL) linked into proprietary code distributed to customers, or AGPL
in a SaaS back-end. Report the fact (package, license, how it is used) and
leave the legal conclusion to a lawyer.
