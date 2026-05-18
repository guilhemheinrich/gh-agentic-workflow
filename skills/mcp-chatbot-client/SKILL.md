---
name: mcp-chatbot-client
description: >-
  Create technology-agnostic specifications for adding an MCP-powered chatbot or
  MCP client to an application. Use when planning frontend chat UI, backend chat
  orchestration, MCP client lifecycle, Streamable HTTP or stdio transport,
  conversation/message endpoints, SSE or streaming updates, tool discovery,
  tool execution, and the roles of chatbot, MCP host, MCP client, and MCP
  server. Keep implementation examples in resources for Python, TypeScript,
  NestJS, and frontend chat patterns.
---

# MCP Chatbot Client

## Purpose

Use this skill to draft a clear, human-readable specification for adding a
chatbot that can use MCP servers. Keep the core spec agnostic: focus on
participants, transport, endpoint contracts, message flow, lifecycle,
streaming, security, and responsibility boundaries.

Load detailed references only when needed:

- Read `resources/architecture-transport.md` for endpoint types, role
  definitions, communication graphs, lifecycle, and security.
- Read `resources/spec-template.md` when producing a full specification.
- Read `resources/frontend-chat-ui.md` for frontend state, REST/SSE contracts,
  event envelopes, and UI orchestration examples.
- Read `resources/typescript-nestjs.md` for TypeScript/NestJS backend examples.
- Read `resources/python-client.md` for Python MCP client/chatbot examples.

## Source Baseline

Use official MCP documentation as the source of truth. Current verified
baseline on 2026-05-18: `https://modelcontextprotocol.io/specification`
redirects to protocol version `2025-11-25`.

- Specification: <https://modelcontextprotocol.io/specification>
- Architecture: <https://modelcontextprotocol.io/docs/learn/architecture>
- Client guide: <https://modelcontextprotocol.io/docs/develop/build-client>
- Client best practices:
  <https://modelcontextprotocol.io/docs/develop/clients/client-best-practices>
- TypeScript SDK: <https://github.com/modelcontextprotocol/typescript-sdk>
- Python SDK: <https://github.com/modelcontextprotocol/python-sdk>

If exact SDK APIs matter, verify the installed SDK version before writing code.
Preserve the protocol concepts even when package names or helper classes differ.

## Workflow

1. Identify where the chatbot host runs: browser UI plus backend orchestrator,
   CLI, desktop app, worker, or service-to-service agent.
2. Decide where MCP clients live. Prefer backend-side MCP clients for web apps
   unless browser auth, CORS, token storage, and server policy are explicitly
   safe.
3. Define endpoint contracts before tool behavior: chat REST endpoints,
   streaming events, MCP transport endpoints, auth, sessions, errors, and
   cancellation.
4. Map the chatbot loop: user message, model call, tool discovery, tool call,
   MCP result, final answer, UI/domain events, persistence.
5. Specify how frontend state follows backend run state and event ordering.
6. Add security, privacy, observability, rate limits, tests, rollout, and
   compatibility.

## Roles

| Role | Responsibility |
| --- | --- |
| Chatbot | User-facing conversation product: UI, messages, run status, model loop, and user intent handling. In MCP terms, it is usually the MCP host or part of the host. |
| MCP host | Application runtime that owns UX, model context, permissions, policy, and one MCP client per server connection. |
| MCP client | Protocol component that initializes one server connection, discovers capabilities, calls tools, reads resources, receives notifications, and closes sessions. |
| MCP server | External or internal server exposing tools, resources, prompts, and optional client-facing requests. |
| LLM provider | Model API used by the chatbot. It is not an MCP participant; the host translates MCP capabilities into model tool context. |

## Endpoint Classes

Treat chatbot endpoints and MCP endpoints as separate contracts.

| Class | Examples | Purpose |
| --- | --- | --- |
| Chat REST | `POST /chat/conversations`, `POST /chat/conversations/:id/messages`, `GET /chat/conversations/:id/messages` | Product API for conversations, persistence, submission, history, and export. |
| Chat stream | `GET /notifications/stream`, `GET /chat/runs/:id/events`, WebSocket equivalent | UI updates: lifecycle, progress, UI commands, domain events. |
| MCP transport | stdio, `POST /mcp`, `GET /mcp` for SSE or `405`, optional `DELETE /mcp`, legacy SSE | JSON-RPC transport between MCP client and MCP server. |
| MCP methods | `initialize`, `tools/list`, `tools/call`, `resources/read`, `prompts/get` | Protocol operations carried inside a transport endpoint. |
| Ops/support | `/health`, `/ready`, `/metrics`, admin trace endpoints | Operations outside MCP and outside the chat user flow. |

## Specification Output

When asked to create a specification, produce these sections:

1. Context, goals, and non-goals
2. Participants and runtime ownership
3. Endpoint inventory and transport decisions
4. Conversation, run, and event lifecycle
5. MCP client lifecycle and capability model
6. Frontend state model and streaming behavior
7. Backend orchestration and model/tool loop
8. Authentication, authorization, privacy, and safety
9. Observability, audit, rate limits, and operations
10. Test strategy, acceptance criteria, and rollout

Use `resources/spec-template.md` for the fill-in template.

## Guardrails

- Keep the MCP client layer thin: connect, discover, invoke, normalize, close.
- Keep business logic in application services or MCP servers, not in chat UI.
- Do not expose secrets or unrestricted MCP credentials to browser code.
- Model tools as user-intent operations, not one-to-one REST wrappers.
- Use ordered, idempotent event envelopes for run updates.
- Document failure modes: transport errors, tool `isError`, model errors,
  cancellation, timeout, auth failure, and partial side effects.
