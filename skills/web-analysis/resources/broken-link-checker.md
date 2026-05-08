# broken-link-checker — Link Integrity Auditing

## Official Documentation

- **GitHub**: https://github.com/stevenvachon/broken-link-checker
- **npm**: https://www.npmjs.com/package/broken-link-checker
- **Command-line Tool**: https://www.npmjs.com/package/broken-link-checker-cli

## Overview

broken-link-checker (blc) is a CLI tool that:

- **Crawls** websites and validates every link.
- **Reports** broken links (404, 500, timeout, refused connection).
- **Supports** internal & external links.
- **Filters** by status (errors only, warnings, all).
- **Outputs** JSON, text, or custom formats.
- **Excludes** patterns (e.g., admin pages, logout URLs).
- **Handles** redirects, authentication, custom headers.

## Docker Image

**Options**:
1. Use the bundled `web-analysis` image (includes blc pre-installed).
2. Use `node:20-alpine` + `npm install -g broken-link-checker` on-the-fly.

### Using bundled web-analysis image

```bash
docker build -t web-analysis /path/to/.agents/skills/web-analysis/
```

Then:

```bash
docker run --rm web-analysis blc https://example.com --help
```

## Running broken-link-checker

### Single page (non-recursive)

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g broken-link-checker && \
    blc https://example.com'
```

**Output**: Console report of links on that page.

### Recursive crawl with JSON

```bash
docker run --rm \
  -v "$(pwd)/link-results:/results" \
  node:20-alpine \
  sh -c 'npm install -g broken-link-checker && \
    blc -r https://example.com --format json > /results/links.json'
```

**Output**: JSON file with all crawled pages and their links.

### Recursive crawl with exclusions

```bash
docker run --rm \
  -v "$(pwd)/link-results:/results" \
  node:20-alpine \
  sh -c 'npm install -g broken-link-checker && \
    blc -r https://example.com \
      --exclude=admin,logout,/internal/ \
      --filter-level=2 \
      --format json > /results/links.json'
```

## Flags Reference

### Crawling Options

- **`-r`** / **`--recursive`** — crawl all reachable pages (default: single page only).
- **`--follow-refuse-redirect`** — follow redirects that are refused (may cause issues; use carefully).
- **`--exclude=<regex>`** — exclude URLs matching regex (e.g., `admin`, `/logout`, `^/internal`).
- **`--exclude=admin,logout`** — multiple patterns (comma-separated).
- **`--include=<regex>`** — only include URLs matching regex.
- **`--filter-level=1`** — report errors only (default).
- **`--filter-level=2`** — report errors and warnings.
- **`--filter-level=3`** — report all links (errors, warnings, notices).

### Request Options

- **`--timeout=10`** — request timeout in seconds (default: 0, no timeout).
- **`--max-connections=10`** — max concurrent requests (default: 10).
- **`--max-connections-per-host=5`** — max per host.
- **`--headers='Authorization: Bearer TOKEN'`** — custom headers.
- **`--user-agent=<string>`** — custom User-Agent.

### Output Options

- **`--format=json`** — JSON output.
- **`--format=text`** — plain text (default).
- **`--format=markdown`** — Markdown table.
- **`--ordered-list`** — output broken links as ordered list.

## Output Format (JSON)

```json
{
  "link": {
    "url": "https://example.com",
    "statusCode": 200,
    "status": "GOOD"
  },
  "pages": [
    {
      "url": "https://example.com",
      "status": "GOOD",
      "links": [
        {
          "url": "https://example.com/about",
          "statusCode": 200,
          "status": "GOOD",
          "external": false
        },
        {
          "url": "https://broken-link.example.com",
          "statusCode": null,
          "status": "BROKEN",
          "reason": "Error: connect ECONNREFUSED",
          "external": false
        },
        {
          "url": "https://external-site.com",
          "statusCode": 404,
          "status": "BROKEN",
          "external": true
        }
      ]
    }
  ]
}
```

### Link status values

| Status | Meaning | HTTP Code |
|--------|---------|-----------|
| `GOOD` | Link is valid and reachable | 200–399 |
| `BROKEN` | Link is invalid (404, 500, timeout, connection refused) | 400+, null |
| `EXCLUDED` | Link matched exclusion pattern | — |

### Reasons for BROKEN status

- **`Error: connect ECONNREFUSED`** — server refused connection (port not open).
- **`Error: getaddrinfo ENOTFOUND`** — DNS resolution failed (domain doesn't exist).
- **`Error: 404 Not Found`** — page doesn't exist.
- **`Error: 500 Internal Server Error`** — server error.
- **`Error: Timeout`** — request took too long.
- **`Error: redirect loop detected`** — circular redirects.

## Common Use Cases

### Crawl entire site, report errors only

```bash
docker run --rm \
  -v "$(pwd)/results:/results" \
  node:20-alpine \
  sh -c 'npm install -g broken-link-checker && \
    blc -r https://example.com \
      --filter-level=1 \
      --format json > /results/broken-links.json'
```

### Exclude admin area and save to file

```bash
docker run --rm \
  -v "$(pwd)/results:/results" \
  node:20-alpine \
  sh -c 'npm install -g broken-link-checker && \
    blc -r https://example.com \
      --exclude=/admin,logout \
      --timeout=15 \
      --format json > /results/links.json'
```

### Scan with authentication

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g broken-link-checker && \
    blc -r https://api.example.com \
      --headers="Authorization: Bearer TOKEN" \
      --format json'
```

### Batch scan multiple domains

```bash
#!/bin/bash
DOMAINS=("https://site1.com" "https://site2.com" "https://site3.com")

for domain in "${DOMAINS[@]}"; do
  echo "Scanning $domain..."
  docker run --rm \
    -v "$(pwd)/results:/results" \
    node:20-alpine \
    sh -c "npm install -g broken-link-checker && \
      blc -r '$domain' \
        --filter-level=2 \
        --timeout=20 \
        --format json > /results/$(echo $domain | md5sum | cut -d' ' -f1).json"
done
```

### Large site with crawl limits

For large sites, limit crawl to prevent excessive requests:

```bash
docker run --rm \
  -v "$(pwd)/results:/results" \
  node:20-alpine \
  sh -c 'npm install -g broken-link-checker && \
    blc -r https://large-site.com \
      --max-connections=5 \
      --timeout=30 \
      --filter-level=2 \
      --format json > /results/links.json &
    
    # Run in background for 5 minutes, then kill if still running
    sleep 300
    pkill -f "blc -r"'
```

## Exclusion Patterns

Common exclusion patterns:

```bash
# Exclude admin area
--exclude=/admin

# Exclude logout link
--exclude=/logout

# Exclude external CDN
--exclude=https://cdn.example.com

# Multiple exclusions
--exclude=/admin,/logout,/internal

# Exclude all /api/ routes
--exclude=/api/

# Exclude external links
--exclude=external
```

## Troubleshooting

### Error: `Error: connect ECONNREFUSED`

**Cause**: Server not accessible from Docker container (usually localhost).

**Fix**: Use public URL or `--network host`:

```bash
docker run --rm --network host \
  node:20-alpine \
  sh -c 'npm install -g broken-link-checker && \
    blc -r http://localhost:3000 --format json'
```

### Error: `Error: getaddrinfo ENOTFOUND`

**Cause**: DNS resolution failed (domain doesn't exist or network issue).

**Fix**: Verify domain is reachable, check DNS:

```bash
docker run --rm node:20-alpine \
  sh -c 'apk add curl && curl -I https://example.com'
```

### Crawl takes too long

**Cause**: Large site with many pages, slow network, or connection limits.

**Fix**: Add exclusions or increase `--max-connections`:

```bash
blc -r https://example.com \
  --exclude=/admin,/internal \
  --max-connections=20 \
  --timeout=30
```

### Memory issues during large crawl

**Cause**: Docker container out of memory.

**Fix**: Increase Docker memory or run with limits:

```bash
docker run --rm -m 2g \
  -v "$(pwd)/results:/results" \
  node:20-alpine \
  sh -c 'npm install -g broken-link-checker && \
    blc -r https://example.com \
      --max-connections=5 \
      --format json > /results/links.json'
```

### Redirects detected but not followed

**Cause**: `--follow-refuse-redirect` not enabled.

**Fix**: Add flag (use cautiously):

```bash
blc -r https://example.com \
  --follow-refuse-redirect \
  --format json
```

## Parsing JSON Results

### Count broken links

```bash
jq '[.pages[].links[] | select(.status == "BROKEN")] | length' results.json
```

### List all broken external links

```bash
jq '.pages[].links[] | select(.status == "BROKEN" and .external == true) | {url, statusCode, reason}' results.json
```

### Find links with specific status code

```bash
jq '.pages[].links[] | select(.statusCode == 404)' results.json
```

### Summary report

```bash
jq '{
  total: [.pages[].links[]] | length,
  good: [.pages[].links[] | select(.status == "GOOD")] | length,
  broken: [.pages[].links[] | select(.status == "BROKEN")] | length,
  external: [.pages[].links[] | select(.external == true)] | length
}' results.json
```

## Integration with CI/CD

### GitHub Actions

```yaml
- name: Check for broken links
  run: |
    docker run --rm \
      -v "${{ github.workspace }}/results:/results" \
      node:20-alpine \
      sh -c 'npm install -g broken-link-checker && \
        blc -r ${{ env.TARGET_URL }} \
          --filter-level=2 \
          --timeout=30 \
          --format json > /results/links.json'

- name: Fail if broken links found
  run: |
    BROKEN=$(jq '[.pages[].links[] | select(.status == "BROKEN")] | length' results/links.json)
    if [ "$BROKEN" -gt 0 ]; then
      echo "Found $BROKEN broken links"
      jq '.pages[].links[] | select(.status == "BROKEN")' results/links.json
      exit 1
    fi
```

## Resources

- **npm Package**: https://www.npmjs.com/package/broken-link-checker
- **CLI Tool**: https://www.npmjs.com/package/broken-link-checker-cli
- **GitHub**: https://github.com/stevenvachon/broken-link-checker
- **HTTP Status Codes**: https://developer.mozilla.org/en-US/docs/Web/HTTP/Status
