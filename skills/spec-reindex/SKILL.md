---
name: spec-reindex
description: >-
  Verify and fix spec/fix folder indexation. Maintains two independent index
  sequences (specs and fixes), detects conflicts (duplicates, gaps) per
  sequence, and re-indexes each into its own continuous sequence. Use when
  running /index, reindexing specs, fixing spec numbering, or resolving index
  conflicts after branch merges.
tags:
  - common
  - spec-kit
---

# Spec re-index skill

## When to use

- User asks to reindex specs/fixes, fix numbering gaps or duplicates, or run `/index`.
- After merging branches where multiple people created the same `NNN-` prefix.
- When inventory must include archived specs (`specs/archived/`, `specs/archive/`, any `specs/archive*` case-insensitive) and `specs/archived/fixes/` (or other archive `fixes/`).

## Two independent sequences

Specs and fixes maintain **separate index sequences** that follow the same rules independently. `specs/064-xxx` and `fixes/064-yyy` are **not** duplicates — they belong to different sequences.

| Family | Directories scanned |
|--------|-------------------|
| **SPECS** | `specs/`, `specs/archive*/` (excluding `fixes/` subdirs within archives) |
| **FIXES** | `fixes/`, `specs/fixes/`, `specs/archive*/fixes/` |

Classification rule: a folder whose parent directory is named `fixes` belongs to the FIXES family; everything else belongs to SPECS.

Diagnostics, sorting, re-indexing, and validation all run **per family**. Cross-references (Step 8) update across all roots regardless of family.

## Critical: run via Docker

**Do not run the script on the host** when the project is developed or validated in Docker. Mount the repo and the skill script read-only, use **bash** (not `alpine/git` unless bash is available).

### Dry-run (always first)

From the **project repository root**:

```bash
docker run --rm \
  -v "$(pwd):/workspace" \
  -v "$HOME/.cursor/skills/spec-reindex/scripts:/scripts:ro" \
  -w /workspace \
  bash:latest \
  bash /scripts/reindex.sh --dry-run --no-git
```

If the image must include git for branch-based priority, use an image that has both `git` and `bash` (e.g. `ubuntu:latest`) and omit `--no-git` when appropriate.

### Full run (after user confirms)

Same command without `--dry-run`. The script prompts `[y/N]` unless `--no-confirm` is passed.

```bash
docker run --rm -it \
  -v "$(pwd):/workspace" \
  -v "$HOME/.cursor/skills/spec-reindex/scripts:/scripts:ro" \
  -w /workspace \
  bash:latest \
  bash /scripts/reindex.sh
```

For non-interactive CI: add `--no-confirm` (and usually `--no-git` if `.git` is not mounted or not desired).

## How to present results to the user

After dry-run, summarize in a short report **per family**:

1. **Count** — total indexed folders, split by SPECS vs FIXES.
2. **Anomalies** — duplicates, gaps, format warnings **within each family** (quote script lines). Do NOT flag cross-family index collisions.
3. **Plan** — table of old index → new index per family if renames are proposed.
4. **Action** — if both sequences print `Indexation OK`, stop. Otherwise ask for explicit confirmation before a non–dry-run.

## Script options

| Option | Meaning |
|--------|--------|
| `--dry-run` | Print inventory, diagnostics, and plan; no filesystem changes |
| `--no-confirm` | Skip the interactive confirmation before renames |
| `--no-git` | Skip `main` / `staging` / first-commit priority (uses dates + name tie-break) |

## Project-specific rules

If the repo defines indexing rules (e.g. `.cursor/rules/.../5-spec-indexing.mdc`), follow them for naming and workflow; this skill only automates detection and renaming.

## Algorithm (reference)

1. Discover `specs/archive*` directories; scan all roots. Classify each folder as SPEC or FIX (parent dir named `fixes` → FIX, otherwise SPEC).
2. Load created dates (`stats.md` then `spec.md`); optional git signals unless `--no-git`.
3. **Per family**: detect duplicates, gaps, and zero-padding format issues.
4. **Per family**: sort by priority key, assign contiguous `001..N` (renames stay under the same parent directory).
5. Two-phase renames via `.tmp-reindex-*` to avoid collisions (all families in one pass).
6. Update internal markdown in the renamed folders; then global cross-refs under all scan roots.
7. **Per family**: validate final indices.

## Skill layout

- `SKILL.md` — this file
- `scripts/reindex.sh` — implementation (bash)
