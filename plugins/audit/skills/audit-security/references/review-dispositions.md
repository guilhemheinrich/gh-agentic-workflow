# Adversarial review dispositions

Three models from other lineages reviewed this skill on 2026-11-24:
`openai/gpt-6.2-astra` (GPT, verdict REJECT), `google/gemini-4-neon`
(Gemini, ACCEPT-WITH-FIXES), `moonshotai/kimi-k3.1-pro` (Kimi,
ACCEPT-WITH-FIXES). Their findings were collapsed into root causes, and
each claim was checked against the files, a Docker run or the official
page before anything was changed. Nothing was accepted on authority.

Verdicts: **ACCEPTED** (fixed), **REJECTED** (evidence against), **DEFERRED**
(valid, not done here). 24 accepted, 5 rejected, 3 deferred.

| # | Root cause | Raised by | Verdict | Evidence and fix |
|---|---|---|---|---|
| 1 | Rule 4 said "Step 5 is not optional"; the manual review is step 6 | all three | ACCEPTED | Read in `SKILL.md`. Reworded |
| 2 | Leads and "read `.env*` by eye" put secret values in the transcript | all three | ACCEPTED | `grep -n` prints the matching line. Rule 2 extended; `SKILL.md` step 4 now gives an `awk` that prints names and lengths (run on the fixture: `FIXTURE_PAYMENT_API_SECRET = <32 chars>`) and `grep -l`; checklist has a "secret-safe leads" rule; trivy command no longer runs its secret scanner |
| 3 | `--verify` presented as a trufflehog flag; raw trufflehog verifies by default | Gemini, Kimi, GPT | ACCEPTED | `trufflehog:3.100.1 --help` lists `--no-verification` and no `--verify`. The wrapper already passed `--no-verification`; docs and `--help` text now say `--verify` is the wrapper's |
| 4 | `npm ci`, `--call-analysis=rust`, `pip-audit -r` and a writable Go mount execute or expose untrusted code | all three | ACCEPTED | pip-audit README: `-r` is "functionally equivalent to `pip install -r`". Rule 1 forbids install/build. Replaced by `npm ci --ignore-scripts --dry-run` on a `:ro` mount with `--network none` (exit 0 in sync, exit 1 on a mismatch, nothing written) and `pip-audit --no-deps --disable-pip` (run: returns PYSEC-2014-82 for jinja2 2.4.1). Rust call analysis is now owner-gated |
| 5 | "Rotate first" told the auditor to revoke production credentials and read provider logs | Kimi, GPT | ACCEPTED | Out of an audit's authorization. The owner rotates; the auditor notifies. Script message changed too |
| 6 | Same output shape hid different coverage: pagination only warned, unsupported lockfiles were silently skipped | GPT | ACCEPTED | `scan-deps.sh` now writes `deps-coverage.json` and exits 2 with `INCOMPLETE`. Proven: fixture plus a `yarn.lock` in API mode exits 2 and names it; both paths still return the same 11 ids. `scan-secrets.sh` flags a shallow clone (proven on a depth-1 clone: history finding lost, `INCOMPLETE` printed); `scan-sast.sh` flags parse errors |
| 7 | Scoring contradictions: unscored advisory P2 or P3; KEV bump with or without "reachability unknown"; F-07 High against the "up one level" rule; EPSS bump "do not apply twice" | Gemini, GPT, Kimi | ACCEPTED | `enrich-kev-epss.py` puts "no score" in P2: `SKILL.md` aligned. One bump table in `report-template.md` with five worked cases; EPSS removed as a bump; F-07 is now Critical |
| 8 | Evidence rule (input + sink, "all four lines") excluded missing-control, config and dependency findings | Kimi | ACCEPTED | Rule 3 and the checklist's closing block now give one shape per kind |
| 9 | Grep used as proof: IDOR re-verify, "not affected" by an empty grep | all three | ACCEPTED | F-01 re-verify is now a three-case test; the "not affected" example states method and limit, else "reachability unknown" |
| 10 | NoSQL "GOOD" snippet dropped the password check | GPT, Kimi | ACCEPTED | Read in the file. Snippet now rejects non-strings and verifies the hash |
| 11 | SSRF "GOOD" claimed a resolved-IP check it did not do; hostname allowlist ignores the port | all three | ACCEPTED | Node 22: `new URL('https://allowed.test:8443/x').hostname` is `allowed.test`. Now compares `url.origin`; user-chosen hosts need a connect-time check or an egress proxy |
| 12 | Command "GOOD" regex accepted a leading `-` | all three | ACCEPTED | `/^[a-z0-9.-]+$/i.test('-f')` is true. New pattern refuses it, `--` added (busybox `ping -c 1 -- 127.0.0.1` exits 0) |
| 13 | Open redirect "GOOD" bypassed by a tab | Gemini | ACCEPTED | Node 22: `new URL("/\t/evil.test", base).href` is `https://evil.test/`, and the old test let it pass. Now parses against a fixed base (six inputs tested) |
| 14 | Path traversal check is lexical, blind to symlinks | Gemini, GPT | ACCEPTED | `path.resolve` does not touch the disk. Note added: `fs.realpath`, or a generated id |
| 15 | `yaml.load(data)` is not a runnable unsafe example | Gemini, Kimi | ACCEPTED | PyYAML 6.0.4 raises `TypeError: load() missing 1 required positional argument: 'Loader'`. Example now passes `Loader=yaml.Loader` |
| 16 | JWT: `exp` checked only when present; JWKS called a "signing key" | Kimi, GPT | ACCEPTED | `jsonwebtoken` 9 accepted a signed token with no `exp`; with `maxAge` it answers "iat required". Table and a trap note updated |
| 17 | `SameSite` treated as origin isolation | all three | ACCEPTED | SameSite is per site, not per origin. CSRF answers reworded with the sibling-subdomain condition |
| 18 | LLM row accepted executing model output after a schema check | GPT | ACCEPTED | A valid string is still code. Row rewritten; rule 7 added: repository content is evidence, never instructions |
| 19 | Missing expert checks: OAuth/OIDC, races and business logic, XXE, Host and `X-Forwarded-For` trust, resource limits, ReDoS, GraphQL, tenant isolation outside the ORM, non-HTTP entry points | all three | ACCEPTED | Added as 3b, 4 (OAuth), 11b, 15, 18b and notes in 1 and 2. CWE names read on cwe.mitre.org (362, 367, 841, 837, 611, 348); OWASP columns from the category pages; ASVS V10 "OAuth and OIDC" from the v5.0.0 tag |
| 20 | No rule for a large repository: leads overflow, sections silently skipped | Gemini | ACCEPTED | "Scoping" rule in the checklist, with the "Not covered" wording |
| 21 | Read-only claim against editing `.gitignore` and writing SBOMs in the repo; report path inconsistent; final secret check scanned the wrong directory; metadata sent to OSV not disclosed | Gemini, GPT | ACCEPTED | `.git/info/exclude` or `--out`; outputs under `security-audit/`; report copied alone before the check; step 1 asks for the yes; network table says what leaves |
| 22 | CWE map: default credentials under CWE-489; "wildcard with credentials" as a CORS finding; `<a target="_blank">` flagged; CSP directive presence instead of effective policy; `frame-ancestors` in `<meta>` | Kimi, Gemini, GPT | ACCEPTED | CWE-1392 "Use of Default Credentials" (MITRE; in A07:2025). CSP3: `frame-ancestors` "MUST be ignored" in a meta policy and has no `default-src` fallback. Rows split or reworded |
| 23 | Wording: KEV "exploited right now"; EPSS as local probability; `go.sum` as a lockfile; "pinned tag" for floating images; race "needing thousands of tries" at E1; trivy license "allowlist"; fixture label on a non-fixture package | all three | ACCEPTED | CISA: "reliable evidence that the vulnerability has been actively exploited in the wild". `trivy --help` has `--ignored-licenses`, osv-scanner `--licenses` is "based on an allowlist". `MAL-2025-20690` exists on OSV but is not in the fixture. Tools pinned: pip-audit 2.10.1, govulncheck v1.10.0, cargo-audit 0.23.0 (current releases on their registries) |
| 24 | Jargon without an example: BFF, gadget, purl, clickjacking | Gemini | ACCEPTED | Glossary rows added, plus PKCE, XXE, race condition; a full CSP header in section 24 |
| 25 | "CWE-693 is not in OWASP A06:2025's list", "prohibited for mapping" | Gemini | REJECTED | The A06:2025 page lists CWE-693 and CWE-1021: the 2025 column was right. MITRE's status is "Discouraged", not prohibited; that nuance was added |
| 26 | `corepack enable && pnpm audit` hangs on a prompt without a TTY | Gemini | REJECTED | Run in `node:22.23.5-alpine` with stdin closed: prints a notice, downloads pnpm, exits 0 |
| 27 | DOM XSS in the fixture is unproven because a URL fragment stays percent-encoded | GPT | REJECTED | `src/widget.js:5` calls `decodeURIComponent` before the sink at line 6. The reviewer was not given the fixture. Rule 3 and the matrix now say "decoded" |
| 28 | "Wrappers not supplied, behaviour unverified" | GPT | REJECTED | Review-input limit, not a defect: the four scripts exist and were re-run on the fixture after every change (11 advisories, 3 at P1, 1 secret, 9 semgrep lines, exit 1 each) |
| 29 | Prototype pollution impact "denial of service at least" is unproven | GPT | REJECTED in part | The primitive is real: lodash 4.17.4 `defaultsDeep` with `{"constructor":{"prototype":{"isAdmin":true}}}` made `({}).isAdmin` true in Docker. The unproven "denial of service" wording was removed; the finding now claims the primitive only |
| 30 | Self-test should run on frozen, checksummed advisory, rule and feed snapshots | GPT, Kimi | DEFERRED | Valid, but needs vendored OSV/KEV/EPSS fixtures and a mock mode in three scripts. For now the self-check asserts exit codes and named ids, and states that counts drift |
| 31 | Follow `next_page_token` instead of failing; ecosystem-aware coverage for nested workspaces in the API fallback | GPT | DEFERRED | The fallback now refuses to look complete (exit 2). Full pagination and recursion duplicate osv-scanner, which is the primary path |
| 32 | Image digests for every tool; govulncheck, cargo-audit and pnpm audit commands never executed here | GPT, Kimi | DEFERRED | Versions are pinned and the digest command is given; the three commands stay marked "not executed", as no Go, Rust or pnpm fixture exists |

Reviewer disagreement left open: GPT wants a dependency with unknown
reachability kept strictly "unknown"; Gemini and the skill keep its priority
and, for KEV, treat unknown as Critical. The skill keeps the conservative
reading (unknown never lowers a priority) and records "reachability
unknown" in the finding.

## Round 2

Same three models, on the round-1 result, 2026-11-24: GPT REJECT (8
findings), Gemini ACCEPT-WITH-FIXES (6), Kimi ACCEPT (no finding). Collapsed
into 11 root causes, each reproduced before any change: 11 accepted (one of
them with the reviewer's mechanism corrected), 0 rejected, 0 deferred.

| # | Root cause | Raised by | Verdict | Evidence and fix |
|---|---|---|---|---|
| R1 | Output written through a path the checkout controls: `> security-audit/sbom.cdx.json` is opened by the host shell before Docker starts; the script guard was bypassable too | GPT | ACCEPTED | Reproduced the bypass: with `app/security-audit` a symlink to a directory outside, `scan-sast.sh --out app/security-audit/sub app` exited 1 and wrote three files outside. New `scripts/out-guard.sh`, sourced by the four scripts: the directory must already exist (`OUT=$(mktemp -d)`), not be a symlink, and be outside the checkout both as typed and resolved. Behaviour change: the scripts no longer `mkdir -p` the output directory. Missing, symlinked, in-checkout, symlinked-parent and relative in-checkout `--out` all exit 2 for each script, nothing written at the escape target. Every redirect in the docs goes to `$OUT`. Supersedes round-1 #21 (`security-audit/` in the repo) |
| R2 | Ecosystem tools run with the checkout as working directory read the repo's own config | GPT | ACCEPTED, mechanism corrected | Reproduced: a committed `.npmrc` with `registry=http://127.0.0.1:9/` made `npm audit` fail with ECONNREFUSED; the same lockfile mounted alone printed `critical: 2, total: 2`. rustup docs: `rust-toolchain.toml` `path` selects a custom toolchain, found by walking up from the working directory. corepack honours `packageManager`. GPT's `cargo install` mechanism is wrong: cargo docs say `cargo install` ignores local configuration discovery. Fix: npm audit, pip-audit (re-run: PYSEC-2014-82) and cargo audit mount only the lockfile; pnpm audit removed (SKILL.md and matrix); govulncheck installed before `cd /w`, with `GOTOOLCHAIN=local CGO_ENABLED=0`, owner-gated. Qualifies round-1 #26: corepack does not hang, it is dropped for this reason |
| R3 | "Secret-safe" commands were not safe verbatim: the inline `awk`, and `grep -rn` leads | Gemini, GPT | ACCEPTED | Canary test (planted values in `.env`, a JSON config, a `.ts` file, a bundle; every backticked lead extracted and run): 6 of the 34 backticked `grep -r` leads printed a canary, all six with `-n`; the `-l` leads print file names only (webhook, LLM, session, fetch, hashing, logging). New `scripts/leads.sh` redacts credential-like values and skips env, key, bundle and lock files; all `-n` leads now call it, 0 canaries printed. Both helpers re-exec themselves in `python:3.12-slim` with `--network none` and the current directory mounted `:ro`: a `.env.local` symlinked to a host file is skipped ("not a file"), a path outside the directory or with `..` exits 2. `list-secret-names.sh` replaces the awk one-liner; on a file with a quoted PEM, base64 continuation lines with `==`, `export K=`, `K=`, YAML and a multi-line quoted value it printed 6 names and 0 canaries. Limit stated in the script: a short literal passed positionally is still printed |
| R4 | Open redirect GOOD emitted `pathname`, not the validated URL | Gemini, GPT | ACCEPTED | Express 4 run: for `/.//evil.test` and `https://app.example.test//evil.test` the pathname version sends `Location: //evil.test` (resolves to `https://evil.test`); the `u.href` version stays on BASE for all 8 inputs, `http://[` included. Re-verify now asserts the origin of the emitted `Location` |
| R5 | OIDC account linking accepted a verified email | GPT | ACCEPTED | OIDC Core 5.7: `sub` and `iss` "are the only Claims that an RP can rely upon as a stable identifier"; email "MUST NOT be used as unique identifiers". Checklist and CWE map: login by `iss` + `sub`; a new link to an existing account needs proof of control of it |
| R6 | JWT: `maxAge` presented as requiring `exp` | GPT | ACCEPTED | `jsonwebtoken` 9.0.3: a signed token with `iat` and no `exp` is accepted, with and without `maxAge: '1h'`; `jose` 5.10.0 `requiredClaims: ['exp']` rejects it. GOOD snippet has an explicit `exp` check |
| R7 | Reachability example and glossary turned an unchecked path into "not affected" | GPT | ACCEPTED | Example now reads "reachability unknown, priority kept"; "not affected" only for an excluded precondition or a call-graph proof, glossary aligned. Resolves the round-1 open disagreement: GPT asked for exactly this |
| R8 | `npm explain`, `pnpm why`, `pip show` need installed packages | Gemini | ACCEPTED | `npm explain lodash` on the fixture lockfile without `node_modules`: "No dependencies found matching lodash". Replaced by a jq query on `package-lock.json`, now over `dependencies`, `devDependencies`, `optionalDependencies` and `peerDependencies` (fixture: the app only) |
| R9 | GraphQL rate limit counted per operation | GPT | ACCEPTED | `graphql` 16.15 `parse` of three aliased `login` fields: 1 operation, 3 root fields. The limiter counts each attempt in the resolver or auth service |
| R10 | "`scan-deps.sh` checks npm only" | Gemini | ACCEPTED | Only the hygiene checks are npm-only; osv-scanner covers every ecosystem. Reworded |
| R11 | "`ls dist/**/*.map` after a build" contradicts rule 1 | Gemini | ACCEPTED | Now: only committed or owner-supplied build output, never run a build |

After the changes the four scripts were re-run on the fixture: exit 1 each,
11 advisories, 3 at P1 with GHSA-jf85-cpcp-j695, `generic-api-key` at
`config/fake-credentials.env:9`, 9 semgrep lines with `eval-detected` at
`src/app.js:12`, nothing written in the fixture.

No reviewer disagreement is left open in this round.

## Round 3

Termination check, 2026-11-24: GPT ACCEPT-WITH-FIXES (6 findings), Kimi
ACCEPT-WITH-FIXES (1), Gemini ACCEPT (none). 7 root causes, each reproduced:
7 accepted, 0 rejected, 0 deferred.

| # | Root cause | Raised by | Verdict | Evidence and fix |
|---|---|---|---|---|
| T1 | Round-2 "lockfile-only" mounts `-v "$PWD/<file>"` still read outside the checkout | GPT | ACCEPTED | Reproduced: a `requirements.txt` symlinked to a host file was handed to the container (its content printed); `-v` with a missing `Cargo.lock` created a directory `Cargo.lock/` in the checkout. New `scripts/stage-inputs.sh`: mounts the checkout `:ro`, copies only regular, non-symlink files that resolve inside it into `$OUT/inputs`, prints `INCOMPLETE: not scanned: F (<reason>)` and exits 2 otherwise. Tested: symlink to host, missing file, file under a symlinked directory and `../x` all refused, nothing created in the checkout; `npm audit` on the staged copy printed `total: 2`. npm audit, pip-audit and cargo audit commands now use `$OUT/inputs` |
| T2 | `leads.sh` printed the line, and a short positional literal is not recognisable as a secret | GPT | ACCEPTED | Our own round-2 note admitted it. Default output is now `file:line` only; `-c` prints the line with every quoted literal emptied (any length) and comments dropped, plus the round-2 redactions. Canary test: every documented lead run verbatim under `set -u`, in both modes, against short canaries on lines the leads match (`jwt.verify(token, "…")`, `createHmac("sha256", "…")`, comments): 30 leads x 2 modes, 0 canaries printed, 0 errors |
| T3 | Consent named only `api.osv.dev` | GPT | ACCEPTED | `tooling-matrix.md` already said osv-scanner uses `api.deps.dev`; npm audit sends the lockfile to the npm registry, pip-audit queries PyPI by default. SKILL.md step 1 now asks for a yes per destination ("no yes: not scanned"); the network table has npm audit and pip-audit rows |
| T4 | SQL lead `\\$queryRawUnsafe` in double quotes is expanded by the shell | GPT | ACCEPTED | Under `set -u` the documented command aborts. Lead single-quoted with `\$queryRawUnsafe`; it now matches `db.$queryRawUnsafe(...)` in the canary file. The same test found a second broken lead: `leads.sh "\.template(" src/` (dependency-triage example) exits 2 with "Unmatched ( or \(", now `\.template\(`. The eval lead lost a backtick that broke its markdown code span |
| T5 | OAuth: absence of `state` reported as CSRF | GPT | ACCEPTED | RFC 9700 4.7.1: "The same protection is provided by PKCE or the OpenID Connect nonce value", PKCE only if the AS supports it. Checklist row and CWE map: a finding only when none of `state`, PKCE, `nonce` is enforced; unverifiable is Unknown |
| T6 | `Math.min(limit, 100)` shown as GOOD | GPT | ACCEPTED | Python sqlite3: `LIMIT ?` with `min(-1, 100)` returned all 500 rows. GOOD is now an integer checked within `1..100`, else 400; `Math.min` alone moved to BAD |
| T7 | `yaml.FullLoader` listed with the RCE loaders | Kimi | ACCEPTED | PyYAML 6.0.4: `!!python/object/apply:os.system` executes under `Loader` and `UnsafeLoader`, `FullLoader` raises `ConstructorError`. Example restricted to `Loader`/`UnsafeLoader` and bare `yaml.load()` before 5.1; FullLoader noted as version-specific (CVE-2020-1747, CVE-2020-14343, fixed by 5.4) |

The four scripts re-run on the fixture after these changes: exit 1 each, 11
advisories, 3 at P1 with GHSA-jf85-cpcp-j695, `generic-api-key` at line 9,
9 semgrep lines with `eval-detected` at `src/app.js:12`, nothing written in
the fixture. No reviewer disagreement is open.
