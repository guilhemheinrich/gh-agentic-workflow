# Feature Specification: Scraper Architecture — Separation of Concerns

**Feature Branch**: `010-refactor-scraper-separation`  
**Created**: 2026-05-08  
**Status**: Draft  
**Input**: User description: "Revoir la combinaison agents/scraper.md, commands/scrape-site.md et un skill.md manquant pour le scraping — séparer les responsabilités, optimiser le contexte."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Goal-Directed Scraping Command (Priority: P1)

As a developer, I want to invoke a scrape command with a clear **intent** (e.g., "extract pricing grids", "map user flow", "capture site skeleton for a POC copycat") so that the scraper agent focuses exclusively on the relevant pages and data, minimizing wasted context and actions.

**Why this priority**: The command is the entry point that shapes everything downstream. Without explicit intent detection, the scraper over-collects irrelevant data and underperforms on the actual objective.

**Independent Test**: Can be tested by invoking the command with different intents and verifying that the scraper receives a focused brief with bounded scope.

**Acceptance Scenarios**:

1. **Given** a user invokes `/scrape-site URL="https://example.com" INTENT="pricing"`, **When** the command parses the intent, **Then** it produces a structured brief instructing the agent to prioritize data tables, pricing sections, and their source URLs.
2. **Given** a user invokes `/scrape-site URL="https://example.com" INTENT="user-flow"`, **When** the command parses the intent, **Then** it produces a brief focusing on navigation paths, CTAs, and step-by-step journey capture.
3. **Given** a user invokes `/scrape-site URL="https://example.com" INTENT="copycat"`, **When** the command parses the intent, **Then** it produces a brief focusing on layout structure, styles, components, and assets download.
4. **Given** a user invokes the command without an explicit INTENT, **When** the command analyzes the user's natural language description, **Then** it infers the closest intent category and confirms with the user before proceeding.

---

### User Story 2 - Agent as Pure Navigator and Data Reporter (Priority: P1)

As an orchestrator, I want the scraper agent to **only navigate and report raw observations** (DOM structure, tables, screenshots, accessibility snapshots) without performing analysis, so that I retain full control over interpretation and context is not wasted on reasoning inside the agent.

**Why this priority**: Separating navigation from analysis prevents the agent from consuming context budget on interpretation that the orchestrator handles better with full project context.

**Independent Test**: Can be tested by verifying agent output contains only raw data artifacts (markdown tables, screenshots, accessibility trees) and zero analytical summaries or recommendations.

**Acceptance Scenarios**:

1. **Given** the agent encounters an HTML `<table>` or semantically structured data (definition lists, key-value grids, repeated data patterns), **When** it processes the page, **Then** it extracts the full table/data as a markdown table artifact in the output directory.
2. **Given** the agent finishes crawling, **When** it produces deliverables, **Then** no file contains interpretive text like "the site appears to be…" or "the primary user journey is…".
3. **Given** the agent encounters a login wall or authentication requirement, **When** credentials/instructions are provided in the brief, **Then** the agent uses them to authenticate and continue navigation.

---

### User Story 3 - Deterministic Web Metrics Skill via Docker (Priority: P2)

As a developer, I want access to a skill that documents deterministic, CLI-based web analysis tools (Lighthouse, pa11y, sitespeed.io, etc.) runnable via Docker, so that I can complement the Playwright-based scraping with reproducible, quantitative metrics without installing anything on the host.

**Why this priority**: Deterministic tooling complements the interactive scraping by providing reproducible data (performance scores, accessibility audits, SEO metrics) that Playwright cannot easily capture.

**Independent Test**: Can be tested by invoking any documented Docker command from the skill and verifying it produces the expected output files (JSON reports, HTML reports).

**Acceptance Scenarios**:

1. **Given** a developer reads the skill, **When** they run the documented Docker command for Lighthouse, **Then** they get a JSON/HTML performance report in the expected output directory.
2. **Given** the skill documents a tool with specific options, **When** the developer copies the command, **Then** it runs without modification (no host dependencies beyond Docker).
3. **Given** the skill references a tool category (performance, accessibility, SEO, security headers), **When** the developer looks up that category, **Then** they find at least one ready-to-use Docker command with expected output format documented.

---

### Edge Cases

- What happens when the target site requires JavaScript-rendered content? The agent uses Playwright which handles SPA/JS rendering natively.
- What happens when the site has anti-bot protections (CAPTCHA, rate limiting)? The agent reports the blocker to the orchestrator and stops; it does not attempt to bypass.
- What happens when a deterministic tool (Lighthouse) fails or times out? The skill documents expected failure modes and retry strategies.
- What happens when data tables span multiple pages (pagination)? The agent follows pagination links within its page budget and concatenates table data across pages.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The command (`scrape-site.md`) MUST detect or accept the user's scraping intent and produce a scoped brief for the agent.
- **FR-002**: The command MUST support at least three intent categories: data extraction (pricing/tables), user-flow analysis, and site structure/copycat.
- **FR-003**: The agent (`scraper.md`) MUST operate exclusively as a navigator: it navigates pages, extracts raw DOM data, captures screenshots, and reports observations without interpretation.
- **FR-004**: The agent MUST extract all `<table>` elements and semantically structured data (definition lists, repeated data patterns) as markdown tables in the output artifacts, including the source URL.
- **FR-005**: The agent MUST use Playwright MCP for all browser interactions; no alternative browser automation is permitted.
- **FR-006**: The agent MUST accept authentication instructions (credentials, login steps) from the brief and execute them when encountering login walls.
- **FR-007**: The skill (`web-analysis/SKILL.md`) MUST document at least 5 deterministic CLI tools executable via Docker, covering performance, accessibility, SEO, security headers, and link checking.
- **FR-008**: Each tool in the skill MUST include a complete Docker command, expected output format, and a reference to official documentation.
- **FR-009**: The command MUST limit the agent's page budget and scope based on the detected intent (e.g., pricing intent limits to pages containing pricing keywords).
- **FR-010**: The agent MUST NOT produce interpretive or analytical content — only raw data, structured extractions, and screenshots.

### Key Entities

- **Scraping Brief**: The structured instruction set produced by the command for the agent, containing: target URL, intent category, page budget, scope filters, authentication details, and expected deliverable types.
- **Data Artifact**: A raw extraction (markdown table, screenshot, accessibility snapshot) produced by the agent, tagged with source URL and page context.
- **Analysis Tool**: A deterministic CLI tool documented in the skill, defined by: name, Docker image, command template, output format, and applicable metrics category.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The agent's context usage per scrape session decreases by at least 40% compared to the current implementation (fewer reasoning tokens, no analysis phase).
- **SC-002**: 100% of HTML tables and structured data on scraped pages are extracted as markdown artifacts with source attribution.
- **SC-003**: All deterministic tools documented in the skill produce valid output when run with the documented Docker command on any machine with Docker installed.
- **SC-004**: The command correctly infers intent category in at least 90% of natural-language invocations (tested against a set of 10 representative prompts).
- **SC-005**: The three artifacts (agent, command, skill) have zero overlapping responsibilities — each file's content is independently replaceable without affecting the others.

## Assumptions

- Docker is available on the developer's machine for running deterministic analysis tools.
- Playwright MCP server (`user-playwright`) is configured and accessible to the agent.
- The existing `SCRAP/{DOMAIN}/` output directory convention is preserved.
- The orchestrator (caller of the command) handles all interpretation and synthesis of raw data produced by the agent.
- Authentication credentials, when needed, are provided by the user at invocation time (not stored in the agent or command).
- The model used for the scraper agent has sufficient capability for Playwright MCP tool calls but does NOT need advanced reasoning (medium-tier model is sufficient).
