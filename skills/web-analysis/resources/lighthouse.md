# Lighthouse — Google Performance & Quality Audit

## Official Documentation

- **Google Lighthouse**: https://developer.chrome.com/docs/lighthouse
- **GitHub**: https://github.com/GoogleChrome/lighthouse
- **Web Vitals**: https://web.dev/vitals/
- **Score Weighting**: https://developer.chrome.com/docs/lighthouse/performance/scoring/

## Overview

Google Lighthouse is an open-source automated testing tool for improving web quality. It measures:

- **Performance**: Core Web Vitals (LCP, FID/TBT, CLS), First Contentful Paint, Speed Index, etc.
- **Accessibility**: WCAG 2.1 AA compliance, ARIA usage, keyboard navigation.
- **Best Practices**: HTTP/2, console errors, deprecated APIs.
- **SEO**: Indexability, mobile-friendliness, structured data.
- **PWA**: Service Worker, install prompt, HTTPS.

## Docker Image

**Official image**: `femtopixel/google-lighthouse:latest`

Includes Node.js, npm, Chromium, and Lighthouse pre-installed.

### Building locally (optional)

If you prefer to use the bundled `web-analysis` image:

```bash
docker build -t web-analysis /path/to/.agents/skills/web-analysis/
```

Then reference as `web-analysis` instead of `femtopixel/google-lighthouse:latest`.

## Running Lighthouse

### Minimal example

```bash
docker run --rm \
  -v "$(pwd)/lighthouse-results:/results" \
  femtopixel/google-lighthouse:latest \
  https://example.com \
  --output=json \
  --output-path=/results/report.json
```

**Output**: `lighthouse-results/report.json` — complete audit report in JSON format.

### Detailed example with all common flags

```bash
docker run --rm \
  -v "$(pwd)/lighthouse-results:/results" \
  femtopixel/google-lighthouse:latest \
  https://example.com \
  --output=json \
  --output-path=/results/report.json \
  --emulated-form-factor=mobile \
  --throttling-method=simulate \
  --only-categories=performance,accessibility,best-practices,seo \
  --chrome-flags="--headless --no-sandbox --disable-dev-shm-usage"
```

## Common Flags Reference

### Output Formats

- **`--output=json`** — JSON format (machine-readable, default).
- **`--output=html`** — Interactive HTML report (visual, includes charts).
- **`--output=csv`** — CSV spreadsheet (limited; not recommended).
- **`--output=json --output=html`** — Multiple formats (outputs both).
- **`--output-path=/results/report.json`** — Save to file instead of stdout.
- **`--output-path=/results/report.html`** — Save HTML report.

### Categories & Scope

- **`--only-categories=performance`** — run only Performance audit.
- **`--only-categories=performance,accessibility`** — multiple categories.
- **`--skip-about-page`** — skip the about:blank page (faster).
- **Possible categories**: `performance`, `accessibility`, `best-practices`, `seo`, `pwa`.

### Device & Throttling

- **`--emulated-form-factor=desktop`** — test as desktop (default).
- **`--emulated-form-factor=mobile`** — test as mobile (375px width).
- **`--throttling-method=simulate`** — CPU & network simulation (default, fastest).
- **`--throttling-method=devtools`** — use Chrome DevTools throttling (more accurate, slower).
- **`--throttling-method=provided`** — use user-provided values (no throttling).

### Network & Timing

- **`--throttling.downloadThroughputKbps=1024`** — simulated download speed (default: 1638 Kbps ≈ 4G).
- **`--throttling.uploadThroughputKbps=512`** — simulated upload speed.
- **`--throttling.rttMs=150`** — round-trip time latency (default: 150ms).
- **`--max-wait-for-load=45000`** — max time to wait for page load (ms, default: 45000).
- **`--timeout=180`** — overall audit timeout in seconds (default: 180).

### Chrome Flags

- **`--chrome-flags="--headless --no-sandbox"`** — (Often needed in Docker) run Chromium headless and disable sandbox.
- **`--chrome-flags="--disable-dev-shm-usage"`** — disable `/dev/shm` usage (reduces memory for constrained environments).
- **`--chrome-flags="--disable-gpu"`** — disable GPU acceleration (saves resources).
- **`--chrome-flags="--single-process"`** — run in single process (risky, not recommended in production).

### Credentials & Cookies

- **`--extra-headers='{"Authorization":"Bearer TOKEN"}'`** — custom headers (e.g., auth tokens).
- **`--extra-headers='{"Cookie":"session=abc123"}'`** — send cookies.

### Advanced Options

- **`--precomputed-lantern-data-path=/path/to/data.json`** — use pre-computed networking model (advanced).
- **`--legacy-navigation`** — use legacy navigation mode (for very old sites).
- **`--view-trace-in-devtools=true`** — open trace in DevTools (CLI only, not Docker).

## Output Format (JSON)

### Top-level structure

```json
{
  "lighthouseVersion": "11.4.0",
  "requestedUrl": "https://example.com",
  "finalDisplayedUrl": "https://example.com",
  "runWarnings": [],
  "categories": {
    "performance": { ... },
    "accessibility": { ... },
    "best-practices": { ... },
    "seo": { ... },
    "pwa": { ... }
  },
  "audits": { ... },
  "configSettings": { ... }
}
```

### Category scores

```json
{
  "performance": {
    "title": "Performance",
    "description": "Performance metrics",
    "score": 0.85,
    "auditRefs": [...]
  }
}
```

**Score**: 0–1 (multiply by 100 for 0–100 scale).
- **0.9–1.0** (90–100): Green (Fast).
- **0.5–0.89** (50–89): Orange (Average).
- **0–0.49** (0–49): Red (Slow).

### Audit details

```json
{
  "audits": {
    "first-contentful-paint": {
      "title": "First Contentful Paint",
      "description": "...",
      "score": 0.85,
      "scoreDisplayMode": "numeric",
      "numericValue": 1200,
      "numericUnit": "millisecond",
      "displayValue": "1.2 s"
    }
  }
}
```

### Key performance metrics (Core Web Vitals)

```json
{
  "audits": {
    "largest-contentful-paint": {
      "numericValue": 2500,
      "numericUnit": "millisecond",
      "displayValue": "2.5 s"
    },
    "cumulative-layout-shift": {
      "numericValue": 0.05,
      "numericUnit": "unitless",
      "displayValue": "0.05"
    },
    "total-blocking-time": {
      "numericValue": 150,
      "numericUnit": "millisecond",
      "displayValue": "150 ms"
    }
  }
}
```

## Common Use Cases

### Quick desktop audit

```bash
docker run --rm \
  -v "$(pwd)/results:/results" \
  femtopixel/google-lighthouse:latest \
  https://example.com \
  --output=html \
  --output-path=/results/report.html
```

Open `results/report.html` in a browser for an interactive dashboard.

### Mobile performance test

```bash
docker run --rm \
  -v "$(pwd)/results:/results" \
  femtopixel/google-lighthouse:latest \
  https://example.com \
  --output=json \
  --output-path=/results/mobile.json \
  --emulated-form-factor=mobile \
  --throttling-method=simulate \
  --only-categories=performance
```

### Accessibility-focused audit

```bash
docker run --rm \
  -v "$(pwd)/results:/results" \
  femtopixel/google-lighthouse:latest \
  https://example.com \
  --output=json \
  --output-path=/results/a11y.json \
  --only-categories=accessibility
```

### Batch audit (multiple URLs)

```bash
#!/bin/bash
for url in https://example.com https://example.com/about https://example.com/contact; do
  docker run --rm \
    -v "$(pwd)/results:/results" \
    femtopixel/google-lighthouse:latest \
    "$url" \
    --output=json \
    --output-path="/results/$(echo $url | md5sum | cut -d' ' -f1).json"
done
```

### Authenticated page audit (with bearer token)

```bash
docker run --rm \
  -v "$(pwd)/results:/results" \
  femtopixel/google-lighthouse:latest \
  https://api.example.com/authenticated-page \
  --output=json \
  --output-path=/results/auth.json \
  --extra-headers='{"Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."}'
```

## Score Interpretation

### Performance Score Thresholds

| Score | Status | Metric |
|-------|--------|--------|
| 90–100 | Green | Good |
| 50–89 | Orange | Needs improvement |
| 0–49 | Red | Poor |

Performance score is weighted by metrics:

- **First Contentful Paint (FCP)**: 10%
- **Speed Index (SI)**: 10%
- **Largest Contentful Paint (LCP)**: 25%
- **Time to Interactive (TTI)**: 10%
- **Total Blocking Time (TBT)**: 30%
- **Cumulative Layout Shift (CLS)**: 15%

### Accessibility Issues (Audit Results)

- **Error**: Must fix (fails WCAG 2.1 AA).
- **Warning**: Review manually (potential issues).
- **Notice**: Informational (passed but review recommended).

### SEO Checklist

- Mobile-friendliness (viewport, font size, tap targets).
- Crawlability (robots.txt, sitemap, indexing directives).
- Structured data (schema.org JSON-LD).
- HTTPS (security).

## Troubleshooting

### Error: `chrome crashed`

**Cause**: Chromium crashed due to resource limits or sandbox issues.

**Fix**: Add `--disable-dev-shm-usage` flag:

```bash
docker run --rm \
  -v "$(pwd)/results:/results" \
  femtopixel/google-lighthouse:latest \
  https://example.com \
  --output=json \
  --output-path=/results/report.json \
  --chrome-flags="--headless --no-sandbox --disable-dev-shm-usage"
```

Or increase Docker memory:

```bash
docker run --rm -m 2g \
  -v "$(pwd)/results:/results" \
  femtopixel/google-lighthouse:latest \
  https://example.com \
  --output=json \
  --output-path=/results/report.json
```

### Error: `ECONNREFUSED`

**Cause**: URL unreachable from container.

**Fix**: Ensure URL is publicly accessible or add `--network host`:

```bash
docker run --rm --network host \
  -v "$(pwd)/results:/results" \
  femtopixel/google-lighthouse:latest \
  http://localhost:3000 \
  --output=json \
  --output-path=/results/report.json
```

### Warning: `SLOW_PAGE_LOAD`

**Cause**: Page took >30s to load.

**Fix**: Increase timeout:

```bash
docker run --rm \
  -v "$(pwd)/results:/results" \
  femtopixel/google-lighthouse:latest \
  https://example.com \
  --output=json \
  --output-path=/results/report.json \
  --max-wait-for-load=60000
```

### Performance scores differ between runs

**Cause**: Network and browser timing variability.

**Fix**: Run multiple times and average; use throttling for consistency:

```bash
for i in {1..3}; do
  docker run --rm \
    -v "$(pwd)/results:/results" \
    femtopixel/google-lighthouse:latest \
    https://example.com \
    --output=json \
    --output-path="/results/run-$i.json" \
    --throttling-method=simulate
done
```

Then compute median scores from the three runs.

## Parsing JSON Output

### Extract overall score

```bash
jq '.categories.performance.score * 100 | round' report.json
```

### Extract all audit scores

```bash
jq '.categories[] | {(.title): (.score * 100 | round)}' report.json
```

### Extract specific metrics

```bash
jq '.audits | {
  fcp: .first-contentful-paint.numericValue,
  lcp: .largest-contentful-paint.numericValue,
  cls: .cumulative-layout-shift.numericValue,
  tbt: .total-blocking-time.numericValue
}' report.json
```

### Find all failing audits

```bash
jq '.audits[] | select(.score == 0 or .score == null) | {title, description}' report.json
```

## Web Vitals Reference

| Metric | Good | Needs Improvement | Poor |
|--------|------|-------------------|------|
| LCP (Largest Contentful Paint) | ≤2.5s | 2.5–4.0s | >4.0s |
| FID (First Input Delay) | ≤100ms | 100–300ms | >300ms |
| CLS (Cumulative Layout Shift) | ≤0.1 | 0.1–0.25 | >0.25 |
| TTFB (Time to First Byte) | ≤600ms | 600–1800ms | >1800ms |
| FCP (First Contentful Paint) | ≤1.8s | 1.8–3.0s | >3.0s |

## Resources

- **Web Vitals Guide**: https://web.dev/vitals/
- **Lighthouse Scoring**: https://developer.chrome.com/docs/lighthouse/performance/scoring/
- **Accessibility Guidelines**: https://www.w3.org/WAI/WCAG21/quickref/
