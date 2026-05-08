# Data Model: Scraper Architecture

**Branch**: `010-refactor-scraper-separation` | **Date**: 2026-05-08

## Entities

### Scraping Brief (Command → Agent contract)

The structured instruction set passed from the command to the agent as part of the agent prompt.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `url` | string (URL) | Yes | Starting URL to scrape |
| `intent` | enum | Yes | One of: `data-extraction`, `user-flow`, `site-structure`, `general` |
| `max_pages` | integer | Yes | Page budget (default from intent or user override) |
| `scope_filters` | list | No | URL patterns and CSS selectors to focus/restrict crawling |
| `scope_filters[].url_pattern` | string | No | URL path pattern to include (regex or glob) |
| `scope_filters[].css_selector` | string | No | CSS selector for priority extraction |
| `auth` | object | No | Authentication instructions |
| `auth.type` | enum | No | `form`, `basic`, `cookie`, `header` |
| `auth.steps` | list | No | Sequential Playwright actions for form-based auth |
| `deliverables` | object | Yes | Flags controlling agent output |
| `deliverables.tables_as_markdown` | boolean | Yes | Extract HTML tables/data as markdown |
| `deliverables.screenshots` | boolean | Yes | Capture full-page screenshots |
| `deliverables.accessibility_snapshots` | boolean | Yes | Capture accessibility tree |
| `deliverables.asset_download` | boolean | Yes | Bulk download images/assets |
| `deliverables.css_extraction` | boolean | No | Extract stylesheets (for site-structure intent) |

### Data Artifact (Agent output)

A file produced by the agent in `SCRAP/{DOMAIN}/`.

| Field | Type | Description |
|-------|------|-------------|
| `type` | enum | `table`, `screenshot`, `accessibility-snapshot`, `asset-list`, `page-data` |
| `source_url` | string (URL) | The page URL where this was extracted |
| `file_path` | string | Relative path within `SCRAP/{DOMAIN}/` |
| `metadata` | object | Page title, extraction timestamp, BFS depth |

### Intent Category

| Category | Default `max_pages` | Key Deliverables | Scope Focus |
|----------|--------------------|--------------------|-------------|
| `data-extraction` | 15 | tables, page-data | Pages with pricing/data keywords |
| `user-flow` | 30 | screenshots, accessibility-snapshots | Sequential navigation paths |
| `site-structure` | 50 | screenshots, css, assets | Full BFS with asset download |
| `general` | 50 | all | No filtering |

### Analysis Tool (Skill catalog entry)

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Tool name (e.g., "Lighthouse") |
| `category` | enum | `performance`, `accessibility`, `seo`, `security`, `link-check`, `tech-detect`, `html-validation` |
| `docker_image` | string | Docker image reference (pinned tag) |
| `command_template` | string | Full `docker run` command with placeholders |
| `output_format` | list | Supported output formats (JSON, HTML, CSV) |
| `output_path` | string | Where results are written (relative to mount) |
| `documentation_url` | string | Official documentation link |
| `use_when` | string | One-line description of when to use this tool |

## Relationships

```
Command ──produces──▶ Scraping Brief ──consumed by──▶ Agent
Agent ──produces──▶ Data Artifact[] ──verified by──▶ Command
Skill ──referenced by──▶ Command (optional deterministic enrichment)
```

## State Transitions

### Scrape Session Lifecycle

```
INIT → BRIEF_GENERATED → AGENT_RUNNING → AGENT_COMPLETE → VERIFICATION → DONE/RETRY
```

- `INIT`: Command receives user invocation
- `BRIEF_GENERATED`: Intent detected, brief structured
- `AGENT_RUNNING`: Agent subagent launched with brief
- `AGENT_COMPLETE`: Agent returns summary
- `VERIFICATION`: Command checks deliverables exist
- `DONE`: All deliverables present
- `RETRY`: Missing deliverables → re-invoke agent for specific phase
