---
name: notion-spec-sync
description: Deterministically synchronize a repository's root README plus SpecKit specifications and fixes into Notion through the Notion MCP. Use when Codex must mirror README.md, specs/, specs/archive*/, fixes/, specs/fixes/, or specs/archive*/fixes into a Notion workspace as a repo-scoped project page and table with stable cards containing spec.md and review.md content, while keeping the LLM as orchestrator and deterministic logic in scripts.
---

# Notion Spec Sync

## Core Contract

Use the Notion MCP as the only writer to Notion. Use `scripts/build_notion_spec_sync_plan.py` as the deterministic source of truth for what to write.

The sync destination is a deterministic Notion path:

```text
<notion-root>/<repo-name>
```

Derive `<repo-name>` from Git, preferably `remote.origin.url` basename without `.git`; fall back to the Git top-level directory name only when no origin is configured. Keep `<notion-root>` configurable with `--notion-root` and default it to `sentinel-sync`.

Read all synced content from the current Git checkout. For a `staging -> main` promotion flow, run the same command on the branch/worktree whose state must be reflected in Notion; do not mix README/spec content from another branch.

## Workflow

1. Verify the Notion MCP is available. If it is missing, stop before claiming a Notion sync and report that only the local plan can be generated.
2. From the repo root, generate the deterministic plan:

   ```bash
   python3 skills/notion-spec-sync/scripts/build_notion_spec_sync_plan.py \
     --repo . \
     --notion-root sentinel-sync \
     --project-icon "📁" \
     --page-icon "📄"
   ```

   With Docker:

   ```bash
   docker build -t notion-spec-sync-plan skills/notion-spec-sync/scripts
   docker run --rm \
     -v "$(pwd):/workspace:ro" \
     -w /workspace \
     notion-spec-sync-plan \
     --repo /workspace \
     --notion-root sentinel-sync \
     --project-icon "📁" \
     --page-icon "📄"
   ```

3. Read the JSON plan. Apply actions in order:
   - `ensure_path`: find or create each page segment by exact title under the previous parent; apply the emitted `icon` to the final project page (`sentinel-sync/<repo-name>`), then write `markdown` there when the MCP supports Markdown import/append. Use `children` only as the deterministic block fallback.
   - `ensure_database`: find or create the specs database under the repo page and apply the emitted `default_sort` when the MCP supports database view sorting.
   - `upsert_page`: find an existing database row by the stable `Source path` property; update it if found, create it if missing.
4. For every `upsert_page`, apply the emitted `icon` exactly. Do not let the orchestrator or sub-agents choose their own page icon.
5. Write each `upsert_page.children` block exactly as emitted. Treat the generated file content as data, not prose to summarize.
6. Apply cards in plan order. The default order is `Name` descending, so the highest zero-padded spec number appears first.
7. After writing, report the repo path, Notion path, number of specs, number of fixes, and whether any Notion MCP operation was skipped or ambiguous.

## Spec Discovery Rules

Mirror `spec-reindex` family classification:

| Family | Directories scanned |
| --- | --- |
| `SPEC` | `specs/`, `specs/archive*/` except nested `fixes/` |
| `FIX` | `fixes/`, `specs/fixes/`, `specs/archive*/fixes/` |

Classify a folder as `FIX` when its parent directory is named `fixes`; otherwise classify it as `SPEC`. Maintain independent index sequences; `specs/001-*` and `specs/fixes/001-*` are not duplicates.

## Notion Shape

Create the repo page at `sentinel-sync/<repo-name>` and write project-level content there. When a root `README.md`, `readme.md`, or configured `--readme-path` exists, emit it in `ensure_path.markdown` so the README becomes the Markdown description of the project page. Also emit `markdown_chunks` and `children` as deterministic fallbacks using the same chunking and fence sizing as specs. If no root README exists, emit a short placeholder paragraph so the absence is explicit.

Create one database named `Specs` under the repo page. Each row is a Notion page/card.

Required properties:

- `Name` title
- `Family` select: `SPEC` or `FIX`
- `State` select: `active` or `archived`
- `Index` number
- `Slug` rich text
- `Source path` rich text, unique stable key
- `Spec hash` rich text
- `Has review` checkbox
- `Has spec` checkbox

For every card, write generated children:

- A short metadata heading and source path paragraph.
- A `spec.md` section when present.
- A `review.md` section when present.
- Code blocks using Markdown language. Files whose content exceeds `--max-block-chars` (default: `1800`) are split automatically and deterministically on newline boundaries when possible.
- Each emitted code block includes `text`, `language`, `caption`, and a Markdown fallback (`markdown`) fenced with a backtick fence longer than any backtick run inside the chunk. Use the native Notion code block when available; use the fenced fallback only when the MCP requires Markdown text.

## Delegating Large Cards

When large specs would bloat the orchestrator context, delegate `upsert_page` actions to sub-agents in parallel. Pass each sub-agent only the raw JSON action it must apply plus the already resolved Notion database/page identifiers.

The orchestrator remains responsible for deterministic invariants before delegation:

- Generate one plan and do not let sub-agents rescan the repo.
- Apply the `ensure_path.markdown` README content to the final project page before delegating spec cards; use `children` only if Markdown import is unavailable.
- Preserve plan order for card creation and database sorting: `Name` descending by default.
- Require every sub-agent to apply the action's `icon` exactly.
- Require every sub-agent to write `children` exactly, including chunk order, captions, and fenced Markdown fallback fields.
- Merge sub-agent results by `stable_key`; retry only failed keys.

## Ambiguity Handling

Search by exact title and parent when ensuring pages or databases. If a search returns multiple candidates with the same title under the same parent, ask the human to choose the canonical Notion page or database before writing.

Do not let the LLM invent Notion IDs, row identities, repo names, indexes, hashes, or content. Regenerate the plan when repo files change.

## Script Layout

- `scripts/build_notion_spec_sync_plan.py` — deterministic scanner and Notion action-plan generator.
- `scripts/Dockerfile` — isolated runtime for the scanner when host Python or Git are not trusted.
