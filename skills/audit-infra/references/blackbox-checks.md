# Black-box checks: DNS, TLS, HTTP, ports, endpoints

What can be learned from outside, with the JSON path of the collector that answers it
and the condition that makes it a finding. Paths prefixed `H:` are in the output of
`collect-headers.sh`, `D:` in `tls-and-dns.sh`. Header interpretation has its own
file: `header-fingerprints.md`.

Lab values quoted below come from `scripts/fixtures/lb-lab` (deliberately broken).
A black-box value is an **observation from one vantage point**. What it lets you infer
about the architecture or the impact is a separate statement: write both, and keep
the inference `UNKNOWN` until a manifest or the owner confirms it.

## DNS

| # | Check | Where | Finding when | Lab / real value |
|---|---|---|---|---|
| B-01 | CNAME chain | `D:dns.cname_chain` | A hop points to a domain the organisation does not control and nobody can say why | lab `www.lab.test`: `["edge.lab.test.","lb.lab.test."]` |
| B-02 | Dangling CNAME | `D:dns.dangling` | `true`: the chain ends on a name that resolves to nothing | lab `dangling.lab.test`: "ends at decommissioned.lab.test … (status NXDOMAIN)" |
| B-03 | Subdomain takeover lead | `D:dns.takeover_candidate` | `true`: the dangling target sits at a provider where a deleted resource name can sometimes be registered by someone else (S3, GitHub Pages, Heroku, Azure App Service…). A **lead**, rated high: whether it is claimable depends on the provider's current rules (reserved names, domain verification). Ask the owner whether the resource exists; never try to register it | made-up example: `assets.example.com CNAME old-bucket.s3.amazonaws.com` |
| B-04 | Wildcard providers | `D:dns.third_party_suffix`, `takeover_http_checked`, `takeover_http_fingerprint` | Suffix set with `dangling: false`: these providers answer for every name, so DNS cannot tell whether the resource exists. Rerun with `--takeover-probe` (one GET to the authorized host: tier 2, not passive). A fingerprint such as `NoSuchBucket` strengthens the lead; `null` with `takeover_http_checked: false` is `UNKNOWN` | not triggered on the lab (no provider suffix) |
| B-05 | Address count | `D:dns.a`, `round_robin` | Informative. One address is **not** "one machine": it can be an anycast address, a managed balancer or a floating IP, and several addresses can lead to one installation. Redundancy is decided white-box (`resilience-checks.md` R-02) | lab `www.lab.test`: 2 A records |
| B-06 | Hosting provider | `D:dns.ptr`, `ns` | Informative: the PTR and NS names say who hosts and who runs DNS | made-up example: NS `*.ns.cloudflare.com` |
| B-07 | CAA | `D:dns.caa` | `records: []` up to the apex: any CA may issue for the domain | lab: `0 issue "letsencrypt.org"` found at `lab.test` |
| B-08 | SPF / DMARC | `D:dns.email` | Sending domain: `dmarc` null or `p=none`. Non-sending domain: lacks `v=spf1 -all` **or** DMARC `p=reject` (SPF covers the envelope sender only; without DMARC the visible `From:` can still be forged) | lab: `v=spf1 -all`, `p=reject` |
| B-09 | Forgotten hosts | certificate SANs (step 2), CT logs | A SAN or a CT entry names a host outside the inventory (`staging.`, `old-`, `admin.`): list it as "discovered, not tested" | `D:tls.certificate.san` from `--tls-only`; CT lookup in `tooling-matrix.md` |
| B-10 | Zone transfer (**tier 3**, not passive) | `dig AXFR`, by hand, command in `tooling-matrix.md` | The transfer succeeds: the whole zone is public. One TCP query to a name server: only for zones whose name servers the owner runs or has cleared, with active scans agreed | lab: `status: REFUSED`, "Transfer failed." (pass) |

Why a takeover matters: whoever registers the abandoned resource name at the provider
serves content on the victim's subdomain, with a valid certificate, and can read
cookies scoped to the parent domain. It becomes critical only when the owner confirms
the resource is gone and the provider does not protect the name; until then write
"dangling record, takeover unconfirmed" (high).

## TLS

| # | Check | Where | Finding when | Lab value |
|---|---|---|---|---|
| B-11 | Legacy protocols | `D:tls.protocols`, `legacy_protocol_accepted` | TLS 1.0 or 1.1 `accepted` (deprecated by RFC 8996) | `:8443` both `accepted`; control `:9443` both `rejected` |
| B-12 | TLS 1.3 | `D:tls.tls13_supported` | Informative. `false` points to an old terminator or policy; it is a finding only against a baseline the owner names. TLS 1.2 with modern suites is still compliant | `true` |
| B-13 | Trust | `D:tls.certificate.trusted`, `verify` | `false`: self-signed, incomplete chain, hostname mismatch | `18 (self-signed certificate)` |
| B-14 | Expiry | `expires_within_14_days`, `expired` | Within 14 days with no visible automation; expired | `expires_within_30_days: true` |
| B-15 | Chain | `certificate.chain_certificates_sent`, `root_sent`, `verify` | `1` **and** `verify` code 20 or 21 with a public CA: the intermediate is missing and clients that do not fetch it fail. `root_sent: true`: the root is sent uselessly (low). `1` alone is fine when a trusted root signed the leaf directly | `1`, `root_sent: false`, `18 (self-signed certificate)` |
| B-16 | Key and signature | `certificate.key`, `signature_algorithm` | RSA under 2048 bits, SHA-1 signature | `2048 bit`, `sha256WithRSAEncryption` |
| B-17 | Names | `certificate.san` | Wildcard shared across unrelated trust zones; internal names disclosed | `DNS:lab-lb` |
| B-18 | HSTS | `D:tls.hsts`, `H:security_headers.hsts` | Absent on an HTTPS site (medium). `max_age` under 15552000 (180 days, the threshold testssl.sh warns under): low. `includeSubDomains` or `preload` set while a subdomain is HTTP-only: that subdomain breaks. One year + `includeSubDomains` + `preload` are **preload-list** requirements: check them only when preloading is wanted | control `:9443`: `max_age: 63072000`, `preload_eligible: true` |
| B-19 | ALPN / HTTP versions | `D:tls.alpn`, `H:protocol.http_versions`, `http3_advertised` | Informative: HTTP/1.1 only at the edge usually means no CDN | `http/1.1` |
| B-20 | OCSP stapling | `D:tls.ocsp_stapling` | **Informative only.** Let's Encrypt ended its OCSP service in 2025 and certificates may carry no OCSP URL at all; `absent` is no longer a defect by itself | `absent` |
| B-21 | Ciphers, known attacks | `--deep` (testssl.sh), all sections of the JSON: jq filter in `tooling-matrix.md` | testssl severity MEDIUM or above (anonymous or NULL suites, RC4, 3DES, no forward secrecy, BEAST/LUCKY13/ROBOT…) | `cipherlist_aNULL CRITICAL`, `BEAST_CBC_TLS1 MEDIUM`, `LUCKY13 LOW` |

## HTTP behaviour

| # | Check | Where | Finding when | Lab value |
|---|---|---|---|---|
| B-22 | HTTP to HTTPS | `H:http_to_https` | Status 200 on port 80, or a redirect that does not start with `https://` on the same host | `null` (target was plain HTTP: itself the finding) |
| B-23 | Security headers | `H:security_headers.missing` | Judge by what the URL serves. JSON API: needs HSTS, `x-content-type-options: nosniff`, `cache-control: no-store` on private answers. HTML application: also CSP, `frame-ancestors` or `x-frame-options`, `referrer-policy`, `permissions-policy`. A missing HTML-only header on an API is not a finding | 5 missing |
| B-24 | Version disclosure | `H:information_leaks` | Any entry | `server: nginx/1.31.10`, `x-powered-by: Express`, `x-backend-server: 10.42.0.11:8080` |
| B-25 | Cookies | `H:cookies[]` | A session or affinity cookie with `secure: false`, `httponly: false` or `samesite: <unset>` | `ROUTEID`: all three missing |
| B-26 | CORS | `H:cors.dangerous` | `true`: the arbitrary probe origin is reflected **and** credentials are allowed, on the URL probed. A cross-site page can then read what that route returns to a logged-in browser, as far as the session cookies' `SameSite` lets them travel. Name the route; do not generalise to the host | `true` |
| B-27 | CORS wildcard | `H:cors.wildcard` | `true` on an endpoint that returns non-public data | `false` |
| B-28 | Error pages | `H:error_page.leaks`, `server_differs_from_main` | Stack trace, framework default page, or version banner; a different `server` shows which layer answers errors | `["server banner with version"]` |
| B-29 | Soft 404 | `H:error_page.soft_404` | `true`: unknown paths return 200, which also blinds every path-based scanner | `false` |
| B-30 | Shared cache on private content | `H:cache` | A response that sets a session cookie lacks `private` / `no-store`, or carries `public`, `s-maxage` or an `age` > 0 | not triggered |

## Load balancing

| # | Check | Where | Finding when | Lab value |
|---|---|---|---|---|
| B-31 | Presence | `H:load_balancing.suspected`, `estimated_backends` | Informative. `false` means "not observable from here". With a single A record it is a **question** for R-02 (is the edge redundant?), not a finding | `true`, 2 distinct `x-served-by` values |
| B-32 | Algorithm | `H:header_variation[].pattern` | Informative guess only: `ABAB` is consistent with round robin, long runs with least-connections or connection reuse. The algorithm is known from the configuration, not from a pattern | `BABABABA` |
| B-33 | Affinity | `H:load_balancing.affinity` | `sticky: true` with a cookie lacking `Secure`/`HttpOnly`, or a cookie value that encodes the backend (BIG-IP) | `sticky: true`, cookie `ROUTEID=a` names the backend |
| B-34 | Backend drift | `H:header_variation` class `backend_diff` on `server`, `etag`, `x-powered-by`, `content-length` | Backends answer with different versions or content: an incomplete rollout or a forgotten node | `x-served-by: app-a / app-b` |
| B-35 | Failover | manual, **by the owner** | Stopping one backend produces errors for longer than the health-check interval | not automated; the auditor never stops anything |

Limits. A CDN or an LB that normalises headers hides its backends completely, and a
balancer that hashes the client address (`ip_hash`, layer-4 hashing) sends every
request of one auditor to the same backend: "not suspected" means "not observable
from here", never "no load balancer". Conversely a rotating header can name caches
or workers rather than machines. And a small
sample lies: measured on the lab, right after the balancer restarted, a run with
`--requests 4` saw `estimated_backends: null` (all four connections landed on fresh
nginx workers, each starting its own round robin at backend A), while the next run of
4 and the runs of 10 and 20 saw `ABAB…`. Keep the default of 10, and rerun with
`--requests 30` before writing a negative.

## Ports (nmap, tier 3, both gates)

`scripts/active-scan.sh … nmap <host>`, only with active scans agreed, never against
a CDN or PaaS address (see `scripts/AUTHORIZATION.md`). "Open" means open **from the
scanning vantage point**: state it (a laptop on the office VPN is not the internet).
nmap scans the first address of a name only: when `dns.aaaa` is not empty, run a
second pass with `--ipv6`, because IPv6 firewall rules are often forgotten.

| # | Check | Finding when |
|---|---|---|
| B-36 | Data ports | 5432, 3306, 1433, 27017, 6379, 9200, 5672, 9092, 11211 open from an untrusted network |
| B-37 | Admin ports | 22, 3389, 5900 open to the world rather than to a bastion or VPN range |
| B-38 | Orchestrator ports | 6443 (Kubernetes API), 10250 (kubelet), 2375/2376 (Docker API), 2379 (etcd), 8500 (Consul) reachable |
| B-39 | Unexplained listeners | Any open port that no manifest, security group or diagram accounts for |
| B-40 | Version banners | `-sV` returns an exact version with known CVEs |
| B-41 | Origin bypass (behind a CDN or WAF) | The origin accepts traffic that did not come through the CDN. Prefer owner-side evidence: an origin firewall limited to the CDN's ranges, or authenticated origin pulls (mTLS). The origin address is **another host**: probing it needs its own confirmation |

Lab (`--ports 80,443,8080,8443,9443,5432`): 80, 443, 8080, 8443 and 9443 `open`,
service `nginx 1.31.10`; `5432 closed`.

## Exposed admin and debug endpoints (tier 3, `--probe-endpoints`, both gates)

The list and its signatures are `scripts/lib/endpoints.tsv`. A path counts as exposed
only if the status is 200 **and** the body matches the signature, which removes
soft-404 false positives. The body is fetched inside the container, its first 64 kB
are matched, then it is discarded: only the boolean reaches the report. Behind a CDN
or PaaS they are ordinary GETs for the owner's own paths: allowed with active scans
agreed, but the answer may come from a cache or be blocked by the provider, so "not
exposed" is `UNKNOWN` there, not `PASS`. `--deep`, nmap and nuclei stay excluded
behind a provider (SKILL.md step 0).
The table says what a match **shows**; anything beyond is `UNKNOWN`, not assumed.

| Path | Severity | What a match shows |
|---|---|---|
| `/.env` | critical | `KEY=value` lines are served: such files usually hold database and API credentials (the values are not read) |
| `/actuator/env` | high | Spring configuration keys are public. Values are masked by default since Spring Boot 3: secrets are possible, not proven |
| `/.git/HEAD`, `/.git/config` | high | Git metadata is served. Whether the objects (the source code) can be fetched too was not tested |
| `/debug/pprof/`, `/console`, `/jolokia`, `/_profiler`, `/phpinfo.php` | high | Debug tooling in production, several are remote-code-execution paths |
| `/metrics`, `/actuator`, `/server-status`, `/server-info`, `/haproxy?stats`, `/debug/vars` | medium | Internal names, versions, traffic and client IPs |
| `POST /graphql` with `{__schema{queryType{name}}}` | medium | Introspection answers; the full schema is probably queryable (only the root type name was asked) |
| `/swagger-ui/`, `/v3/api-docs`, `/openapi.json` | low | Full API surface documented; fine for a public API, a finding for an internal one |
| `/.well-known/security.txt` | good | A disclosure contact exists (positive finding) |

Lab: `/.git/HEAD` (high), `/metrics` (medium), `/server-status` (medium) reported
exposed; the 21 other paths returned 404.

A hit is evidence, not a licence to go further: do not download the `.git` directory or
read the `.env`. Record the status and the signature match, and stop.
