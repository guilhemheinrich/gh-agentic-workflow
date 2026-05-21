# Combined Analysis — Run All Tools

## Sequential Script

Build the bundled image once before running the script:

```bash
docker build -t web-analysis /path/to/skills/web-analysis/
```

Save as `run-all-analysis.sh` at the project root:

```bash
#!/bin/bash
TARGET_URL="${1:-https://example.com}"
OUTPUT_DIR="./web-analysis-results"
IMAGE="${WEB_ANALYSIS_IMAGE:-web-analysis}"

mkdir -p "$OUTPUT_DIR"/{lighthouse,pa11y,axe,links,html,security,tech}

echo "▶ Lighthouse (performance + SEO + a11y)..."
docker run --rm -v "$OUTPUT_DIR/lighthouse:/results" \
  femtopixel/google-lighthouse:latest "$TARGET_URL" \
  --output=json --output-path=/results/report.json \
  --chrome-flags="--headless --no-sandbox"

echo "▶ pa11y (accessibility WCAG 2.1 AA)..."
docker run --rm -v "$OUTPUT_DIR/pa11y:/results" "$IMAGE" \
  pa11y --runner htmlcs --runner axe --standard=WCAG2AA --reporter json "$TARGET_URL" > "$OUTPUT_DIR/pa11y/report.json"

echo "▶ axe-core CLI (accessibility + contrast)..."
docker run --rm -v "$OUTPUT_DIR/axe:/results" "$IMAGE" \
  axe "$TARGET_URL" \
  --save report.json \
  --dir /results \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage"

echo "▶ broken-link-checker (link integrity)..."
docker run --rm -v "$OUTPUT_DIR/links:/results" node:22-alpine \
  sh -c "npm install -g broken-link-checker 2>/dev/null && blc -r \"$TARGET_URL\" > /results/report.txt 2>&1"

echo "▶ html-validate (W3C HTML)..."
docker run --rm -v "$OUTPUT_DIR/html:/results" node:22-alpine \
  sh -c "npm install -g html-validate 2>/dev/null && html-validate \"$TARGET_URL\" --format json > /results/report.json 2>&1 || true"

echo "▶ Wappalyzer (technology detection)..."
docker run --rm -v "$OUTPUT_DIR/tech:/results" node:22-alpine \
  sh -c "npm install -g wappalyzer-cli 2>/dev/null && wappalyzer \"$TARGET_URL\" --format json > /results/tech.json 2>&1 || true"

echo "▶ Security headers..."
docker run --rm -v "$OUTPUT_DIR/security:/results" alpine:latest \
  sh -c "apk add --no-cache curl >/dev/null 2>&1 && curl -s -I -H 'User-Agent: Mozilla/5.0' \"$TARGET_URL\" > /results/headers.txt"

echo ""
echo "✓ All tools completed. Results in: $OUTPUT_DIR/"
ls -la "$OUTPUT_DIR"/*/
```

## Docker Compose

```yaml
version: '3.8'

x-common: &common
  restart: "no"

services:
  lighthouse:
    <<: *common
    image: femtopixel/google-lighthouse:latest
    volumes:
      - ./results/lighthouse:/results
    command:
      - "${TARGET_URL:-https://example.com}"
      - "--output=json"
      - "--output-path=/results/report.json"
      - "--chrome-flags=--headless --no-sandbox"

  sitespeed:
    <<: *common
    image: sitespeedio/sitespeed.io:latest
    volumes:
      - ./results/sitespeed:/sitespeed.io
    command:
      - "${TARGET_URL:-https://example.com}"
      - "--n=1"
      - "--outputFormat=json"

  pa11y:
    <<: *common
    image: web-analysis
    volumes:
      - ./results/pa11y:/results
    command: >
      sh -c "pa11y
             --runner htmlcs
             --runner axe
             --standard=WCAG2AA
             --reporter json
             ${TARGET_URL:-https://example.com} > /results/report.json"

  axe:
    <<: *common
    image: web-analysis
    volumes:
      - ./results/axe:/results
    command:
      - "axe"
      - "${TARGET_URL:-https://example.com}"
      - "--save"
      - "report.json"
      - "--dir"
      - "/results"
      - "--chromedriver-path"
      - "/usr/bin/chromedriver"
      - "--chrome-path"
      - "/usr/bin/chromium-browser"
      - "--chrome-options=no-sandbox,disable-dev-shm-usage"

  links:
    <<: *common
    image: node:22-alpine
    volumes:
      - ./results/links:/results
    command: >
      sh -c "npm install -g broken-link-checker 2>/dev/null &&
             blc -r ${TARGET_URL:-https://example.com} > /results/report.txt 2>&1"

  security:
    <<: *common
    image: alpine:latest
    volumes:
      - ./results/security:/results
    command: >
      sh -c "apk add --no-cache curl >/dev/null 2>&1 &&
             curl -s -I ${TARGET_URL:-https://example.com} > /results/headers.txt"
```

Usage :

```bash
TARGET_URL=https://example.com docker compose up --abort-on-container-exit
```

## Output Structure

```
web-analysis-results/
├── lighthouse/
│   └── report.json       # Scores + audits détaillés
├── pa11y/
│   └── report.json       # Violations WCAG
├── axe/
│   └── report.json       # Violations axe-core + contraste
├── links/
│   └── report.txt        # Liens cassés
├── html/
│   └── report.json       # Erreurs HTML
├── security/
│   └── headers.txt       # En-têtes HTTP bruts
├── tech/
│   └── tech.json         # Technologies détectées
└── sitespeed/            # (si docker-compose)
    └── index.html        # Dashboard interactif
```
