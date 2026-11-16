#!/usr/bin/env bash
# branch-policy.sh — integration-branch discipline for worktrees, pushes and PRs.
#
#   detect     inspect the repository, report the deploy branch and a verdict
#   init       write .branch-policy and install the local git hooks
#   doctor     report what is installed, what is missing, what is bypassable
#   worktree   create a worktree branched from the right base
#   pr-base    print the base branch a pull request must target
#   drift      re-run detection and compare it with the committed policy
#
# Bash 3.2 compatible (macOS system bash). No associative arrays, no ${x,,}.
set -euo pipefail

VERSION="1.1.0"
HOOK_MARKER="branch-policy-hook v1"
POLICY_REL=".branch-policy"

# Branch names that mean "CI deploys from here" in the wild, with an optional
# environment suffix (staging-eu). Override with BRANCH_POLICY_CANDIDATES.
CANDIDATE_NAMES="${BRANCH_POLICY_CANDIDATES:-staging develop dev preprod pre-prod integration next qa uat recette sandbox preview testing demo acceptance}"

# `environment:` is deliberately absent: GitHub Environments gate non-deploy jobs
# too, and it produced a LOCK on a test-only branch.
DEPLOY_RE='deploy|argocd|helm|kubectl|image_tag|imageTag|ecr|ecs|cloudfront|s3 sync|docker push|npm publish'

die() { printf 'branch-policy: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

repo_root() { git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository"; }
hooks_dir() { git rev-parse --git-path hooks; }   # honours core.hooksPath, and the common dir from a linked worktree

policy_path() { printf '%s/%s\n' "$(repo_root)" "$POLICY_REL"; }

candidate_re() {
  local n re=""
  for n in $CANDIDATE_NAMES; do re="${re}${re:+|}${n}"; done
  printf '^(%s)(-[a-z0-9._-]+)?$\n' "$re"
}

# Parse, never source. `.branch-policy` arrives with a clone; sourcing it would
# execute whatever a repository author wrote into it.
parse_policy() {
  local line key val
  while IFS= read -r line; do
    case "$line" in \#*|"") continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"
    case "$val" in *[!A-Za-z0-9._/\ -]*) note "branch-policy: ignoring unsafe value for $key"; continue ;; esac
    case "$key" in
      INTEGRATION_BRANCH) INTEGRATION_BRANCH="$val" ;;
      PROTECTED_BRANCHES) PROTECTED_BRANCHES="$val" ;;
      EXCEPTION_PREFIXES) EXCEPTION_PREFIXES="$val" ;;
      POLICY_REVIEWED)    POLICY_REVIEWED="$val" ;;
    esac
  done < "$1"
}

default_branch() {
  local d b
  d="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$d" ]; then printf '%s\n' "${d#origin/}"; return 0; fi
  for b in main master; do
    if git show-ref --verify --quiet "refs/remotes/origin/$b" || git show-ref --verify --quiet "refs/heads/$b"; then
      printf '%s\n' "$b"; return 0
    fi
  done
  # `git symbolic-ref` answers on an unborn HEAD; `rev-parse` fails there.
  git symbolic-ref --quiet --short HEAD 2>/dev/null || echo main
}

# A topic branch cut before the policy was committed carries no file in its tree.
# Fall back to the copy on HEAD, then on the long-lived branches, so `pr-base`
# answers instead of pretending the repository has no policy.
load_policy() {
  INTEGRATION_BRANCH=""; PROTECTED_BRANCHES=""; EXCEPTION_PREFIXES=""; POLICY_REVIEWED=""
  POLICY_SOURCE=""
  local p tmp ref def
  p="$(policy_path)"
  if [ -f "$p" ]; then
    parse_policy "$p"
    if [ -n "$INTEGRATION_BRANCH" ] && [ -n "$PROTECTED_BRANCHES" ]; then
      POLICY_SOURCE="working tree"; return 0
    fi
  fi
  def="$(default_branch)"
  tmp="$(mktemp)"
  # Best-effort list of places the policy is likely committed. The two deploy
  # names here are guesses for the chicken-and-egg case only: the integration
  # branch is unknown until the policy is found.
  for ref in HEAD "refs/remotes/origin/$def" refs/remotes/origin/main refs/remotes/origin/master \
             refs/remotes/origin/staging refs/remotes/origin/develop \
             "refs/heads/$def" refs/heads/main refs/heads/master; do
    if git show "$ref:$POLICY_REL" > "$tmp" 2>/dev/null; then
      parse_policy "$tmp"
      if [ -n "$INTEGRATION_BRANCH" ] && [ -n "$PROTECTED_BRANCHES" ]; then
        POLICY_SOURCE="$ref (not in this working tree)"; rm -f "$tmp"; return 0
      fi
    fi
  done
  rm -f "$tmp"
  return 1
}

all_branch_names() {
  git for-each-ref --format='%(refname:short)' refs/remotes/origin refs/heads 2>/dev/null \
    | sed 's#^origin/##' | grep -v '^HEAD$' | sort -u || true
}

# `git ls-files` resolves its pathspecs against the CWD, so it must be anchored
# to the repository root or it returns nothing from a subdirectory.
ci_files() {
  git -C "$(repo_root)" ls-files \
    '.github/workflows/*' '.github/actions/*' \
    'bitbucket-pipelines.yml' '.gitlab-ci.yml' '.gitlab/ci/*' \
    'azure-pipelines.yml' '.azure-pipelines/*' \
    '.circleci/config.yml' 'Jenkinsfile' '.drone.yml' 2>/dev/null | sort -u
}

# Does FILE name BRANCH in a branch-trigger position, rather than anywhere at all?
# `npm run dev` must not turn `dev` into a deploy branch.
ci_branch_hit() {
  local name="$1" file="$2"
  awk -v name="$name" '
    function boundary(s, i, n,   b, a) {
      b = (i > 1) ? substr(s, i - 1, 1) : ""
      a = substr(s, i + n, 1)
      return (b !~ /[A-Za-z0-9_\/-]/ && a !~ /[A-Za-z0-9_\/-]/)
    }
    {
      here = (tolower($0) ~ /branch|only:|except:|trigger|ref_name|ref:/)
      i = index($0, name)
      if (i > 0 && boundary($0, i, length(name)) && (here || ctx > 0)) { found = 1 }
      if (here) { ctx = 4 } else if (ctx > 0) { ctx-- }
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

# score_candidate <name> -> "<score>\t<deploy?>\t<evidence>"
score_candidate() {
  local name="$1" score=0 ev="" f root ci_hit="" deploy_hit=""
  root="$(repo_root)"
  if git show-ref --verify --quiet "refs/remotes/origin/$name"; then
    score=$((score + 1)); ev="on origin"
  else
    ev="local only"
  fi
  # `git ls-files` prints repo-relative paths. Resolving them against the cwd
  # skipped every CI file when the command ran from a subdirectory.
  for f in $(ci_files); do
    [ -f "$root/$f" ] || continue
    if ci_branch_hit "$name" "$root/$f"; then
      ci_hit="${ci_hit}${ci_hit:+,}$f"
      if grep -qiE "$DEPLOY_RE" "$root/$f" 2>/dev/null; then deploy_hit="$f"; fi
    fi
  done
  if [ -n "$ci_hit" ]; then
    score=$((score + 2))
    ev="$ev; triggers $(printf '%s' "$ci_hit" | tr ',' '\n' | head -2 | tr '\n' ' ')"
  fi
  if [ -n "$deploy_hit" ]; then
    score=$((score + 1)); ev="$ev; deploy keywords in $deploy_hit"
  fi
  printf '%s\t%s\t%s\n' "$score" "${deploy_hit:+yes}" "$ev"
}

cmd_detect() {
  local def re best_name="" best_score=0 best_deploy="" line score deploy ev name found=0
  local def_score=0 def_deploy=""
  def="$(default_branch)"; re="$(candidate_re)"
  printf 'repository      %s\n' "$(repo_root)"
  printf 'default branch  %s\n' "$def"
  printf 'CI files        %s\n' "$(ci_files | tr '\n' ' ' | sed 's/ $//')"
  printf '\n%-14s %-6s %s\n' "CANDIDATE" "SCORE" "EVIDENCE"

  # The default branch is scored too: a repository whose default IS the deploy
  # branch is a different, and legitimate, configuration.
  if printf '%s\n' "$def" | grep -qE "$re"; then
    line="$(score_candidate "$def")"
    def_score="$(printf '%s' "$line" | cut -f1)"; def_deploy="$(printf '%s' "$line" | cut -f2)"
    printf '%-14s %-6s %s\n' "$def" "$def_score" "$(printf '%s' "$line" | cut -f3) [default branch]"
  fi

  for name in $(all_branch_names); do
    printf '%s\n' "$name" | grep -qE "$re" || continue
    [ "$name" = "$def" ] && continue
    found=1
    line="$(score_candidate "$name")"
    score="$(printf '%s' "$line" | cut -f1)"
    deploy="$(printf '%s' "$line" | cut -f2)"
    ev="$(printf '%s' "$line" | cut -f3)"
    printf '%-14s %-6s %s\n' "$name" "$score" "$ev"
    # Highest score wins; a deploy keyword breaks a tie.
    if [ "$score" -gt "$best_score" ] || { [ "$score" = "$best_score" ] && [ -n "$deploy" ] && [ -z "$best_deploy" ]; }; then
      best_score="$score"; best_name="$name"; best_deploy="$deploy"
    fi
  done
  if [ "$found" = 0 ] && [ "$def_score" = 0 ]; then
    printf '%-14s %-6s %s\n' "(none)" "-" "no deploy-style branch exists (develop, staging, preprod, ...)"
  fi

  printf '\n'
  if [ -n "$best_deploy" ] && [ "$best_score" -ge 4 ]; then
    printf 'VERDICT  LOCK — CI deploys from %s, but git points everything at %s.\n' "$best_name" "$def"
    printf '         branch-policy.sh init --integration %s --protected "%s"\n' "$best_name" "$def"
    return 0
  fi
  if [ -n "$def_deploy" ]; then
    printf 'VERDICT  ALIGNED — the deploy branch %s is already the default branch.\n' "$def"
    printf '         Pull requests already propose the right base. Install only to protect\n'
    printf '         a separate production branch, if one exists:\n'
    printf '         branch-policy.sh init --integration %s --protected "<production branch>"\n' "$def"
    return 0
  fi
  if [ "$found" = 1 ]; then
    printf 'VERDICT  REVIEW — candidates exist, none carries deploy evidence in a CI file.\n'
    printf '         The pipeline may live where this scan does not read (a Jenkins job, an\n'
    printf '         ArgoCD manifest), or the branch may be abandoned. Confirm with a human:\n'
    printf '         branch-policy.sh init --integration %s --protected "%s"\n' "${best_name:-<branch>}" "$def"
    return 0
  fi
  printf 'VERDICT  SKIP — no deploy-looking branch found. Nothing to lock.\n'
  printf '         Names scanned: %s\n' "$CANDIDATE_NAMES"
  printf '         Another name? BRANCH_POLICY_CANDIDATES="..." branch-policy.sh detect\n'
  return 0
}

# The policy is only shared if git tracks it. A `.gitignore` anywhere — including
# a global one, which no repository reveals — silently keeps it local, and every
# other clone then has no policy at all.
check_policy_tracked() {
  local p="$1" root="$2" rel ign
  rel="${p#"$root"/}"
  if git ls-files --error-unmatch "$rel" >/dev/null 2>&1; then return 0; fi
  ign="$(git check-ignore -v "$rel" 2>/dev/null || true)"
  if [ -n "$ign" ]; then
    printf 'IGNORED %s is excluded by: %s\n' "$rel" "$ign" >&2
    printf '        Other clones will have no policy. Remove that pattern, or move the file.\n' >&2
    return 1
  fi
  printf 'UNTRACKED %s is not committed yet: git add %s\n' "$rel" "$rel" >&2
  return 1
}

# reference-transaction arrived in git 2.28. An older git runs the pre-push hook
# and ignores the other one without a word.
check_git_version() {
  local v maj min
  v="$(git --version | awk '{print $3}')"
  maj="${v%%.*}"; min="${v#*.}"; min="${min%%.*}"
  case "$maj$min" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$maj" -lt 2 ] || { [ "$maj" -eq 2 ] && [ "$min" -lt 28 ]; }; then
    printf 'WARNING git %s has no reference-transaction hook (needs 2.28). Fetch detection is off.\n' "$v" >&2
    return 1
  fi
  return 0
}

cmd_init() {
  local integ="" protected="" exceptions="hotfix/ revert/" force=0 protect_integ=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --integration) integ="${2:-}"; shift 2 ;;
      --protected)   protected="${2:-}"; shift 2 ;;
      --exceptions)  exceptions="${2:-}"; shift 2 ;;
      --protect-integration) protect_integ=1; shift ;;
      --force)       force=1; shift ;;
      *) die "init: unknown option $1" ;;
    esac
  done
  [ -n "$integ" ] || die "init: --integration is required (run 'detect' first)"
  [ -n "$protected" ] || protected="$(default_branch)"
  # Deploy-on-merge repositories usually want the deploy branch closed too: a
  # direct push there ships unreviewed code.
  [ "$protect_integ" = 1 ] && protected="$protected $integ"
  case "$integ$protected$exceptions" in
    *[!A-Za-z0-9._/\ -]*) die "init: branch names and prefixes accept only [A-Za-z0-9._/- ] — no substitutions" ;;
  esac

  local root p hd tpl h
  root="$(repo_root)"; p="$root/$POLICY_REL"; hd="$(hooks_dir)"
  tpl="$(cd "$(dirname "$0")/../templates/hooks" 2>/dev/null && pwd || true)"
  [ -n "$tpl" ] || die "init: hook templates not found next to this script"

  {
    printf '# Integration-branch policy. Committed on purpose: agents and humans read it.\n'
    printf '# Regenerate with: branch-policy.sh init --integration <br> --protected "<br...>"\n'
    printf 'INTEGRATION_BRANCH=%s\n' "$integ"
    printf 'PROTECTED_BRANCHES="%s"\n' "$protected"
    printf 'EXCEPTION_PREFIXES="%s"\n' "$exceptions"
    printf 'POLICY_REVIEWED=%s\n' "$(date -u +%Y-%m-%d)"
  } > "$p"
  printf 'wrote   %s\n' "${p#"$root"/}"
  check_policy_tracked "$p" "$root" || true

  mkdir -p "$hd"
  for h in pre-push reference-transaction; do
    install_hook "$tpl/$h" "$hd/$h" "$force"
  done
  check_git_version || true

  printf '\nCommit %s on EVERY long-lived branch, starting with %s: a hook that finds no\n' "$POLICY_REL" "$integ"
  printf 'policy enforces nothing.\n'
  printf 'Local hooks are a guardrail, not a lock. Set the server-side rules too:\n'
  printf '  - default base branch of new pull requests -> %s\n' "$integ"
  printf '  - block direct pushes to %s, require a pull request\n' "$protected"
  printf '  See references/server-side-protection.md.\n'
}

install_hook() {
  local src="$1" dst="$2" force="$3"
  [ -f "$src" ] || die "missing template $src"
  if [ -f "$dst" ]; then
    if grep -q "$HOOK_MARKER" "$dst" 2>/dev/null; then
      cp "$src" "$dst"; chmod +x "$dst"; printf 'update  %s\n' "$dst"; return 0
    fi
    if [ "$force" = 1 ] && [ -n "$(git config --get core.hooksPath || true)" ]; then
      die "refusing --force: $dst belongs to the hook manager owning core.hooksPath. Chain instead."
    fi
    if [ "$force" = 1 ]; then
      cp "$dst" "$dst.pre-branch-policy.bak"
      cp "$src" "$dst"; chmod +x "$dst"
      printf 'replace %s (previous kept as %s.pre-branch-policy.bak)\n' "$dst" "$dst"
      return 0
    fi
    cp "$src" "$dst.branch-policy"; chmod +x "$dst.branch-policy"
    printf 'CHAIN   %s already exists. Installed %s.branch-policy instead.\n' "$dst" "$dst"
    printf '        A hook reads stdin once, so tee it — an exec at the end gets nothing:\n'
    printf '          input="$(cat)"\n'
    printf '          printf %%s "$input" | "%s.branch-policy" "$@" || exit $?\n' "$dst"
    printf '          printf %%s "$input" | <the existing logic>\n'
    return 0
  fi
  cp "$src" "$dst"; chmod +x "$dst"; printf 'install %s\n' "$dst"
}

# Commits on a protected branch that never came back to the integration branch —
# the measurable form of a forgotten forward-port. Merge commits are excluded, so
# an ordinary promotion merge does not register as debt. A squash-merge promotion
# does, and that is a known limitation of the metric.
forward_port_debt() {
  local p integ prod n
  integ="refs/remotes/origin/$INTEGRATION_BRANCH"
  git show-ref --verify --quiet "$integ" || return 0
  for p in $PROTECTED_BRANCHES; do
    prod="refs/remotes/origin/$p"
    git show-ref --verify --quiet "$prod" || continue
    n="$(git rev-list --count --no-merges "$integ..$prod" 2>/dev/null || echo 0)"
    [ "$n" -gt 0 ] || continue
    printf 'DEBT    %s commit(s) on origin/%s are absent from origin/%s:\n' "$n" "$p" "$INTEGRATION_BRANCH"
    git log --oneline --no-merges -5 "$integ..$prod" | sed 's/^/          /'
    printf '          Forward-port them, or the next branch cut from %s re-ships the bug.\n' "$INTEGRATION_BRANCH"
  done
}

cmd_doctor() {
  local root hd ok=0 h drift_file
  root="$(repo_root)"; hd="$(hooks_dir)"
  if load_policy; then
    printf 'policy          %s (%s)\n' "$POLICY_REL" "$POLICY_SOURCE"
    check_policy_tracked "$root/$POLICY_REL" "$root" || ok=1
    printf '  integration   %s\n' "$INTEGRATION_BRANCH"
    printf '  protected     %s\n' "$PROTECTED_BRANCHES"
    printf '  exceptions    %s\n' "$EXCEPTION_PREFIXES"
    printf '  reviewed      %s\n' "${POLICY_REVIEWED:-unknown}"
  else
    printf 'policy          MISSING (%s) — run detect, then init\n' "$POLICY_REL"; ok=1
  fi
  printf 'hooks dir       %s' "$hd"
  if [ -n "$(git config --get core.hooksPath || true)" ]; then
    printf ' (core.hooksPath=%s — a hook manager owns this directory)' "$(git config --get core.hooksPath)"
  fi
  printf '\n'
  for h in pre-push reference-transaction; do
    if [ -f "$hd/$h" ] && grep -q "$HOOK_MARKER" "$hd/$h" 2>/dev/null; then
      if [ -x "$hd/$h" ]; then printf '  %-22s installed\n' "$h"
      else printf '  %-22s NOT EXECUTABLE — git skips it silently\n' "$h"; ok=1; fi
    elif [ -f "$hd/$h.branch-policy" ]; then
      printf '  %-22s staged as %s.branch-policy, not chained yet\n' "$h" "$h"; ok=1
    else
      printf '  %-22s missing\n' "$h"; ok=1
    fi
  done
  check_git_version || ok=1
  if [ -n "${INTEGRATION_BRANCH:-}" ]; then
    if git show-ref --verify --quiet "refs/remotes/origin/$INTEGRATION_BRANCH"; then
      printf 'origin/%-14s present\n' "$INTEGRATION_BRANCH"
    else
      printf 'origin/%-14s MISSING — fetch, or the policy names a branch nobody has\n' "$INTEGRATION_BRANCH"; ok=1
    fi
    forward_port_debt
  fi
  drift_file="$(git rev-parse --git-common-dir)/branch-policy-drift"
  if [ -s "$drift_file" ]; then
    printf '\ndrift notices from fetch (clear with: branch-policy.sh drift --clear):\n'
    tail -5 "$drift_file" | sed 's/^/  /'
  fi
  printf '\nNot checked here: server-side branch protection. A local hook dies to --no-verify.\n'
  return $ok
}

# A worktree directory inside the repository is a nested checkout. Left untracked
# and unignored, `git add -A` commits it as an embedded repository.
warn_worktree_not_ignored() {
  local dir="$1" top
  case "$dir" in /*) return 0 ;; esac
  top="${dir%%/*}"
  git check-ignore -q "$top/" 2>/dev/null && return 0
  note "WARNING: $top/ is not ignored. \`git add -A\` would commit the worktree as an embedded repo."
  note "         echo '$top/' >> .gitignore"
}

# base_for_branch <branch> -> the branch a pull request from it must target.
base_for_branch() {
  local head="$1" p
  for p in $EXCEPTION_PREFIXES; do
    case "$head" in "$p"*) printf '%s\n' "$(printf '%s' "$PROTECTED_BRANCHES" | awk '{print $1}')"; return 0 ;; esac
  done
  printf '%s\n' "$INTEGRATION_BRANCH"
}

cmd_worktree() {
  load_policy || die "no policy — run detect then init first"
  local branch="" from="" dir="" explicit=0 exception=0 p base
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-}"; explicit=1; shift 2 ;;
      --dir)  dir="${2:-}"; shift 2 ;;
      -*) die "worktree: unknown option $1" ;;
      *)  branch="$1"; shift ;;
    esac
  done
  [ -n "$branch" ] || die "worktree: usage: branch-policy.sh worktree <branch> [--from REF] [--dir DIR]"
  [ -n "$dir" ] || dir=".worktrees/$(printf '%s' "$branch" | tr '/' '-')"

  for p in $EXCEPTION_PREFIXES; do
    case "$branch" in "$p"*) exception=1 ;; esac
  done

  if [ "$explicit" = 0 ]; then
    # An exception branch defaults to the branch its pull request will target,
    # never to the integration branch: a hotfix cut from staging would carry
    # every unpromoted commit into production.
    base="$(base_for_branch "$branch")"
    from="origin/$base"
    if ! git fetch --quiet origin "$base" 2>/dev/null; then
      git show-ref --verify --quiet "refs/remotes/origin/$base" \
        || die "cannot fetch origin/$base and no local copy of it exists"
      note "WARNING: fetch failed (offline?). Using the local origin/$base, which may be stale."
    fi
    [ "$exception" = 1 ] && note "EXCEPTION: $branch is an exception branch — base is origin/$base."
  elif [ "$exception" = 0 ]; then
    note "EXCEPTION: $branch branches from $from, not origin/$INTEGRATION_BRANCH."
    note "           Its name matches no prefix in EXCEPTION_PREFIXES ($EXCEPTION_PREFIXES)."
    note "           Its pull request still targets $INTEGRATION_BRANCH. Record why in the description."
  fi

  git show-ref --verify --quiet "refs/heads/$branch" && die "branch $branch already exists"
  warn_worktree_not_ignored "$dir"
  # --no-track on purpose: tracking origin/main from a topic branch turns a plain
  # `git push` into a push at a protected branch.
  git worktree add --no-track -b "$branch" "$dir" "$from"
  printf '\nworktree %s\n  branch %s\n  from   %s (%s)\n  PR base must be %s\n' \
    "$dir" "$branch" "$from" "$(git rev-parse --short "$from")" "$(base_for_branch "$branch")"
  printf '  first push: git push -u origin %s\n' "$branch"
}

cmd_pr_base() {
  load_policy || die "no policy — run detect then init first"
  local head base
  head="$(git rev-parse --abbrev-ref HEAD)"
  base="$(base_for_branch "$head")"
  if [ "$base" != "$INTEGRATION_BRANCH" ]; then
    note "EXCEPTION: $head matches an exception prefix — base is $base."
    note "           Forward-port it: merge $base back into $INTEGRATION_BRANCH the same day."
  fi
  printf '%s\n' "$base"
}

cmd_drift() {
  local status=0 declared="" clear=0 re name line score deploy def drift_file
  while [ $# -gt 0 ]; do
    case "$1" in
      --clear) clear=1; shift ;;
      *) die "drift: unknown option $1" ;;
    esac
  done
  if load_policy; then declared="$INTEGRATION_BRANCH"; fi
  re="$(candidate_re)"; def="$(default_branch)"
  for name in $(all_branch_names); do
    printf '%s\n' "$name" | grep -qE "$re" || continue
    [ "$name" = "$declared" ] && continue
    [ "$name" = "$def" ] && continue
    line="$(score_candidate "$name")"
    score="$(printf '%s' "$line" | cut -f1)"; deploy="$(printf '%s' "$line" | cut -f2)"
    if [ -n "$deploy" ] && [ "$score" -ge 4 ]; then
      printf 'DRIFT   %s carries CI deploy evidence and is not the declared integration branch (%s)\n' \
        "$name" "${declared:-none}"
      printf '        %s\n' "$(printf '%s' "$line" | cut -f3)"
      status=1
    fi
  done
  drift_file="$(git rev-parse --git-common-dir)/branch-policy-drift"
  if [ -s "$drift_file" ]; then
    printf 'DRIFT   fetch notices pending:\n'; sed 's/^/        /' "$drift_file"
    status=1
    if [ "$clear" = 1 ]; then rm -f "$drift_file"; printf '        cleared.\n'; fi
  fi
  [ -n "$declared" ] && forward_port_debt
  [ "$status" = 0 ] && printf 'no drift — %s is still the only deploy branch\n' "${declared:-<none declared>}"
  return $status
}

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  printf '\nbranch-policy.sh %s\n' "$VERSION"
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    detect)  cmd_detect "$@" ;;
    init)    cmd_init "$@" ;;
    doctor)  cmd_doctor "$@" ;;
    worktree) cmd_worktree "$@" ;;
    pr-base) cmd_pr_base "$@" ;;
    drift)   cmd_drift "$@" ;;
    -h|--help|help) usage ;;
    --version) printf '%s\n' "$VERSION" ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
