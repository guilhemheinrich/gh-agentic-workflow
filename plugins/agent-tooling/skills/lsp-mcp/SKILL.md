---
name: lsp-mcp
description: >-
  Install, configure, and use the CJL.lsp-mcp VS Code extension — an MCP server
  that bridges VS Code's already-running Language Servers (LSP) to AI agents.
  Claude Code has a native LSP tool; this skill is for other MCP clients
  (Cursor, OpenCode, Roo, Codex). Covers MCP client setup at project and global
  scope via scripts/setup.sh, installing the right LSP-providing VS Code extension per
  language (Python, JS/TS, HTML, CSS, Vue, Nuxt, PHP, Symfony, Go), registering
  extensions in the project .vscode/extensions.json, and driving the execute_lsp
  tool (hover, definition, references, rename, call hierarchy, symbols). Use when
  setting up code-intelligence tooling for an agent or troubleshooting lsp-mcp.
tags:
  - mcp
  - lsp
  - vscode
  - code-intelligence
  - tooling
---

# lsp-mcp — VS Code Language Servers as an MCP tool

**Claude Code has a native LSP tool; prefer it there.** This skill is for other
MCP clients (Cursor, OpenCode, Roo Code, Codex...) that lack one.

`CJL.lsp-mcp` ([marketplace](https://marketplace.visualstudio.com/items?itemName=CJL.lsp-mcp))
exposes the language servers already running inside a VS Code window as one MCP
tool, `execute_lsp`, over Streamable HTTP at `http://127.0.0.1:9527/mcp`.

## Mental model

- It is a bridge: it starts no language server. VS Code must be running with the
  project open, the language extension installed, and one file of that language
  opened so the server warms up.
- Transport is HTTP, not stdio: the client connects to the URL.
- Empty results usually mean: VS Code closed, another window owns the port, or
  the language extension is missing or not yet activated.

## Setup

```bash
code --install-extension CJL.lsp-mcp
bash scripts/setup.sh <claude|cursor|opencode> <project|global> [python,vue,nuxt,php,symfony,go]
```

`scripts/setup.sh` merges the MCP client entry into the right file (`.mcp.json`,
`.cursor/mcp.json`, `opencode.json`, or the global equivalents), and at project
scope writes `lsp-mcp.*` keys to `.vscode/settings.json` and extension
recommendations to `.vscode/extensions.json`. It is idempotent; languages are
auto-detected when omitted. Set `LSP_MCP_PORT` to change the port (give each
project window its own port, in `lsp-mcp.port` and in the client URL). Restart
the client afterwards. Other `lsp-mcp.*` settings: `enabled`, `maxRetries`,
`cors.enabled`, `cors.allowOrigins`, `outputFormat` (`json` recommended),
`maxResults` (default 200).

Client specifics: OpenCode uses `"type": "remote"` under `mcp`; Claude Code uses
`"type": "http"`; Roo Code uses `"type": "streamable-http"`.

## Language server per language

| Language | Extension |
|---|---|
| Python | `ms-python.python` (pulls Pylance) |
| JS / TS, HTML, CSS | built in to VS Code |
| Vue, Nuxt | `Vue.volar` (Nuxt has no dedicated LSP) |
| PHP, Symfony | `bmewburn.vscode-intelephense-client` (built-in PHP only lints) |
| Go | `golang.go` (run "Go: Install/Update Tools" once for `gopls`) |

## `execute_lsp`

Arguments: `operation`, `uri` (absolute file path, not `file://`), `line` and
`character` for position-based operations, `query` for `workspace_symbols`,
`newName` for `rename`. **Positions are 1-based on input and output**, so an
output `namePosition` feeds straight back as `line`/`character`.

| Operation | Needs | Returns |
|---|---|---|
| `hover`, `definition`, `declaration`, `implementation`, `references`, `completions` | uri, line, character | docs / locations / items |
| `rename` | + `newName` | summary of edits |
| `symbol_at_position`, `incoming_calls`, `outgoing_calls` | uri, line, character | symbol metadata, callers, callees (each with `namePosition`) |
| `document_symbols` | uri | outline of one file |
| `workspace_symbols` | query | symbols across workspace (truncated by `maxResults`) |
| `class_file_contents` | `jdt://` uri | decompiled Java |

Workflow: locate (`workspace_symbols` / `document_symbols`), understand (`hover`,
`definition`), assess impact (`references`, `incoming_calls`), then act
(`rename`). Chain call hierarchy through each result's `namePosition`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Client cannot connect | Open the project in VS Code; check `lsp-mcp.port`; `curl http://127.0.0.1:<port>/mcp` |
| Empty results | Install the language extension; open a file of that type |
| Foreign results | A different window owns the port; use per-project ports |
| Off-by-one positions | Everything is 1-based; use values verbatim |
| Rename did nothing | Verify the position with `symbol_at_position` |
