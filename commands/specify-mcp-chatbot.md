---
name: specify-mcp-chatbot
description: >-
  Generic prompt for /speckit.specify to create an MCP-powered chatbot or
  frontend client specification. Covers chat UI, product chat endpoints,
  streaming events, MCP client lifecycle, backend orchestration boundaries,
  security, testing, and rollout.
tags:
  - architecture
  - backend
  - react
  - security
  - spec-kit
  - typescript
---

# `/specify-mcp-chatbot` - Generic prompt for MCP chatbot

This command provides the frontend/client counterpart to
`/specify-mcp-backend`. It requests a complete specification from
`/speckit.specify` for a **chatbot or application client capable of using MCP
servers**.

By default, for a web application, the frontend owns the chat interface and
consumes product endpoints, while the backend owns LLM orchestration,
credentials, and MCP clients.

## Usage

```text
/specify-mcp-chatbot Add a support chatbot that can call our internal MCP tools
/specify-mcp-chatbot Specify a chat drawer in the app that streams run progress and tool summaries
/specify-mcp-chatbot Create a frontend chat client for an existing MCP backend
```

## Expected behavior

When this command is invoked, the agent must:

1. Reframe the user need as a `/speckit.specify` request.
2. Read and apply the skill `skills/mcp-chatbot-client/SKILL.md`.
3. Read `skills/mcp-chatbot-client/resources/frontend-chat-ui.md` when the
   need includes a browser or application interface.
4. Produce a specification oriented around user journeys, product contracts,
   and UI states, not a direct implementation.
5. Clearly distinguish the chatbot product endpoints from MCP endpoints.
6. Avoid placing MCP credentials, LLM secrets, or privileged authorization in
   the browser, unless explicitly requested with documented security
   conditions.

## Standard prompt for `/speckit.specify`

Use the prompt below as-is or complete it with the project context provided by
the user.

```text
Create a complete Spec Kit feature specification for adding an MCP-powered
chatbot or frontend client experience to an existing application.

Original request:
[PASTE THE USER REQUEST HERE]

Known project context:
- Frontend runtime/framework: [unknown unless provided]
- Backend runtime/framework: [unknown unless provided]
- Existing authentication model: [unknown unless provided]
- Existing chat or notification infrastructure: [unknown unless provided]
- MCP servers to use: [unknown unless provided]
- LLM provider/model layer: [unknown unless provided]
- Target surface: [chat drawer, full page, command palette, admin assistant,
  mobile view, CLI, desktop, etc.]

Reference material:
- Read and apply `skills/mcp-chatbot-client/SKILL.md`.
- Use `skills/mcp-chatbot-client/resources/spec-template.md` for the target
  section structure.
- Use `skills/mcp-chatbot-client/resources/frontend-chat-ui.md` for frontend
  state, event handling, endpoint contracts, and UI guardrails.

Specification goal:
Define the product behavior for a chatbot/client that can use MCP servers. The
spec must cover the user-facing chat experience, conversation and run lifecycle,
streaming update contract, MCP client lifecycle, backend orchestration boundary,
security and privacy model, observability, tests, and rollout.

Default decisions when the request is underspecified:
- For web applications, make the backend orchestrator the MCP host.
- Keep MCP clients backend-side by default; the browser should not hold MCP
  credentials, LLM provider secrets, or privileged server tokens.
- The frontend submits user messages to product chat endpoints and receives
  ordered product events over SSE, WebSocket, or a documented fallback.
- Use asynchronous message submission: the submit endpoint returns a `runId`
  quickly and the UI follows progress through the stream.
- Represent tool activity as safe user-facing summaries, not raw internal MCP
  payloads.
- Require explicit user confirmation before destructive or externally visible
  tool calls when the domain implies risk.
- Never render untrusted tool output as raw HTML.
- If the browser is intentionally the MCP host, explicitly specify browser-safe
  Streamable HTTP, CORS, exposed MCP headers, user-scoped auth, token storage,
  permission prompts, and session cleanup.

The generated specification must include these sections:
1. Context, goals, non-goals, and assumptions
2. Participants and runtime ownership:
   - Frontend chat UI
   - Backend chat orchestrator
   - MCP host
   - MCP client sessions
   - MCP servers
   - LLM provider
   - Application services
   - Event stream or notification channel
3. Endpoint inventory and transport decisions:
   - product chat REST endpoints
   - chat streaming endpoint
   - MCP transport endpoints or stdio launch contracts
   - operations endpoints such as health/readiness when relevant
4. Conversation, message, run, and event lifecycle:
   - conversation creation/selection
   - message submission
   - run creation
   - model request
   - tool discovery
   - tool execution
   - tool result handling
   - final answer
   - failure and cancellation
   - persistence and history reconciliation
5. Frontend state model and UX contract:
   - composer disabled states
   - optimistic user messages
   - assistant message insertion
   - run progress labels
   - retry and reset behavior
   - conversation switching
   - history paging
   - accessibility
   - privacy/consent notices
6. Streaming behavior:
   - event envelope fields
   - `runId`, `conversationId`, `clientRequestId`, and sequence handling
   - ordering, buffering, deduplication, reconnect, heartbeat, and replay
   - malformed event handling
7. MCP client lifecycle and capability mapping:
   - session scope
   - initialization
   - capability discovery
   - tool registry strategy
   - tool name collision policy
   - resource and prompt usage
   - cancellation and cleanup
8. Backend orchestration and model/tool loop:
   - chat service boundary
   - LLM provider abstraction
   - MCP client manager
   - tool router
   - persistence model
   - idempotency
   - background execution
   - timeout and partial side-effect policy
9. Security, privacy, and safety:
   - authentication
   - authorization
   - MCP credential ownership
   - CORS and Origin/Host validation
   - confirmation policy
   - prompt/tool output injection defenses
   - secret redaction
   - audit trail
   - rate limits
   - retention, export, and delete behavior
10. Observability and operations:
    - logs
    - metrics
    - traces
    - run-step trace
    - alerting
    - feature flags
    - backpressure
    - cost tracking
11. Test strategy and acceptance criteria
12. Rollout, compatibility, fallback mode, and migration plan

User stories to cover at minimum:
- P1: A user can open the chatbot, create or select a conversation, send a
  message, and see an assistant answer.
- P1: After submission, the backend returns a run id without waiting for the
  full model/tool loop, and the frontend displays ordered run progress.
- P1: The chatbot can use at least one authorized MCP capability and present a
  safe summary of the tool activity.
- P1: Failed model calls, MCP transport errors, tool-level errors, and
  authorization failures are visible and recoverable in the UI.
- P2: The frontend survives reconnects, duplicate events, out-of-order events,
  and conversation switches without corrupting the message list.
- P2: Users can review chat history according to the product retention policy.
- P3: Operators can inspect run traces, tool usage, latency, cost, and security
  denials without seeing secrets.

Functional requirements must be explicit and testable:
- The system MUST define product chat endpoints separately from MCP transport
  endpoints.
- The system MUST return an asynchronous run identifier for message submission.
- The frontend MUST track conversation id, active run id, run status, messages,
  progress labels, and last recoverable error.
- The event stream MUST include enough identifiers to order, deduplicate, and
  filter events per conversation and run.
- The backend MUST own MCP credentials and LLM provider secrets unless a direct
  browser MCP variant is explicitly specified.
- Tool calls MUST enforce schema validation and authorization before execution.
- The UI MUST show safe tool summaries and MUST NOT render raw untrusted tool
  output as HTML.
- The system MUST document cancellation, timeout, retry, and partial side-effect
  behavior.
- The system MUST include tests for frontend state transitions, stream ordering,
  duplicate/malformed events, one successful MCP tool call, one tool error, one
  authorization denial, and one end-to-end chat flow.

If the user has not provided concrete MCP servers or tools, do not invent
domain-specific capabilities. Specify the chatbot foundation and include
requirements for integrating project-specific MCP servers later.

Produce the complete `spec.md` content directly according to the repository's
Spec Kit template and conventions. Do not output implementation code, task
lists, or planning artifacts.
```

## Short variant

```text
Create a complete Spec Kit `spec.md` for an MCP-powered chatbot/frontend client.

Apply `skills/mcp-chatbot-client/SKILL.md` and, for browser UI, apply
`skills/mcp-chatbot-client/resources/frontend-chat-ui.md`.

Default to a backend-hosted MCP architecture: frontend chat UI + product chat
endpoints + backend orchestrator that owns LLM calls, MCP clients, credentials,
authorization, run state, persistence, and event publication.

The spec must define conversation/run lifecycle, chat REST endpoints, stream
events, frontend state, MCP client lifecycle, tool summaries, security/privacy,
observability, tests, rollout, and fallback behavior.

Produce the full `spec.md` only.
```
