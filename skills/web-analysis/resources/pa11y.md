# pa11y — Automated Accessibility Testing (WCAG 2.1)

## Official Documentation

- **pa11y Official**: https://pa11y.org/
- **GitHub**: https://github.com/pa11y/pa11y
- **WCAG 2.1 Reference**: https://www.w3.org/WAI/WCAG21/quickref/
- **Section 508**: https://www.access-board.gov/ict/

## Overview

pa11y is an open-source automated accessibility testing tool that validates against WCAG 2.1 AA/AAA standards and Section 508 compliance. It runs via Chromium and detects:

- **Contrast issues** (text on background insufficient luminosity).
- **Missing ARIA labels** (screen reader accessibility).
- **Keyboard navigation** (tab order, focus traps).
- **Semantic HTML** (headings, lists, regions).
- **Alternative text** (images, form labels).
- **Page structure** (landmarks, sections).

## Docker Image

**Official image**: `node:20-alpine` + npm `pa11y` package  
**Alternative**: Use the bundled `web-analysis` image (includes pa11y pre-installed).

### Using bundled web-analysis image

If building locally:

```bash
docker build -t web-analysis /path/to/.agents/skills/web-analysis/
```

Then:

```bash
docker run --rm -v "$(pwd)/results:/results" web-analysis \
  pa11y https://example.com
```

## Running pa11y

### Minimal example

```bash
docker run --rm \
  -v "$(pwd)/pa11y-results:/results" \
  node:20-alpine \
  sh -c 'npm install -g pa11y && \
    pa11y https://example.com'
```

**Output**: Console output (list of violations).

### JSON output example

```bash
docker run --rm \
  -v "$(pwd)/pa11y-results:/results" \
  node:20-alpine \
  sh -c 'npm install -g pa11y && \
    pa11y --json https://example.com > /results/report.json'
```

**Output**: `pa11y-results/report.json` — structured violations array.

### WCAG 2.1 AAA compliance check

```bash
docker run --rm \
  -v "$(pwd)/pa11y-results:/results" \
  node:20-alpine \
  sh -c 'npm install -g pa11y && \
    pa11y \
      --standard=WCAG2AAA \
      --wait=1000 \
      --json \
      https://example.com > /results/report.json'
```

## Flags Reference

### Standards

- **`--standard=WCAG2AA`** — WCAG 2.1 Level AA (default, most common).
- **`--standard=WCAG2AAA`** — WCAG 2.1 Level AAA (stricter).
- **`--standard=Section508`** — US Section 508 compliance.

**Difference**: AAA is more strict than AA (e.g., 7:1 contrast for AAA vs 4.5:1 for AA).

### Reporting & Output

- **`--json`** — JSON output.
- **`--reporter=json`** — explicitly set JSON reporter.
- **`--reporter=csv`** — CSV format.
- **`--reporter=cli`** — CLI output (default, human-readable).
- **`--timeout=10`** — request timeout in seconds.
- **`--wait=1000`** — wait (ms) before testing (for JS-rendered content).

### Headless Browser

- **`--chromeLaunchConfig='{"headless":"new"}'`** — modern headless mode.
- **`--chromeLaunchConfig='{"headless":"new","args":["--no-sandbox"]}'`** — headless + no sandbox (Docker-friendly).
- **`--chromeLaunchConfig='{"headless":"new","args":["--disable-dev-shm-usage"]}'`** — disable `/dev/shm` (low-memory environments).

### Ignoring Rules

- **`--ignore=WCAG2AA.Principle1.Guideline1_1_1_Non_text_Content`** — ignore a specific rule.
- **`--ignore=WCAG2AA.Principle1.Guideline1_1_1_Non_text_Content,WCAG2AA.Principle2.Guideline2_1_1_Keyboard`** — multiple rules (comma-separated).

### Other Options

- **`--level=error`** — only report errors (ignore warnings/notices).
- **`--level=warning`** — report errors and warnings.
- **`--level=notice`** — report all issues (default).
- **`--headers='{"Accept-Language":"en-US"}'`** — custom headers.

## Output Format (JSON)

### Top-level structure

```json
{
  "documentTitle": "Example Site",
  "pageUrl": "https://example.com",
  "issues": [
    {
      "code": "WCAG2AAA.Principle1.Guideline1_4_3_C_Luminosity",
      "type": "error",
      "typeCode": 1,
      "message": "Contrast (Minimum): The contrast ratio of 3.5:1 does not meet WCAG AAA standard",
      "context": "<a href=\"#\">low contrast link</a>",
      "selector": "a.weak-link",
      "runner": "axe"
    }
  ],
  "runnerResults": {
    "axe": { "passes": 50, "violations": 5 }
  }
}
```

### Issue types

- **`type: "error"`** — WCAG violation, must fix for compliance.
- **`type: "warning"`** — potential issue, review manually.
- **`type: "notice"`** — informational, pass but consider.
- **`type: "pass"`** — (in results) rule passed (not reported as violation).

### Common error codes

| Code | Issue |
|------|-------|
| `WCAG2AA.Principle1.Guideline1_4_3_C_Luminosity` | Low contrast text |
| `WCAG2AA.Principle2.Guideline2_1_1_Keyboard` | Not keyboard accessible |
| `WCAG2AA.Principle1.Guideline1_1_1_Non_text_Content` | Missing alt text |
| `WCAG2AA.Principle3.Guideline3_2_1_On_Focus` | Focus event causes unexpected change |
| `WCAG2AA.Principle4.Guideline4_1_1_Parsing` | Invalid HTML (e.g., duplicate IDs) |
| `WCAG2AA.Principle4.Guideline4_1_2_Name_Role_Value` | Missing ARIA labels or name/role/value |

## Common Use Cases

### Quick accessibility scan

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g pa11y && pa11y https://example.com'
```

### Save errors-only JSON report

```bash
docker run --rm \
  -v "$(pwd)/results:/results" \
  node:20-alpine \
  sh -c 'npm install -g pa11y && \
    pa11y \
      --standard=WCAG2AA \
      --json \
      --level=error \
      https://example.com > /results/errors.json'
```

### Batch scan (multiple pages)

```bash
#!/bin/bash
PAGES=("https://example.com" "https://example.com/about" "https://example.com/contact")

for page in "${PAGES[@]}"; do
  echo "Scanning $page..."
  docker run --rm \
    -v "$(pwd)/results:/results" \
    node:20-alpine \
    sh -c "npm install -g pa11y && \
      pa11y \
        --json \
        --standard=WCAG2AA \
        '$page' > /results/$(echo $page | md5sum | cut -d' ' -f1).json"
done
```

### WCAG 2.1 AAA strict check

```bash
docker run --rm \
  -v "$(pwd)/results:/results" \
  node:20-alpine \
  sh -c 'npm install -g pa11y && \
    pa11y \
      --standard=WCAG2AAA \
      --json \
      https://example.com > /results/aaa-report.json'
```

### Test with custom headers (auth)

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g pa11y && \
    pa11y \
      --headers="{\"Authorization\":\"Bearer TOKEN\"}" \
      --json \
      https://api.example.com/authenticated-page'
```

### Wait for JS-rendered content

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g pa11y && \
    pa11y \
      --wait=2000 \
      --json \
      https://spa-framework.example.com'
```

## Standards Comparison

### WCAG 2.1 Level AA (Default)

**Target users**: Most disabilities (visual, hearing, motor, cognitive).

**Requirements**:
- Text contrast: 4.5:1 for body text, 3:1 for large text.
- Keyboard accessible.
- Focus visible.
- Alt text for images.
- Form labels.
- Heading hierarchy.

### WCAG 2.1 Level AAA (Stricter)

**Target users**: All disabilities, including edge cases.

**Requirements**:
- Text contrast: 7:1 (vs 4.5:1 for AA).
- Enhanced keyboard support.
- Extended alt text guidance.
- Captions for multimedia (not just audio descriptions).
- Sign language for videos.

**Note**: AAA is aspirational; many sites aim for AA as a practical baseline.

### Section 508 (US Legal Standard)

Subset of WCAG 2.0 AA, US government accessibility requirement.

## Troubleshooting

### Error: `Error: Failed to launch browser`

**Cause**: Chromium missing or cannot start in Docker.

**Fix**: Add sandbox/memory flags:

```bash
docker run --rm \
  -v "$(pwd)/results:/results" \
  node:20-alpine \
  sh -c 'npm install -g pa11y && \
    pa11y \
      --chromeLaunchConfig="{\"headless\":\"new\",\"args\":[\"--no-sandbox\",\"--disable-dev-shm-usage\"]}" \
      --json \
      https://example.com > /results/report.json'
```

### Error: `ECONNREFUSED`

**Cause**: URL unreachable from container.

**Fix**: Use public URL or `--network host`:

```bash
docker run --rm --network host \
  node:20-alpine \
  sh -c 'npm install -g pa11y && pa11y http://localhost:3000'
```

### No violations reported, but page has accessibility issues

**Cause**: Automated testing misses complex issues (context-dependent violations).

**Fix**: Combine with manual review:

1. Use pa11y for quick automated checks.
2. Manually test keyboard navigation, screen reader output, color blindness.
3. Check with real users (user testing).

### JSON output format different than expected

**Cause**: pa11y version differences.

**Fix**: Pin pa11y version:

```bash
npm install -g pa11y@6.2.3
```

## Ignoring False Positives

Some rules generate false positives. To ignore specific rules:

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g pa11y && \
    pa11y \
      --ignore=WCAG2AA.Principle1.Guideline1_1_1_Non_text_Content \
      --json \
      https://example.com'
```

## Parsing JSON Output

### Count violations by severity

```bash
jq 'group_by(.type) | map({(.[0].type): length})' report.json
```

### Extract all error messages

```bash
jq '.issues[] | select(.type == "error") | .message' report.json
```

### Find issues on specific selector

```bash
jq '.issues[] | select(.selector == "button.submit")' report.json
```

## Integration with CI/CD

### GitHub Actions

```yaml
- name: Run pa11y accessibility test
  run: |
    docker run --rm \
      -v "${{ github.workspace }}/results:/results" \
      node:20-alpine \
      sh -c 'npm install -g pa11y && \
        pa11y --json ${{ env.TARGET_URL }} > /results/report.json'

- name: Check for errors
  run: |
    ERRORS=$(jq '[.issues[] | select(.type == "error")] | length' results/report.json)
    if [ "$ERRORS" -gt 0 ]; then
      echo "Found $ERRORS accessibility errors"
      exit 1
    fi
```

## Resources

- **WCAG 2.1 Quick Reference**: https://www.w3.org/WAI/WCAG21/quickref/
- **Web Accessibility Basics**: https://www.w3.org/WAI/fundamentals/
- **pa11y Configuration**: https://github.com/pa11y/pa11y#usage
- **Axe Rules (used by pa11y)**: https://github.com/dequelabs/axe-core/blob/develop/doc/rule-descriptions.md
