# `linear api` as the transport of `lw` — measured behaviour

Measured on **2026-11-12** on macOS (Darwin 25.5, Apple silicon) with
`linear 3.1.0` (`schpet/linear-cli`, installed by
`brew install schpet/tap/linear` → `/opt/homebrew/bin/linear`), workspace
`septeo-proptech`. Read-only GraphQL only. Real payloads:
[`tests/linear-watch/fixtures/linear-real/`](../tests/linear-watch/fixtures/linear-real/README.md).

In every transcript below the API key is loaded with
`. ~/.config/linear/env; export LINEAR_API_KEY` and never appears on argv;
keys, e-mails and names are replaced by `<key>`, `<email>`, `<redacted>`.
A small wrapper printed exit code, stdout and stderr separately; its output is
quoted as-is.

## Answers in one screen

| # | Question | Measured answer | Consequence for `lw` |
|---|---|---|---|
| 1 | Which credential wins? | `LINEAR_API_KEY` from the environment beats a stored credential (`linear auth login`) **and** a `.env` / `.linear.toml` in the cwd. An empty `LINEAR_API_KEY=` counts as unset. `--workspace` is refused while `LINEAR_API_KEY` is set (exit 2). | Always export `LINEAR_API_KEY` to the child; set `LINEAR_IGNORE_ENV_FILE=1`; never pass `--workspace`. |
| 2 | Exit codes / streams | 0 ok (stdout) · 1 GraphQL validation or bad input (stderr JSON, HTTP 400) · 2 usage (stderr text) · **3 not found = the HTTP 200 + `errors` case (stdout JSON, `data: null`)** · 4 no key (stderr text) or 401 (stderr JSON) · 5 unreachable (stderr text). | Codes are distinguishable; LW-2 still reads **both** streams, because the JSON body moves between stdout and stderr by class. Rate limiting (5) was not provoked: 12 vs 13 needs the body. |
| 3 | `--paginate` on `comments` | Works: 7 pages of 5 → 31 unique nodes, identical to one `first: 250` call. Output is a **bare JSON array of nodes**, no `data` envelope. Requires `$after` declared and used, and `pageInfo { hasNextPage endCursor }` selected — without `pageInfo` it silently returns one page, exit 0. Refuses two connections in one query. | Prefer `first: 250` without `--paginate` at this volume (≤ 31 comments per project in a morning); if paginating, assert `pageInfo` is in the document. |
| 4 | launchd's empty environment | `PATH=/usr/bin:/bin:/usr/sbin:/sbin`; bare `linear` → `command not found`, exit 127; `/opt/homebrew/bin/linear` runs; `LINEAR_API_KEY` is absent (exit 4). `HOME` is set. | `LW_LINEAR_BIN` defaults to `/opt/homebrew/bin/linear` (the Homebrew symlink, never the `Cellar/…/3.1.0` realpath that `brew upgrade` moves); the daemon loads the key from `~/.config/linear/env` itself. |

The roadmap's "Done when" fallback ("if the CLI cannot give a distinguishable
exit code for a GraphQL error, LW-2 parses the body") is **not needed for the
classes LW-2 acts on**: 4 (credential), 3 (not found) and 1 (bad query) are
distinct. It is needed only inside exit 5, where unreachable, timeout and rate
limit share one code.

## 1. Credential precedence

Documented by `linear --help`:

```text
Environment:
  LINEAR_API_KEY            API key to use instead of a stored credential
  LINEAR_TEAM_ID            Default team key
  LINEAR_DEBUG=1            Show the details and causes of errors
  LINEAR_IGNORE_ENV_FILE=1  Do not load .env files
```

Before the test nothing was stored (`linear auth list` → `No workspaces
configured`). The real key was stored through stdin, plaintext file (the
system-keyring path, the default without `--plaintext`, was **not** tested):

```console
$ ( . ~/.config/linear/env; printf '%s' "$LINEAR_API_KEY" ) | env -u LINEAR_API_KEY linear auth login --plaintext
Logged in to workspace: Septeo Proptech (septeo-proptech)
  User: <redacted> <<email>>
  Set as default workspace
$ cat ~/.config/linear/credentials.toml
default = "septeo-proptech"
septeo-proptech = "<key>"
```

| Case | Stored credential | Environment | Exit | Output |
|---|---|---|---|---|
| A | real | unset | 0 | stdout `{"data":{"organization":{"urlKey":"septeo-proptech"}}}` |
| B | real | `LINEAR_API_KEY=<bogus>` | **4** | stderr `{"errors":[{"message":"Authentication required, not authenticated",…"statusCode":401…}]}` |
| C | real | `LINEAR_API_KEY=<bogus>` + `--workspace septeo-proptech` | **2** | stderr `✗ API request failed: Cannot use --workspace while LINEAR_API_KEY is set` / `Unset LINEAR_API_KEY or remove the --workspace flag.` |
| D | real | `LINEAR_API_KEY=` (empty) | 0 | stdout data — empty counts as unset |
| E0 | bogus (edited into `credentials.toml`) | unset | 4 | stderr 401 body |
| E | bogus | `LINEAR_API_KEY=<real>` | **0** | stdout data |

B and E prove it both ways: **the environment wins**, the stored credential is
not even tried as a fallback when the environment key is rejected.

Files in the working directory (`.env`, `.linear.toml`), env unset:

```text
cwd .env with LINEAR_API_KEY=<bogus>, env unset          → exit 4, 401 JSON body   (the .env was loaded)
same, LINEAR_IGNORE_ENV_FILE=1                           → exit 4, "✗ API request failed: No API key configured"
same .env in the PARENT dir only (not a git repo)        → exit 4, "No API key configured" (parents not searched)
cwd .env bogus, env real                                 → exit 0
cwd .linear.toml api_key = "<bogus>", env unset          → exit 4, 401 JSON body   (third credential source)
cwd .linear.toml bogus, env real                         → exit 0
```

`LINEAR_IGNORE_ENV_FILE=1` does not cover `.linear.toml`; the defence there is
that an environment key always wins, plus a fixed working directory (launchd
starts jobs in `/`).

The machine was left as found: `linear auth logout --workspace septeo-proptech --yes`
(`✓ Removed credentials for workspace septeo-proptech`) emptied
`~/.config/linear/credentials.toml`, which did not exist before and was then
deleted. The key file `~/.config/linear/env` was only read.

## 2. Exit code and streams of `linear api`

Documented by `linear --help`:

```text
Exit status:
  0    Success
  1    Any other failure, including GraphQL errors such as an invalid query
  2    Usage error: bad flags or values, rejected before anything is sent
  3    Not found: an issue, team, or other entity the command looked up
  4    Authentication: no usable API key, or Linear rejected it
  5    Unavailable: Linear could not be reached, timed out, rate limited
       the request, or failed with a server error. A create or update may
       still have taken effect
  130  Cancelled at a prompt or in the editor
```

Measured (`HTTP` = the same document sent with curl, key passed through
`curl -K -` on stdin):

| Case | Command (document) | HTTP | Exit | stdout | stderr |
|---|---|---|---|---|---|
| success | stdin `query Q($k: String!) { issue(id: $k) { identifier state { name type } } }`, `--variables-json '{"k":"TT-2287"}'` | 200 | 0 | `{"data":{"issue":{"identifier":"TT-2287","state":{"name":"In Progress","type":"started"}}}}` | empty |
| **200 + `errors`** | `issue(id: "TT-999999")` | **200** | **3** | `{"errors":[{"message":"Entity not found: Issue","path":["issue"],…"code":"INPUT_ERROR","statusCode":400,…}],"data":null}` | empty |
| partial (one alias found, one not) | `{ a: issue(id: "TT-2287") {…} b: issue(id: "TT-999999") {…} }` | 200 | 3 | same `INPUT_ERROR` on `path ["b"]`, **`"data":null`** — the found issue is lost too | empty |
| unknown field | `{ organization { urlKey nopeField } }` | **400** | 1 | empty | `{"errors":[{"message":"Cannot query field \"nopeField\" on type \"Organization\".",…"code":"GRAPHQL_VALIDATION_FAILED"…}]}` |
| syntax error | `{ organization { urlKey ` | 400 | 1 | empty | `{"errors":[{"message":"Syntax Error: Expected Name, found <EOF>.",…"code":"GRAPHQL_PARSE_FAILED"…}]}` |
| wrong variable type | `--variables-json '{"k":42}'` for `$k: String!` | 400 | 1 | empty | `{"errors":[{"message":"Variable \"$k\" got invalid value 42; String cannot represent a non string value: 42",…"code":"BAD_USER_INPUT"…}]}` |
| missing variable | `$k: String!` not provided | — | 1 | empty | `{"errors":[{"message":"Variable \"$k\" of required type \"String!\" was not provided.",…"code":"BAD_USER_INPUT"…}]}` |
| bad key | `LINEAR_API_KEY=<bogus>` | **401** | 4 | empty | `{"errors":[{"message":"Authentication required, not authenticated","extensions":{"type":"authentication error","code":"AUTHENTICATION_ERROR","statusCode":401,…}}]}` |
| no key | env unset, nothing stored | — | 4 | empty | `✗ API request failed: No API key configured` / `  Set LINEAR_API_KEY, add api_key to .linear.toml, or run \`linear auth login\`.` |
| unreachable | `HTTPS_PROXY=http://127.0.0.1:9` | — | 5 | empty | `✗ API request failed: Request to https://api.linear.app failed: Connection refused (os error 61)` |

Two findings that correct the roadmap's wording:

- An unknown field is **not** "HTTP 200 with an `errors` body": Linear answers
  **400**. The real 200-with-errors case is *not found*, and the CLI maps it to
  exit **3** with the body on **stdout**.
- The JSON body is on stdout for exit 0 and 3, on stderr for exit 1 and 4;
  failures raised by the CLI itself (no key, usage, unreachable, pagination
  refusals) are human text on stderr starting with `✗ API request failed:`.

Also observed, once, unplanned: a query
`issues(filter: {id: {in: $ids}})` with `$ids: [String!]` exited **5** with
stderr `✗ API request failed: Request to https://api.linear.app failed:
Connection reset by peer (os error 54)`. The same query with `$ids: [ID!]`
succeeded twice right after. Exit 5 does happen in the wild; it must leave the
cursor untouched (LW-3).

**Variables:** `--variable k=42` sends a **number** (same `BAD_USER_INPUT` as
above) — the CLI coerces anything that looks like a number, boolean or null. A
12-hex-digit project slugId can be all digits. LW-2 passes variables through
`--variables-json` only.

**Grouped queries:** because a single missing identifier nulls the whole
`data` (partial row above), LW-3's "one grouped query over identifiers" must
use a connection filter, where missing issues are simply absent:

```console
$ linear api --variables-json '{"ids":["TT-2287","TT-999999"]}' 'query S($ids: [ID!]) { issues(filter: {id: {in: $ids}}) { nodes { identifier state { type } } } }'
{"data":{"issues":{"nodes":[{"identifier":"TT-2287","state":{"type":"started"}}]}}}
exit=0
```

Not measured: rate limiting (exit 5 by documentation, not provoked — 2500
requests/hour is far above `lw`'s ≈ 24/h), timeouts, 5xx.

## 3. `--paginate` on the `comments` connection

```console
$ Q='query C($since: DateTimeOrDuration!, $p: String!, $after: String) { comments(first: 5, after: $after, filter: {createdAt: {gt: $since}, issue: {project: {slugId: {eq: $p}}}}) { nodes { id createdAt issue { identifier } } pageInfo { hasNextPage endCursor } } }'
$ V='{"since":"2026-11-12T08:00:00Z","p":"5842ed0c2bcd"}'
$ linear api --variables-json "$V" "$Q" | jq -c '{n: (.data.comments.nodes|length), pi: .data.comments.pageInfo}'
{"n":5,"pi":{"hasNextPage":true,"endCursor":"ce95beb5-76df-450e-b1a3-824c706525f9"}}
$ linear api --paginate --variables-json "$V" "$Q" > pall.json; echo "exit=$?"
exit=0
$ head -c 120 pall.json
[{"id":"c9dceae3-9888-4aa9-a5b2-2e812e96c9c3","createdAt":"2026-11-12T15:46:49.980Z","issue":{"identifier":"TT-2537"}},…
$ jq 'length, ([.[].id]|unique|length)' pall.json
31
31
$ # control: one page large enough
$ linear api --variables-json "$V" 'query C($since: DateTimeOrDuration!, $p: String!) { comments(first: 250, filter: {createdAt: {gt: $since}, issue: {project: {slugId: {eq: $p}}}}) { nodes { id } pageInfo { hasNextPage } } }' | jq -c '{n: (.data.comments.nodes|length), more: .data.comments.pageInfo.hasNextPage}'
{"n":31,"more":false}
```

Traps:

```text
$after not declared                → exit 1, stderr "✗ API request failed: Linear sent the same pagination cursor twice" / "Retry the command."
pageInfo not selected              → exit 0, ONE page (5 nodes), no warning
two paginated connections          → exit 1, stderr "✗ API request failed: --paginate does not support queries with multiple paginated connections"
GraphQL error on page 1            → exit 1, nothing on stdout, error JSON on stderr (same as without --paginate)
```

## 4. `linear` under launchd

A transient job submitted to launchd (removed right after):

```console
$ launchctl submit -l com.lw0.probe -o "$OUT" -e "$OUT" -- /bin/sh -c 'echo "PATH=$PATH"; echo "HOME=$HOME"; echo "LINEAR_API_KEY set: ${LINEAR_API_KEY:+yes}"; linear --version; echo "rc bare=$?"; /opt/homebrew/bin/linear --version; echo "rc abs=$?"; env -u LINEAR_API_KEY /opt/homebrew/bin/linear api "{ organization { urlKey } }" >/dev/null 2>&1; echo "rc abs api without key=$?"'
$ launchctl remove com.lw0.probe; cat "$OUT"
PATH=/usr/bin:/bin:/usr/sbin:/sbin
HOME=/Users/<redacted>
LINEAR_API_KEY set: 
/bin/sh: linear: command not found
rc bare=127
linear 3.1.0
rc abs=0
rc abs api without key=4
```

(The probe also printed a `command -v linear` line, omitted here: it printed
`none`, and its `rc` was `echo`'s, not the lookup's.)

`/opt/homebrew/bin/linear` is the Homebrew symlink to
`/opt/homebrew/Cellar/linear/3.1.0/…`; `lw` must store the symlink path, which
survives `brew upgrade`, never the resolved one.

## 5. The LW-3 poll documents, run once against real Linear

The four documents of `scripts/lw` (`CommentsSince`, `IssuesUpdatedSince`,
`ProjectIssueStates`, `WatchedIssues`) were run on **2026-11-12** through
`linear_api()` with `/opt/homebrew/bin/linear`, read-only, project
`5842ed0c2bcd`, `since 2026-11-12T08:00:00Z`; the probe printed counts only:

```text
CommentsSince ok nodes=39 hasNext=False
IssuesUpdatedSince ok nodes=100 hasNext=True
ProjectIssueStates ok nodes=100 hasNext=True  types=['backlog', 'duplicate', 'started', 'unstarted']
  ProjectIssueStates paged total=125
WatchedIssues ok nodes=2 hasNext=None  idents=['TT-2287', 'TT-2519'] comments=[3, 2] project=['5842ed0c2bcd']
```

- Every document is valid: no `GRAPHQL_VALIDATION_FAILED`, `$after: null` on
  the first page is accepted, `_paged()` followed `endCursor` to 125 open
  issues.
- `issues(filter: {id: {in: $ids}})` takes identifiers, and the nested
  `comments(filter: {createdAt: {gt: $since}})` works: `TT-999999` is simply
  absent, the two others come back with their comments.
- The workspace has a state type `duplicate` besides `completed` and
  `canceled`; the baseline keeps it (it only excludes the two finished types).
