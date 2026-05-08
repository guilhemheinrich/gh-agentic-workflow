# Contract: Agent Output (Agent → Command)

The scraper agent produces artifacts in the `SCRAP/{DOMAIN}/` directory and returns a structured summary to the orchestrator.

## Return Summary Format

When the agent completes, it returns a YAML summary to the caller:

```yaml
domain: string            # Extracted hostname
pages_crawled: integer    # Total pages visited
page_budget_reached: boolean
errors:                   # Pages that failed
  - url: string
    reason: string        # 404, 500, timeout, blocked
artifacts:
  tables: integer         # Number of markdown table files
  screenshots: integer    # Number of PNG files
  snapshots: integer      # Number of accessibility snapshot files
  assets: integer         # Number of downloaded assets
output_directory: string  # Relative path to SCRAP/{DOMAIN}/
```

## Directory Structure

```
SCRAP/{DOMAIN}/
├── tables/
│   ├── {page-slug}--table-{N}.md    # Each extracted table
│   └── ...
├── screenshots/
│   ├── {page-slug}.png              # Full-page screenshot
│   └── ...
├── snapshots/
│   ├── {page-slug}.yaml             # Accessibility tree
│   └── ...
├── pages/
│   ├── {page-slug}.json             # Raw page data (title, headings, links, meta)
│   └── ...
├── assets/                           # Downloaded images/resources (if requested)
├── resources-urls.txt                # URL list for bulk download
└── crawl-log.json                    # BFS traversal log with timestamps
```

## Table Artifact Format

Each extracted table is a standalone markdown file:

```markdown
<!-- Source: {full_url} -->
<!-- Extracted: {ISO timestamp} -->
<!-- Selector: {CSS selector that matched} -->

| Column 1 | Column 2 | ... |
|----------|----------|-----|
| data     | data     | ... |
```

## Verification Contract

The command verifies these minimum conditions after agent completion:

| Condition | Required |
|-----------|----------|
| `output_directory` exists | Always |
| At least 1 file in `pages/` | Always |
| At least 1 file in `tables/` | When `deliverables.tables_as_markdown: true` and tables exist on site |
| At least 1 file in `screenshots/` | When `deliverables.screenshots: true` |
| `crawl-log.json` exists | Always |
