#!/usr/bin/env bash
# test-branch-policy.sh — offline regression suite for branch-policy.sh.
#
# Builds throwaway git repositories under $TMPDIR and asserts behaviour, never
# network access. Run it after any change to the script or to either hook.
#
#   ./test-branch-policy.sh          # all cases
#   ./test-branch-policy.sh -k base  # only cases whose name matches
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BP="$HERE/branch-policy.sh"
FILTER="${2:-}"
[ "${1:-}" = "-k" ] || FILTER=""

PASS=0; FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/branch-policy-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

git_() { git -c user.email=t@example.invalid -c user.name=Test "$@"; }

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
case_wanted() { [ -z "$FILTER" ] && return 0; case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac; }

# A repository with main (default) + staging, and a workflow deploying staging.
fixture() {
  local d="$TMP/$1"
  mkdir -p "$d" && cd "$d"
  git init -q -b main o.git --bare
  git clone -q o.git app 2>/dev/null
  cd app
  mkdir -p .github/workflows src
  printf 'on:\n  push:\n    branches: [staging]\njobs:\n  d:\n    steps:\n      - run: kubectl apply -f k8s/\n' \
    > .github/workflows/deploy.yml
  printf 'on: [pull_request]\njobs:\n  t:\n    steps:\n      - run: npm run dev\n      - run: npm run deploy-preview\n' \
    > .github/workflows/ci.yml
  printf '.worktrees/\n' > .gitignore
  git_ add -A && git_ commit -q -m "chore: ci"
  git_ push -q origin main
  git_ checkout -q -b staging && git_ commit -q --allow-empty -m "feat: on staging" && git_ push -q origin staging
  git_ checkout -q -b dev main && git_ push -q origin dev
  git_ checkout -q main
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git_ fetch -q origin
  printf '%s\n' "$d/app"
}

# Installs the policy the way the skill prescribes: committed on EVERY long-lived
# branch. A fixture that leaves staging without it also leaves staging not
# containing main, which is not what a real repository looks like.
install_policy() {
  bash "$BP" init --integration staging --protected main >/dev/null 2>&1
  git_ add -A && git_ commit -q -m "chore: branch policy"
  BRANCH_POLICY_ALLOW=1 git_ push -q origin main
  git_ checkout -q staging && git_ merge -q main -m "chore: policy onto staging"
  git_ push -q origin staging
  git_ checkout -q main && git_ fetch -q origin
}

# ---------------------------------------------------------------- detection
if case_wanted "detect-lock"; then
  printf 'detect\n'
  APP="$(fixture detect)"; cd "$APP"
  out="$(bash "$BP" detect)"
  case "$out" in *"VERDICT  LOCK"*) ok "LOCK on a staging-deploying repository" ;;
    *) bad "LOCK on a staging-deploying repository" "$(printf '%s' "$out" | tail -2)" ;; esac
  # `npm run dev` must not make `dev` a deploy branch.
  case "$out" in *"dev            1"*) ok "dev scores 1, not a false LOCK" ;;
    *) bad "dev scores 1, not a false LOCK" "$(printf '%s' "$out" | grep '^dev' || true)" ;; esac
  # CI files must be found from a subdirectory too.
  cd "$APP/src"
  case "$(bash "$BP" detect)" in *"VERDICT  LOCK"*) ok "LOCK from a subdirectory" ;;
    *) bad "LOCK from a subdirectory" ;; esac
fi

if case_wanted "detect-aligned"; then
  APP="$(fixture aligned)"; cd "$APP"
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/staging
  case "$(bash "$BP" detect)" in *"VERDICT  ALIGNED"*) ok "ALIGNED when the deploy branch is the default" ;;
    *) bad "ALIGNED when the deploy branch is the default" ;; esac
fi

if case_wanted "detect-skip"; then
  mkdir -p "$TMP/skip" && cd "$TMP/skip" && git init -q -b main .
  case "$(bash "$BP" detect 2>&1)" in *"VERDICT  SKIP"*) ok "SKIP on an unborn repository, no crash" ;;
    *) bad "SKIP on an unborn repository, no crash" ;; esac
fi

# Branch names are variables, not constants. Same behaviour on a repository whose
# roles are carried by `develop` and `production`, with no `staging` anywhere.
if case_wanted "names-are-variables"; then
  d="$TMP/gitflow"; mkdir -p "$d" && cd "$d"
  git init -q -b master o.git --bare
  git clone -q o.git app 2>/dev/null
  cd app
  mkdir -p .github/workflows
  printf 'on:\n  push:\n    branches: [develop]\njobs:\n  d:\n    steps:\n      - run: helm upgrade app .\n' \
    > .github/workflows/deploy.yml
  printf '.worktrees/\n' > .gitignore
  git_ add -A && git_ commit -q -m "chore: ci" && git_ push -q origin master
  git_ checkout -q -b production master && git_ push -q origin production
  git_ checkout -q -b develop master && git_ commit -q --allow-empty -m "feat: on develop" && git_ push -q origin develop
  git_ checkout -q master
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
  git_ fetch -q origin

  out="$(bash "$BP" detect)"
  case "$out" in *"VERDICT  LOCK"*) ok "LOCK names develop, with no staging in the repository" ;;
    *) bad "LOCK names develop, with no staging in the repository" "$(printf '%s' "$out" | tail -2)" ;; esac
  case "$out" in *"--integration develop"*) ok "the suggested command carries develop" ;;
    *) bad "the suggested command carries develop" ;; esac

  bash "$BP" init --integration develop --protected "production master" >/dev/null 2>&1
  git_ add -A && git_ commit -q -m "chore: policy"
  BRANCH_POLICY_ALLOW=1 git_ push -q origin master
  git_ checkout -q develop && git_ merge -q master -m "chore: policy onto develop" && git_ push -q origin develop
  git_ checkout -q master && git_ fetch -q origin

  bash "$BP" worktree feat/z >/dev/null 2>&1
  [ "$(git -C "$d/app/.worktrees/feat-z" rev-parse HEAD)" = "$(git rev-parse origin/develop)" ] \
    && ok "a worktree starts at origin/develop" || bad "a worktree starts at origin/develop"
  [ "$(cd "$d/app/.worktrees/feat-z" && bash "$BP" pr-base 2>/dev/null)" = develop ] \
    && ok "pr-base answers develop" || bad "pr-base answers develop"

  git_ commit -q --allow-empty -m "chore: y"
  out="$(git_ push origin HEAD:production 2>&1 || true)"
  case "$out" in *"BLOCKED: direct push to protected branch 'production'"*) ok "a push to production is blocked" ;;
    *) bad "a push to production is blocked" ;; esac
  case "$out" in *"CI deploys from 'develop'"*) ok "the refusal names develop as the target to use" ;;
    *) bad "the refusal names develop as the target to use" ;; esac
fi

# ------------------------------------------------------------------ install
if case_wanted "install"; then
  printf 'install\n'
  APP="$(fixture install)"; cd "$APP"
  out="$(bash "$BP" init --integration staging --protected main 2>&1)"
  case "$out" in *"UNTRACKED .branch-policy"*) ok "untracked policy is reported" ;;
    *) bad "untracked policy is reported" ;; esac
  [ -x "$(git rev-parse --git-path hooks)/pre-push" ] && ok "pre-push installed executable" || bad "pre-push installed executable"
  git_ add -A && git_ commit -q -m policy
  bash "$BP" doctor >/dev/null 2>&1 && ok "doctor exits 0 once installed" || bad "doctor exits 0 once installed"

  # An existing foreign hook must not be clobbered.
  printf '#!/bin/sh\nexit 0\n' > "$(git rev-parse --git-path hooks)/pre-push"
  out="$(bash "$BP" init --integration staging --protected main 2>&1)"
  case "$out" in *"CHAIN"*) ok "existing hook is chained, not replaced" ;; *) bad "existing hook is chained, not replaced" ;; esac

  # --force must refuse under a hook manager.
  git config core.hooksPath .husky && mkdir -p .husky && printf '#!/bin/sh\nexit 0\n' > .husky/pre-push
  out="$(bash "$BP" init --integration staging --protected main --force 2>&1 || true)"
  case "$out" in *"refusing --force"*) ok "--force refused under core.hooksPath" ;; *) bad "--force refused under core.hooksPath" ;; esac
  git config --unset core.hooksPath
fi

# ------------------------------------------------------------------- policy
if case_wanted "policy-injection"; then
  printf 'policy\n'
  APP="$(fixture inject)"; cd "$APP"; install_policy
  canary="$TMP/CANARY"
  printf 'INTEGRATION_BRANCH=staging\nPROTECTED_BRANCHES="main $(touch %s)"\n' "$canary" > .branch-policy
  bash "$BP" doctor >/dev/null 2>&1 || true
  if [ -e "$canary" ]; then bad "a command substitution in the policy is not executed"
  else ok "a command substitution in the policy is not executed"; fi
  git_ checkout -q -- .branch-policy
fi

if case_wanted "policy-fallback"; then
  APP="$(fixture fallback)"; cd "$APP"; install_policy
  # A branch cut before the policy existed: its tree carries no .branch-policy,
  # which is exactly the case that used to disarm the hooks.
  root="$(git rev-list --max-parents=0 HEAD | head -1)"
  git worktree add -q --no-track -b feat/old "$APP/.worktrees/feat-old" "$root"
  cd "$APP/.worktrees/feat-old"
  if [ -f .branch-policy ]; then
    bad "fixture invalid: the old branch already carries the policy"
  else
    ok "the old branch carries no policy file"
  fi
  [ "$(bash "$BP" pr-base 2>/dev/null)" = staging ] \
    && ok "pr-base answers from a branch whose tree lacks the policy" \
    || bad "pr-base answers from a branch whose tree lacks the policy"
fi

# ---------------------------------------------------------------- pre-push
if case_wanted "push-blocked"; then
  printf 'pre-push\n'
  APP="$(fixture push)"; cd "$APP"; install_policy
  git_ commit -q --allow-empty -m "chore: x"
  out="$(git_ push origin HEAD:main 2>&1 || true)"
  case "$out" in *BLOCKED*) ok "refspec push to main is blocked" ;; *) bad "refspec push to main is blocked" ;; esac
  out="$(BRANCH_POLICY_ALLOW=1 git_ push origin main 2>&1 || true)"
  case "$out" in *BLOCKED*) bad "BRANCH_POLICY_ALLOW bypasses" ;; *) ok "BRANCH_POLICY_ALLOW bypasses" ;; esac

  # A tag carries no base branch and must not be inspected.
  git_ tag -a v1.0.0 -m v1
  out="$(git_ push origin v1.0.0 2>&1 || true)"
  case "$out" in *"WRONG BASE"*) bad "a tag push produces no base warning" ;; *) ok "a tag push produces no base warning" ;; esac

  # A fork is not the repository the policy describes.
  git init -q -b main --bare "$TMP/push/fork.git" && git remote add fork "$TMP/push/fork.git"
  out="$(git_ push fork main 2>&1 || true)"
  case "$out" in *BLOCKED*) bad "a push to a fork remote is allowed" ;; *) ok "a push to a fork remote is allowed" ;; esac
fi

if case_wanted "push-base"; then
  APP="$(fixture base)"; cd "$APP"; install_policy
  # Correctly based branch, then someone else merges into staging: stay silent.
  bash "$BP" worktree feat/right >/dev/null 2>&1
  git_ checkout -q staging && git_ commit -q --allow-empty -m "feat: someone else" && git_ push -q origin staging
  git_ checkout -q main && git_ fetch -q origin
  cd "$APP/.worktrees/feat-right" && git_ commit -q --allow-empty -m "feat: mine"
  out="$(git_ push origin feat/right 2>&1 || true)"
  case "$out" in *"WRONG BASE"*) bad "a branch cut from staging stays silent when staging advances" ;;
    *) ok "a branch cut from staging stays silent when staging advances" ;; esac

  # Branch cut from production while staging is ahead: warn, but let it through.
  cd "$APP" && git_ checkout -q -b feat/wrong origin/main && git_ commit -q --allow-empty -m "feat: oops"
  out="$(git_ push origin feat/wrong 2>&1 || true)"
  case "$out" in *"WRONG BASE"*) ok "a branch cut from production is named" ;; *) bad "a branch cut from production is named" ;; esac
  case "$out" in *"feat/wrong -> feat/wrong"*|*"new branch"*) ok "the warning does not block the push" ;;
    *) bad "the warning does not block the push" ;; esac

  git_ commit -q --allow-empty -m "feat: oops2"
  if BRANCH_POLICY_STRICT=1 git_ push origin feat/wrong >/dev/null 2>&1; then
    bad "BRANCH_POLICY_STRICT refuses the push"
  else
    ok "BRANCH_POLICY_STRICT refuses the push"
  fi
fi

# ---------------------------------------------------------------- worktree
if case_wanted "worktree"; then
  printf 'worktree\n'
  APP="$(fixture wt)"; cd "$APP"; install_policy
  bash "$BP" worktree feat/a >/dev/null 2>&1
  [ "$(git -C "$APP/.worktrees/feat-a" rev-parse HEAD)" = "$(git rev-parse origin/staging)" ] \
    && ok "a feature worktree starts at origin/staging" || bad "a feature worktree starts at origin/staging"
  [ -z "$(git -C "$APP/.worktrees/feat-a" config --get branch.feat/a.merge || true)" ] \
    && ok "no upstream is set (--no-track)" || bad "no upstream is set (--no-track)"
  bash "$BP" worktree hotfix/b >/dev/null 2>&1
  [ "$(git -C "$APP/.worktrees/hotfix-b" rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    && ok "a hotfix worktree starts at origin/main" || bad "a hotfix worktree starts at origin/main"
fi

# ------------------------------------------------------------------- drift
if case_wanted "drift"; then
  printf 'drift\n'
  APP="$(fixture drift)"; cd "$APP"; install_policy
  bash "$BP" drift >/dev/null 2>&1 && ok "no drift on a clean repository" || bad "no drift on a clean repository"

  # A hotfix that landed on main and never came back is counted.
  bash "$BP" worktree hotfix/c >/dev/null 2>&1
  ( cd "$APP/.worktrees/hotfix-c" && git_ commit -q --allow-empty -m "fix: urgent" \
      && BRANCH_POLICY_ALLOW=1 git_ push -q origin HEAD:main )
  git_ fetch -q origin
  case "$(bash "$BP" doctor 2>&1)" in *"DEBT    1 commit"*) ok "forward-port debt is counted" ;;
    *) bad "forward-port debt is counted" ;; esac

  # A new deploy-looking branch arriving by fetch leaves a notice, clearable.
  git -C "$TMP/drift/o.git" branch preprod main
  git_ fetch -q origin 2>/dev/null
  case "$(bash "$BP" drift 2>&1 || true)" in *"fetch notices pending"*) ok "the fetch hook records a notice" ;;
    *) bad "the fetch hook records a notice" ;; esac
  bash "$BP" drift --clear >/dev/null 2>&1 || true
  case "$(bash "$BP" drift 2>&1 || true)" in *"fetch notices pending"*) bad "--clear clears the notices" ;;
    *) ok "--clear clears the notices" ;; esac
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
