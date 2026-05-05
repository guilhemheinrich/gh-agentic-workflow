---
description: >-
  Run the full Specify → Plan → Tasks pipeline in one shot, pausing if any step
  requires user input.
tags:
  - cursor
  - spec-kit
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Command resolution (where definitions live)

Each pipeline step follows the **same** workflow as the corresponding Cursor command, but the backing markdown file may live in **either** place (and under **either** filename):

| Phase   | Slash command (any of)                         | Definition file (any of)                          |
|---------|-----------------------------------------------|---------------------------------------------------|
| Specify | `/speckit.specify` or `/specify`              | `speckit.specify.md` or `specify.md`            |
| Plan    | `/speckit.plan` or `/plan`                    | `speckit.plan.md` or `plan.md`                  |
| Tasks   | `/speckit.tasks` or `/tasks`                  | `speckit.tasks.md` or `tasks.md`                |

**Search locations** (in order — first match wins):

1. **Workspace / repository** where `/spt` was invoked: `<repo>/.cursor/commands/`
2. **User-level** Cursor commands directory (e.g. `~/.cursor/commands/` on Unix, `%USERPROFILE%\.cursor\commands\` on Windows)

For each phase, pick the **first** existing file among the two filenames in location (1); if none exist, repeat for location (2). If no definition file is found for a phase after both locations, **stop** and tell the user which filenames were expected and where to add them.

When reporting progress to the user, mention which path you loaded (repo vs user) and which filename variant you used.

## Purpose

This command orchestrates the three core SpecKit phases sequentially:

1. **Specify** — create the feature specification (resolved command: see table above)
2. **Plan** — produce the technical implementation plan
3. **Tasks** — generate the dependency-ordered task list

Each phase runs to completion before the next one starts. If a phase surfaces questions that require user input (e.g. `[NEEDS CLARIFICATION]` markers, ambiguous scope choices, gate failures needing justification), the workflow **pauses immediately** and presents those questions to the user. Only after the user has answered and the phase has fully completed does the next phase begin.

## Execution Flow

### Phase 1 — Specify

1. **Resolve** the Specify command file per [Command resolution](#command-resolution-where-definitions-live). Execute the **full** workflow defined in that file, passing `$ARGUMENTS` as the feature description.
2. Follow every step of that command: pre-execution hooks, branch creation, spec generation, quality validation, checklist creation, and post-execution hooks.
3. **Pause condition**: If the specify step produces `[NEEDS CLARIFICATION]` questions or any other prompt requiring user input, **STOP HERE**. Present the questions to the user exactly as described in the specify command. Wait for the user's answers, incorporate them into the spec, and finish the specify phase completely before moving on.
4. Once the specify phase reports completion (branch name, spec file path, checklist results), print:

   ```
   ✅ Phase 1/3 — Specify: COMPLETE
   Proceeding to Plan…
   ```

### Phase 2 — Plan

5. **Resolve** the Plan command file per [Command resolution](#command-resolution-where-definitions-live). Execute the **full** workflow defined in that file.
6. Follow every step: setup script, context loading, research phase, design & contracts phase, agent context update, and hooks.
7. **Pause condition**: If the plan step encounters unresolved `NEEDS CLARIFICATION` items, gate failures, or any situation requiring user input, **STOP HERE**. Present the issue to the user and wait for resolution before continuing.
8. Once the plan phase reports completion, print:

   ```
   ✅ Phase 2/3 — Plan: COMPLETE
   Proceeding to Tasks…
   ```

### Phase 3 — Tasks

9. **Resolve** the Tasks command file per [Command resolution](#command-resolution-where-definitions-live). Execute the **full** workflow defined in that file.
10. Follow every step: prerequisites check, design document loading, task generation, tasks.md creation, report, and hooks.
11. **Pause condition**: If the tasks step encounters any situation requiring user input, **STOP HERE** and wait for resolution.
12. Once the tasks phase reports completion, print a final summary:

    ```
    ✅ Phase 3/3 — Tasks: COMPLETE

    ═══════════════════════════════════════
    🏁 /spt Pipeline Complete
    ═══════════════════════════════════════
    Branch:    <branch name>
    Spec:      <spec file path>
    Plan:      <plan file path>
    Tasks:     <tasks file path>
    ═══════════════════════════════════════
    ```

## Rules

- **Sequential execution**: Never start Phase N+1 before Phase N is fully complete (including user Q&A).
- **Pause on questions**: Any time a phase needs user input, stop the pipeline and clearly indicate which phase you are in (e.g. "⏸️ Phase 1/3 — Specify: Waiting for your input").
- **Resume after answers**: Once the user answers, finish the current phase, then continue to the next.
- **Full fidelity**: Each phase must follow the **resolved** command file exactly — do not skip steps, hooks, or validations.
- **Error propagation**: If a phase fails with an unrecoverable error, stop the pipeline and report the failure clearly. Do not proceed to the next phase.
- **Arguments forwarding**: `$ARGUMENTS` is passed as the feature description to the specify phase. Subsequent phases derive their context from the artifacts created by prior phases (spec → plan → tasks).
