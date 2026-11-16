---
name: web-analysis
description: >-
  Deterministic web analysis tools executable via Docker. Covers performance
  (Lighthouse, sitespeed.io), accessibility (pa11y, axe-core CLI), SEO, security headers,
  link checking, technology detection, and HTML validation. All tools produce
  machine-readable output without host dependencies.
tags:
  - web-analysis
  - docker
  - performance
  - accessibility
  - seo
  - security
---

# Web analysis: audit tools via Docker

Each tool runs in a container and produces a machine-readable report
(JSON/HTML); nothing is installed on the host. Flags, advanced examples and
output interpretation live in `resources/`.

Prerequisites: Docker, and network access to the target URL.

## Bundled image

```bash
docker build -t web-analysis <path-to-this-skill-directory>/
docker run --rm web-analysis pa11y https://example.com
docker run --rm web-analysis axe https://example.com \
  --chromedriver-path /usr/bin/chromedriver --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage"
docker run --rm web-analysis lighthouse https://example.com --chrome-flags="--headless --no-sandbox"
```

The `Dockerfile` bundles Lighthouse, pa11y, axe-core CLI, broken-link-checker,
html-validate, curl and jq on Node 22 Alpine with Chromium and ChromeDriver,
and copies `pa11y.json` (no-sandbox launch args) into `/work`.
`Dockerfile.sitespeed` only documents the official sitespeed.io image: do not
build it, pull and run that image instead.

## Tools

| Question | Tool | Image | Reference |
|---|---|---|---|
| Fast enough? Scores for performance, SEO, a11y, PWA | Lighthouse | `femtopixel/google-lighthouse` | `resources/lighthouse.md` |
| Real-world metrics, waterfalls, throttled networks, multi-run | sitespeed.io | `sitespeedio/sitespeed.io` | `resources/sitespeed.md` |
| WCAG 2.1 A/AA/AAA violations with selectors | pa11y | bundled | `resources/pa11y.md` |
| Contrast, ARIA, landmarks; CI gate on violations | axe-core CLI | bundled | `resources/axe-core-cli.md` |
| Dead links (404, timeout, DNS) | broken-link-checker | bundled | `resources/broken-link-checker.md` |
| CSP, HSTS, X-Frame-Options, ... | curl + jq | `alpine` | `resources/security-headers.md` |
| Frameworks, CMS, CDN, analytics in use | Wappalyzer CLI | `node:22-alpine` | `resources/wappalyzer.md` |
| HTML validity (W3C rules) | html-validate | bundled | `resources/html-validate.md` |

Pin image tags instead of `latest` when results must be reproducible in CI.

## Combined analysis

`resources/combined-analysis.md` has a `run-all-analysis.sh` and a compose
example that run every tool against one URL and aggregate results under
`./web-analysis-results/{lighthouse,pa11y,links,html,security,tech}/`.
