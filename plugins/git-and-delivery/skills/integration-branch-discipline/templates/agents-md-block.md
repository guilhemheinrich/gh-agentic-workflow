<!--
Paste this section into the consumer repository's AGENTS.md (and let CLAUDE.md
point at it, rather than duplicating the text).

Replace every <PLACEHOLDER> with this repository's own branch names, taken from
.branch-policy — never from habit:

  <INTEGRATION_BRANCH>  = INTEGRATION_BRANCH  (develop, staging, preprod, recette…)
  <PROTECTED_BRANCH>    = first of PROTECTED_BRANCHES (main, master, production…)
  <EXCEPTION_PREFIXES>  = EXCEPTION_PREFIXES  (hotfix/ revert/)
  <ENVIRONMENT>         = what the integration branch deploys to (staging, QA…)

Keep the values identical to .branch-policy — two sources of truth that disagree
are worse than none.
-->

## Branch policy — the entry door is `<INTEGRATION_BRANCH>`

CI deploys `<INTEGRATION_BRANCH>` to `<ENVIRONMENT>` on every merge.
`<PROTECTED_BRANCH>` is the production record, and nothing lands there except a
promotion of `<INTEGRATION_BRANCH>` or a hotfix. The machine-readable copy of
this policy is `.branch-policy` at the repository root; read it rather than
assuming.

Four rules, in force for every agent and every human:

1. **Branch from `origin/<INTEGRATION_BRANCH>`, never from `<PROTECTED_BRANCH>`.**
   ```bash
   git fetch origin <INTEGRATION_BRANCH>
   git worktree add --no-track -b feat/<slug> .worktrees/<slug> origin/<INTEGRATION_BRANCH>
   ```
   Equivalent one-liner: `branch-policy.sh worktree feat/<slug>`. The
   `--no-track` matters: an upstream pointing at a protected branch turns a plain
   `git push` into a push at production.

2. **Every pull request targets `<INTEGRATION_BRANCH>` — except an exception
   branch, which targets `<PROTECTED_BRANCH>`.** State the base explicitly; a
   default is a thing that changes without telling you. `branch-policy.sh pr-base`
   prints the right one for the current branch, exception included.
   ```bash
   gh pr create --base "$(branch-policy.sh pr-base)" --head "$(git rev-parse --abbrev-ref HEAD)"
   ```

3. **Never push to `<PROTECTED_BRANCH>` directly.** The local `pre-push` hook
   refuses it. If you find yourself reaching for `--no-verify`, the answer is a
   pull request, not a bypass.

4. **Exceptions are named, not improvised.** Only `<EXCEPTION_PREFIXES>` branches
   may cut from `<PROTECTED_BRANCH>`, and `branch-policy.sh worktree` bases them
   there automatically. A hotfix that ships to production is forward-ported into
   `<INTEGRATION_BRANCH>` the same day; otherwise the next branch cut from
   `<INTEGRATION_BRANCH>` does not contain the fix and ships the bug again.

### When you are unsure

Run `branch-policy.sh doctor`. It prints the policy in force, whether the hooks
are installed, whether `origin/<INTEGRATION_BRANCH>` exists, and how many commits
on `<PROTECTED_BRANCH>` still owe a forward-port. Do not guess the base branch
from the repository's default branch: on this repository they differ on purpose.
