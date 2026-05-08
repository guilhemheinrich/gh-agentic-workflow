# Implementation Plan: Scraper Architecture — Separation of Concerns

**Branch**: `010-refactor-scraper-separation` | **Date**: 2026-05-08 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/010-refactor-scraper-separation/spec.md`

## Summary

Refactor the scraping toolchain into three files with strictly separated responsibilities:
1. **Agent** (`agents/scraper.md`) — pure Playwright navigator that crawls, extracts raw data (tables, snapshots, DOM), and reports without interpretation.
2. **Command** (`commands/scrape-site.md`) — intent-driven orchestrator that detects the scraping goal, produces a scoped brief, delegates to the agent, and verifies deliverables.
3. **Skill** (`.agents/skills/web-analysis/SKILL.md`) — reference library of deterministic CLI tools (Lighthouse, pa11y, sitespeed.io, etc.) runnable via Docker for reproducible web metrics.

## Technical Context

**Language/Version**: Markdown (agent/command/skill definitions), Bash (Docker commands in skill)  
**Primary Dependencies**: Playwright MCP (`user-playwright`), Docker (deterministic tools)  
**Storage**: Filesystem (`SCRAP/{DOMAIN}/` output directory)  
**Testing**: Manual invocation + deliverable verification (existing pattern)  
**Target Platform**: macOS/Linux developer machine with Docker  
**Project Type**: Cursor agentic configuration (agents, commands, skills)  
**Performance Goals**: Agent context usage reduced ≥40% vs current (fewer reasoning tokens)  
**Constraints**: Agent must NOT analyze — only navigate and extract; Skill tools must be Docker-only (no host installs)  
**Scale/Scope**: 3 files to rewrite/create; ~1000 lines total across all three

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Applicable? | Status |
|-----------|-------------|--------|
| I. Explicit Type Contracts | No — markdown config files, not TypeScript | N/A ✅ |
| II. Semantic Documentation | Partially — each file has a clear role header | Pass ✅ |
| III. Readable Functional Style | No — not code | N/A ✅ |
| IV. Pure Functional Core | Conceptually — agent is "pure" (no analysis side-effects) | Pass ✅ |
| V. Flat Orchestration | Yes — command orchestrates linearly (detect intent → brief → delegate → verify) | Pass ✅ |
| VI. Typed I/O Boundaries | Analogous — the "Scraping Brief" is the typed contract between command and agent | Pass ✅ |
| VII. Strict Module Isolation | Yes — three files have zero overlapping responsibilities | Pass ✅ |

**Gate result**: PASS — no violations.

## Project Structure

### Documentation (this feature)

```text
specs/010-refactor-scraper-separation/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output (Scraping Brief schema)
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
agents/
└── scraper.md                    # REWRITE: pure navigator agent

commands/
└── scrape-site.md                # REWRITE: intent-driven orchestrator command

.agents/skills/
└── web-analysis/
    ├── SKILL.md                  # NEW: deterministic web tools reference
    ├── Dockerfile                # NEW: multi-tool Docker image
    └── resources/
        └── tool-catalog.md       # NEW: detailed tool documentation
```

**Structure Decision**: Reuse existing `agents/` and `commands/` directories. Create new `.agents/skills/web-analysis/` following the established pattern from `k8s-troubleshoot/`.

## Complexity Tracking

No violations — no complexity justifications needed.
