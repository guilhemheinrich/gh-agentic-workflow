# Worked example — GitHub

The same instance, pointed at GitHub. A machine that pushes to both hosts
runs one daemon and one set of hooks; each host contributes its own requests
and its own token.

## Instantiating

```bash
prw plan                  # "tokens … github missing", "next: prw setup --github"
prw setup --github        # hidden prompt; stores GITHUB_WATCH_TOKEN in the same env file
prw doctor                # "ok GitHub token accepted"
```

A GitHub PR is named `github:OWNER/REPO`:

```bash
prw subscribe github:octo-org/cockpit 42 --session <id>
prw subscribe --branch "$(git branch --show-current)" --session <id>   # host read from `origin`
```

The comment hook records what the agent posts with `gh pr comment` or
`gh api` (Bash matcher), reading the comment URL GitHub returns
(`…/pull/42#issuecomment-4521`, `…#discussion_r…`).

## Verified against real payloads

`tests/fixtures/github-real/` holds payloads fetched with `gh api` on
2026-11-02 from `cli/cli` pull request 14858 (merged, 26 check runs, three
reviews, two inline comments), trimmed to the fields read. The test
`github-real.test.sh` runs the snapshot over them.

| Field | Confirmed on the real payload |
|---|---|
| `merged`, `state`, `merge_commit_sha`, `mergeable`, `mergeable_state` | yes (`merged: true`, `mergeable_state: clean`) |
| check run `status`, `conclusion` (`success`, `skipped`), `name`, `started_at`, `completed_at`, `html_url` | yes; 26 runs collapse to 21 names |
| review `state` (`COMMENTED`, `APPROVED`), `user.login` | yes |
| inline comment `id`, `path`, `line`, `original_line` | yes |

## Not yet verified against a real payload

Say so rather than trust the mapping:

- **Legacy commit statuses** (`state`: `success` / `pending` / `failure` /
  `error`, `context`, `target_url`): the PR used had none.
- **Conversation comments** (`issues/N/comments`): the PR used had none, and
  nothing in this repository has a review or a comment to fetch.
- **`mergeable_state: dirty` and `mergeable: null`**: the conflict mapping and
  the "keep the previous answer while GitHub computes" rule are written from
  GitHub's documentation, and tested on invented values only.
- **Token permissions.** The list asked by `prw setup --github` (Pull requests,
  Checks, Commit statuses, Issues, read) is from documentation; no
  fine-grained token was created to confirm it is the minimum or enough. The
  daemon has never run against GitHub with a real token on this machine.

## Differences from Bitbucket worth knowing

- GitHub has no PR "participants" list: approval and change requests are read
  from the **last** review of each user, so a later comment-only review does not
  clear a change request.
- Check runs of a workflow can repeat by name across re-runs; they collapse by
  name, the latest wins.
- GitHub rate-limits with `403` or `429`: a persistent `429` is logged and the
  cycle moves on, a `403` is "no access" for that repository only.
