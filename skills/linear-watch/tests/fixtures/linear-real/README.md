# Real Linear payloads (LW-0)

Captured on **2026-11-12** (≈ 16:50 Europe/Paris) with `linear` 3.1.0
(`schpet/linear-cli`, `brew install schpet/tap/linear`), read-only GraphQL,
workspace `septeo-proptech`, project slugId `5842ed0c2bcd`
(`broker-pa-run-and-evolutions-courant`). How each call behaves is documented
in [`references/linear-cli.md`](../../../references/linear-cli.md).

## What was rewritten

Everything else (ids of comments, issues and states, timestamps, state
names and types, `pageInfo`, error bodies) is byte-for-byte what Linear sent,
re-indented.

- **People**: every `user` object → `id` `00000000-0000-4000-8000-00000000000N`,
  `name` `Person A|B`, `displayName` `person-a|b` (stable mapping across files;
  two people in this sample).
- **Titles in URLs**: `…/issue/TT-2537/<title-slug>` → `…/issue/TT-2537/redacted-title`
  (the `#comment-…` anchor is kept). Project URL name part →
  `…/project/redacted-name-<slugId>`, so the slugId extraction still sees the
  real shape.
- **Project name** → `Completed project (name redacted)`.
- No comment body and no issue title were queried.

## Files

| File | Query (variables) | HTTP | `linear api` exit | Stream |
|---|---|---|---|---|
| `comments-since.json` | `CommentsSince`, `first: 50`, `since 2026-11-12T08:00:00Z`, `p 5842ed0c2bcd` — 31 nodes, `hasNextPage: false` | 200 | 0 | stdout |
| `comments-since-paginated.json` | same query, `first: 5` + `--paginate` — **bare array** of the 31 nodes, no `data` envelope | 200 ×7 | 0 | stdout |
| `issues-updated-since.json` | `IssuesUpdatedSince`, `first: 50`, same bounds — 50 nodes, `hasNextPage: true` (a real first page) | 200 | 0 | stdout |
| `project-completed.json` | `ProjectState`, `project(id: "c70b17017c41")` — `state: "completed"`, `status.type: "completed"` | 200 | 0 | stdout |
| `errors-not-found.json` | `issue(id: "TT-999999")` — `errors` + `data: null` | **200** | **3** | **stdout** |
| `errors-unknown-field.json` | `{ organization { urlKey nopeField } }` — `GRAPHQL_VALIDATION_FAILED` | 400 | 1 | stderr |
| `errors-wrong-variable-type.json` | `issue(id: $k)` with `{"k": 42}` for `String!` — `BAD_USER_INPUT` | 400 | 1 | stderr |
| `errors-unauthenticated.json` | any query with a bogus key — `AUTHENTICATION_ERROR` | 401 | 4 | stderr |

The full GraphQL documents:

```graphql
query CommentsSince($since: DateTimeOrDuration!, $p: String!, $after: String) {
  comments(first: 50, after: $after, orderBy: createdAt,
           filter: {createdAt: {gt: $since}, issue: {project: {slugId: {eq: $p}}}}) {
    nodes { id createdAt updatedAt url botActor { id name }
            user { id name displayName }
            issue { id identifier url state { name type } } }
    pageInfo { hasNextPage endCursor }
  }
}

query IssuesUpdatedSince($since: DateTimeOrDuration!, $p: String!, $after: String) {
  issues(first: 50, after: $after, orderBy: updatedAt,
         filter: {updatedAt: {gt: $since}, project: {slugId: {eq: $p}}}) {
    nodes { id identifier url updatedAt state { id name type } }
    pageInfo { hasNextPage endCursor }
  }
}

query ProjectState($p: String!) {
  project(id: $p) { id slugId name url state status { name type }
                    completedAt canceledAt updatedAt }
}
```

Observed in this sample, worth a test: `botActor` is `null` on every comment,
and one comment has `updatedAt` 45 ms **before** its `createdAt`
(`c9dceae3…`: created `15:46:49.980Z`, updated `15:46:49.935Z`) — never order
comments by `updatedAt`.

## How the poll tests replay this day (LW-3)

`tests/bin/linear` serves these files to `test_cycle.py` as Linear would answer
the poll queries: it applies the `since` variable, hides what is newer than
`FAKE_LINEAR_NOW` (Linear's present), and answers a call with `after` with the
terminal page. Its answers to `ProjectIssueStates` and `WatchedIssues` are
**synthesized** from the captured issue and comment nodes (those two queries
were validated against Linear but their payloads were not captured).
