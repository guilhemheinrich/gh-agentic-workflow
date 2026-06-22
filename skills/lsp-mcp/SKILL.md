---
name: lsp-mcp
description: >-
  Install, configure, and use the CJL.lsp-mcp VS Code extension — an MCP server
  that bridges VS Code's already-running Language Servers (LSP) to AI agents.
  Covers MCP client setup for Claude Code, Cursor, and OpenCode at both project
  and global scope, installing the right LSP-providing VS Code extension per
  language (Python, JS/TS, HTML, CSS, Vue, Nuxt, PHP, Symfony, Go), registering
  extensions in the project .vscode/settings.json, and driving the execute_lsp
  tool (hover, definition, references, rename, call hierarchy, symbols). Use when
  setting up code-intelligence tooling for an agent or troubleshooting lsp-mcp.
tags:
  - mcp
  - lsp
  - vscode
  - code-intelligence
  - tooling
---

# lsp-mcp — Bridging VS Code Language Servers to AI Agents

`CJL.lsp-mcp` is a VS Code extension ([marketplace](https://marketplace.visualstudio.com/items?itemName=CJL.lsp-mcp)) that exposes the **language servers already running inside your VS Code window** as a single MCP tool, `execute_lsp`. The agent gets the *same* semantic intelligence the editor has — go-to-definition, find-references, hover docs, rename, call hierarchy — instead of grepping text.

## Mental model (read this first)

- The extension **does NOT bundle or start language servers itself.** It is a *bridge*. It surfaces whatever LSP features are *currently active* in the VS Code instance.
- Therefore: for a language to work through lsp-mcp, **VS Code must already be running with the project open AND the matching language extension installed and activated** (i.e. you've opened at least one file of that language so the server warms up).
- Transport is **HTTP** (Streamable HTTP), not stdio. Default endpoint: `http://127.0.0.1:9527/mcp`. The MCP client connects to that URL — it does not spawn a process.

```
┌────────────────────── VS Code (must be open on the project) ──────────────────────┐
│  Pylance / gopls / Intelephense / Volar / tsserver ...  (the real LSPs)            │
│                        ▲                                                           │
│                        │ VS Code LSP API                                           │
│                 CJL.lsp-mcp extension ── HTTP :9527/mcp ──┐                         │
└──────────────────────────────────────────────────────────┼───────────────────────┘
                                                            │
                              MCP client (Claude Code / Cursor / OpenCode) ── execute_lsp
```

Consequence: if `execute_lsp` returns empty/“no results,” the usual cause is that VS Code isn't open, the project root differs, or the language extension for that file type isn't installed/activated.

---

## 1. Install & start the MCP server

1. **Install the extension** in VS Code: `Ctrl+Shift+X` → search `cjl.lsp-mcp` → Install. Or via CLI:
   ```bash
   code --install-extension CJL.lsp-mcp
   ```
2. **Open the target project** in VS Code (`File → Open Folder`). The HTTP server starts automatically on activation.
3. Verify it's listening (default port `9527`):
   ```bash
   curl -s http://127.0.0.1:9527/mcp -H "Accept: text/event-stream"
   ```

### Extension settings (`lsp-mcp.*`)

Set these in **User** settings (global) or **Workspace** settings (`.vscode/settings.json`, per project — recommended so the port travels with the repo).

| Setting | Type | Default | Notes |
|---|---|---|---|
| `lsp-mcp.enabled` | boolean | `true` | Master on/off. |
| `lsp-mcp.port` | number | `9527` | Change if the port collides; if busy it auto-retries. |
| `lsp-mcp.maxRetries` | number | `10` | Port-conflict retry attempts. |
| `lsp-mcp.cors.enabled` | boolean | `true` | Keep on for client connectivity. |
| `lsp-mcp.cors.allowOrigins` | string | `*` | Tighten if needed. |
| `lsp-mcp.outputFormat` | string | `json` | `json` is easiest for agents to parse. |
| `lsp-mcp.maxResults` | number | `200` | Cap on `references`/`workspace_symbols` results. |

Example `.vscode/settings.json` (project scope):
```jsonc
{
  "lsp-mcp.enabled": true,
  "lsp-mcp.port": 9527,
  "lsp-mcp.outputFormat": "json",
  "lsp-mcp.maxResults": 200
}
```

> If you run **multiple projects/windows at once**, give each its own `lsp-mcp.port` in its workspace settings (e.g. 9527, 9528, …) and point each MCP client config at the matching URL — otherwise they fight over the same port.

---

## 2. Register the MCP server in the AI client

The server is HTTP. Every client just needs the URL `http://127.0.0.1:9527/mcp`. Below: where the file lives at **project** vs **global** scope, and the exact JSON per client.

### Claude Code

| Scope | File location |
|---|---|
| **Project** (committed, shared with the team) | `.mcp.json` at the **repo root** |
| **Global / user** | `~/.claude.json` (Windows: `%USERPROFILE%\.claude.json`) |

`.mcp.json` (project scope) — this is the standard Claude Code MCP file:
```json
{
  "mcpServers": {
    "lsp-mcp": {
      "type": "http",
      "url": "http://127.0.0.1:9527/mcp"
    }
  }
}
```

Or add it from the CLI (project scope writes to `.mcp.json`):
```bash
claude mcp add --transport http --scope project lsp-mcp http://127.0.0.1:9527/mcp
```
Scopes: `--scope project` → `.mcp.json` (repo root) · `--scope user` → global `~/.claude.json` · `--scope local` → project-private in `~/.claude.json`.

### Cursor

| Scope | File location |
|---|---|
| **Project** | `.cursor/mcp.json` at the repo root |
| **Global** | `~/.cursor/mcp.json` (Windows: `%USERPROFILE%\.cursor\mcp.json`) |

```json
{
  "mcpServers": {
    "lsp": {
      "url": "http://127.0.0.1:9527/mcp"
    }
  }
}
```

### OpenCode

OpenCode uses `type: "remote"` for HTTP servers (not `"http"`), under the `mcp` key.

| Scope | File location |
|---|---|
| **Project** | `opencode.json` at the repo root |
| **Global** | `~/.config/opencode/opencode.json` |

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "lsp": {
      "type": "remote",
      "url": "http://127.0.0.1:9527/mcp",
      "enabled": true
    }
  }
}
```

### Other clients (reference)

- **Roo Code**: `{ "type": "streamable-http", "url": "http://127.0.0.1:9527/mcp", "disabled": false }`
- **Codex / Gemini / IFlow**: same HTTP URL, follow each client's MCP config schema.

After editing any config, **restart the client** (or reload its MCP servers) so it reconnects.

---

## 3. Install the right Language Server per language

lsp-mcp only relays what VS Code provides. Install the extension below, open a file of that type once to activate the server, and lsp-mcp exposes it. Register these in the project `.vscode/extensions.json` `recommendations` so teammates/agents are prompted to install them.

| Language | LSP source | VS Code extension `itemName` | Notes |
|---|---|---|---|
| **Python** | Pylance | `ms-python.python` + `ms-python.vscode-pylance` | Install `ms-python.python`; it pulls Pylance, the actual LSP. `charliermarsh.ruff` adds lint/format intelligence. |
| **JavaScript / TypeScript** | tsserver | *built-in* (`vscode.typescript-language-features`) | No extension needed — ships with VS Code. |
| **HTML** | VS Code HTML LS | *built-in* (`vscode.html-language-features`) | Built-in. |
| **CSS / SCSS / LESS** | VS Code CSS LS | *built-in* (`vscode.css-language-features`) | Built-in (this is the “does it exist” answer: yes, it's bundled). |
| **Vue** | Volar / Vue Language Server | `Vue.volar` | Official “Vue (Official)” extension. Provides `.vue` SFC intelligence. |
| **Nuxt** | Volar + tsserver (+ helpers) | `Vue.volar` (core) · `Nuxt.mdc` (Comark/MDC content) · `Nuxtr.nuxtr-vscode` (productivity) | Nuxt has **no dedicated LSP**; intelligence comes from `Vue.volar` for `.vue` and TS for the rest. Install Volar; add the others as helpers. |
| **PHP** | Intelephense | `bmewburn.vscode-intelephense-client` | The real PHP LSP. The built-in `vscode.php-language-features` only does `php -l` linting — install Intelephense for hover/definition/references. |
| **Symfony** | Intelephense (PHP) + helpers | PHP LSP via `bmewburn.vscode-intelephense-client` · helpers: `TheNouillet.symfony-vscode` or `tonka3000.symfony` | Symfony has **no standalone LSP**; semantic features come from the PHP LSP. Helper extensions add route/service/Twig awareness on top. |
| **Go** | gopls | `golang.go` | Official Go extension; uses `gopls`. Run “Go: Install/Update Tools” once so `gopls` is present. |

Project `.vscode/extensions.json`:
```json
{
  "recommendations": [
    "ms-python.python",
    "ms-python.vscode-pylance",
    "Vue.volar",
    "Nuxt.mdc",
    "Nuxtr.nuxtr-vscode",
    "bmewburn.vscode-intelephense-client",
    "golang.go"
  ]
}
```

Install any of them from the CLI:
```bash
code --install-extension ms-python.python
code --install-extension Vue.volar
code --install-extension bmewburn.vscode-intelephense-client
code --install-extension golang.go
```

> **Activation reminder:** after installing, open at least one file of that language in the running VS Code window so the server boots. Until it does, `execute_lsp` returns nothing for that file type.

---

## 4. Using `execute_lsp`

A single tool, `execute_lsp`, takes an `operation` plus arguments. **All line/character positions are 1-based** (they match VS Code's “Ln 9, Col 16” status bar) on both input *and* output — so an output `namePosition` like `9:16` feeds straight back as `line=9, character=16` with no conversion.

### Arguments

- `operation` (required) — one of the operations below.
- `uri` (required) — an **absolute file path** is recommended (e.g. `D:/code/app/src/main.ts` or `/home/user/app/src/main.ts`). Don't hand-build `file://` URIs.
- `line`, `character` — required for position-based operations.
- `query` — required for `workspace_symbols`.
- `newName` — required for `rename`.

### Operations

**Position-based** (need `uri` + `line` + `character`):
| Operation | Returns | Use for |
|---|---|---|
| `hover` | Signature + docs/JSDoc at position | Understand a symbol without opening files. |
| `definition` | File + line range | Jump to where a symbol is defined. |
| `declaration` | File + line range | Declaration (e.g. TS `.d.ts`). |
| `implementation` | File + line range | Concrete impls of an interface/abstract. |
| `references` | List of file + line ranges | Find every usage before refactoring. |
| `completions` | Up to 50 items (kind + detail) | What's valid at this position. |
| `rename` | Summary of files/edits changed (needs `newName`) | Safe project-wide rename. |
| `symbol_at_position` | Symbol metadata + `namePosition` | Seed for call-hierarchy chaining. |
| `incoming_calls` | Callers (each with `namePosition`) | Who calls this function. |
| `outgoing_calls` | Callees (each with `namePosition`) | What this function calls. |

**Non-position** (need only `uri`, or `query`):
| Operation | Needs | Returns |
|---|---|---|
| `document_symbols` | `uri` | Hierarchical symbol outline of one file. |
| `workspace_symbols` | `query` | Symbols across the workspace (empty query → all, truncated by `maxResults`). |
| `class_file_contents` | `jdt://` `uri` | Decompiled Java source. |

### Recommended workflow

1. **Locate** the symbol: `workspace_symbols` (by name) or `document_symbols` (outline a file) to get its `line`/`character`.
2. **Understand** it: `hover` for the signature/docs; `definition`/`implementation` to read the source.
3. **Assess impact**: `references` (and `incoming_calls`) to see everything that depends on it.
4. **Act**: `rename` for a safe rename, or use the positions to make precise edits.
5. **Trace logic**: chain `outgoing_calls` / `incoming_calls` using each result's `namePosition` as the next call's `line`/`character`.

### Example call

Find references to the symbol at line 42, col 17 of a TS file:
```json
{
  "operation": "references",
  "uri": "D:/code/gh-agentic-workflow/src/service.ts",
  "line": 42,
  "character": 17
}
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Client can't connect | VS Code not open, or wrong port | Open the project in VS Code; confirm `lsp-mcp.port`; `curl http://127.0.0.1:<port>/mcp`. |
| `execute_lsp` returns empty | Language extension not installed/activated | Install the extension from §3; open a file of that type once. |
| Wrong/foreign results | A *different* VS Code window owns the port | Use per-project ports; point the client URL at the right one. |
| Positions off by one | Treating output as 0-based | Everything is **1-based** in and out — use values verbatim. |
| Rename touched nothing | Symbol's LSP doesn't support rename, or position is off | Verify with `symbol_at_position` first. |
| Connection refused after edits | Client didn't reconnect | Restart the client / reload MCP servers. |
