# Quickstart — Rules: Impact Audit (P7) + UI Verification

Minimal sequence to land the two rule edits. No language toolchain, no Docker, no test runner — pure textual edits with grep-based static checks.

## Prerequisites

- Working tree on branch `012-rules-impact-audit-ui-verification`.
- `rg` (ripgrep) available locally for verification checks.

## Sequence

### 1. Edit `5-spec-driven-dev.mdc` — add P7

Target file: `rules/05-workflows-and-processes/5-spec-driven-dev.mdc`

Three additive insertions, in this order:

1. After the existing P6 bullet in the **Properties** list, append a P7 bullet (`- **P7 (impact-audit)**: ...`).
2. After the existing **`## Concept Rename / Semantic Redefinition Audit (P6)`** section and BEFORE **`## Anti-patterns`**, add a new section **`## Exported-symbol Signature / Behaviour Audit (P7)`** with the same four labelled sub-blocks as P6: Trigger, Required `tasks.md` template (fenced markdown), Reviewer red flag, Failure mode this prevents.
3. In the **Anti-patterns** list, append one bullet referencing P7.

Mirror P6's tone and length. Do not renumber P1..P6.

### 2. Create `7-ui-verification.mdc`

Target file: `rules/07-quality-assurance/7-ui-verification.mdc` (new).

Use the skeleton in `plan.md` §"Edit 2". Five sections:

1. YAML frontmatter — exactly four keys (`description`, `globs`, `alwaysApply: false`, `tags`).
2. `# UI dev-time verification` title + `## Desired state` paragraph.
3. `## Properties` — exactly two bullets: `**P1 (visual diff)**` and `**P2 (interactive validation)**`. Declarative MUST/SHOULD only, no ordered procedure.
4. `## Triggers` — distinguish P1 (always on frontend change) from P2 (only when a new interactive element ships).
5. `## Skill References` + `## Enforcement` — link to `./7-testing.mdc` and `../05-workflows-and-processes/5-spec-driven-dev.mdc` via relative paths; flag the future operationalising skill with a `[NEEDS CLARIFICATION: priority=P2]` slug placeholder.

### 3. Verify frontmatter shape

```text
rg -n '^(description|globs|alwaysApply|tags):' rules/07-quality-assurance/7-ui-verification.mdc | head -n 20
```

Expect exactly four matches inside the first 15 lines of the file.

### 4. Verify globs narrowness

```text
rg -n "globs:.*\\*\\*/\\*'" rules/07-quality-assurance/7-ui-verification.mdc
```

Expect zero matches (no `**/*` catch-all).

### 5. Verify P7 wiring

```text
rg -n 'P7' rules/05-workflows-and-processes/5-spec-driven-dev.mdc
```

Expect at least three matches: Properties bullet, detail-section heading, Anti-patterns bullet.

### 6. Verify cross-references resolve

```text
test -f rules/07-quality-assurance/7-testing.mdc
test -f rules/05-workflows-and-processes/5-spec-driven-dev.mdc
test -f rules/00-architecture/0-rules-structure.mdc
```

All three must exit 0 (these are the targets of the new rule's relative-path links).

### 7. Manual read — no procedural prose in `7-ui-verification.mdc`

Read the new file end-to-end. Confirm there is NO ordered list of imperative actions (no `1. open the browser, 2. take a snapshot, 3. ...`). The how-to belongs in the future skill, not the rule.

### 8. (Optional) Refresh asset registry

If the repo provides an asset-registry refresh skill, run it so `7-ui-verification.mdc` is catalogued. Otherwise append a hand-written entry mirroring an existing rule entry shape in `asset-registry.yml`. This step is decided in the TASKS phase.

## Acceptance — done when

- `rg -n '^\- \*\*P7' rules/05-workflows-and-processes/5-spec-driven-dev.mdc` returns one match.
- `rg -n '^\- \*\*P[12] \(' rules/07-quality-assurance/7-ui-verification.mdc` returns two matches.
- All three cross-reference target files exist (step 6).
- Reviewer can locate P7's four-part section in `5-spec-driven-dev.mdc` in under 60 seconds (SC-001).
- Reviewer can confirm frontmatter compliance of `7-ui-verification.mdc` by reading only its first 15 lines (SC-002).
