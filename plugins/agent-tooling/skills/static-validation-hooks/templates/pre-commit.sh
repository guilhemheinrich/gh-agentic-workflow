#!/usr/bin/env bash
# .githooks/pre-commit
#
# Replays the on-edit validation hook over the staged files. Covers what the
# agent hook never sees: files written through the Bash tool, code generators,
# human edits. Activate with `git config core.hooksPath .githooks` (a `hooks`
# target in the task runner, and the SessionStart hook in a cloud session).
#
# - VALIDATE_NO_FIX=1: report only. A `--fix` would repair the working tree and
#   commit the unfixed index anyway.
# - The per-file budget is raised: nothing loops on an agent here, and a check
#   killed by the budget is a warning, i.e. a false pass.
# - It reads the working-tree copy of each staged file, not the index blob.
# - One-off bypass: git commit --no-verify.
set -uo pipefail

root="$(git rev-parse --show-toplevel)" || exit 1
cd "$root" || exit 1
hook=.agents/hooks/validate-on-edit.sh
[[ -x "$hook" ]] || exit 0

export VALIDATE_NO_FIX=1
export VALIDATE_BUDGET_S="${VALIDATE_BUDGET_S:-30}"

failed=0
while IFS= read -r -d '' file; do
  [[ -f "$file" ]] || continue
  out="$("$hook" --check "$file" 2>&1)"; rc=$?
  if (( rc != 0 )); then
    printf '%s\n\n' "$out" >&2
    failed=1
  elif [[ "$out" == *'[validate]'* ]]; then
    # Warning (stack down, unrouted extension…): shown, never blocking.
    printf '%s\n\n' "$out" | sed -n '/\[validate\]/,$p' >&2
  fi
done < <(git diff --cached --name-only --diff-filter=ACMR -z)

(( failed )) && printf 'pre-commit: static validation failed, commit refused.\n' >&2
exit "$failed"
