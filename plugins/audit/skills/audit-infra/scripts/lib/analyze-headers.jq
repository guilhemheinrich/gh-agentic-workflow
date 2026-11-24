# Turns the raw curl samples gathered by collect-headers.inner.sh into one report.
# Inputs (all --slurpfile, so each is wrapped in a one-element array):
#   $samples $sticky $cors $notfound $http $endpoints ; plus $url $probed_at $curl_version $nfbody

# Headers whose value is unique per request by design: never evidence of several backends.
def per_request_names: ["date","age","expires","set-cookie","cf-ray","x-request-id","request-id",
  "x-amzn-requestid","x-amzn-trace-id","x-amz-request-id","x-amz-id-2","x-amz-cf-id","x-trace-id",
  "x-correlation-id","traceparent","x-runtime","x-response-time","x-timer","x-varnish",
  "x-envoy-upstream-service-time","report-to","nel","content-security-policy",
  "content-security-policy-report-only","x-vercel-id","fly-request-id","x-azure-ref",
  "x-cloud-trace-context","x-github-request-id","x-fastly-request-id","x-nf-request-id",
  "x-kong-upstream-latency","x-kong-proxy-latency","x-kong-request-id","x-msedge-ref"];

# Headers that describe the state of a cache, not the identity of a backend.
def cache_state_names: ["x-cache","x-cache-hits","x-cache-status","cf-cache-status","x-drupal-cache",
  "x-proxy-cache","x-nginx-cache","x-litespeed-cache","cdn-cache","x-cache-lookup"];

# Fingerprint rules: header (lowercase), regex on its value ("" = presence is enough),
# the layer it places in the chain, and what it identifies.
def rules: [
  {h:"server", re:"^cloudflare", layer:"cdn", id:"Cloudflare (CDN + WAF)"},
  {h:"cf-ray", re:"", layer:"cdn", id:"Cloudflare (value suffix = edge POP)"},
  {h:"cf-cache-status", re:"", layer:"cdn", id:"Cloudflare cache"},
  {h:"server", re:"AkamaiGHost|AkamaiNetStorage", layer:"cdn", id:"Akamai"},
  {h:"x-akamai-transformed", re:"", layer:"cdn", id:"Akamai"},
  {h:"server", re:"CloudFront", layer:"cdn", id:"Amazon CloudFront"},
  {h:"x-amz-cf-pop", re:"", layer:"cdn", id:"Amazon CloudFront (value = edge POP)"},
  {h:"x-amz-cf-id", re:"", layer:"cdn", id:"Amazon CloudFront"},
  {h:"via", re:"cloudfront", layer:"cdn", id:"Amazon CloudFront"},
  {h:"x-served-by", re:"^cache-", layer:"cdn", id:"Fastly (value = cache node and POP)"},
  {h:"x-fastly-request-id", re:"", layer:"cdn", id:"Fastly"},
  {h:"x-azure-ref", re:"", layer:"cdn", id:"Azure Front Door"},
  {h:"x-msedge-ref", re:"", layer:"cdn", id:"Azure Front Door / Microsoft edge"},
  {h:"x-vercel-id", re:"", layer:"cdn", id:"Vercel edge (value prefix = region)"},
  {h:"x-nf-request-id", re:"", layer:"cdn", id:"Netlify edge"},
  {h:"fly-request-id", re:"", layer:"cdn", id:"Fly.io proxy (value suffix = region)"},
  {h:"x-github-request-id", re:"", layer:"cdn", id:"GitHub Pages"},
  {h:"x-sucuri-id", re:"", layer:"waf", id:"Sucuri WAF"},
  {h:"x-iinfo", re:"", layer:"waf", id:"Imperva (Incapsula) WAF"},
  {h:"x-cdn", re:"Imperva|Incapsula", layer:"waf", id:"Imperva (Incapsula) WAF"},
  {h:"set-cookie", re:"^(incap_ses|visid_incap)", layer:"waf", id:"Imperva (Incapsula) WAF cookie"},
  {h:"set-cookie", re:"^__cf_bm=", layer:"waf", id:"Cloudflare Bot Management cookie"},
  {h:"set-cookie", re:"^(ak_bmsc|bm_sv)=", layer:"waf", id:"Akamai Bot Manager cookie"},
  {h:"server", re:"^awselb", layer:"lb", id:"AWS Elastic Load Balancer answered itself (no backend reached)"},
  {h:"x-amzn-trace-id", re:"", layer:"lb", id:"AWS ALB or API Gateway"},
  {h:"set-cookie", re:"^(AWSALB|AWSALBCORS|AWSELB|AWSALBTG)", layer:"lb", id:"AWS load balancer stickiness cookie"},
  {h:"set-cookie", re:"^BIGipServer", layer:"lb", id:"F5 BIG-IP persistence cookie (value encodes backend IP:port)"},
  {h:"set-cookie", re:"^(SERVERID|SRVID|ROUTEID|route|sticky|INGRESSCOOKIE|ARRAffinity|ARRAffinitySameSite|GCLB|__cflb|lb_route)=", layer:"lb", id:"Load balancer affinity cookie"},
  {h:"via", re:"1\\.1 google", layer:"lb", id:"Google Cloud HTTP(S) Load Balancer"},
  {h:"server", re:"^(Google Frontend|gws|GSE|ESF)", layer:"lb", id:"Google front end"},
  {h:"server", re:"BigIP|BIG-IP", layer:"lb", id:"F5 BIG-IP"},
  {h:"x-amz-apigw-id", re:"", layer:"gateway", id:"AWS API Gateway"},
  {h:"x-amzn-requestid", re:"", layer:"gateway", id:"AWS API Gateway or Lambda"},
  {h:"server", re:"^kong", layer:"gateway", id:"Kong gateway"},
  {h:"via", re:"kong", layer:"gateway", id:"Kong gateway"},
  {h:"x-kong-proxy-latency", re:"", layer:"gateway", id:"Kong gateway"},
  {h:"server", re:"envoy", layer:"proxy", id:"Envoy (Istio, Contour, Emissary, AWS App Mesh)"},
  {h:"x-envoy-upstream-service-time", re:"", layer:"proxy", id:"Envoy (value = upstream latency in ms)"},
  {h:"server", re:"^(nginx|openresty|tengine)", layer:"proxy", id:"nginx family (often the ingress controller)"},
  {h:"server", re:"^Caddy", layer:"proxy", id:"Caddy"},
  {h:"server", re:"Varnish", layer:"proxy", id:"Varnish cache"},
  {h:"x-varnish", re:"", layer:"proxy", id:"Varnish cache (two ids = cache hit)"},
  {h:"via", re:"varnish", layer:"proxy", id:"Varnish cache"},
  {h:"server", re:"^ATS", layer:"proxy", id:"Apache Traffic Server"},
  {h:"via", re:"vegur", layer:"proxy", id:"Heroku router"},
  {h:"server", re:"^(Apache|LiteSpeed|Microsoft-IIS)", layer:"proxy", id:"Web server"},
  {h:"via", re:"", layer:"proxy", id:"At least one intermediary declares itself (RFC 9110 Via)"},
  {h:"server", re:"^(Kestrel|gunicorn|uvicorn|Werkzeug|waitress|Jetty|Apache-Coyote|WEBrick|Cowboy|Puma|hypercorn|daphne)", layer:"app", id:"Application server answering directly"},
  {h:"x-powered-by", re:"", layer:"app", id:"Application framework or runtime"},
  {h:"x-aspnet-version", re:"", layer:"app", id:"ASP.NET runtime version"},
  {h:"x-aspnetmvc-version", re:"", layer:"app", id:"ASP.NET MVC version"},
  {h:"x-generator", re:"", layer:"app", id:"CMS or site generator"},
  {h:"x-drupal-cache", re:"", layer:"app", id:"Drupal"},
  {h:"server", re:"^AmazonS3", layer:"storage", id:"Amazon S3 serving directly"},
  {h:"x-amz-request-id", re:"", layer:"storage", id:"Amazon S3 (or S3-compatible) origin"},
  {h:"x-ms-request-id", re:"", layer:"storage", id:"Azure Storage or Azure service origin"},
  {h:"x-goog-generation", re:"", layer:"storage", id:"Google Cloud Storage origin"}
];

def layer_rank: {"cdn":1,"waf":2,"lb":3,"gateway":4,"proxy":5,"app":6,"storage":7};
# RFC 1918, plus RFC 6598 shared space (100.64/10: EKS secondary CIDRs, meshes) and
# link-local (169.254/16).
def private_ip: "(?<![0-9.])(10\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}|192\\.168\\.[0-9]{1,3}\\.[0-9]{1,3}|172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9]{1,3}\\.[0-9]{1,3}|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9]{1,3}\\.[0-9]{1,3}|169\\.254\\.[0-9]{1,3}\\.[0-9]{1,3})(?![0-9])";
# Cookie values are session material: the report keeps the name and the attributes only.
def redact_cookie: split(";") as $p
  | (($p[0] | split("=")[0]) + "=<redacted>")
    + (if ($p | length) > 1 then ";" + ($p[1:] | join(";")) else "" end);
def safe($name): if $name == "set-cookie" then (split(" | ") | map(redact_cookie) | join(" | ")) else . end;

def letters: "ABCDEFGHIJKLMNOPQRSTUVWXYZ" | split("");

# For a list of answers: which headers differ between answers, and how.
def diff($list):
  ($list | length) as $n
  | ([$list[].headers | keys[]] | unique) as $names
  | [ $names[] as $name
      | [ $list[] | (.headers[$name] // ["<absent>"]) | join(" | ") ] as $vals
      | ($vals | unique) as $distinct
      | select(($distinct | length) > 1)
      | { header: $name,
          distinct: ($distinct | length),
          class: (if (per_request_names | index($name)) then "per_request"
                  elif (cache_state_names | index($name)) then "cache_state"
                  elif (($distinct | length) == $n and $n >= 4) then "per_request"
                  else "backend_diff" end),
          values: ($distinct[0:8] | map(safe($name))),
          pattern: ([ $vals[] as $v | letters[($distinct | index($v)) % 26] ] | join("")) } ];

def cookie($raw):
  ($raw | split(";") | map(gsub("^\\s+|\\s+$"; ""))) as $parts
  | ($parts[1:] | map(ascii_downcase)) as $attrs
  | { name: ($parts[0] | split("=")[0]),
      secure: ($attrs | any(. == "secure")),
      httponly: ($attrs | any(. == "httponly")),
      samesite: (($attrs | map(select(startswith("samesite="))) | .[0] // "samesite=<unset>") | split("=")[1]),
      domain: (($attrs | map(select(startswith("domain="))) | .[0] // null) | if . then split("=")[1] else null end),
      persistent: ($attrs | any(startswith("max-age=") or startswith("expires="))) };

def brief($r): if $r == null then null elif $r.error then {error: $r.error} else
  { status: $r.meta.http_code, location: ($r.headers.location[0] // null),
    server: ($r.headers.server[0] // null) } end;

$samples[0] as $all
| ($all | map(select(.error | not))) as $ok
| ($sticky[0] | map(select(.error | not))) as $sok
| ($ok[0] // {headers: {}, meta: {}}) as $first
| ($first.headers) as $H
| ($url | startswith("https://")) as $https
| diff($ok) as $var
| diff($sok) as $svar
| ($var | map(select(.class == "backend_diff"))) as $bd
| ($svar | map(select(.class == "backend_diff"))) as $sbd
| ([$ok[].meta.remote_ip] | unique) as $ips
| ([$ok[] | .headers | to_entries[]] | group_by(.key) | map({key: .[0].key, value: ([.[].value[]] | unique)}) | from_entries) as $union
| ([ rules[] as $r
     | ($union[$r.h] // []) as $vals
     | ($vals | map(select($r.re == "" or test($r.re; "i")))) as $hit
     | select(($hit | length) > 0)
     | {layer: $r.layer, identifies: $r.id, header: $r.h, evidence: ($hit[0] | safe($r.h) | .[0:160])} ]
   | sort_by(layer_rank[.layer])) as $fp
| ([$ok[] | (.headers["set-cookie"] // [])[]] | map(cookie(.)) | unique_by(.name)) as $cookies
| ($H["strict-transport-security"][0] // null) as $hsts
| ($H["content-security-policy"][0] // null) as $csp
| ($cors[0]) as $c
| ($notfound[0]) as $nf
| {
    target: $url,
    probed_at: $probed_at,
    collector: $curl_version,
    requests: {sent: ($all | length), answered: ($ok | length),
               errors: ($all | map(select(.error) | .error) | unique)},
    protocol: {
      http_versions: ([$ok[].meta.http_version] | unique),
      status_codes: ([$ok[].meta.http_code] | unique),
      alt_svc: ($H["alt-svc"][0] // null),
      http3_advertised: (($H["alt-svc"][0] // "") | test("h3")),
      time_total_s: (if ($ok | length) > 0 then
        {min: ([$ok[].meta.time_total] | min), max: ([$ok[].meta.time_total] | max)} else null end)
    },
    remote_ips: $ips,
    layers: $fp,
    load_balancing: {
      suspected: ((($bd | length) > 0) or (($ips | length) > 1) or ($fp | any(.layer == "lb"))),
      estimated_backends: (if ($bd | length) > 0 then ([$bd[].distinct] | max) else null end),
      evidence: (
        [ $bd[] | "header '\(.header)' takes \(.distinct) values over \($ok | length) fresh connections, pattern \(.pattern)" ]
        + (if ($ips | length) > 1 then ["\($ips | length) distinct remote IPs answered: \($ips | join(", ")) (DNS round robin or anycast)"] else [] end)
        + [ $fp[] | select(.layer == "lb") | "\(.header): \(.evidence) -> \(.identifies)" ]),
      note: (if ($bd | length) > 0 then null else
        "no backend-specific header rotated over \($ok | length) fresh connections: not proof of a single backend (headers may be normalised, affinity may be by source IP, and a proxy with several workers keeps one round-robin position per worker)" end),
      affinity: (
        if ($sok | length) == 0 then {tested: false, reason: "no Set-Cookie in the first answer"}
        elif ($bd | length) == 0 then {tested: true, sticky: null, reason: "no backend-specific header to compare"}
        else {tested: true, sticky: (($sbd | length) == 0),
              detail: (if ($sbd | length) == 0
                       then "with the first answer's cookies replayed, backend-specific headers stop varying"
                       else "backend-specific headers still vary with cookies replayed: no cookie affinity" end)} end)
    },
    header_variation: $var,
    cache: {
      cache_control: ($H["cache-control"][0] // null),
      age: ($H["age"][0] // null),
      vary: ($H["vary"][0] // null),
      etag: ($H["etag"][0] // null),
      state_headers: ($union | with_entries(select(.key as $k | cache_state_names | index($k))))
    },
    security_headers: {
      present: ($H | with_entries(select(.key | IN("strict-transport-security","content-security-policy",
        "x-content-type-options","x-frame-options","referrer-policy","permissions-policy",
        "cross-origin-opener-policy","cross-origin-resource-policy","cross-origin-embedder-policy")) | .value |= .[0])),
      missing: ([ "content-security-policy","x-content-type-options","referrer-policy","permissions-policy" ]
                + (if $https then ["strict-transport-security"] else [] end)
                | map(select(. as $n | $H[$n] | not))
                + (if ($H["x-frame-options"] | not) and (($csp // "") | test("frame-ancestors") | not)
                   then ["x-frame-options (or CSP frame-ancestors)"] else [] end)),
      hsts: (if $hsts == null then null else
        { raw: $hsts,
          max_age: (($hsts | capture("max-age=\"?(?<n>[0-9]+)"; "i") | .n | tonumber) // null),
          include_subdomains: ($hsts | test("includeSubDomains"; "i")),
          preload: ($hsts | test("preload"; "i")) }
        | .preload_eligible = ((.max_age // 0) >= 31536000 and .include_subdomains and .preload) end)
    },
    information_leaks: (
      [ ($union.server // [])[] | select(test("[0-9]+\\.[0-9]+")) | {header: "server", value: ., why: "exact version disclosed"} ]
      + [ "x-powered-by","x-aspnet-version","x-aspnetmvc-version","x-generator","x-backend-server","x-upstream","x-forwarded-for","x-forwarded-host","x-forwarded-server","x-real-ip","x-debug-token","x-debug-token-link"
          | . as $n | ($union[$n] // [])[] | {header: $n, value: ., why: "should not reach the client"} ]
      + [ $union | to_entries[] | .key as $k | .value[] | select(test(private_ip)) | {header: $k, value: (safe($k) | .[0:160]), why: "internal (private, shared or link-local) address disclosed"} ]),
    cookies: $cookies,
    cors: (if $c.error then {error: $c.error} else
      { sent_origin: "https://audit-infra.invalid",
        allow_origin: ($c.headers["access-control-allow-origin"][0] // null),
        allow_credentials: ($c.headers["access-control-allow-credentials"][0] // null),
        reflects_arbitrary_origin: (($c.headers["access-control-allow-origin"][0] // "") == "https://audit-infra.invalid"),
        wildcard: (($c.headers["access-control-allow-origin"][0] // "") == "*") }
      | .dangerous = (.reflects_arbitrary_origin and ((.allow_credentials // "") | ascii_downcase) == "true") end),
    http_to_https: (if $http[0] == null then null else brief($http[0])
      | if .error then . else .redirects_to_https = ((.location // "") | startswith("https://")) end end),
    error_page: (if $nf.error then {error: $nf.error} else
      { status: $nf.meta.http_code,
        server: ($nf.headers.server[0] // null),
        server_differs_from_main: (($nf.headers.server[0] // null) != ($H.server[0] // null)),
        soft_404: ($nf.meta.http_code == 200),
        leaks: ([ ["stack trace", "Traceback \\(most recent call last\\)|\\bat [a-zA-Z0-9_.$]+\\([A-Za-z0-9_]+\\.(java|kt|scala):[0-9]+\\)|\\.php on line [0-9]+|at .*\\.js:[0-9]+:[0-9]+"],
                  ["framework default page", "Whitelabel Error Page|Apache Tomcat/|Django|Werkzeug|Laravel|Symfony\\\\|Express"],
                  ["server banner with version", "(nginx|Apache|openresty|Microsoft-IIS|Jetty)/[0-9]+\\.[0-9]+"] ]
                | map(. as $rule | select($nfbody | test($rule[1])) | $rule[0])),
        body_excerpt: ($nfbody | gsub("\\s+"; " ") | .[0:200]) } end),
    endpoints: (if ($endpoints[0] | length) == 0 then {probed: false} else
      { probed: true,
        exposed: ($endpoints[0] | map(select(.exposed and .severity != "good") | {path, severity, what})),
        good: ($endpoints[0] | map(select(.exposed and .severity == "good") | .path)),
        all: ($endpoints[0] | map({path, status, signature_matched})) } end)
  }
