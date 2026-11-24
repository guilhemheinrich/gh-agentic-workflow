# Glossary for humans

Plain definitions of the words an infrastructure audit uses, each with an example.
Examples marked "lab" come from `scripts/fixtures`; "real" ones were seen in one
ordinary page load of a public site on 2026-11-24 (an illustration, not something to
repeat: practise on the lab); the others are made up and say so.

## The path of a request

| Term | Plain meaning | Example |
|---|---|---|
| DNS | The phone book that turns a name into an address | real: `example.com` resolves to `104.20.23.154` and three other addresses |
| A / AAAA record | A name pointing to an IPv4 / IPv6 address | lab: `lb.lab.test A 192.0.2.10` |
| CNAME | A name that is an alias of another name | lab: `www.lab.test CNAME edge.lab.test` |
| NS / PTR record | NS: which servers answer for a domain. PTR: the reverse, from an address to a name, which often names the hosting provider | lab: `lab.test NS ns.lab.test` |
| SPF / DMARC | DNS records saying which servers may send mail for a domain (SPF) and what receivers should do with forgeries (DMARC) | lab: `v=spf1 -all` (nobody sends) and `v=DMARC1; p=reject` |
| Dangling record | An alias pointing to something that no longer exists | lab: `dangling.lab.test CNAME decommissioned.lab.test`, which resolves to nothing |
| Subdomain takeover | Someone else claims the abandoned thing a dangling alias points to, and now serves content under your name | made-up example: `assets.example.com` still aliases a deleted S3 bucket; an attacker creates a bucket with that name |
| CDN | A network of servers close to users that caches and relays your site | real: `cf-ray: …-CDG` means a Cloudflare server in Paris answered |
| Edge / POP | One location of a CDN | real: `x-amz-cf-pop: CDG52-P6` |
| Origin | Your real server, hidden behind the CDN | made-up example: the VM at `203.0.113.10` that Cloudflare fetches pages from |
| WAF | Web application firewall: a filter that blocks requests that look like attacks | real: stackoverflow.com sets a `__cf_bm` bot-management cookie |
| Load balancer (LB) | Splits incoming requests between several identical servers | lab: `lab-lb` alternates between `app-a` and `app-b` |
| L4 vs L7 | An L4 balancer forwards connections without reading them; an L7 balancer reads HTTP and can route by path or cookie | made-up example: AWS NLB (L4) vs ALB (L7) |
| Round robin | The simplest balancing rule: each server in turn | lab: header pattern `BABABABA` over 8 requests |
| Sticky session / affinity | The balancer keeps sending one user to the same server, usually with a cookie | lab: cookie `ROUTEID=a` pins the client to backend A |
| Reverse proxy | A server that receives requests on behalf of others and forwards them | lab: nginx forwarding to the two backends |
| Ingress | In Kubernetes, the rule set (and the proxy applying it) that routes outside HTTP traffic to services | lab: `Ingress shop` routes `/api` to Service `api` |
| API gateway | A reverse proxy specialised for APIs: authentication, quotas, routing | made-up example: Kong in front of ten microservices |
| Backend / upstream | The server that finally does the work | lab: `backend-a`, `backend-b` |
| TLS termination | The point where one encrypted connection ends. What follows is either clear text or a second, separate TLS connection | made-up example: browser to load balancer in HTTPS (TLS session 1); load balancer to pods either in plain HTTP, or in HTTPS again (TLS session 2) |

## Black-box and white-box

| Term | Plain meaning | Example |
|---|---|---|
| Black-box | Looking from outside, as a visitor or attacker would, with no inside knowledge | `collect-headers.sh` reading response headers |
| White-box | Reading the configuration and code that describe the system | `scan-iac.sh` reading Kubernetes manifests |
| Fingerprint | A detail that betrays which software or vendor is in use | lab: `server: nginx/1.31.10` |
| Passive vs active | Passive = looking at what is already public; active = sending probes the target would not normally receive | DNS lookup (passive) vs port scan (active) |
| Port scan | Knocking on every door of a machine to see which ones answer | lab: nmap finds `8080`, `8443`, `9443` open |
| Scope | The written list of what may be tested | "shop.example.com, tiers 0 to 2, this week" |
| Finding | One defect, with its evidence, its impact and its fix | "PostgreSQL declared exposed outside the cluster" |
| False positive | A tool reports a problem that does not exist | lab: nuclei tagged the nginx lab as `splunk` |
| Soft 404 | A site that answers "200 OK" for pages that do not exist | made-up example: every unknown URL shows the home page |

## TLS and HTTP

| Term | Plain meaning | Example |
|---|---|---|
| TLS | The encryption behind `https://` | lab: TLS 1.3 negotiated with `TLS_AES_256_GCM_SHA384` |
| Certificate | The identity card a server shows; signed by an authority, valid for listed names, with an expiry date | lab: `CN=lab-lb`, valid 20 days from lab start |
| Self-signed | A certificate that vouches for itself: browsers reject it | lab: `verify: 18 (self-signed certificate)` |
| SAN | The list of names a certificate is valid for | lab: `DNS:lab-lb` |
| Cipher suite | The set of algorithms agreed for one connection | `ECDHE-RSA-AES256-GCM-SHA384` |
| HSTS | A header telling browsers "always use HTTPS for this site" | real: github.com `max-age=31536000; includeSubdomains; preload` |
| HSTS preload | Being listed inside browsers as HTTPS-only before the first visit | requires `max-age` of one year, `includeSubDomains`, `preload` |
| OCSP stapling | The server attaches a fresh "this certificate is not revoked" proof | lab: `absent` (informative only since 2025) |
| CAA | A DNS record listing which authorities may issue certificates for the domain | lab: `0 issue "letsencrypt.org"` |
| CORS | Rules that say which other websites may read responses from this one | lab: any origin is echoed back with credentials allowed, which is dangerous |
| CSP | A header listing where a page may load scripts and frames from | made-up example: `default-src 'self'` |
| Cookie flags | `Secure` (HTTPS only), `HttpOnly` (hidden from JavaScript), `SameSite` (`Strict`: never sent on requests coming from another site; `Lax`: sent only when the user navigates there; `None`: always sent) | lab: `ROUTEID=a; Path=/` has none. Made-up example: with `Lax`, clicking a link from a mail to the shop sends the cookie, an image or `fetch` embedded in another site does not |
| ALPN | The step of the TLS handshake where client and server agree on HTTP/1.1 or HTTP/2 | lab: `"alpn": "http/1.1"` |
| mTLS | TLS where the client also presents a certificate, so each side proves who it is | made-up example: partners call the API on 8443 with a client certificate |
| CT logs | Certificate Transparency: public registers of every certificate issued; they reveal forgotten host names | made-up example: a certificate for `old-admin.example.com` listed in crt.sh |
| HTTP/2, HTTP/3 | Newer, faster versions of HTTP; HTTP/3 runs over UDP (QUIC) | real: `alt-svc: h3=":443"` advertises HTTP/3 |

## Kubernetes and containers

| Term | Plain meaning | Example |
|---|---|---|
| Container | A packaged program with its files, isolated from its neighbours | `nginx:1.31.10-alpine` |
| Image tag vs digest | A tag is a movable label; a digest is the fingerprint of exact contents | `redis:7-alpine` vs `redis@sha256:…` |
| Pod | One or more containers that run together; the unit Kubernetes schedules | real: `bedrock-654dcdd69-4vdcv` |
| Deployment / replicas | "Keep N identical pods running" | lab: `web x2`, `api x1` |
| Service | A stable name and address in front of a set of pods | lab: `svc api:8080` |
| ClusterIP / NodePort / LoadBalancer | Service reachable only inside / on a port of every node / through a load balancer the environment provisions (external or internal) | lab: `postgres` declares a `LoadBalancer` entry point; whether it is public is `UNKNOWN` until verified |
| Namespace | A folder for grouping resources; **not** a security boundary by itself | lab: `shop`, `payments` |
| NetworkPolicy | A firewall rule between pods; without any, everything may talk to everything | lab: `payments` has one, `shop` has none |
| Flat network | A network where nothing is separated from anything | lab: namespace `shop` |
| securityContext | The settings that say how much power a container has | `runAsNonRoot: true`, `privileged: false` |
| Privileged container | A container with almost the powers of the host machine | lab: `api` |
| RBAC | Who may do what in the cluster | lab: a role allowing `*` on `*` |
| ServiceAccount | The identity a pod uses to talk to the cluster | lab: `ledger` has its own, `shop` pods share `default` |
| Probe (readiness, liveness) | A periodic "are you ready / are you alive" question to a container | lab: `ledger` answers on `/ready` and `/live` |
| HPA | Rule that adds or removes pods according to load | lab: `ledger` scales from 3 to 10 |
| PodDisruptionBudget | "Never take down more than N pods at once" during maintenance | lab: `minAvailable: 2` for `ledger` |
| Helm chart | A template that generates Kubernetes manifests | must be rendered (`helm template`) before auditing |

## Infrastructure as code, supply chain, operations

| Term | Plain meaning | Example |
|---|---|---|
| IaC | Infrastructure described in files instead of clicks | Terraform, CloudFormation, Kubernetes manifests |
| Security group | A cloud firewall rule set attached to machines | lab: port 22 open to `0.0.0.0/0` |
| `0.0.0.0/0` | "Every address on the internet" | lab: PostgreSQL port allowed from `0.0.0.0/0` |
| IAM | The cloud's permission system | lab: a policy allowing every action on every resource |
| Wildcard | `*`, meaning "everything" | `Action = "*"` |
| CVE | A publicly catalogued vulnerability | `CVE-2021-44228` (Log4Shell) |
| SBOM | The ingredient list of a piece of software | lab: syft lists 710 components in `redis:7-alpine` |
| Provenance | Proof of where and how an artefact was built | a signed attestation linking an image to a commit |
| SLSA | A scale describing how trustworthy a build's provenance is | made-up example: "SLSA Build level 2: built by a hosted pipeline that signs the provenance" (level 3 adds a hardened, isolated builder) |
| OIDC federation | The pipeline proves its identity to the cloud with a short-lived token instead of a stored key | made-up example: a GitHub Actions job assumes an AWS role only if it runs from `repo:acme/shop` on `main` |
| KEV / EPSS | KEV: the list of vulnerabilities known to be exploited (CISA). EPSS: a 0 to 1 estimate that one will be | made-up example: a CVE in KEV is patched first, whatever its score |
| Pinning | Fixing an exact version so it cannot change silently | `uses: actions/checkout@<40-hex commit>` |
| SPOF | Single point of failure: one thing whose loss stops everything | lab: `postgres x1` |
| RPO / RTO | How much data you accept to lose / how long you accept to be down | made-up example: RPO 1 hour, RTO 4 hours |
| Observability | Being able to tell what the system is doing from logs, metrics and traces | a dashboard, plus an alert when the error rate rises |
| Rate limiting | Capping how many requests one client may send | made-up example: 10 logins per minute per IP |
| Timeout / retry budget | How long to wait, and how many times to try again, before giving up | made-up example: 2 retries with backoff, never 3 x 3 x 3 |
| Graceful shutdown | Finishing in-flight requests before stopping | a `preStop` hook and SIGTERM handling |
