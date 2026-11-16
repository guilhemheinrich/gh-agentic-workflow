#!/usr/bin/env bash
# skills/static-validation-hooks/tests/fixtures/worktree.sh
#
# A main checkout and a linked worktree of it, both carrying the SAME Compose
# file — which is the whole point. Since the project name is resolved by asking
# Compose, a linked worktree now resolves its main checkout's stack, and the
# only thing standing between the agent and a verdict about a file it did not
# write is the checkout-identity test (plan D6, FR-016).
#
# Nothing here is thrown away by `git clean` or touched outside $CASE_DIR, and
# no git identity is read from the developer's own configuration: the commit is
# made with `-c user.name/-c user.email` so a machine with no global git config
# runs the suite exactly like one that has it.
#
# bash 3.2 compatible.

# voe_worktree_fixture MAIN_DIR WT_DIR DECLARED_PROJECT IMAGE
# Creates MAIN_DIR as a git repository holding compose.yml (declaring
# DECLARED_PROJECT) and app.txt, then adds WT_DIR as a linked worktree of it.
voe_worktree_fixture() {
  local main="$1" wt="$2" declared="$3" image="$4"

  command -v git >/dev/null 2>&1 || {
    printf 'fixture: git is not on PATH, so the worktree cases cannot run\n' >&2
    return 1
  }

  mkdir -p "$main" || return 1
  cat >"$main/compose.yml" <<YML
name: $declared
services:
  app:
    image: $image
    command: sleep 900
YML
  printf 'clean\n' >"$main/app.txt"

  git -C "$main" init -q >/dev/null 2>&1 || { printf 'fixture: git init failed\n' >&2; return 1; }
  git -C "$main" add -A >/dev/null 2>&1 || return 1
  git -c user.name=voe -c user.email=voe@example.invalid -C "$main" \
    commit -q -m "voe fixture" >/dev/null 2>&1 || {
      printf 'fixture: git commit failed\n' >&2; return 1; }
  git -C "$main" worktree add -q -b voe-wt "$wt" >/dev/null 2>&1 || {
    printf 'fixture: git worktree add failed\n' >&2; return 1; }

  # The fixture must really be a LINKED worktree, or the case would assert
  # against an ordinary directory and pass for the wrong reason.
  local gd gcd
  gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)"
  gcd="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -z "$gd" ] || [ "$gd" = "$gcd" ]; then
    printf 'fixture: %s is not a linked worktree (git-dir=%s common=%s)\n' "$wt" "$gd" "$gcd" >&2
    return 1
  fi
  [ -f "$wt/compose.yml" ] || {
    printf 'fixture: the worktree does not carry compose.yml\n' >&2; return 1; }
  return 0
}
