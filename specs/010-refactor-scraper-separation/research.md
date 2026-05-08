# Research: Scraper Architecture — Separation of Concerns

**Branch**: `010-refactor-scraper-separation` | **Date**: 2026-05-08

## R1: Deterministic Web Analysis Tools (Docker-based)

### Decision
Document and package the following 7 tools as Docker-executable commands in the skill:

| Tool | Category | Docker Image | Output Format |
|------|----------|--------------|---------------|
| Lighthouse | Performance + SEO + Accessibility + PWA | `patrickhulce/lighthouse-ci` or `femtopixel/google-lighthouse` | JSON, HTML |
| pa11y | Accessibility (WCAG 2.1) | `buildkite/pa11y-ci` or custom alpine + pa11y | JSON, CSV |
| sitespeed.io | Performance (RUM metrics, waterfall) | `sitespeedio/sitespeed.io` | JSON, HTML dashboard |
| broken-link-checker (blc) | Link checking | `node:alpine` + `broken-link-checker` | stdout/JSON |
| Security Headers | Security headers analysis | `alpine/curl` + custom script | JSON |
| Wappalyzer CLI | Technology detection | `AliasIO/wappalyzer` or `wappalyzer/cli` | JSON |
| html-validate | HTML validation (W3C) | `node:alpine` + `html-validate` | JSON, stylish |

### Rationale
- All produce machine-readable output (JSON) suitable for post-processing.
- All run without external API keys (except Wappalyzer cloud which has a local CLI alternative).
- Docker ensures zero host pollution and version pinning.
- Covers the full spectrum: performance, accessibility, SEO, security, link integrity, tech detection, HTML validity.

### Alternatives Considered
- **WebPageTest**: Requires API key and external service — rejected for local determinism.
- **axe-core CLI**: Overlaps with pa11y, pa11y has better Docker image support.
- **Playwright's built-in HAR**: Already available via the agent (not deterministic in the same sense).

---

## R2: Agent Model Selection for Pure Navigation

### Decision
Use `composer-2-fast` (available in subagent pool) as the agent model.

### Rationale
- Pure navigation + data extraction requires tool-calling ability but minimal reasoning.
- `composer-2-fast` handles Playwright MCP tool calls correctly.
- Lower cost per token than Sonnet-class models, aligned with the "reduce context usage" goal.
- The agent no longer performs analysis (Phase 3 in current implementation is removed), so advanced reasoning is unnecessary.

### Alternatives Considered
- **claude-4.6-sonnet-medium** (current): Overpowered for pure navigation; wastes budget on reasoning capability not needed.
- **gpt-4o-mini**: Not available in the subagent pool.

---

## R3: Intent Detection Strategy (Command)

### Decision
The command implements intent detection via keyword matching and pattern recognition in the user's natural-language description. Three primary categories with fallback to "general exploration":

| Intent Category | Trigger Keywords | Agent Focus |
|-----------------|-----------------|-------------|
| `data-extraction` | pricing, tarif, grille, table, plan, subscription, rates, cost | Prioritize `<table>`, `<dl>`, repeated data patterns, pricing sections |
| `user-flow` | flow, journey, parcours, étape, funnel, navigation, onboarding | Prioritize CTAs, forms, navigation paths, screenshots of each step |
| `site-structure` | skeleton, structure, layout, design, style, copycat, POC, clone | Prioritize CSS extraction, component hierarchy, asset download, layout screenshots |

### Rationale
- Simple keyword matching is sufficient because the user always provides some context.
- Fallback to confirmation prompt if no keywords match.
- The brief includes scope filters (URL path patterns, CSS selectors to focus on) based on intent.

### Alternatives Considered
- **LLM-based intent classification**: Over-engineered for 3 categories; adds latency and cost.
- **User explicitly picks from a menu**: Less natural than detecting from description.

---

## R4: Scraping Brief Structure (Command → Agent Contract)

### Decision
The command produces a structured brief (inline in the agent prompt, not a separate file) with:

```yaml
url: "https://example.com"
intent: "data-extraction"
max_pages: 20
scope_filters:
  - url_pattern: "/pricing"
  - css_selector: "table, .pricing-card, [class*=price]"
auth:
  type: "form"
  steps:
    - navigate: "/login"
    - fill: { selector: "#email", value: "user@example.com" }
    - fill: { selector: "#password", value: "***" }
    - click: "#submit"
deliverables:
  - tables_as_markdown: true
  - screenshots: true
  - accessibility_snapshots: true
  - asset_download: false
```

### Rationale
- Structured brief constrains the agent's behavior without needing the agent to reason about scope.
- `scope_filters` directly limit which pages/sections the agent processes.
- `deliverables` flags control what the agent produces (no asset download for flow analysis, etc.).
- Auth instructions are step-by-step Playwright actions the agent can execute mechanically.

### Alternatives Considered
- **Free-text brief**: Agent would need to interpret intent, wasting context.
- **Separate brief file**: Adds filesystem complexity; inline in prompt is simpler for a subagent.

---

## R5: Skill Structure Reference (k8s-troubleshoot Pattern)

### Decision
Follow the `k8s-troubleshoot` skill pattern exactly:
- `SKILL.md` as the main entry point with prerequisites, Docker setup, tool catalog, and usage examples.
- Optional `Dockerfile` for a multi-tool image.
- Optional `resources/` directory for extended documentation.

### Rationale
- Consistency with the existing skill library.
- The k8s-troubleshoot skill is the quality reference cited by the user.
- Single-file skill (SKILL.md) is self-contained enough for agents to load.

### Alternatives Considered
- **One skill per tool**: Would fragment the catalog and require loading multiple skills.
- **CLI script wrapper**: Adds maintenance burden; Docker commands in markdown are simpler.
