# PostToolUse payloads of the Linear MCP — fixtures for LW-6

What each file is, and how much of it was measured (2026-11-12).

## Measured

- **The hook envelope** — `envelope-list-teams-cli.json`. A real PostToolUse
  payload, captured by a hook passed to a headless `claude -p --settings …`
  child on a read-only `list_teams` call. Only session ids and paths were
  replaced. What it shows:
  - `tool_response` is a list of content blocks,
    `[{"type": "text", "text": "<JSON of the result>"}]`;
  - in the CLI the tool is named `mcp__claude_ai_Linear__<tool>`, in Claude
    Desktop `mcp__0b0fa505-9003-4e08-9570-9316f3527103__<tool>` (a UUID
    prefix): the hook matcher must be the regex
    `mcp__.*__(save_comment|save_issue)`;
  - the payload carries `mcp_server: {"name": "claude.ai Linear", "source": "claudeai"}`.
- **The response shapes** of `save_comment` and `save_issue`: the field names,
  their order and the content-block wrapping were read from about 1,900
  `save_comment` / `save_issue` results of the Desktop server
  `0b0fa505-…` in local session transcripts (November 2026). Every success was
  a text block holding a JSON object; every failure was a plain string
  starting with `Error:`. The fields `lw` relies on:
  - comment: `id` (UUID), `body`, `createdAt`, `author {id, name}`,
    `quotedText`, `resolvedAt`, `onBehalfOf`;
  - issue: `id` (the identifier, e.g. `TT-2117`), `url`
    (`https://linear.app/…`), `status` (state name), `statusType`.

## Not measured

- **No live write capture.** The plan was to create and delete a throwaway
  issue and comment in team Agents (MDL) with the hook armed. Both attempts —
  through a headless child and through this session's own MCP tool — were
  refused by the auto-mode classifier (external system writes), and copying
  transcript results verbatim into the repository was refused too
  (sensitive-source provenance). So every `save-*.json` file is **hand-written**:
  real field names and wrapping, invented ids, names and text.
- **Whether Claude Desktop write calls carry `mcp_server`** is unverified. `lw`
  does not require it: when present and not naming Linear, the payload is
  rejected; when absent, the response shape decides.
- The failed calls (`*-error.json`) are written as PostToolUse payloads whose
  `tool_response` is the error string. Claude Code may route failures to a
  separate event instead; either way `lw` writes nothing for them.

## Files

| File | Call | Expected `own_writes` row |
|---|---|---|
| `save-comment-created.json` | new comment on TT-2287 | `comment`, its UUID |
| `save-comment-edited.json` | existing comment edited | `comment`, its UUID |
| `save-issue-state.json` | TT-2117 → `In Review` | `state`, `TT-2117`, `In Review` |
| `save-issue-state-again.json` | TT-2117 → state type `completed` | `state`, `TT-2117`, `Done` (replaces the row above) |
| `save-issue-created-with-state.json` | new issue TT-2250 with a state | `state`, `TT-2250`, `In Progress` |
| `save-issue-no-state.json` | TT-2133, links only | none |
| `save-comment-error.json`, `save-issue-error.json` | failed calls | none |
| `other-mcp-save-comment-named.json` | made-up: Notion's `save_comment`, `mcp_server` set | none |
| `other-mcp-save-comment-generic.json` | made-up: another server, no `mcp_server`, `{id, body, createdAt}` | none |
| `envelope-list-teams-cli.json` | read-only `list_teams` | none (not a write) |
