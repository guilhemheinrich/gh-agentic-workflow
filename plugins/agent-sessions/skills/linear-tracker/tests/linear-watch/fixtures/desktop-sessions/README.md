# Fake desktop sessions folder

Stands in for `~/Library/Application Support/Claude/claude-code-sessions/` in
the LW-5 expiry tests. Hand-written, fake UUIDs only. The real layout is
`<folder>/<a>/<b>/local_<uuid>.json`; `lw` reads only `cliSessionId`,
`priorCliSessionIds` and `isArchived` (types measured on 5,422 real files on
2026-11-12: `cliSessionId` string or null, `priorCliSessionIds` null or a list
of strings, `isArchived` boolean). Every other key here holds `DECOY` so a test
can assert it never reaches lw's output.

| File | CLI session ids | `isArchived` | Case |
|---|---|---|---|
| `workspace-a/account-1/local_…0a.json` | `aaaaaaaa-…01` | true | archived, matched by `cliSessionId` |
| `workspace-a/account-1/local_…0b.json` | `bbbbbbbb-…02`, prior `bbbbbbbb-…01` | true | archived, matched by `priorCliSessionIds` |
| `workspace-a/account-2/local_…0c.json` | `cccccccc-…01` | false | live session |
| `workspace-b/account-1/local_…0d.json` | `dddddddd-…01` (no prior key) | true | archived copy… |
| `workspace-b/account-1/local_…0e.json` | `eeeeeeee-…01`, prior `dddddddd-…01` | false | …whose id lives on in a live file: not archived |
| `workspace-b/account-1/local_…0f.json` | null | false | never started: ignored |
| `workspace-b/account-1/not-a-session.json` | `ffffffff-…01` | false | outside the `local_*.json` glob: ignored |
