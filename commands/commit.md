---
name: commit
description: >-
  Smart commit using the gitter agent. Analyzes all pending changes, groups them
  into logical semantic batches, and commits each with a conventional message.
tags:
  - git
---

# `/commit` — Semantic Smart Commit

Delegate entirely to the **gitter** agent (`@gitter`).

## Behavior

1. Invoke the gitter agent
2. The gitter agent analyzes all pending changes (staged, unstaged, untracked)
3. Groups files into **logical semantic batches** (by feature, intent, module)
4. Commits each batch with a proper **Conventional Commits** message

## Usage

```
/commit
/commit only the auth module changes
/commit with scope api
```

## Delegation

This command is a thin wrapper. All logic lives in the gitter agent.

**Agent**: `@gitter` — invoke with the smart commit workflow (default action).
