---
name: integration-branch-discipline
description: >-
  Lock a repository onto the branch its CI actually deploys — whatever that
  branch is called on it: `develop`, `staging`, `preprod`, `recette` — so no
  worktree is cut from the default branch and no pull request targets it by
  accident. Branch names are variables throughout: the roles are "integration
  branch" and "protected branch", and `develop` / `staging` are only the two most
  frequent values. Covers the detection question first (which repositories need
  this, and how you tell from the CI files rather than from folklore), then the
  enforcement: a committed `.branch-policy`, a `pre-push` hook that refuses a
  protected target and names a branch cut from the wrong base, a
  `reference-transaction` hook that notices a new deploy branch arriving by
  fetch, and the forge-side rules that are the only real lock. Ships
  `branch-policy.sh` (detect · init · doctor · worktree · pr-base · drift), the
  two hook templates, an AGENTS.md block, and a per-forge reference for the
  server-side settings. Use when a repository has a deploy branch distinct from
  its default branch, when an agent or a human opened a pull request against the
  default branch, when onboarding a repository whose merge rules live only in
  someone's head, or when a hotfix needs a named exception.
tags:
  - git
  - ci-cd
  - hooks
  - process
  - devops
---

# Integration Branch Discipline

The moment a repository deploys from a branch that is not its default branch,
the default stops being the place work goes and becomes the place work ends up.
Git does not know that. Its defaults all still point at the default branch:
`git clone` checks it out, `git worktree add` takes whatever base you type, and
a new pull request proposes the default as its base. The accident is not a
mistake anyone makes — it is the path of least resistance.

## 0. Two roles, and the names they happen to carry

This skill is about **roles**, never about branch names. Two roles matter, and
both are variables:

| Role | Variable in `.branch-policy` | Names it commonly carries |
| ---- | ---------------------------- | ------------------------- |
| **Integration branch** — what CI deploys on merge, the entry door for new work | `INTEGRATION_BRANCH` | `develop`, `staging`, `preprod`, `integration`, `next`, `recette`, `uat`, `qa`, `sandbox`, `acceptance` |
| **Protected branch** — the production record, nobody pushes to it | `PROTECTED_BRANCHES` | `main`, `master`, `production`, `release` |

`develop` and `staging` are the two most frequent values, nothing more. They are
*suspicious candidates* the detector scores, not the answer. Nothing in the
tooling hardcodes a name: `detect` reads the candidate list from
`BRANCH_POLICY_CANDIDATES`, and every hook and command reads the role from the
committed `.branch-policy`.

**Reading convention for the rest of this document.** Prose says "the integration
branch" and "the protected branch". Transcripts show real output from the test
fixture, where the integration branch is named `staging` and the protected branch
`main` — read those two strings as the fixture's values, never as the rule.

That claim is a test, not a promise. `scripts/test-branch-policy.sh` carries a
second fixture with no `staging` and no `main` anywhere: default branch `master`,
entry door `develop`, production `production`. Six assertions run on it, and they
are the same six behaviours:

```text
  ok    LOCK names develop, with no staging in the repository
  ok    the suggested command carries develop
  ok    a worktree starts at origin/develop
  ok    pr-base answers develop
  ok    a push to production is blocked
  ok    the refusal names develop as the target to use
```

Run it with `./scripts/test-branch-policy.sh -k names-are-variables`.

Two failure modes, both cheap to produce:

1. **A worktree cut from the protected branch.** It misses everything merged to
   the integration branch since the last promotion, so the change is written and
   reviewed against a base that will never be deployed. Git reverts nothing by
   itself — the merge back is an ordinary three-way merge. What you lose is the
   test: CI on the branch validated a combination that does not exist, and the
   first build of the real combination happens after the merge, on the deploy
   branch.
2. **A pull request targeting the protected branch.** It bypasses the environment
   where the change was supposed to be tried. The code reaches production without
   ever running on the deploy branch, and the first person to notice is a user.

An agent reproduces both faster than a human, because it reads the default
branch and believes it.

```text
                    detect                    lock                      verify
   repository ──▶ branch-policy.sh ──▶ .branch-policy (committed) ──▶ doctor
                      detect              pre-push hook              drift
                        │                 reference-transaction        │
                        ▼                        │                     ▼
            LOCK / ALIGNED / REVIEW / SKIP       ▼            forge-side rules
                                        worktree · pr-base    (the actual lock)
```

## 1. What is in this bundle

| File                                       | Role                                                       |
| ------------------------------------------ | ---------------------------------------------------------- |
| `scripts/branch-policy.sh`                 | detect · init · doctor · worktree · pr-base · drift         |
| `templates/hooks/pre-push`                 | Refuses a protected target; names a branch cut from production. |
| `templates/hooks/reference-transaction`    | Notices a new deploy-looking branch arriving by fetch.      |
| `templates/agents-md-block.md`             | The policy section to paste into the repository's AGENTS.md.|
| `scripts/test-branch-policy.sh`            | Offline regression suite — 34 cases, throwaway repositories. |
| `references/server-side-protection.md`     | GitHub / GitLab / Bitbucket / Azure — the real lock.        |

## 2. Does this repository need it?

Ask the CI files, not the team.

```bash
branch-policy.sh detect
```

```text
repository      /path/to/app
default branch  main
CI files        .github/workflows/ci.yml .github/workflows/deploy.yml

CANDIDATE      SCORE  EVIDENCE
dev            1      on origin
staging        4      on origin; triggers .github/workflows/deploy.yml; deploy keywords in .github/workflows/deploy.yml

VERDICT  LOCK — CI deploys from staging, but git points everything at main.
         branch-policy.sh init --integration staging --protected "main"
```

Four points, each a separate claim you can check:

| Point | Claim                                                                    |
| ----- | ------------------------------------------------------------------------ |
| +1    | The branch exists on `origin`, not only in someone's clone.               |
| +2    | A CI file names it **in a branch-trigger position** (`branches: [<name>]`, `only:`, `trigger:`). |
| +1    | That same file also deploys (`helm`, `kubectl`, `argocd`, `docker push`, …). |

The `dev` row above is the reason the second point says "in a branch-trigger
position". That fixture's `ci.yml` contains `npm run dev` and `npm run
deploy-preview`; a plain text match scores `dev` 4 and locks the repository onto
a branch nobody deploys. The scan requires the name to sit on, or within four
lines of, a line mentioning a branch trigger.

Read that table as a ranking of candidates, not as a verdict on `staging`. On a
Git-flow repository the same table names `develop`; on one that promotes through
an acceptance environment it names `preprod` or `recette`. The winner is whichever
candidate carries the deploy evidence.

Four verdicts:

- **LOCK** — a candidate reaches 4 **including the deploy point**, and differs
  from the default branch. This is the dangerous configuration. Install.
- **ALIGNED** — the deploy branch is already the default branch. Pull requests
  propose the right base on their own. Install only to protect a separate
  production branch.
- **REVIEW** — candidates exist, none carries deploy evidence. Ask a human, then
  install with an explicit `--integration`.
- **SKIP** — no candidate at all. A repository whose default branch is its only
  long-lived branch needs none of this.

### Where the scan is blind, and why REVIEW exists

It reads `.github/workflows/`, `bitbucket-pipelines.yml`, `.gitlab-ci.yml`,
`azure-pipelines.yml`, `.circleci/config.yml`, `Jenkinsfile` and `.drone.yml`,
and it is a heuristic over text. Four layouts defeat it, all landing in REVIEW
or SKIP rather than in a wrong LOCK:

1. **GitOps.** The branch name lives in an ArgoCD `Application` (`targetRevision:
   staging`), not in a pipeline file. Score 1.
2. **Reusable workflows.** The caller holds the branch trigger, the callee holds
   `helm upgrade`. The branch point and the deploy point are in different files,
   so the deploy point is never awarded.
3. **A branch name held in a variable.** `rules: - if: $CI_COMMIT_BRANCH ==
   $DEPLOY_BRANCH` never contains the literal name.
4. **A name outside the candidate list.** Fifteen names ship by default —
   `develop`, `staging`, `preprod`, `integration`, `recette`, `uat`, `acceptance`
   and the rest — each with an optional environment suffix, so `staging-eu` and
   `preprod-2` match. A house name does not. Widen it for one run, or for good in
   the shell profile:
   `BRANCH_POLICY_CANDIDATES="golden trunk-next" branch-policy.sh detect`.

A monorepo adds a fifth case that the scan gets *wrong* rather than blind: one
service deploying from an integration branch and another straight from the
default branch produces a repository-wide LOCK. The policy is per repository, so
a repository with two deployment models needs a human decision, not this tool.

## 3. Install

```bash
branch-policy.sh init --integration staging --protected "main"
```

```text
wrote   .branch-policy
UNTRACKED .branch-policy is not committed yet: git add .branch-policy
install .git/hooks/pre-push
install .git/hooks/reference-transaction

Commit .branch-policy on EVERY long-lived branch, starting with staging: a hook
that finds no policy enforces nothing.
Local hooks are a guardrail, not a lock. Set the server-side rules too:
  - default base branch of new pull requests -> staging
  - block direct pushes to main, require a pull request
  See references/server-side-protection.md.
```

Two artefacts, in different places on purpose:

- **`.branch-policy`, at the repository root, committed.** The shared truth: four
  variables, read by the hooks, by the script, and by any agent that can `cat`.
- **The hooks, in the hooks directory, never committed.** `.git/hooks` is not
  cloned. Every clone and every machine runs `init` again, or runs without hooks.

```bash
cat .branch-policy
```

```text
# Integration-branch policy. Committed on purpose: agents and humans read it.
# Regenerate with: branch-policy.sh init --integration <br> --protected "<br...>"
INTEGRATION_BRANCH=staging
PROTECTED_BRANCHES="main"
EXCEPTION_PREFIXES="hotfix/ revert/"
POLICY_REVIEWED=2026-09-17
```

Three options worth knowing at install time:

| Option                   | Effect                                                              |
| ------------------------ | ------------------------------------------------------------------- |
| `--protect-integration`  | Adds the deploy branch to `PROTECTED_BRANCHES`. On a deploy-on-merge repository, a direct push there ships unreviewed code. |
| `--exceptions "..."`     | Branch prefixes allowed to cut from production. Default `hotfix/ revert/`. |
| `--force`                | Replaces an existing hook, keeping a `.bak`. Refused when `core.hooksPath` is set: that directory belongs to a hook manager. |

The file is read, never sourced. A value carrying anything outside
`[A-Za-z0-9._/- ]` is dropped with a message, and the loader falls back to the
committed copy:

```text
branch-policy: ignoring unsafe value for PROTECTED_BRANCHES
policy          .branch-policy (HEAD (not in this working tree))
```

That matters because `.branch-policy` arrives with a clone. A sourced policy file
is remote code execution on `git push`.

Then confirm:

```bash
branch-policy.sh doctor
```

```text
policy          .branch-policy (working tree)
  integration   staging
  protected     main
  exceptions    hotfix/ revert/
  reviewed      2026-09-17
hooks dir       .git/hooks
  pre-push               installed
  reference-transaction  installed
origin/staging        present

Not checked here: server-side branch protection. A local hook dies to --no-verify.
```

`doctor` exits 1 on anything missing, so a setup step can gate on it.

## 4. Daily use — three commands

**Start work.** The base is fetched fresh, and it is the branch the pull request
will target:

```bash
branch-policy.sh worktree feat/invoice-export
```

```text
worktree .worktrees/feat-invoice-export
  branch feat/invoice-export
  from   origin/staging (cab50d2)
  PR base must be staging
  first push: git push -u origin feat/invoice-export
```

**Open the pull request.** Name the base explicitly. A default is a thing that
changes without telling you:

```bash
gh pr create --base "$(branch-policy.sh pr-base)" --head "$(git rev-parse --abbrev-ref HEAD)"
```

**Push.** Nothing to do, unless you aimed at a protected branch:

```bash
git push origin HEAD:main
```

```text
  BLOCKED: direct push to protected branch 'main' on remote 'origin'.
  CI deploys from 'staging'. Open a pull request against it instead.

    git push -u origin $(git rev-parse --abbrev-ref HEAD)
    gh pr create --base staging

  Deliberate exception (release promotion, hotfix): BRANCH_POLICY_ALLOW=1 git push ...
```

The refspec form above is the one that slips past a human reading the command
aloud, and it is caught like any other. A push to a *different* remote is not:
the hook compares the remote's URL with `origin`'s, so pushing `main` to your own
fork stays your business.

### Naming a branch cut from production

```bash
git push origin feat/from-main
```

```text
  WRONG BASE: 'feat/from-main' starts exactly at origin/main, and is 2 commit(s) behind origin/staging.
              It was cut from production, not from the deploy branch.
              git rebase --onto origin/staging 7bfbdd67069f1b5ca4c6354e911d504b363b65ab feat/from-main
```

The test behind that message took three attempts, and the first two are the
obvious ones:

1. *Is the branch tip a descendant of the integration branch?* No: the moment
   anyone else merges, every correctly based branch answers no. Pure noise.
2. *Does the branch share more history with the protected branch than with the
   integration branch?* No: in a healthy repository the integration branch
   contains the protected one, so both merge bases are the same commit and
   nothing is ever detected.
3. *Does the branch point sit **exactly** on production's tip while the deploy
   branch has moved past it?* Yes. Cutting from `main` puts the branch point
   there by construction; cutting from `staging` puts it somewhere `main` has not
   reached.

The third test is silent on a branch cut from the integration branch after two
other people merged, and fires on a branch cut from the protected branch one
second ago. It warns rather than blocks, because a legitimate case exists — a
branch deliberately started at the promotion point. `BRANCH_POLICY_STRICT=1`
turns it into a refusal.

## 5. Exceptions — named, never improvised

A locked repository still ships hotfixes. `EXCEPTION_PREFIXES` names the branch
prefixes that may cut from production, and the tooling then treats them
consistently instead of arguing with you:

```bash
branch-policy.sh worktree hotfix/expired-token
```

```text
EXCEPTION: hotfix/expired-token is an exception branch — base is origin/main.

worktree .worktrees/hotfix-expired-token
  branch hotfix/expired-token
  from   origin/main (7bfbdd6)
  PR base must be main
  first push: git push -u origin hotfix/expired-token
```

No `--from` is needed, and pointing it at the integration branch would be the
bug: a hotfix based on the deploy branch carries every unpromoted commit into
production. The base follows the pull request target, always.

**The forward-port is the whole exception.** A hotfix that lands on the protected
branch and never reaches the integration branch is a fix that exists only in
production. Nothing reverts it — the next feature branch cut from the integration
branch simply does not contain it, and ships the bug again. `doctor` and `drift`
count that debt:

```text
DEBT    1 commit(s) on origin/main are absent from origin/staging:
          6844d8c fix: expired token
          Forward-port them, or the next branch cut from staging re-ships the bug.
```

Merge commits are excluded, so an ordinary promotion merge does not register.
One known limitation: a team that promotes the integration branch into the
protected one by **squash** merge produces a permanent non-zero count, because
the squash commit exists nowhere else. Read the listed subjects rather than the
number.

A `--from` on a branch whose name matches no prefix still works, and says so:

```text
EXCEPTION: chore/one-off branches from origin/main, not origin/staging.
           Its name matches no prefix in EXCEPTION_PREFIXES (hotfix/ revert/).
           Its pull request still targets staging. Record why in the description.
```

The tool refuses nothing there. A policy that blocks legitimate work gets
uninstalled within a week.

## 6. Proactive detection — there is no post-fetch hook

Git has no `post-fetch` hook. The event you want exists under a name that does
not suggest it: `reference-transaction` fires whenever refs change, and a
`git fetch` creating a new remote-tracking branch is a ref change.

Measured on git 2.50.1, one fetch creating one branch, with a hook that logs its
state and stdin:

```text
REFTX[prepared]  0000000000000000000000000000000000000000 522c3ee… refs/remotes/origin/staging
REFTX[committed] 0000000000000000000000000000000000000000 522c3ee… refs/remotes/origin/staging
```

Two invocations per transaction, and an all-zero old value marks a ref that did
not exist. So the hook filters on three conditions — state `committed`, ref under
`refs/remotes/`, old value all zeros — and a new deploy-looking branch announces
itself during the fetch that brings it:

```text
  branch-policy: new remote branch 'origin/preprod' looks like a deploy branch.
  The declared integration branch is 'staging'. Run: branch-policy.sh drift
```

Three constraints on this hook, each load-bearing:

- **It always exits 0.** A non-zero exit at the `prepared` state aborts the ref
  transaction, which breaks `git fetch` itself. A repository-hygiene tool that
  can break `fetch` is a tool that gets deleted.
- **It needs git 2.28 or later.** Older git never calls a hook by that name and
  says nothing about it. `init` and `doctor` compare your version and warn.
- **It tests for "zeros only", never for 40 characters.** A SHA-256 repository
  writes 64 zeros, and a length comparison silently detects nothing there.

`drift` reads both that trail and the CI files again:

```bash
branch-policy.sh drift
```

```text
DRIFT   preprod carries CI deploy evidence and is not the declared integration branch (staging)
        on origin; triggers .github/workflows/deploy-dev.yml; deploy keywords in .github/workflows/deploy-dev.yml
```

Exit 1 on drift, so it fits a CI job or a session-start hook. A new branch alone
produces a notice; a new branch wired into a deploy pipeline produces DRIFT. The
difference matters: teams create a spare long-lived branch by accident often,
and rewire CI almost never. Notices accumulate until you acknowledge them —
`branch-policy.sh drift --clear` — so an untended CI job does not fail forever on
one stale fetch.

## 7. What the local hooks cannot do

A git hook is a file in a directory that is not cloned, not reviewed, and not
consulted by the server. `git push --no-verify` skips it. Hooks catch mistakes;
they stop nobody.

The lock is on the forge, and it is two settings:

1. **The default base branch of a new pull request** → the integration branch. On
   GitHub that is the repository default branch, and moving it removes the whole
   "opened against the wrong branch by accident" class for every human and every
   agent that omits `--base`.
2. **A rule refusing direct pushes to the production branch**, with an empty
   exemption list.

Two things neither setting does, and both belong in the conversation before you
change anything:

- **Nothing stops someone deliberately opening a pull request against the
  protected branch and merging it with the required approval.** The forge makes
  the wrong target harder to reach by accident; the review is what makes it
  deliberate.
- **Moving the default branch moves more than the pull-request default.** On
  GitHub, `on: schedule` workflows and `workflow_dispatch` run from the default
  branch, so scheduled automation starts executing the deploy branch's code.
  Check what your scheduled jobs do before the switch.

Per-forge commands, and how to read the settings back, are in
[references/server-side-protection.md](references/server-side-protection.md).
Verify by reading the rule back through the API, not by pushing to production:
the "just try it" test performs the forbidden mutation whenever protection turns
out to be absent.

## 8. Teaching the agents — AGENTS.md

`templates/agents-md-block.md` is the section to paste into the consumer
repository's `AGENTS.md`, with `<PLACEHOLDER>` replaced. Keep `CLAUDE.md`
pointing at `AGENTS.md` rather than holding a second copy: two policy texts
drift, and the day they disagree is the day someone follows the wrong one.

Every branch name in that template is a `<PLACEHOLDER>`; fill them from
`.branch-policy` rather than from habit. The block states the four rules, the
exact `worktree` and `gh pr create` commands, the hotfix exception inline with
rule 2 — an agent that reads "every pull request targets the integration branch"
and then meets a `hotfix/` branch has to choose, and it chooses wrong — and one
instruction that matters more than the rest:

> Do not guess the base branch from the repository's default branch: on this
> repository they differ on purpose.

That sentence exists because the model's prior is strong and correct almost
everywhere else.

## 9. Traps, each one observed while building this

| # | Trap                                                                 | Evidence                                                                                                  | Handled by |
| - | --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | ---------- |
| 1 | A global ignore file excludes the directory holding the policy.        | `git check-ignore -v` answered with a `~/.gitignore_global` line excluding the agent directory. The file was written, and would never have been pushed. | Policy at the repository root; `init` and `doctor` run `git ls-files --error-unmatch` and print `IGNORED` or `UNTRACKED`. |
| 2 | A hook that reads the policy from the working tree.                    | `git checkout` of a branch cut before the policy commit → `working tree has policy? no` → hook silently disarmed on the branches most likely to be wrong. | Both hooks resolve the policy from the working tree, then `HEAD`, then each long-lived branch. |
| 3 | `git worktree add -b feat/x dir origin/main` sets the upstream to `origin/main`. | `branch 'feat/x' set up to track 'origin/main'` — a later bare `git push` then aims at production.            | `worktree` passes `--no-track` and prints `git push -u origin <branch>`. |
| 4 | `core.hooksPath` is set (husky, lefthook).                             | `git rev-parse --git-path hooks` returned `.myhooks` once `core.hooksPath=.myhooks` was set, and the repository's own `.git/hooks` from a linked worktree. | That one call resolves both cases. `doctor` prints the override; `--force` is refused there. |
| 5 | A hook already exists at that path.                                    | `CHAIN .git/hooks/pre-push already exists.` — a naive install would have replaced a lint hook.                | `init` writes `<hook>.branch-policy` and prints a stdin-tee chaining snippet: a hook reads stdin once, so an `exec` at the end receives nothing. |
| 6 | `.worktrees/` is not ignored.                                          | `warning: adding embedded git repository: .worktrees/feat-invoice-export` on a routine `git add -A`.          | `worktree` warns and prints the `echo '.worktrees/' >> .gitignore` line. |
| 7 | `git ls-files` resolves pathspecs against the current directory.       | Run from `src/`, `detect` scored `staging` 1 instead of 4 and downgraded LOCK to REVIEW.                      | `ci_files` runs `git -C "$(repo_root)" ls-files`, and file tests resolve against the root. |

Trap 4 has a consequence worth stating: under husky the hooks live in a tracked
directory, so they *are* shared by a clone — the opposite of `.git/hooks`. Better,
and it makes the hook reviewable code in the repository.

## 10. Order of operations

1. `detect` — and stop here on SKIP.
2. Confirm the integration branch with a human on REVIEW.
3. `init`, then commit `.branch-policy` on every long-lived branch, through a
   pull request into the integration branch first. A hook that finds no policy
   enforces nothing, and old branches are exactly where it is needed.
4. Set the two forge-side rules, and read them back through the API.
5. Paste the AGENTS.md block.
6. `doctor` — it must exit 0.
7. Every other clone and machine: `init` again, for the hooks.

## 11. What a three-model panel changed here

Three reviewers from other lineages attacked this package before release and
returned 56 findings between them. The ones that changed the code are visible in
it: the policy is parsed rather than sourced, so a cloned `.branch-policy` cannot
execute on `git push` (§3); the wrong-base test was rebuilt twice and now uses
the branch-point criterion (§4); LOCK requires deploy evidence and `dev` no
longer scores on `npm run dev` (§2); the hotfix base follows the pull-request
target (§5); `ls-files` is anchored to the repository root (trap 7); `--force` is
refused under a hook manager (§3); tags, deletions, SHA-256 repositories and
pushes to a fork are all excluded from the hook's reach; and the forge reference
lost a paragraph that contradicted itself while gaining the scheduled-workflow
caveat (§7).

One finding was rejected, and the measurement is the reason. A reviewer stated
that `git rev-parse --git-path hooks` ignores `core.hooksPath`, so `init` would
write hooks git never runs. On git 2.50.1 that call returns `.myhooks` when
`core.hooksPath=.myhooks` is set, and `init` installed into `.husky/` on a
husky-style fixture. Two commands refute it:

```bash
git config core.hooksPath .myhooks && git rev-parse --git-path hooks
```

A panel finding is a candidate until you run them. Every case the panel raised
that survived is now a row in `scripts/test-branch-policy.sh`, so the next change
to this package cannot quietly undo one:

```bash
./scripts/test-branch-policy.sh
```

```text
34 passed, 0 failed
```
