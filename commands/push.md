---
name: push
description: >-
  Push current branch to the remote using the gitter agent. If the current branch
  is a feature branch, returns a link to create a Pull Request with a suggested
  description.
---

# `/push` — Push to Remote

Delegate entirely to the **gitter** agent (`@gitter`).

## Behavior

1. Invoke the gitter agent to push the current branch to the remote
2. If no upstream is set, push with `-u origin <branch>`
3. **If (and only if) the current branch is a feature branch** (e.g. `feat/...`, `fix/...`, `feature/...`, `chore/...`, or any branch that is not `main`, `master`, `develop`, `staging`):
   - Generate a PR description based on the commits on this branch (vs. base branch)
   - Return a **clickable link** to create a Pull Request on the remote (GitHub/Bitbucket)
   - Include a suggested PR title and body summary

## Usage

```
/push
```

## Feature Branch Detection

A branch is considered a feature branch if it is **not** one of: `main`, `master`, `develop`, `staging`.

When detected as a feature branch, the gitter agent must:
1. Identify the base branch (using merge target resolution: `develop` → `staging` → `main` → `master`)
2. Summarize commits between base and HEAD
3. Provide the PR creation link with pre-filled title and body

## Delegation

This command is a thin wrapper. All logic lives in the gitter agent.

**Agent**: `@gitter` — invoke with the push workflow.
