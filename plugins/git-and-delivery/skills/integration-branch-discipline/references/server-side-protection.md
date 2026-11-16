# Server-side protection — the part a local hook cannot do

A git hook lives in `.git/hooks`, which is not cloned, not reviewed, and dies to
`git push --no-verify`. It catches mistakes. It stops nobody. The lock is on the
forge, and it has exactly two moving parts:

1. **The default base branch of a new pull request.** Change it and the whole
   class of "opened against `main` by accident" disappears, for humans and for
   every agent that omits `--base`.
2. **A rule refusing direct pushes to the production branch.** Change it and the
   other class disappears too.

Everything below is those two settings, per forge. **`staging` and `main` below
are placeholders**, standing for the integration branch and the protected branch
of the repository at hand — on a Git-flow repository read them as `develop` and
`master`, on a promotion-through-acceptance one as `recette` and `production`.
Take the two real names from `.branch-policy`, and replace `<owner>`, `<repo>`
and `<workspace>` too.

---

## GitHub

### 1. Default branch → the integration branch

The base of a new pull request defaults to the repository's default branch.
Point the default at `staging` and `main` stops being the accidental target.

```bash
gh api -X PATCH repos/<owner>/<repo> -f default_branch=staging
```

Consequences worth stating before you run it, because one of them bites:

- A fresh `git clone` checks out `staging`, and the landing page shows `staging`.
- **`on: schedule` workflows and `workflow_dispatch` run from the default
  branch.** Nightly jobs, cron-driven releases and manual dispatch buttons all
  start executing the deploy branch's code instead of production's. Read
  `.github/workflows/` for `schedule:` before switching, and decide per job.
- Anything else keyed on "default branch" — branch-name defaults in actions,
  code scanning baselines — follows too.

That is usually what you want, and it is always a surprise to someone. Announce it.

If you cannot move the default branch — a published library whose `main` is what
consumers read — keep it and rely on rule 2 plus an explicit `--base` everywhere.

### 2. Refuse direct pushes to `main`

Rulesets are the current mechanism; classic branch protection still works.

```bash
gh api -X PUT repos/<owner>/<repo>/branches/main/protection \
  --input - <<'JSON'
{
  "required_pull_request_reviews": { "required_approving_review_count": 1 },
  "required_status_checks": null,
  "enforce_admins": true,
  "restrictions": null
}
JSON
```

`enforce_admins: true` is the field that matters. Without it, the one account
most likely to push to `main` at 19:00 on a Friday is exempt.

### 3. Verify, do not assume

```bash
gh api repos/<owner>/<repo> --jq .default_branch
```

```bash
gh api repos/<owner>/<repo>/branches/main/protection --jq '.enforce_admins.enabled'
```

A 404 on the second call means the branch is unprotected, not that the call
failed.

---

## GitLab

Default branch, and a protection rule where "no one may push, maintainers may
merge" is expressed as push level `0`:

```bash
glab api -X PUT projects/:id --field default_branch=staging
```

```bash
glab api -X POST projects/:id/protected_branches \
  --field name=main --field push_access_level=0 --field merge_access_level=40
```

`push_access_level=0` is `NO_ACCESS`; `merge_access_level=40` is `MAINTAINER`.

GitLab has no per-project "merge request target branch" separate from the default
branch: the merge-request form proposes `default_branch`, so the first command is
the whole lever. If the project must keep `main` as its default, the protection
rule is your only control, and every merge request states its target by hand.

Check what is actually in force rather than trusting the last command you ran:

```bash
glab api projects/:id/protected_branches
```

---

## Bitbucket Cloud

Two objects, and they are easy to confuse. The **branching model** declares which
branch is "development" and which is "production" — that is what pre-fills the
target of a new pull request. **Branch restrictions** are the enforcement.

Branching model, so a new pull request proposes `staging`:

```bash
curl -sS -X PUT -u "$BB_USER:$BB_APP_PASSWORD" \
  -H 'Content-Type: application/json' \
  https://api.bitbucket.org/2.0/repositories/<workspace>/<repo>/branching-model/settings \
  -d '{"development":{"name":"staging","use_mainbranch":false},"production":{"name":"main","use_mainbranch":false,"enabled":true}}'
```

Restriction, so nobody pushes to `main`:

```bash
curl -sS -X POST -u "$BB_USER:$BB_APP_PASSWORD" \
  -H 'Content-Type: application/json' \
  https://api.bitbucket.org/2.0/repositories/<workspace>/<repo>/branch-restrictions \
  -d '{"kind":"push","branch_match_kind":"glob","pattern":"main","users":[],"groups":[]}'
```

An empty `users` and `groups` is the whole point: a restriction with a non-empty
exemption list is a restriction that the exempt person forgets exists.

Read back both, because they are stored separately:

```bash
curl -sS -u "$BB_USER:$BB_APP_PASSWORD" \
  https://api.bitbucket.org/2.0/repositories/<workspace>/<repo>/branch-restrictions
```

---

## Azure DevOps

The default branch is a repository property; the enforcement is a **branch
policy** on `refs/heads/main`.

```bash
az repos update --repository <repo> --default-branch staging --project <project>
```

```bash
az repos policy approver-count create --project <project> \
  --repository-id <repo-id> --branch main --blocking true --enabled true \
  --minimum-approver-count 1 --creator-vote-counts false --allow-downvotes false --reset-on-source-push true
```

Azure has no "block push" toggle separate from policy: a branch carrying any
blocking policy refuses a direct push. So the approver-count policy is both the
review requirement and the push lock.

---

## What to check after any of this

Three questions. The answers come from the forge, not from memory:

| Question                                          | How you know                                   |
| ------------------------------------------------- | ---------------------------------------------- |
| Does a new pull request propose the right base?   | Open one in the UI and read the base selector. Close it. |
| Is the protection rule actually in force?         | Read it back through the API (the `--jq` calls above). A 404 means unprotected, not "call failed". |
| Is the exemption list empty?                      | Same read-back: `restrictions`, `users`, `groups`, and `enforce_admins`. |

**Do not test protection by pushing to production.** The obvious check — disable
the local hook and push a throwaway commit to `main` — performs exactly the
mutation you are trying to forbid whenever the rule turns out to be missing. The
API read-back answers the same question and changes nothing.

If you want the push path exercised end to end, do it on a scratch repository
carrying the same ruleset, and keep the production repository out of it.

## What none of this prevents

A person can still open a pull request against the production branch on purpose,
get the required approval, and merge it. The forge makes the wrong target hard to
reach by accident; the review is what makes it deliberate. If that path must be
closed too, the control is organisational — a named set of people allowed to
merge into production — not a branch setting.
