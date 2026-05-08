# Wappalyzer — Technology Detection

## Official Documentation

- **Official Site**: https://www.wappalyzer.com/
- **GitHub**: https://github.com/AliasIO/wappalyzer
- **NPM Package**: https://www.npmjs.com/package/wappalyzer-cli
- **Technology Database**: https://www.wappalyzer.com/technologies (2000+ detectable technologies)

## Overview

Wappalyzer is an open-source technology detection engine that:

- **Identifies** JavaScript frameworks, CMS platforms, CDNs, analytics tools, etc.
- **Detects** 2000+ technologies across 80+ categories.
- **Reports** confidence scores (0–100%) for each detection.
- **Outputs** JSON, CSV, or CLI format.
- **Works** on any accessible website.

Common detections:

- **JavaScript Frameworks**: React, Vue.js, Angular, Next.js, Nuxt, Svelte, Gatsby.
- **CMS**: WordPress, Drupal, Joomla, Wix, Shopify.
- **Backend**: Node.js, Django, Ruby on Rails, Laravel, Spring Boot.
- **Databases**: PostgreSQL, MySQL, MongoDB, Redis.
- **CDNs & Hosting**: Cloudflare, Akamai, AWS, Vercel.
- **Analytics**: Google Analytics, Mixpanel, Segment.
- **Payment**: Stripe, PayPal, Square.
- **Monitoring**: Sentry, New Relic, Datadog.

## Docker Image

**Options**:
1. Use `node:20-alpine` + `npm install -g wappalyzer-cli` on-the-fly.
2. Custom Docker image for repeated use.

### Quick run

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g wappalyzer-cli && \
    wappalyzer https://example.com --format json'
```

## Running Wappalyzer

### Minimal example (JSON)

```bash
docker run --rm \
  -v "$(pwd)/tech-results:/results" \
  node:20-alpine \
  sh -c 'npm install -g wappalyzer-cli && \
    wappalyzer https://example.com --format json > /results/tech.json'
```

**Output**: JSON array of detected technologies.

### JSON with delay (for JS-heavy sites)

```bash
docker run --rm \
  -v "$(pwd)/tech-results:/results" \
  node:20-alpine \
  sh -c 'npm install -g wappalyzer-cli && \
    wappalyzer https://example.com \
      --format json \
      --delay=1000 > /results/tech.json'
```

### CSV output

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g wappalyzer-cli && \
    wappalyzer https://example.com --format csv'
```

## Flags Reference

### Output Options

- **`--format=json`** — JSON format (machine-readable, default).
- **`--format=csv`** — CSV format (spreadsheet-friendly).
- **`--format=text`** — Plain text (human-readable).
- **`--format=html`** — HTML report (visual).

### Request Options

- **`--delay=1000`** — delay before scanning (ms) for JS-rendered content.
- **`--timeout=30`** — request timeout in seconds.
- **`--headers='User-Agent: Custom'`** — custom headers.

### Other Options

- **`--max-attempts=3`** — retries for failed requests.
- **`--user-agent=<string>`** — custom User-Agent.
- **`--recursive`** — scan multiple pages (slow).

## Output Format (JSON)

```json
{
  "url": "https://example.com",
  "technologies": [
    {
      "slug": "react",
      "name": "React",
      "confidence": 100,
      "version": "18.2.0",
      "icon": "React.svg",
      "website": "https://reactjs.org",
      "category": {
        "id": 18,
        "name": "JavaScript frameworks",
        "slug": "javascript-frameworks"
      },
      "cpe": "cpe:/a:facebook:react:18.2.0"
    },
    {
      "slug": "next.js",
      "name": "Next.js",
      "confidence": 100,
      "version": "13.4.0",
      "icon": "Next.js.svg",
      "website": "https://nextjs.org",
      "category": {
        "id": 18,
        "name": "JavaScript frameworks",
        "slug": "javascript-frameworks"
      }
    },
    {
      "slug": "google-analytics",
      "name": "Google Analytics",
      "confidence": 95,
      "version": "4",
      "icon": "Google Analytics.svg",
      "website": "https://analytics.google.com",
      "category": {
        "id": 74,
        "name": "Analytics",
        "slug": "analytics"
      }
    }
  ]
}
```

### Field meanings

- **`slug`**: Unique identifier for the technology.
- **`name`**: Human-readable name.
- **`confidence`**: Detection confidence (0–100%). Higher = more certain.
- **`version`**: Detected version (null if not detected).
- **`icon`**: Icon filename (used in web UI).
- **`website`**: Official website link.
- **`category`**: Category info (id, name, slug).
- **`cpe`**: CPE (Common Platform Enumeration) identifier for vulnerability tracking.

## Technology Categories

Wappalyzer organizes technologies into 80+ categories:

| Category | Examples |
|----------|----------|
| JavaScript frameworks | React, Vue, Angular, Next.js, Nuxt, Svelte |
| CMS | WordPress, Drupal, Joomla, Wix, Squarespace |
| Web frameworks | Django, Rails, Laravel, Spring, FastAPI |
| Backend languages | Python, Node.js, Java, PHP, Ruby, Go |
| Databases | PostgreSQL, MySQL, MongoDB, Redis, Elasticsearch |
| Message queues | RabbitMQ, Kafka, SQS |
| CDNs | Cloudflare, Akamai, AWS CloudFront, Fastly |
| Hosting | AWS, Azure, Google Cloud, Heroku, Vercel, Netlify |
| Analytics | Google Analytics, Mixpanel, Amplitude, Segment |
| Payment gateways | Stripe, PayPal, Square, Braintree |
| Monitoring | Sentry, New Relic, Datadog, Splunk |
| Error tracking | Sentry, Bugsnag, Rollbar, Raygun |
| Performance monitoring | APM tools, RUM (Real User Monitoring) |
| A/B testing | Optimizely, VWO, Convert |
| Ad networks | Google AdSense, Criteo, AdRoll |
| Font delivery | Google Fonts, Typekit, Fonts.com |
| Maps | Google Maps, Mapbox, Leaflet |
| Video | YouTube, Vimeo, Wistia, JW Player |

## Common Use Cases

### Quick tech stack check

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g wappalyzer-cli && \
    wappalyzer https://example.com --format json'
```

### Save to file

```bash
docker run --rm \
  -v "$(pwd)/results:/results" \
  node:20-alpine \
  sh -c 'npm install -g wappalyzer-cli && \
    wappalyzer https://example.com --format json > /results/tech.json'
```

### CSV export for spreadsheet

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g wappalyzer-cli && \
    wappalyzer https://example.com --format csv' > tech-stack.csv
```

### Wait for JS-heavy sites (SPA)

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g wappalyzer-cli && \
    wappalyzer https://spa-app.example.com \
      --delay=2000 \
      --format json'
```

### Batch scan multiple sites

```bash
#!/bin/bash
URLS=("https://example.com" "https://competitor1.com" "https://competitor2.com")

for url in "${URLS[@]}"; do
  echo "Scanning $url..."
  docker run --rm \
    -v "$(pwd)/results:/results" \
    node:20-alpine \
    sh -c "npm install -g wappalyzer-cli && \
      wappalyzer '$url' --format json > /results/$(echo $url | md5sum | cut -d' ' -f1).json"
done
```

### Custom headers (auth)

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g wappalyzer-cli && \
    wappalyzer https://api.example.com \
      --headers="Authorization: Bearer TOKEN" \
      --format json'
```

## Parsing JSON Output

### List all detected technologies

```bash
jq '.technologies[] | "\(.name) (\(.version // "unknown"))"' tech.json
```

### Extract only frameworks

```bash
jq '.technologies[] | select(.category.name == "JavaScript frameworks")' tech.json
```

### Get high-confidence detections only

```bash
jq '.technologies[] | select(.confidence >= 90)' tech.json
```

### Count by category

```bash
jq 'group_by(.category.name) | map({category: .[0].category.name, count: length})' tech.json
```

### Find all technologies with versions

```bash
jq '.technologies[] | select(.version != null) | {name, version}' tech.json
```

## Output Interpretation

### Confidence Scores

- **100%**: Definite detection (e.g., `<meta name="generator" content="WordPress">`).
- **90–99%**: Very high confidence (multiple indicators).
- **50–89%**: Medium confidence (one or two indicators).
- **< 50%**: Low confidence (possible false positive).

### Version Detection

- **Exact version**: Usually from `meta` tags, headers, or JavaScript globals.
- **Major version**: Inferred from API or feature detection.
- **null**: Version not detected.

## Common False Positives & Negatives

### False Positives

**Example**: Detecting old jQuery when site uses Preact.

**Cause**: Old libraries included but not actively used.

**Mitigation**: Check confidence scores, combine with manual inspection.

### False Negatives

**Example**: Missing React detection on SPA without JS bundle analysis.

**Cause**: Technologies injected dynamically or obfuscated.

**Mitigation**: Use `--delay` to allow JS execution.

## Troubleshooting

### Error: `Error: Failed to fetch URL`

**Cause**: URL unreachable from container.

**Fix**: Verify URL is publicly accessible:

```bash
docker run --rm alpine:latest \
  sh -c 'apk add curl && curl -I https://example.com'
```

### No technologies detected

**Cause**: Either site uses custom tech stack or site requires JS execution.

**Fix**: Add delay:

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g wappalyzer-cli && \
    wappalyzer https://example.com \
      --delay=2000 \
      --format json'
```

Or the site may genuinely use custom/unusual tech.

### Memory issues with recursive scan

**Cause**: `--recursive` flag causes excessive requests.

**Fix**: Avoid `--recursive` or limit to smaller sites:

```bash
docker run --rm -m 1g \
  node:20-alpine \
  sh -c 'npm install -g wappalyzer-cli && \
    wappalyzer https://example.com --format json'
```

## Integration with CI/CD

### GitHub Actions

```yaml
- name: Detect technologies
  run: |
    docker run --rm \
      -v "${{ github.workspace }}/results:/results" \
      node:20-alpine \
      sh -c 'npm install -g wappalyzer-cli && \
        wappalyzer ${{ env.TARGET_URL }} --format json > /results/tech.json'

- name: Check for vulnerable dependencies
  run: |
    jq '.technologies[] | select(.name | test("jQuery|moment|lodash")) | select(.version != null)' results/tech.json | \
    while read -r tech; do
      echo "Checking for CVEs: $(echo $tech | jq -r '.name + " " + .version')"
      # Optional: Call external CVE database
    done
```

## Technology Database Reference

The complete Wappalyzer technology database is available at:

- **Web UI**: https://www.wappalyzer.com/technologies
- **JSON Format**: https://github.com/AliasIO/wappalyzer/blob/master/src/technologies.json (2000+ entries)

## Resources

- **Wappalyzer Official**: https://www.wappalyzer.com/
- **GitHub**: https://github.com/AliasIO/wappalyzer
- **Technology Database**: https://www.wappalyzer.com/technologies
- **npm**: https://www.npmjs.com/package/wappalyzer-cli
- **CPE Reference**: https://nvd.nist.gov/products/cpe/
