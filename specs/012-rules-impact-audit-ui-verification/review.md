Speculative: true

# Review — spec 012 (Rules: Impact Audit P7 + UI Verification)

**Verdict**: **Approved**
**Reviewer**: Bohr (claude-opus-4-7) — Phase 7 speculative pass
**Counts**: Critical 0 | High 0 | Medium 0 | Low 2 | Info 2
**SameModelWarning**: unknown (no implementer-model attribution available in dispatch)

## Scope of this review

- Diff against `main`:
  - MODIFIED `rules/05-workflows-and-processes/5-spec-driven-dev.mdc`
  - MODIFIED `asset-registry.yml` (single additive entry at lines 727–738)
  - CREATED `rules/07-quality-assurance/7-ui-verification.mdc`
- Doc-only spec; no runtime / code / test / Docker surface. Docker-only execution rule does not apply per `flow-docker` SKILL allowance (host tools `git`, `grep`, `awk` only).
- Speculative mode: VERIFY already ran inline (`verify.sh` reported all 12 checks PASS) — I do not re-comment on test status per protocol.

## Spec coverage matrix (FR-001..FR-012)

| FR | Requirement | Evidence | Status |
|----|-------------|----------|--------|
| FR-001 | P7 bullet in Properties list, immediately after P6 | `5-spec-driven-dev.mdc:26` — `**P7 (impact-audit)**` follows `**P6 (rename-audit)**:25` | PASS |
| FR-002 | P7 detail section uses P6's four-part shape | `5-spec-driven-dev.mdc:56–79` — headings **Trigger**, **Required `tasks.md` template**, **Reviewer red flag**, **Failure mode this prevents** in the same order and casing as the P6 block at L28–54 | PASS |
| FR-003 | P7 trigger covers signature changes AND observable behaviour | `5-spec-driven-dev.mdc:60–64` — parameters added/removed/reordered/retyped, return type changes, observable behaviour shift under previously-defined inputs, overload/generic dispatch variant | PASS |
| FR-004 | `tasks.md` template enumerates call sites via LSP/`rg` + requires per-call-site update or documentation | `5-spec-driven-dev.mdc:68–75` — fenced ` ```markdown ` block with `[impact-audit]` tag, LSP "Find References" + `rg` fallback, explicit "Update each call site … OR document explicitly why a given call site requires no change" | PASS |
| FR-005 | Anti-patterns bullet added | `5-spec-driven-dev.mdc:87` — "Modifying the signature or observable behaviour of an exported symbol in spec X without an impact-audit task — see P7." | PASS |
| FR-006 | New file with frontmatter (4 keys, `alwaysApply: false`) | `7-ui-verification.mdc:1–15` — `description` (L2), `globs` (L8), `alwaysApply: false` (L9), `tags` (L10) all within first 15 lines | PASS |
| FR-007 | Narrow frontend-only globs, no catch-all | `7-ui-verification.mdc:8` — `'**/*.tsx,**/*.jsx,**/*.vue,**/*.svelte,**/*.html,**/*.css,**/*.scss'`. No `**/*` and no `**/*.ts` | PASS |
| FR-008 | Exactly two properties P1 and P2, declarative | `7-ui-verification.mdc:25–26` — `**P1 (visual diff)**` and `**P2 (interactive validation)**`, both phrased MUST | PASS |
| FR-009 | P1 requires before/after browser snapshot via browser MCP at implementation time, not codified E2E | `7-ui-verification.mdc:25` — "before-state and an after-state browser snapshot ... captured via Playwright MCP or an equivalent browser tool, at implementation time. This snapshot is an authoring artefact and MUST NOT be substituted by the codified E2E suite." | PASS |
| FR-010 | P2 conditional on new interactive element + click + observable assertion | `7-ui-verification.mdc:26` — fires only when new interactive element introduced; click/focus/submit + observable outcome asserted against spec | PASS |
| FR-011 | No procedural step-by-step prose; how-to deferred to skill | `7-ui-verification.mdc:37` — `[NEEDS CLARIFICATION: priority=P2]` placeholder for future skill slug; manual read shows zero ordered "1./2./3." recipe blocks | PASS |
| FR-012 | Relative cross-refs match convention in `5-spec-driven-dev.mdc` | `7-ui-verification.mdc:38–39` — `[./7-testing.mdc]` and `[../05-workflows-and-processes/5-spec-driven-dev.mdc]`; both targets resolve on disk | PASS |

All twelve FRs satisfied with traceable evidence.

## Architecture compliance (governing rule: `rules/00-architecture/0-rules-structure.mdc`)

| Principle | Check | Status |
|-----------|-------|--------|
| P1 (one category per file) | P7 stays inside `05-workflows-and-processes/`; UI rule lives inside `07-quality-assurance/`; no cross-category mixing | PASS |
| P2 (narrow globs) | `7-ui-verification.mdc` globs are extension-narrow (7 specific frontend extensions); no `**/*` and no `**/*.ts` (which would match backends) | PASS |
| P3 (agnostic categories use pseudo-code or Go) | `07-quality-assurance/` is agnostic; the new UI rule body uses no framework syntax — only verbs ("clicked, focused, submitted") and abstract artefacts ("snapshot", "interaction trace"). Playwright MCP is named in prose only, not as syntax. | PASS |
| Content shape (declarative, no procedural prose) | `7-ui-verification.mdc` has zero numbered imperative recipes; sections are Desired state / Properties / Triggers / Skill References / Enforcement — matches sibling `7-testing.mdc` skeleton | PASS |
| File naming `{N}-{kebab-slug}.mdc` | `7-ui-verification.mdc` — `N=7`, slug = `ui-verification`, slots after `7-testing.mdc` | PASS |
| Frontmatter (description / globs / alwaysApply / tags) | All four keys present in first 15 lines (`7-ui-verification.mdc:1–15`) | PASS |

No architectural drift from the de-facto constitution. Plan §"Constitution Check" claims are upheld in the produced files.

## Security review

- **Personal-trace scan** (Critical category if found): `grep -rn '/Users/' rules/05-workflows-and-processes/5-spec-driven-dev.mdc rules/07-quality-assurance/7-ui-verification.mdc` returns ZERO matches. `verify.sh` step at L82–88 codifies the same check and reported PASS. No personal-trace leak. **PASS**.
- No secrets, tokens, credentials, or environment-dependent paths introduced.
- No new attack surface; doc-only spec.

## Sibling-pattern consistency

Compared `7-ui-verification.mdc` against sibling `7-testing.mdc` (the canonical sibling under `07-quality-assurance/`):

| Section | `7-testing.mdc` | `7-ui-verification.mdc` | Consistent? |
|---------|-----------------|--------------------------|-------------|
| H1 | `# Testing — principles (agnostic)` | `# UI dev-time verification` | YES |
| Desired state | one paragraph | one paragraph | YES |
| Properties | numbered bullets `**Pn (short-name)**:` | numbered bullets `**Pn (short-name)**:` | YES |
| Skill References | bullet list of relative links | bullet list of relative links + forward-ref placeholder | YES |
| Enforcement | Detect / Fix bullets | Detect / Fix bullets | YES |

One deviation worth flagging (informational, not blocking): `7-ui-verification.mdc` adds a `## Triggers` section between Properties and Skill References — a useful disambiguation for the P1-always-vs-P2-conditional distinction (addresses Edge Case "pure visual reflow" from `spec.md:47`). The sibling `7-testing.mdc` has no Triggers section because all of its properties are unconditional. This is an intentional, content-justified deviation rather than drift.

## Performance / maintainability

- `5-spec-driven-dev.mdc` body length: 97 lines (was ~50 before; added ~47 for the P7 detail section + properties bullet + anti-pattern bullet). Well within the plan's "~120 lines each" budget.
- `7-ui-verification.mdc` body length: 44 lines. Below the plan's "80–120 lines" estimate — concise, readable, no padding.
- No N+1, no unbounded loops (n/a for doc files). Reading complexity is linear and low.

## Deferred clarifications

`spec.md:104–106` carries one open question:

> **[NEEDS CLARIFICATION: priority=P2]** Exact slug of the future skill that operationalises `7-ui-verification.mdc` (candidates: `ui-verification-mcp`, `browser-visual-diff`, `playwright-mcp-verification`). Defaults to a forward-reference placeholder in the rule's "Skill References" section until decided.

Assessment: The implementation in `7-ui-verification.mdc:37` carries the `[NEEDS CLARIFICATION: priority=P2]` marker verbatim with the same three candidate slugs. The rule does NOT accidentally rely on a resolved slug — every load-bearing invariant (P1, P2, Triggers, Enforcement) is expressed without naming the skill. Defer to next iteration; owner = whoever creates the operationalising skill. **No blocker.**

## Findings

### Low

**L1** — `7-ui-verification.mdc:25` (P1) requires a "before-state and an after-state browser snapshot" but the rule is silent on storage / retention of these snapshots. `7-testing.mdc` is similarly silent on artefact storage for E2E, so the asymmetry is small; nonetheless a future reader may ask "where do I put them?". This is correctly out-of-scope (the future skill will encode it per FR-011), but a one-line note in `## Enforcement` like "snapshot storage location is defined by the UI-verification skill" would close the loop without adding procedural prose. Non-blocking.

**L2** — `7-ui-verification.mdc:8` glob list is a comma-separated string (matching the sibling `7-testing.mdc:5` convention). The repo's other rules occasionally use a YAML list. Both forms are accepted by Cursor/Claude Code rule loaders; the chosen form is consistent with the nearest sibling, so this is informational only. No change requested.

### Info

**I1** — Same-model warning: the dispatch did not carry an `implementerModel` field, so I cannot verify whether Bohr (claude-opus-4-7) is reviewing its own output. If the orchestrator routed implementation to a different model (e.g. claude-sonnet-4-5), the cross-model safety property holds. Otherwise the next pipeline iteration should record `implementerModel` for the speculative reviewer to consume.

**I2** — Speculative mode caveat: per dispatch instructions and `dev-it/SKILL.md` Phase 7 protocol, this review was produced without waiting on VERIFY. The dispatch metadata indicates `verify.sh PASS, all 12 checks` ran inline; if any post-review debugger pass rewrites the produced `.mdc` files, this review must be re-dispatched for the changed files only.

## Asset-registry side-effect

`asset-registry.yml:727–738` adds a single entry for `7-ui-verification.mdc` immediately after the existing `7-testing.mdc` entry at L718. Key shape (`path`, `type: rule`, `tags`, `description` folded scalar) matches the sibling. No other registry entries modified. Indentation is consistent (2-space, matching surrounding entries). **PASS.**

## Verdict reasoning

- Zero Critical (no security / data-loss / regression class issues; personal-trace scan clean).
- Zero High (no architectural drift; FR coverage is complete; sibling pattern respected).
- Zero Medium (no missing-test concerns because this is a doc-only spec; no ambiguity in produced invariants).
- Two Low (snapshot storage note + glob-format consistency observation) — both informational.

Per the reviewer skill verdict rules: only Low → **Approved** with notes. The implementation is mechanically clean, FR-traceable, architecture-compliant, and free of personal traces. Ready for Phase 8 (debugger no-op given green VERIFY) and Phase 11 (PUSH-IT).

## Next hints

- **nextHints**:
  - `phase8: skip-debugger` — VERIFY already green, review found no Critical/High.
  - `phase9: archive-ok` — both deliverables ship as-is.
  - `phase11: ready-to-push` — single commit recommended (3 files: 2 rules + asset-registry entry).
  - `followup-spec`: open a tiny spec for the UI-verification skill once the slug is decided (resolves the deferred P2 clarification).
