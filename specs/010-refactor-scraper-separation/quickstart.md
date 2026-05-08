# Quickstart: Scraper Architecture Refactoring

## What Changed

The scraping toolchain is split into three independent files:

| File | Responsibility | Does NOT do |
|------|---------------|-------------|
| `commands/scrape-site.md` | Detect intent, build brief, delegate, verify | Navigate, extract data, analyze |
| `agents/scraper.md` | Navigate pages, extract raw data, report | Analyze, interpret, decide scope |
| `.agents/skills/web-analysis/SKILL.md` | Document deterministic Docker tools | Navigate, orchestrate, decide |

## Usage

### Basic Scraping (intent auto-detected)

```
/scrape-site URL="https://example.com" I want to extract their pricing grid
```

### Explicit Intent

```
/scrape-site URL="https://example.com" INTENT="data-extraction" MAX_PAGES=10
/scrape-site URL="https://example.com" INTENT="user-flow"
/scrape-site URL="https://example.com" INTENT="site-structure"
```

### With Authentication

```
/scrape-site URL="https://app.example.com" INTENT="user-flow" AUTH_EMAIL="user@test.com" AUTH_PASSWORD="pass123"
```

### Deterministic Analysis (from skill)

Read the skill for Docker commands:
```bash
# Lighthouse performance audit
docker run --rm -v "$(pwd)/reports:/reports" \
  femtopixel/google-lighthouse \
  --output=json --output-path=/reports/lighthouse.json \
  https://example.com

# Accessibility audit
docker run --rm -v "$(pwd)/reports:/reports" \
  --entrypoint pa11y \
  node:20-alpine \
  --reporter json https://example.com > reports/a11y.json
```

## Output Location

All scraping artifacts land in:
```
SCRAP/{domain}/
├── tables/          # Markdown tables (data-extraction)
├── screenshots/     # Full-page PNGs (user-flow, site-structure)
├── snapshots/       # Accessibility trees (user-flow)
├── pages/           # Raw page JSON data
├── assets/          # Downloaded resources (site-structure)
└── crawl-log.json   # BFS traversal record
```

## Key Design Decisions

1. **Agent never analyzes** — it only reports raw observations. The caller (command/user) interprets.
2. **Intent shapes scope** — different intents set different page budgets and deliverable flags.
3. **Docker for metrics** — all deterministic tools run in containers, never on the host.
4. **Brief is the contract** — the command's output to the agent is a structured YAML brief, not free text.
