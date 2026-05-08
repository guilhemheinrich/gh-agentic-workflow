# Contract: Scraping Brief (Command → Agent)

The Scraping Brief is the sole communication interface between the orchestrator command and the scraper agent. It is passed inline as structured YAML within the agent's system prompt.

## Schema

```yaml
# Required fields
url: string          # Starting URL (must be valid HTTP/HTTPS)
intent: enum         # data-extraction | user-flow | site-structure | general
max_pages: integer   # Page budget (1-100)
deliverables:
  tables_as_markdown: boolean
  screenshots: boolean
  accessibility_snapshots: boolean
  asset_download: boolean
  css_extraction: boolean  # Optional, defaults to false

# Optional fields
scope_filters:       # List of focus constraints
  - url_pattern: string     # URL path regex/glob to include
  - css_selector: string    # CSS selector for priority extraction

auth:                # Authentication instructions
  type: enum         # form | basic | cookie | header
  steps:             # For type=form: sequential Playwright actions
    - navigate: string
    - fill: { selector: string, value: string }
    - click: string
  credentials:       # For type=basic/header
    username: string
    password: string
    header_name: string
    header_value: string
```

## Validation Rules

1. `url` must be a valid URL with `http` or `https` scheme.
2. `max_pages` must be between 1 and 100 inclusive.
3. If `auth` is provided, `auth.type` determines which sub-fields are required.
4. `deliverables` must have at least one flag set to `true`.

## Intent Defaults

When the command generates the brief, it applies these defaults based on intent:

| Intent | max_pages | tables | screenshots | a11y | assets | css |
|--------|-----------|--------|-------------|------|--------|-----|
| data-extraction | 15 | ✓ | ✗ | ✗ | ✗ | ✗ |
| user-flow | 30 | ✗ | ✓ | ✓ | ✗ | ✗ |
| site-structure | 50 | ✗ | ✓ | ✗ | ✓ | ✓ |
| general | 50 | ✓ | ✓ | ✓ | ✓ | ✗ |

User overrides always take precedence over defaults.
