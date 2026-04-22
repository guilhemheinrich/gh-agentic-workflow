---
name: merge
description: >-
  Merge current branch into the target using the gitter agent. Cautious about
  regressions. If the merge strategy is ambiguous or not specified, asks the user
  for clarification before proceeding.
---

# `/merge` — Cautious Merge

Delegate entirely to the **gitter** agent (`@gitter`).

## Behavior

1. Invoke the gitter agent to perform the merge
2. **Regression awareness**: the gitter agent must check for potential conflicts and regressions before merging
3. **Strategy clarification**: if the merge strategy has **not** been explicitly indicated (merge commit, squash, rebase, fast-forward), the gitter agent **MUST ask the user** before proceeding — never guess

## Usage

```
/merge
/merge into develop
/merge into main --squash
/merge staging
```

## Critical Rules

- **NEVER auto-pick a merge strategy** if it wasn't specified by the user. Always ask.
- **NEVER force-merge** through conflicts. Stop and report.
- **Always fetch and pull** the target branch before merging to avoid stale merges.
- **Check for regressions**: review the diff between the branches. If the merge introduces deletions of important code, reversions, or conflicting changes — warn the user before proceeding.
- If no target branch is specified, use the gitter agent's default target resolution (`develop` → `staging` → `main` → `master`).

## Clarification Example

When the strategy is ambiguous, the gitter agent should return something like:

> Je m'apprête à merger `feat/042-auth-flow` dans `develop`.
> Quelle stratégie de merge souhaitez-vous ?
> - **merge commit** (`git merge --no-ff`)
> - **squash** (`git merge --squash`)
> - **rebase** (`git rebase`)
> - **fast-forward** (`git merge --ff-only`)

## Delegation

This command is a thin wrapper. All logic lives in the gitter agent.

**Agent**: `@gitter` — invoke with the merge workflow.
