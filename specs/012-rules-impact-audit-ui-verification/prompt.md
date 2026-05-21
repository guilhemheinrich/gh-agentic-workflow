# Spec 012 — Rules: Impact Audit + UI Verification

## Original request (fr)

Voici une proposition d'amélioration sur plusieurs points pour mon agentic. Vérifie que cela reste pertinent dans le contexte de ce repo, en particulier dans le dossier rules :

- Toujours utiliser un lsp pour vérifier où les fonctions modifiées sont appelées : si on modifie une fonction A dans le cadre d'une spec, pour une raison X, il faut vérifier les points d'impact en vérifiant les occurrences de la fonction. Sinon on peut avoir des effets de bord qui mènent à des régressions.
- Ajouter un AGENTS.md à la racine de chaque projet frontend : lorsqu'on modifie le frontend, il faut impérativement (MUST) prendre un screenshot via le MCP playwright (ou autre outil de browser) AVANT l'endroit où la modification s'effectue, et APRÈS, et se poser la question de la cohérence vis-à-vis de la spec.
- De la même manière, lorsqu'on ajoute un élément interactif dans l'UI, on doit impérativement (MUST) vérifier en cliquant dessus dans un browser intégré / MCP, et vérifier si le résultat est celui qu'on attend.

Y a-t-il des redites ? Est-ce pertinent ?

## Scope clarification (post-analysis, validated by user)

**OUT OF SCOPE**: no edit to root `AGENTS.md`. The "frontend AGENTS.md" idea from the original request is dropped. Everything captured by this spec lives under `rules/`.

**IN SCOPE — two deliverables**:

1. **Extend `rules/05-workflows-and-processes/5-spec-driven-dev.mdc`** with a new property **P7 (impact-audit)** broader than the existing P6 (rename-audit). Trigger: any spec that modifies the signature or behavior of an exported function/method/class. Required action: a cross-codebase call-site sweep (LSP "Find References", `rg`, or equivalent) added as an explicit task in `tasks.md`.

2. **Create `rules/07-quality-assurance/7-ui-verification.mdc`** — a new rule fusing the two UI-related proposals into a single invariant: any spec that ships a frontend change MUST, at implementation time (not via the codified E2E suite), verify the change in a real browser via the Playwright MCP (or equivalent browser tool). Two sub-properties:
   - **P1 (visual diff)**: snapshot the page BEFORE the change is applied AND AFTER, then confirm the diff matches what the spec describes.
   - **P2 (interactive validation)**: when a new interactive element is added (button, form field, link, etc.), actually click/use it in the browser and confirm the observable outcome matches the spec.

## English translation

Proposal for improvements to my agentic stack — verify relevance in the context of this repo, in particular the `rules/` folder:

- Always use an LSP to verify where modified functions are called: when a function A is changed for spec reason X, impact points MUST be audited by listing the function's occurrences across the codebase. Otherwise side-effects lead to regressions.
- ~~Add an `AGENTS.md` at the root of every frontend project~~ **(dropped)**. When a frontend change is implemented, MUST take a screenshot via Playwright MCP (or another browser tool) BEFORE the modification site AND AFTER, then ask: is this consistent with the spec?
- Similarly, when an interactive UI element is added, MUST verify by clicking it in an integrated browser / MCP and confirm the result matches expectations.

Are there redundancies? Is this relevant?

## Non-goals

- No changes to the root `AGENTS.md`.
- No new skill is produced by this spec (the procedure for *how* to use Playwright MCP for snapshot-and-click verification is left for a future skill).
- No tooling/automation is produced: the rules describe invariants the agent / human must follow, not scripts.
- No code, no E2E suite — this spec only writes/edits `.mdc` rule files.

## Context for the spec author

- Existing rule `rules/05-workflows-and-processes/5-spec-driven-dev.mdc` already defines P1..P6; we ADD P7 in the same shape (Trigger + Required `tasks.md` template + Reviewer red flag + Failure mode).
- Existing rule taxonomy lives under `rules/{00..09}-*/`; `07-quality-assurance/` is the chosen folder for the new UI verification rule per `rules/00-architecture/0-rules-structure.mdc`.
- The repo has no frontend itself — these rules are templates consumed by downstream projects. Therefore globs MUST narrow to frontend file types only (`**/*.tsx,**/*.vue,**/*.svelte,**/*.html,...`) to avoid loading the rule on backend-only specs.
- Existing skills/rules NOT redundant with this spec:
  - `skills/e2e-spec-writing/SKILL.md` — about writing E2E spec docs, not about dev-time browser verification.
  - `rules/07-quality-assurance/7-testing.mdc` — agnostic testing principles, mentions Playwright only as a reference.
  - `rules/05-workflows-and-processes/5-spec-driven-dev.mdc` P6 — semantic rename audit, narrower trigger than P7.
