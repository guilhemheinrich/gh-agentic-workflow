# Header fingerprints: what a response header hints

Every layer between the browser and the application may add, rewrite or forget to
strip a header. Reading them back to front reconstructs the chain. The machine-readable
version of this table is `scripts/lib/analyze-headers.jq` (`rules`), applied by
`scripts/collect-headers.sh`.

All "real example" lines were captured on 2026-11-24 with one ordinary page load per
site, the request any browser sends. They illustrate what a header looks like; they
are **not a method to repeat**: never point the collectors, and even less a scanner,
at a site you were not asked to audit. To practise, use `scripts/fixtures/lb-lab`.

A header is a hint about a product, never proof that a control is enforced, and never
a count of machines. Write the observed value and the inference as two statements.

## Reading method

1. **Collect several answers, not one.** A single response hides load balancing.
   `collect-headers.sh` sends N requests on fresh connections and diffs them.
2. **Classify each header**: per-request noise (`date`, `cf-ray`, `x-request-id`),
   cache state (`x-cache`, `age`), or responder identity (`x-served-by`, `server`).
   Only the third class hints at several responders, and a responder can be a cache
   node or a worker process rather than a backend machine (`etag` differences usually
   mean different content, not different servers).
3. **Order the layers** from the outside in: CDN, WAF, load balancer, gateway, reverse
   proxy / ingress, application server, storage origin.
4. **Compare the 404 page with the 200 page.** A different `Server` on the error page
   means the error was answered by another layer than the application.

Worked example, real (`https://www.mozilla.org/en-US/`):

```
server: granian
via: 1.1 google, 1.1 varnish, 1.1 varnish
x-backend-server: bedrock-654dcdd69-4vdcv.gcp-eu-west1
x-served-by: cache-par-lfpg1960042-PAR, cache-par-lfpg1960042-PAR, cache-par-lfpg1960079-PAR
x-cache: MISS, HIT
```

Reading: `x-served-by: cache-…-PAR` and `via: 1.1 varnish` = Fastly, edge in Paris;
`via: 1.1 google` = a Google Cloud HTTP(S) load balancer behind it; `x-backend-server:
bedrock-654dcdd69-4vdcv` has the shape `<deployment>-<replicaset hash>-<pod id>` = a
Kubernetes pod of a Deployment named `bedrock`, in `gcp-eu-west1`; `server: granian` =
the Python application server answering inside that pod. Four layers from five headers.

## CDN and edge

| Header | Reveals | Real example |
|---|---|---|
| `server: cloudflare` | Cloudflare proxies the site (CDN, and WAF if enabled) | `server: cloudflare` (example.com) |
| `cf-ray` | Cloudflare; the suffix is the IATA code of the edge that answered | `cf-ray: a5f896167a5ea595-CDG` = Paris CDG |
| `cf-cache-status` | Cloudflare cache verdict: `HIT`, `MISS`, `DYNAMIC` (not cacheable), `BYPASS` | `cf-cache-status: DYNAMIC` (stackoverflow.com) |
| `x-amz-cf-pop`, `x-amz-cf-id` | Amazon CloudFront; the POP code names the edge location | `x-amz-cf-pop: CDG52-P6` (aws.amazon.com) |
| `via: … (CloudFront)` | CloudFront distribution hostname | `via: 1.1 1555ca….cloudfront.net (CloudFront)` |
| `x-cache: Miss from cloudfront` | CloudFront cache verdict | `x-cache: Miss from cloudfront` |
| `x-served-by: cache-…` | Fastly; one entry per cache node crossed, last 3 letters = POP | `x-served-by: cache-sjc1000087-SJC, cache-sjc10081-SJC, cache-par-lfpg1960088-PAR` = shield in San Jose, edge in Paris |
| `x-cache: MISS, HIT` + `x-cache-hits` | Fastly, one verdict per node of `x-served-by` | `x-cache: MISS, HIT, HIT` / `x-cache-hits: 0, 17, 22` |
| `x-timer` | Fastly timing (`VS` start, `VE` elapsed ms) | `x-timer: S1795525121.465143,VS0,VE1` |
| `x-vercel-id`, `x-vercel-cache` | Vercel; the id prefix is the region | `x-vercel-id: cdg1::vrt5t-…` |
| `x-nf-request-id`, `server: Netlify` | Netlify edge | `cache-status: "Netlify Edge"; hit; ttl=31491763` |
| `x-azure-ref`, `x-msedge-ref` | Azure Front Door | made-up example: `x-azure-ref: 20261124T120000Z-r1…` |
| `server: AkamaiGHost`, `x-akamai-transformed` | Akamai | made-up example: `server: AkamaiGHost` |
| `x-github-request-id` | GitHub (Pages or github.com) | `x-github-request-id: 1C99:BE9CF:247D88:5C7EF0:6B0589FE` |
| `alt-svc: h3=":443"` | HTTP/3 (QUIC) offered on UDP 443, almost always by a CDN | `alt-svc: h3=":443"; ma=86400` (example.com) |
| `cache-status` (RFC 9211) | Standardised cache verdict, names the cache | see Netlify above |

## WAF and bot protection

| Header or cookie | Reveals | Example |
|---|---|---|
| `set-cookie: __cf_bm=…` | Cloudflare Bot Management sets its cookie. It shows the product, not that any WAF rule set is enforcing | real: stackoverflow.com sets `__cf_bm` |
| `set-cookie: incap_ses_…`, `visid_incap_…`; `x-iinfo`; `x-cdn: Imperva` | Imperva (Incapsula) WAF | made-up example: `x-cdn: Imperva` |
| `set-cookie: ak_bmsc`, `bm_sv` | Akamai Bot Manager | made-up example |
| `x-sucuri-id`, `x-sucuri-cache` | Sucuri WAF | made-up example: `x-sucuri-id: 18007` |
| `server: awselb/2.0` on a 403 with a fixed HTML body | AWS WAF or ALB rule answered, the application never saw the request | made-up example |
| Status `403`/`406`/`429` on an ordinary request of the collector | A WAF or rate limiter may exist even if no header names it | Observe only. Sending an attack-shaped payload (`' OR 1=1`, a scanner User-Agent) to provoke it is an active test: not done by this skill's scripts, and never at the light tier |

## Load balancers

| Header or cookie | Reveals | Example |
|---|---|---|
| `via: 1.1 google` | Google Cloud HTTP(S) Load Balancer | real: mozilla.org `via: 1.1 google, 1.1 varnish, 1.1 varnish` |
| `server: gws`, `Google Frontend`, `ESF` | Google front end | real: `server: gws` (google.com) |
| `x-amzn-trace-id: Root=1-…` | AWS ALB (or API Gateway) | made-up example: `x-amzn-trace-id: Root=1-67a1b2c3-…` |
| `set-cookie: AWSALB=…; AWSALBCORS=…` | ALB with sticky sessions enabled; `AWSELB` = Classic ELB | made-up example |
| `set-cookie: BIGipServer<pool>=<n>.<p>.0000` | F5 BIG-IP persistence. The value **encodes the backend private IP and port** (little-endian decimal): a leak in itself | made-up example: `BIGipServerpool_web=335544330.20480.0000` = 10.0.0.20:80 |
| `set-cookie: SERVERID=…`, `ROUTEID=…`, `route=…`, `INGRESSCOOKIE=…`, `ARRAffinity=…` | HAProxy, Apache mod_proxy_balancer, ingress-nginx, Azure App Service affinity | lab: `ROUTEID=a` then `ROUTEID=b` on the next connection |
| The same header taking k values in rotation over N fresh connections | At least k distinct responders behind something that distributes requests. Not a machine count: the values can name caches or workers (see the Fastly example above) | lab: `x-served-by` pattern `BABABABA` over 8 requests = 2 responders (the lab has 2 backends) |
| Several A records, or a different `remote_ip` per request | DNS round robin or anycast in front of everything else | lab: `www.lab.test` resolves to 2 A records |

## Reverse proxies, ingress and gateways

| Header | Reveals | Example |
|---|---|---|
| `server: nginx/1.x`, `openresty` | nginx family. In Kubernetes this is usually ingress-nginx. With a version = information leak | lab: `server: nginx/1.31.10` |
| `server: envoy`, `istio-envoy`; `x-envoy-upstream-service-time` | Envoy: Istio, Contour, Emissary, Gateway API. The value is the upstream latency in ms | made-up example: `x-envoy-upstream-service-time: 12` |
| `x-kong-upstream-latency`, `x-kong-proxy-latency`, `via: kong/3.x` | Kong gateway, with its version in `via` | made-up example |
| `x-amz-apigw-id`, `x-amzn-requestid` | AWS API Gateway (often in front of Lambda) | made-up example |
| `x-varnish: 1234 5678`, `via: 1.1 varnish` | Varnish; two ids = the object was served from cache | real: mozilla.org `via: … 1.1 varnish` |
| `server: Caddy`, `server: ATS/9.x`, `via: 1.1 vegur` | Caddy, Apache Traffic Server, Heroku router | made-up example |
| `x-cache: cp6016 miss, cp6015 hit/653814` | Named cache hosts crossed, each with its verdict and hit count | real: www.wikipedia.org |

## Application and origin

| Header | Reveals | Example |
|---|---|---|
| `x-powered-by` | Framework or runtime | real: `x-powered-by: Next.js, Payload` (vercel.com); lab: `Express` |
| `server: gunicorn`, `uvicorn`, `granian`, `Kestrel`, `Jetty`, `Apache-Coyote` | The application server is exposed with no rewriting proxy in front, or the proxy passes `Server` through | real: `server: granian` (mozilla.org) |
| `server: <pod-name>` or `x-backend-server: <pod-name>` | A Kubernetes pod name: Deployment name, ReplicaSet hash, sometimes cluster and region | real: `server: mw-web.eqiad.main-7b9967db5c-ftvn4` (wikipedia.org) |
| `x-aspnet-version`, `x-aspnetmvc-version`, `x-generator` | Exact runtime or CMS version | made-up example: `x-aspnet-version: 4.0.30319` |
| `server: AmazonS3`, `x-amz-request-id` + `x-amz-id-2` | The object comes from S3 (directly or as a CDN origin) | made-up example |
| `x-ms-request-id`, `x-goog-generation` | Azure Storage, Google Cloud Storage origin | made-up example |
| `set-cookie: JSESSIONID`, `PHPSESSID`, `ASP.NET_SessionId`, `connect.sid`, `laravel_session` | Java servlet, PHP, ASP.NET, Express, Laravel | real: github.com sets `_gh_sess` (Rails-style session) |

## Leaks: headers that should never reach a client

| Header | Why it matters |
|---|---|
| `x-backend-server`, `x-upstream`, `x-served-by` with a hostname or private IP | Names an internal host. Lab: `x-backend-server: 10.42.0.11:8080` |
| `x-forwarded-for`, `x-forwarded-host`, `x-real-ip` in a **response** | The proxy echoes request-side headers: misconfiguration, and it discloses the internal hop list |
| Any value matching 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10 (shared space, common in EKS and meshes) or 169.254.0.0/16 | Internal addressing plan disclosed; `collect-headers.sh` flags it under `information_leaks` |
| `server` or `x-powered-by` with a version | Lets an attacker match known CVEs without probing |
| `x-debug-token`, `x-debug-token-link` | Symfony profiler is enabled in production |
| `x-client-ip` (or similar) echoing the caller's address | Harmless alone, but confirms which hop the application sees as the client: check it is not a proxy address (then rate limiting and audit logs are keyed on the wrong IP) |
| Client-supplied `X-Forwarded-For` / `-Host` / `-Proto` trusted by the edge | Not visible in a response: read the proxy configuration (nginx `set_real_ip_from`, ingress `use-forwarded-headers`, the application's trusted-proxy list). Trusting them from any source lets a client forge its IP (allow-list and rate-limit bypass) or the host. Do not test it by sending forged headers without active scans agreed |

## Cache, transport and policy headers

| Header | What to check | Falsifiable test |
|---|---|---|
| `cache-control` | An authenticated page must carry `private` or `no-store` | Fail if a response that sets a session cookie lacks both, or carries `public`, `s-maxage` or an `age` > 0 |
| `age` | > 0 proves a shared cache sits in front | real: `age: 65332` (wikipedia.org) = cached 18 h ago |
| `vary` | Must list every request header that changes the body (`Accept-Encoding`, `Origin` when CORS is dynamic) | Fail if `access-control-allow-origin` reflects the Origin and `vary` lacks `Origin` (cache poisoning) |
| `strict-transport-security` | Present, `max-age` of at least 180 days. `includeSubDomains` and `preload` only if every subdomain is HTTPS; one year + both are the preload-list requirements | real: github.com `max-age=31536000; includeSubdomains; preload` |
| `content-security-policy` | Present on HTML. Fail on `unsafe-inline` in `script-src` without a nonce or hash; on **any** `unsafe-eval` (a nonce does not neutralise it); on `*` in `script-src` / `default-src`; on a missing `object-src 'none'` or `frame-ancestors` | Directive reference: `testing-and-debugging:web-analysis/resources/security-headers.md` |
| `access-control-allow-origin` | Never reflects an arbitrary Origin together with `allow-credentials: true` | lab: reflected `https://audit-infra.invalid` with credentials = `cors.dangerous: true` |
| `set-cookie` flags | Session cookies: `Secure`, `HttpOnly`, `SameSite` | lab: `ROUTEID=a; Path=/` has none of the three |
| `location` on port 80 | Starts with `https://`, same host, status 301 or 308 | Fail on 200 over plain HTTP, or a redirect to another host first |

## Limits of this method

- Any layer can strip or forge any header. Absence proves nothing; a present header is
  strong but not absolute evidence. Confirm with the white-box side when available.
- A CDN in front means every header, IP and TLS property observed belongs to the CDN,
  not to the origin. The origin's own posture is only visible from inside, or if the
  origin is reachable directly (which is itself a finding: CDN bypass).
- Cookie affinity hides backend rotation from any client that keeps cookies. The
  collector therefore sends its N requests without cookies, then replays with them.
