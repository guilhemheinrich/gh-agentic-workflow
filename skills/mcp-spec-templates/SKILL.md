---
name: mcp-spec-templates
description: >-
  Two fill-in specification templates for Model Context Protocol work: one for
  adding an MCP server to an existing backend, one for adding an MCP-powered
  chatbot (MCP client plus chat UI) to an application. Use when drafting a
  Spec Kit specification, plan or design document for either, so every section
  (transport, endpoint contract, lifecycle, security, observability, tests,
  rollout) is covered. Templates only: protocol knowledge comes from the
  official MCP documentation.
tags:
  - mcp
  - documentation
  - spec-kit
---

# MCP Spec Templates

Two templates, no doctrine. Pick one, copy it into the spec, fill every section
(write "n/a" with a reason rather than deleting a section).

| Need | Template |
| --- | --- |
| Expose an existing backend's capabilities to MCP clients (IDE assistants, agents) | [templates/backend-mcp-server-spec.md](templates/backend-mcp-server-spec.md) |
| Let an application's users chat with a model that calls MCP tools (chat UI, orchestration backend, MCP client lifecycle, streaming) | [templates/chatbot-client-spec.md](templates/chatbot-client-spec.md) |

A product that does both (exposes a server and embeds a chatbot) fills both
templates and cross-references the shared transport and auth decisions.

## Source of truth

Use the official documentation, not memory: <https://modelcontextprotocol.io/specification>
(protocol revision `2025-11-25` when this skill was written; check the current
one). If the spec depends on exact SDK APIs, verify the installed SDK version
first (Python and TypeScript SDKs live under `github.com/modelcontextprotocol`).

## Guardrails that belong in every spec

- Keep the MCP layer a thin adapter: protocol in, application service calls out.
  No business logic in handlers.
- Model tools as user-intent operations, not one-to-one REST wrappers; keep
  resources read-only and use tools for mutation.
- Validate every tool input against an explicit schema; return structured errors.
- Apply the backend's authorization policy to MCP calls; never leak secrets.
- stdio servers: stdout carries protocol messages only, logs go to stderr.
- HTTP servers: validate `Origin` and `Host`, require authentication when remote.
- Describe behaviour and contracts, not implementation, when feeding
  `/speckit.specify`.
