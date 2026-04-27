---
name: scrape-site
description: >-
  Delegates to the scraper agent to crawl a website and produce a structured
  report in SCRAP/{domain}/. Verifies that all expected deliverables exist
  after the agent completes.
tags:
  - scraping
  - playwright
---

# `/scrape-site` — Web Scraper

Delegate entirely to the **scraper** agent (`@scraper`).

## Usage

```
/scrape-site URL="https://example.com"
/scrape-site URL="https://example.com" MAX_PAGES=20
```

## Required Parameter

| Parameter | Description | Example |
|-----------|-------------|---------|
| **URL** | Starting URL to scrape | `https://example.com` |
| MAX_PAGES | *(optional)* Page budget, default 50 | `20` |

**FAIL-FAST**: If `URL` is not provided at invocation, **ABORT immediately**. Ask the user to provide the target URL.

## Behavior

1. Extract the `URL` (and optional `MAX_PAGES`) from the invocation.
2. Invoke the **scraper** agent with the parameters. The scraper handles the full 5-phase workflow: Init → Crawl → Analyse → Assets → Report (see `agents/scraper.md` for details).
3. When the scraper returns, **verify the deliverables** exist.

## Deliverable Verification

After the scraper agent completes, extract `{DOMAIN}` from the URL and check that the following files exist:

```bash
ls -la SCRAP/{DOMAIN}/overview.md \
       SCRAP/{DOMAIN}/sitemap.md \
       SCRAP/{DOMAIN}/journeys.md \
       SCRAP/{DOMAIN}/resources-urls.txt \
       SCRAP/{DOMAIN}/screenshots/
```

### Verification Checklist

| Deliverable | Check |
|-------------|-------|
| `overview.md` | Exists and is non-empty |
| `sitemap.md` | Exists and contains a Page Inventory table |
| `journeys.md` | Exists and contains at least one User Journey section |
| `resources-urls.txt` | Exists (may be empty if no images found) |
| `screenshots/` | Directory exists and contains at least one `.png` |
| `assets/` | Directory exists (may be empty if no images) |

### On Success

Display a summary to the user:

```
Scraping complete for {DOMAIN}.

Report:
  - SCRAP/{DOMAIN}/overview.md
  - SCRAP/{DOMAIN}/sitemap.md
  - SCRAP/{DOMAIN}/journeys.md

Assets:
  - {N} screenshots in SCRAP/{DOMAIN}/screenshots/
  - {M} images downloaded in SCRAP/{DOMAIN}/assets/
  - Full URL list: SCRAP/{DOMAIN}/resources-urls.txt
```

### On Failure

If any mandatory deliverable is missing, report the gap and re-invoke the scraper agent for the missing phase only.

## Delegation

This command is a thin wrapper. All scraping logic lives in the scraper agent.

**Agent**: `@scraper` — invoke with the full crawl workflow.
