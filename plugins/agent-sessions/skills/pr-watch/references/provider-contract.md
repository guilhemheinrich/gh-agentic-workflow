# Provider contract

A **provider** is what `prw` needs to know about one Git host. Adding a host
means writing one file, `scripts/lib/<host>.sh`, plus a transport function in
`api.sh` and three lines in `provider.sh`. The engine (store, diff, daemon,
wait, hooks) never names a host.

Two reference providers ship: `bitbucket.sh` (Bitbucket Cloud) and `github.sh`
(GitHub). Read them before writing a third; GitLab and Azure DevOps are the
likely next ones and are **not built**.

## 1. The repo key

A key names a repository on one host and is the only host-bearing string the
engine stores.

| Host | Key | Why |
|---|---|---|
| Bitbucket Cloud | `WS/REPO` | the original form: state written before GitHub existed keeps working |
| GitHub | `github:OWNER/REPO` | prefix because `OWNER/REPO` and `WS/REPO` can collide |
| a new host | `<host>:PATH` | never reuse a bare form |

`provider.sh` turns a key into a host (`provider_of`) and a path (`repo_of`),
and a git remote URL into a key (`repo_from_remote`, which asks each provider's
`<host>_repo_from_url`).

## 2. Functions a provider implements

All take the **key**, never a bare path. A provider reads `repo_of "$key"`
itself.

| Function | Returns |
|---|---|
| `<host>_repo_from_url URL` | the key of a remote URL of this host, nothing otherwise |
| `<host>_check_credential` | 0 when the credential is loaded, else a one-line fix on stderr and 1 |
| `<host>_pr_for_branch KEY BRANCH` | the number of the open PR whose source is BRANCH, nothing if none; the transport's code when the lookup fails |
| `<host>_pr_merge_commit KEY PR` | the merge commit of a merged PR, nothing until known |
| `<host>_snapshot_fetch KEY PR [PREV_FILE]` | the PR snapshot (§3) on stdout |
| `<host>_build_fetch KEY COMMIT [PR_SNAPSHOT_FILE]` | the build snapshot (§4) on stdout |

The transport, `<x>_get PATH_OR_URL`, prints the body and returns:

| Code | Meaning |
|---|---|
| 0 | 2xx |
| 10 | 401: the credential is rejected (stderr `auth`); the daemon stops calling this host for the cycle |
| 11 / 14 | 404 / 403: no such resource / no access to it; logged, other repos keep being polled |
| 12 | 429 that persists after one `Retry-After` wait |
| 13 | anything else |

It also sets `HTTP_CODE` and `HTTP_URL`, which the daemon logs and `doctor`
reports. The credential goes through a curl config read on stdin (`-K -`),
**never argv**: `ps` and logs must not see it. Only GET exists.

## 3. The PR snapshot

Everything the diff compares. No comment body, ever: bodies are third-party text.

```json
{
  "repo": "<key>", "pr": 42,
  "state": "OPEN | MERGED | DECLINED | SUPERSEDED",
  "head": "<sha>", "dest_head": "<sha>", "dest_branch": "staging",
  "merge_commit": "<sha> | null",
  "title": "…", "url": "https://…",
  "participants": { "<id>": { "name": "…", "state": "approved | changes_requested" } },
  "statuses":     { "<key>": { "name": "…", "state": "SUCCESSFUL | FAILED | STOPPED | INPROGRESS", "updated": "<iso> | null", "url": "… | null" } },
  "comments":     { "<id>": { "author": "…", "path": "… | null", "line": 12, "deleted": false } },
  "conflict": false,
  "fetched_at": "<iso>"
}
```

Rules the diff relies on:

- `participants` holds only people whose current verdict is an approval or a
  change request; a comment-only review is absent.
- `statuses` is the CI of **the head commit**, keyed by something stable across
  polls. A new head makes every status new again.
- `comment` ids are unique across every comment list the host has, and are the
  ids the comment hook records.
- `conflict` must keep its previous value while the host cannot say yet
  (GitHub answers `mergeable: null` for a few seconds after a push).

## 4. The build snapshot

What the post-merge phase compares: `{repo, commit, phase: "build", statuses,
fetched_at}`. A fast-forward merge keeps the PR head as the merge commit: a
status already present in the PR snapshot with the same key and the same
`updated` is the finished PR run and **must be dropped**, or the PR's CI would
pass for the branch's.

## 5. Mapping the two reference hosts

| Snapshot field | Bitbucket Cloud | GitHub |
|---|---|---|
| PR | `pullrequests/N` | `pulls/N` |
| `state` | `state` | `merged` ? `MERGED` : `state == closed` ? `DECLINED` : `OPEN` |
| `head` / `dest_head` | `source.commit.hash` / `destination.commit.hash` | `head.sha` / `base.sha` |
| `merge_commit` | `merge_commit.hash` | `merge_commit_sha`, only when `merged` |
| `participants` | `participants[]`: `approved`, `state` | `pulls/N/reviews`: last `APPROVED` / `CHANGES_REQUESTED` per user, `DISMISSED` clears |
| `statuses` | `commit/<head>/statuses`: `state` is already the target vocabulary | `commits/<head>/check-runs` (`conclusion` `success` `neutral` `skipped` → SUCCESSFUL, `cancelled` → STOPPED, other → FAILED, not `completed` → INPROGRESS) plus `commits/<head>/statuses` (`success` / `pending` / other) |
| `comments` | `pullrequests/N/comments`, paged by `next` | `pulls/N/comments` (inline) + `issues/N/comments` (conversation), paged by `page=` |
| `conflict` | `diffstat` has a `merge conflict` entry (the heaviest call: only when a head moved) | `mergeable == false` or `mergeable_state == dirty` |
| PR for a branch | `pullrequests?q=source.branch.name="B" AND state="OPEN"` | `pulls?state=open&head=OWNER:B` |

## 6. Checklist for a new host

1. `<host>_get` in `api.sh`, with the table of codes above and a unit test per code.
2. `scripts/lib/<host>.sh` with the six functions.
3. `provider.sh`: one `case` branch in `provider_of`, `repo_of`, and each dispatcher.
4. A credential variable in the env file, a `setup --<host>` option, a line in `doctor`.
5. **Real payloads in `tests/fixtures/<host>-real/`**, fetched from the host, with a
   `README.md` naming the source and the date. A fixture written from memory
   cannot catch a wrongly remembered field: the first GitHub fixtures were, and
   only a real-payload test settles it.
6. Run the suite under the macOS system `jq` as well as the Docker one: the two
   disagree on operator precedence in `A + B as $x | …`.
