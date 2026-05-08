# sitespeed.io — Real User Metrics & Performance Dashboard

## Official Documentation

- **sitespeed.io**: https://www.sitespeed.io/
- **GitHub**: https://github.com/sitespeedio/sitespeed.io
- **Docker Hub**: https://hub.docker.com/r/sitespeedio/sitespeed.io
- **Connectivity Profiles**: https://www.sitespeed.io/documentation/throttle/
- **Metrics Guide**: https://www.sitespeed.io/documentation/metrics/

## Overview

sitespeed.io is an open-source performance measurement tool that:

- Measures **real user metrics** (TTFB, FCP, LCP, CLS, TBT, SpeedIndex).
- Captures **video** of page rendering (optional).
- Analyzes **waterfall** of resource loading.
- Supports **multi-run** stability analysis (min/max/median).
- Generates **interactive HTML dashboard**.
- Simulates **network connectivity** (3G, 4G, LTE).
- Supports **budget** enforcement (fail if metrics exceed thresholds).

## Docker Image

**Official image**: `sitespeedio/sitespeed.io:latest`

Large image (~1GB) includes Chromium, FFmpeg (for video), and all Node.js dependencies.

## Running sitespeed.io

### Minimal example (single run, HTML dashboard)

```bash
docker run --rm \
  -v "$(pwd)/sitespeed-results:/sitespeed.io" \
  sitespeedio/sitespeed.io:latest \
  https://example.com
```

**Output**: Interactive HTML dashboard at `sitespeed-results/index.html`.

### Desktop performance test (3 runs)

```bash
docker run --rm \
  -v "$(pwd)/sitespeed-results:/sitespeed.io" \
  sitespeedio/sitespeed.io:latest \
  https://example.com \
  --n=3 \
  --outputFormat=json
```

**Output**: HTML dashboard + JSON results in `sitespeed-results/pages/`.

### Mobile 4G test with visual metrics

```bash
docker run --rm \
  -v "$(pwd)/sitespeed-results:/sitespeed.io" \
  sitespeedio/sitespeed.io:latest \
  https://example.com \
  --n=3 \
  --emulateDevices.type=phone \
  --connectivity.profile=4g \
  --visualMetrics \
  --outputFormat=json
```

## Flags Reference

### Number of Runs & Device

- **`--n=1`** — number of runs (default: 1).
- **`--n=3`** — run 3 times, report min/max/median.
- **`--n=5`** — more runs = more stable results (slower).
- **`--browsers=chrome`** — browser (default: Chrome).
- **`--emulateDevices.type=phone`** — mobile device emulation.
- **`--emulateDevices.type=tablet`** — tablet emulation.

### Connectivity Simulation

- **`--connectivity.profile=native`** — no throttling (default).
- **`--connectivity.profile=3g`** — 3G throttle (TTFB 500ms, latency 400ms).
- **`--connectivity.profile=4g`** — 4G throttle (TTFB 50ms, latency 150ms).
- **`--connectivity.profile=lte`** — LTE throttle (high speed).
- **`--connectivity.profile=2g`** — 2G throttle (slow, for testing resilience).
- **`--connectivity.engine=tc`** — use Linux tc (traffic control) for throttling.

### Metrics & Capture

- **`--visualMetrics`** — compute visual metrics (First Visual Change, Speed Index, etc.).
- **`--video`** — capture video of rendering (disk-intensive, slow).
- **`--video=false`** — disable video capture (default for large runs).
- **`--screenshotResolution=1920x1080`** — capture at specific resolution.
- **`--delay=1000`** — delay before starting test (ms).
- **`--pageLoadStrategy=none`** — don't wait for page to load (dangerous).
- **`--pageLoadStrategy=normal`** — wait for `load` event (default).
- **`--pageLoadStrategy=eager`** — wait for `DOMContentLoaded` (faster).

### Output & Reporting

- **`--outputFormat=json`** — JSON results (no HTML dashboard).
- **`--outputFormat=html`** — HTML dashboard (default).
- **`--urlAlias=myalias`** — rename URL in results.
- **`--config=/path/to/config.json`** — load configuration from file.

### Advanced Options

- **`--crawler.depth=2`** — crawl N levels deep (default: 1, just the URL).
- **`--crawler.maxPages=10`** — crawl max N pages.
- **`--scriptPath=/path/to/script.cjs`** — run custom script (e.g., login, form submission).
- **`--budget=/path/to/budget.json`** — enforce performance budget (fail if metrics exceed).
- **`--har`** — generate HAR (HTTP Archive) file.
- **`--gpsi.key=API_KEY`** — upload to Google PageSpeed Insights.

## Output Format (JSON)

### Directory structure

```
sitespeed-results/
├── index.html
├── pages/
│   └── example-com/
│       ├── index.json
│       ├── browsertime.json
│       ├── visualmetrics.json
│       └── screenshots/
│           ├── 1.png
│           ├── 2.png
│           └── final.png
└── data/
    └── browsertime.json (aggregated)
```

### Metrics in JSON (browsertime.json)

```json
{
  "browser": "chrome",
  "url": "https://example.com",
  "runs": [
    {
      "timings": {
        "timeToFirstByte": 240,
        "firstPaint": 1200,
        "firstContentfulPaint": 1250,
        "largestContentfulPaint": 2500,
        "cumulativeLayoutShift": 0.05,
        "totalBlockingTime": 150,
        "speedIndex": 2000
      },
      "fullyLoaded": 3500,
      "rumSpeedIndex": 1950,
      "pageLoadTime": 3500
    }
  ],
  "statistics": {
    "timings": {
      "timeToFirstByte": {
        "mean": 240,
        "median": 240,
        "min": 235,
        "max": 245,
        "p99": 245
      }
    }
  }
}
```

## Common Use Cases

### Quick desktop performance check

```bash
docker run --rm \
  -v "$(pwd)/results:/sitespeed.io" \
  sitespeedio/sitespeed.io:latest \
  https://example.com
```

Open `results/index.html` in browser for dashboard.

### Mobile 4G 3-run stability test

```bash
docker run --rm \
  -v "$(pwd)/results:/sitespeed.io" \
  sitespeedio/sitespeed.io:latest \
  https://example.com \
  --n=3 \
  --emulateDevices.type=phone \
  --connectivity.profile=4g \
  --visualMetrics
```

### Slow network resilience test (2G)

```bash
docker run --rm \
  -v "$(pwd)/results:/sitespeed.io" \
  sitespeedio/sitespeed.io:latest \
  https://example.com \
  --connectivity.profile=2g \
  --video
```

### Batch test multiple URLs

```bash
for url in https://example.com https://example.com/about https://example.com/contact; do
  docker run --rm \
    -v "$(pwd)/results:/sitespeed.io" \
    sitespeedio/sitespeed.io:latest \
    "$url" \
    --n=3 \
    --outputFormat=json \
    --urlAlias="$(echo $url | cut -d'/' -f3)"
done
```

### Performance budget enforcement

Create `budget.json`:

```json
{
  "timings": {
    "pageLoadTime": {
      "budget": 3000
    },
    "firstContentfulPaint": {
      "budget": 1500
    },
    "largestContentfulPaint": {
      "budget": 2500
    }
  }
}
```

Then run:

```bash
docker run --rm \
  -v "$(pwd):/work" \
  sitespeedio/sitespeed.io:latest \
  https://example.com \
  --budget=/work/budget.json
```

Fails with exit code 1 if any metric exceeds budget.

### Crawl entire site (depth 2)

```bash
docker run --rm \
  -v "$(pwd)/results:/sitespeed.io" \
  sitespeedio/sitespeed.io:latest \
  https://example.com \
  --crawler.depth=2 \
  --crawler.maxPages=20
```

## Connectivity Profiles Detail

### 3G Profile

- **Download**: 400 kbps
- **Upload**: 300 kbps
- **Latency**: 400 ms
- **Use case**: Testing on slower networks (emerging markets).

### 4G Profile

- **Download**: 4 Mbps
- **Upload**: 3 Mbps
- **Latency**: 50 ms
- **Use case**: Testing on modern mobile networks.

### LTE Profile

- **Download**: 10 Mbps
- **Upload**: 8 Mbps
- **Latency**: 20 ms
- **Use case**: Testing on high-speed mobile.

### Native (No throttle)

- **Network**: Full local network speed.
- **Use case**: Baseline performance testing, CI/CD.

## Troubleshooting

### Error: `Failed to launch browser`

**Cause**: Chromium missing or sandbox issue.

**Fix**: Use official image + check Docker memory:

```bash
docker run --rm -m 2g \
  -v "$(pwd)/results:/sitespeed.io" \
  sitespeedio/sitespeed.io:latest \
  https://example.com
```

### Video capture fails

**Cause**: FFmpeg missing or video encoding error.

**Fix**: Disable video or ensure sufficient disk space:

```bash
docker run --rm \
  -v "$(pwd)/results:/sitespeed.io" \
  sitespeedio/sitespeed.io:latest \
  https://example.com \
  --video=false
```

### Connectivity throttling not applied

**Cause**: Docker host not supporting tc (Linux traffic control) or connectivity engine mismatch.

**Fix**: Use explicit engine:

```bash
docker run --rm --network host \
  -v "$(pwd)/results:/sitespeed.io" \
  sitespeedio/sitespeed.io:latest \
  https://example.com \
  --connectivity.profile=4g \
  --connectivity.engine=tc
```

Or disable throttling if testing host-level performance:

```bash
docker run --rm \
  -v "$(pwd)/results:/sitespeed.io" \
  sitespeedio/sitespeed.io:latest \
  https://example.com \
  --connectivity.profile=native
```

### Run takes too long (many pages)

**Cause**: Crawling many pages, each with N runs.

**Fix**: Reduce runs or limit crawl:

```bash
docker run --rm \
  -v "$(pwd)/results:/sitespeed.io" \
  sitespeedio/sitespeed.io:latest \
  https://example.com \
  --n=1 \
  --crawler.maxPages=5
```

## Parsing JSON Results

### Extract mean FCP

```bash
jq '.statistics.timings.firstContentfulPaint.mean' results/data/browsertime.json
```

### Extract median LCP

```bash
jq '.statistics.timings.largestContentfulPaint.median' results/data/browsertime.json
```

### Compare runs (min/max/median)

```bash
jq '.statistics.timings | keys[] as $metric | {($metric): .[$metric] | {min, median, max}}' results/data/browsertime.json
```

## Integration with CI/CD

### GitHub Actions

```yaml
- name: Run sitespeed.io performance test
  run: |
    docker run --rm \
      -v "${{ github.workspace }}/results:/sitespeed.io" \
      sitespeedio/sitespeed.io:latest \
      ${{ env.TARGET_URL }} \
      --n=3 \
      --outputFormat=json

- name: Check performance budget
  run: |
    FCP=$(jq '.statistics.timings.firstContentfulPaint.median' results/data/browsertime.json)
    if [ "$FCP" -gt 1500 ]; then
      echo "FCP too slow: ${FCP}ms (budget: 1500ms)"
      exit 1
    fi
```

## Resources

- **Web Vitals**: https://web.dev/vitals/
- **Connectivity Profiles**: https://www.sitespeed.io/documentation/throttle/
- **Metrics Documentation**: https://www.sitespeed.io/documentation/metrics/
- **Budget Configuration**: https://www.sitespeed.io/documentation/budget/
- **Video Analysis**: https://www.sitespeed.io/documentation/video-analysis/
