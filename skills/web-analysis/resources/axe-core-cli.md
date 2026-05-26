# axe-core CLI — Accessibility and Contrast Testing

## Official Documentation

- **axe-core GitHub**: https://github.com/dequelabs/axe-core
- **axe-core CLI package**: https://www.npmjs.com/package/@axe-core/cli
- **axe-core CLI source**: https://github.com/dequelabs/axe-core-npm/tree/develop/packages/cli
- **Rules reference**: https://dequeuniversity.com/rules/

## Overview

`@axe-core/cli` provides the `axe` command for running the open-source axe-core accessibility engine against rendered web pages. It starts a browser, evaluates the DOM, and reports rule violations with selectors, impacted nodes, remediation guidance, and WCAG tags.

Use it for:

- **Color contrast checks** on rendered text via the `color-contrast` rule.
- **WCAG regression gates** in CI using `--exit`.
- **Focused checks** by rule (`--rules`) or standard tag (`--tags`).
- **Machine-readable reports** via `--stdout` or `--save`.

Automated tools do not prove full accessibility compliance. Combine axe-core with keyboard testing, screen reader checks, and manual review for release sign-off.

## Docker Image

The bundled `web-analysis` image includes:

- `@axe-core/cli`
- Chromium
- ChromeDriver
- Node.js 22

Build it from the skill directory:

```bash
docker build -t web-analysis /path/to/skills/web-analysis/
```

Run `axe` directly:

```bash
docker run --rm web-analysis \
  axe https://example.com \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage"
```

## Running axe-core CLI

### Minimal accessibility scan

```bash
docker run --rm web-analysis \
  axe https://example.com \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage"
```

**Output**: Human-readable CLI report.

### JSON report to stdout

```bash
docker run --rm web-analysis \
  axe --stdout https://example.com \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage"
```

### Save JSON report

```bash
docker run --rm \
  -v "$(pwd)/axe-results:/results" \
  web-analysis \
  axe https://example.com \
  --save report.json \
  --dir /results \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage"
```

**Output**: `axe-results/report.json`.

### Fail CI when violations are found

```bash
docker run --rm web-analysis \
  axe https://example.com \
  --exit \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage"
```

`--exit` makes the process exit with code `1` when any rule fails.

### Test only color contrast

```bash
docker run --rm web-analysis \
  axe https://example.com \
  --rules color-contrast \
  --exit \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage"
```

Use this as a narrow gate when the question is specifically: "Are rendered text/background contrasts valid?"

### Test WCAG AA rules

```bash
docker run --rm web-analysis \
  axe https://example.com \
  --tags wcag2a,wcag2aa,wcag21a,wcag21aa,wcag22aa \
  --exit \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage"
```

### Multiple pages

```bash
docker run --rm web-analysis \
  axe https://example.com https://example.com/contact \
  --stdout \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage"
```

`axe` is not a crawler. Pass the exact URLs to test, or feed it a route list from a sitemap/crawler step.

### Wait for JavaScript-rendered content

```bash
docker run --rm web-analysis \
  axe https://example.com \
  --load-delay=2000 \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage"
```

### Limit scope to part of a page

```bash
docker run --rm web-analysis \
  axe https://example.com \
  --include "#main" \
  --exclude "#cookie-banner" \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage"
```

## Flags Reference

### Rules and Standards

- **`--rules color-contrast,html-has-lang`** — run only specific axe rules.
- **`--tags wcag2a,wcag2aa`** — run rules matching specific tags.
- **`--disable color-contrast`** — skip specific rules.

Useful tags include:

| Tag | Purpose |
|-----|---------|
| `wcag2a` | WCAG 2.0 Level A |
| `wcag2aa` | WCAG 2.0 Level AA |
| `wcag21a` | WCAG 2.1 Level A |
| `wcag21aa` | WCAG 2.1 Level AA |
| `wcag22aa` | WCAG 2.2 Level AA |
| `best-practice` | axe best practices beyond strict WCAG |

### Reporting and CI

- **`--stdout`** — print JSON to stdout and silence normal logs.
- **`--save report.json`** — save JSON under the current or configured output directory.
- **`--dir /results`** — output directory for saved reports.
- **`--exit`** / **`-q`** — exit with code `1` when violations are found.
- **`--verbose`** / **`-v`** — print tool/environment details.

### Browser and Timing

- **`--chrome-options="no-sandbox,disable-dev-shm-usage"`** — Docker-friendly Chromium flags.
- **`--browser chrome`** — choose Chrome explicitly.
- **`--chromedriver-path /usr/bin/chromedriver`** — force a ChromeDriver path if auto-detection fails.
- **`--chrome-path /usr/bin/chromium-browser`** — force the Chromium executable path in the bundled Alpine image.
- **`--timeout=120`** — increase axe execution timeout for large pages.
- **`--load-delay=2000`** — wait after load before running checks.

## Output Format

`--stdout` returns an array, one entry per tested page. Each page result includes arrays such as `violations`, `passes`, `incomplete`, and `inapplicable`.

Important fields in `violations`:

```json
[
  {
    "url": "https://example.com",
    "violations": [
      {
        "id": "color-contrast",
        "impact": "serious",
        "description": "Ensure the contrast between foreground and background colors meets WCAG thresholds",
        "help": "Elements must meet minimum color contrast ratio thresholds",
        "helpUrl": "https://dequeuniversity.com/rules/axe/...",
        "tags": ["cat.color", "wcag2aa", "wcag143"],
        "nodes": [
          {
            "target": [".button-secondary"],
            "html": "<button class=\"button-secondary\">Cancel</button>",
            "failureSummary": "Fix any of the following..."
          }
        ]
      }
    ]
  }
]
```

## Common Use Cases

### Extract contrast violations only

```bash
docker run --rm web-analysis \
  axe --stdout https://example.com \
  --rules color-contrast \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage" \
  | jq '.[].violations[] | {id, impact, targets: [.nodes[].target]}'
```

### Count violations by rule

```bash
docker run --rm web-analysis \
  axe --stdout https://example.com \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage" \
  | jq '[.[].violations[].id] | group_by(.) | map({rule: .[0], count: length})'
```

### Use against a local dev server

On Linux:

```bash
docker run --rm --network host web-analysis \
  axe http://localhost:3000 \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage"
```

On macOS/Windows Docker Desktop:

```bash
docker run --rm web-analysis \
  axe http://host.docker.internal:3000 \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage"
```

## Troubleshooting

### Chrome or ChromeDriver cannot start

Use Docker-friendly Chrome flags:

```bash
docker run --rm web-analysis \
  axe https://example.com \
  --browser chrome \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-setuid-sandbox,disable-dev-shm-usage"
```

### Page is audited before the app finishes rendering

Add a load delay:

```bash
docker run --rm web-analysis \
  axe https://example.com \
  --load-delay=3000 \
  --chromedriver-path /usr/bin/chromedriver \
  --chrome-path /usr/bin/chromium-browser \
  --chrome-options="no-sandbox,disable-dev-shm-usage"
```

### Authenticated pages

`@axe-core/cli` is best for public pages or pages reachable with preconfigured browser/session setup. For complex login flows, prefer Playwright/Cypress with axe-core integration, or use pa11y actions for simple form login steps.
