---
name: scrape-site
description: >-
  Intent-driven web scraping orchestrator. Detects scraping intent from natural
  language, builds a structured brief, delegates to the scraper agent, and
  verifies deliverables. Supports data extraction, user flow analysis,
  site structure cloning, and general-purpose scraping with configurable
  parameters.
tags:
  - scraping
  - playwright
---

# `/scrape-site` — Intent-Driven Web Scraping Orchestrator

A Cursor command that orchestrates web scraping via intent detection, brief generation, agent delegation, and deliverable verification.

## Usage

```bash
/scrape-site URL="https://example.com" INTENT="data-extraction"
/scrape-site URL="https://example.com" MAX_PAGES=15
/scrape-site URL="https://pricing.example.com" "Extract pricing tables and plans"
/scrape-site URL="https://example.com" AUTH_EMAIL="user@example.com" AUTH_PASSWORD="secret" AUTH_TYPE="form"
/scrape-site URL="https://example.com" INTENT="site-structure" MAX_PAGES=100
```

## Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| **URL** | string | ✓ Yes | — | Starting URL to scrape. FAIL-FAST if missing. |
| INTENT | enum | ✗ No | auto-detect | Scraping intent: `data-extraction`, `user-flow`, `site-structure`, `general` |
| MAX_PAGES | integer | ✗ No | from intent | Maximum pages to crawl |
| AUTH_EMAIL | string | ✗ No | — | Email for authentication |
| AUTH_PASSWORD | string | ✗ No | — | Password for authentication |
| AUTH_TYPE | enum | ✗ No | form | Auth method: `form`, `basic`, `cookie`, `header` |
| DESCRIPTION | string | ✗ No | — | Natural language description for intent detection (used if INTENT not provided) |

---

## Intent Detection

If `INTENT` parameter is not provided, the command scans the `DESCRIPTION` parameter for keywords to infer intent. If neither is provided and ambiguity exists, the command asks the user to clarify.

### Keyword Mapping Table

| Intent | Keywords |
|--------|----------|
| `data-extraction` | pricing, tarif, grille, table, plan, subscription, rates, cost, données, data |
| `user-flow` | flow, journey, parcours, étape, funnel, navigation, onboarding, signup, login |
| `site-structure` | skeleton, structure, layout, design, style, copycat, POC, clone, template |
| `general` | *(fallback when no keywords match)* |

### Detection Logic

1. If `INTENT` parameter is explicitly provided → use it immediately
2. Else if `DESCRIPTION` is provided → scan for keywords:
   - If keywords from one intent category are found → use that intent
   - If keywords from multiple categories are found → ask user to clarify
   - If no keywords match → use `general`
3. Else if only `URL` is provided → use `general`

---

## Intent Defaults Table

When an intent is determined, apply these default parameters if not explicitly overridden:

| Intent | max_pages | tables_as_markdown | screenshots | accessibility_snapshots | asset_download | css_extraction |
|--------|-----------|-------------------|-------------|----------------------|----------------|---------------|
| `data-extraction` | 15 | true | false | false | false | false |
| `user-flow` | 30 | false | true | true | false | false |
| `site-structure` | 50 | false | true | false | true | true |
| `general` | 50 | true | true | true | true | false |

---

## Scraping Brief Generation

The command constructs a YAML brief structure and passes it to the `@scraper` agent:

```yaml
url: string                    # Starting URL from parameter
intent: enum                   # data-extraction | user-flow | site-structure | general
max_pages: integer            # From intent defaults or user override
scope_filters:
  - url_pattern: string       # (optional) URL patterns to include/exclude
  - css_selector: string      # (optional) CSS selectors to scope crawl
auth:
  type: enum                  # form | basic | cookie | header
  email: string               # (optional) auth email
  password: string            # (optional) auth password
  steps: []                   # (optional) manual auth steps
deliverables:
  tables_as_markdown: boolean  # Convert tables to markdown
  screenshots: boolean         # Capture page screenshots
  accessibility_snapshots: boolean  # ARIA snapshots
  asset_download: boolean      # Download images and assets
  css_extraction: boolean      # Extract and normalize CSS
```

### Brief Construction Algorithm

1. Extract `URL` from parameters. **FAIL-FAST** if missing.
2. Detect or apply `INTENT` (see Intent Detection above).
3. Apply intent defaults for `max_pages`, `tables_as_markdown`, `screenshots`, `accessibility_snapshots`, `asset_download`, `css_extraction`.
4. Override defaults with explicit parameters (e.g., if user provides `MAX_PAGES=100`, use that).
5. If `AUTH_EMAIL` and `AUTH_PASSWORD` are provided:
   - Build `auth` section with `type`, `email`, `password`
   - If `AUTH_TYPE` is provided, use it; else default to `form`
6. Build the brief YAML structure.

---

## Authentication Handling

The command supports three authentication workflows:

### Form Authentication
```yaml
auth:
  type: form
  email: user@example.com
  password: secret
```
The scraper agent will locate login form and submit credentials.

### Basic Auth
```yaml
auth:
  type: basic
  email: user@example.com
  password: secret
```
Passed as HTTP Authorization header.

### Cookie / Header Auth
```yaml
auth:
  type: cookie
  steps:
    - action: fetch
      url: https://example.com/auth
      headers: {...}
```
For advanced workflows; user provides steps.

---

## Agent Delegation

Once the brief is constructed, invoke the `@scraper` agent:

```
@scraper

[brief YAML structure as input]
```

The scraper agent handles:
- Browser initialization and page loading
- Recursive crawl with page budget enforcement
- Table extraction and markdown conversion
- Screenshot capture (with optional accessibility snapshots)
- Asset download and storage
- CSS extraction and aggregation
- Sitemap and journey generation
- Final report output to `SCRAP/{DOMAIN}/`

---

## Deliverable Verification

After the scraper agent returns, verify that expected artifacts exist:

### Directory Structure Check

Extract `{DOMAIN}` from the URL and check:

```bash
SCRAP/{DOMAIN}/
├── crawl-log.json                # Crawl metadata and statistics
├── pages/                        # (at least 1 file)
│   ├── page_1.md
│   └── ...
├── tables/                       # (if tables_as_markdown: true)
├── screenshots/                  # (if screenshots: true)
│   ├── page_1.png
│   └── ...
├── assets/                       # (if asset_download: true)
│   ├── image_1.png
│   └── ...
└── css/                          # (if css_extraction: true)
    └── combined.css
```

### Verification Checklist

| Deliverable | Condition | Action on Failure |
|-------------|-----------|-------------------|
| `crawl-log.json` | Must exist | Re-invoke scraper for Init phase |
| `pages/` | Must contain ≥ 1 file | Re-invoke scraper for Crawl phase |
| `tables/` | Must exist if `tables_as_markdown: true` | Re-invoke scraper for Analyse phase |
| `screenshots/` | Must exist if `screenshots: true` | Re-invoke scraper for Assets phase |
| `assets/` | Must exist if `asset_download: true` | Re-invoke scraper for Assets phase |
| `css/` | Must exist if `css_extraction: true` | Re-invoke scraper for Assets phase |

---

## Retry Logic

If verification fails:

1. Identify missing deliverables
2. Determine which phase failed (Init → Crawl → Analyse → Assets → Report)
3. Re-invoke the `@scraper` agent with the same brief + instruction to retry only the failed phase
4. Re-verify the missing deliverable
5. If retry succeeds, report success with available artifacts
6. If retry fails twice, report error with partial results and ask user for manual intervention

---

## Success Output

When verification passes, display a summary:

```
✓ Scraping complete for {DOMAIN}

Intent: {INTENT}
Pages crawled: {N}
Duration: {elapsed time}

Deliverables:
  ✓ crawl-log.json ({file size})
  ✓ {N} pages in pages/
  ✓ {M} tables in tables/ [if enabled]
  ✓ {K} screenshots in screenshots/ [if enabled]
  ✓ {L} assets downloaded in assets/ [if enabled]
  ✓ CSS extracted to css/combined.css [if enabled]

Output directory: SCRAP/{DOMAIN}/
```

---

## Failure Modes and Recovery

### URL Missing
```
✗ FAIL-FAST: URL parameter is required.

Usage: /scrape-site URL="https://example.com"
```
**Action**: Abort immediately. Ask user to provide URL.

### Intent Ambiguous
```
? Multiple intents detected. Please clarify:

Detected keywords:
  - data-extraction: "pricing", "plans"
  - site-structure: "layout", "template"

Which intent? Provide INTENT=data-extraction or INTENT=site-structure
```
**Action**: Ask user to clarify or provide explicit INTENT.

### Deliverable Missing After Crawl
```
✗ Verification failed: Missing tables in tables/ (tables_as_markdown: true)

Retrying Analyse phase...
```
**Action**: Re-invoke scraper for failed phase once. Report if retry succeeds or fails.

### Partial Success
```
⚠ Scraping partially complete for {DOMAIN}

Succeeded:
  ✓ {N} pages crawled
  ✓ {K} screenshots captured

Failed:
  ✗ Asset download (reason: {error})
  ✗ CSS extraction (reason: {error})

Available output: SCRAP/{DOMAIN}/
```
**Action**: Report partial results and available artifacts.

---

## Implementation Notes

- **This command orchestrates only.** It does not navigate, extract, or analyze content directly.
- **Intent detection is keyword-based,** not semantic. Keywords are case-insensitive.
- **Auth credentials are passed to scraper agent,** not stored by this command.
- **Deliverable verification uses filesystem checks,** not content inspection.
- **Retry is attempted once per failed phase.** If retry fails, report and stop.
- **Brief YAML is the contract** between this command and the scraper agent. Both must use identical schema.

