# MCP Chatbot Specification Template

Use this template when the user asks for a specification, implementation plan,
or design document for adding an MCP-powered chatbot.

## 1. Context, Goals, And Non-Goals

- Existing application:
- Current frontend runtime:
- Current backend runtime:
- Existing auth model:
- User workflows to support:
- MCP servers to connect:
- LLM provider or model layer:
- Goals:
- Non-goals:

## 2. Participants And Ownership

| Participant | Runtime | Responsibility | Owner |
| --- | --- | --- | --- |
| Frontend chat UI | | Message composer, message list, status, event handling. | |
| Backend chat orchestrator | | Conversations, runs, model loop, MCP clients, policy. | |
| MCP client session | | One protocol connection per MCP server. | |
| MCP server | | Tools, resources, prompts, domain adapters. | |
| LLM provider | | Generate assistant responses and tool calls. | |
| Application services | | Existing business use cases. | |
| Event stream | | Lifecycle/UI/domain updates to clients. | |

Decision: Is the backend the MCP host? If not, describe which runtime owns MCP
clients and why.

## 3. Endpoint Inventory

### Product Chat API

| Endpoint | Method | Auth | Request | Response | Notes |
| --- | --- | --- | --- | --- | --- |
| `/chat/status` | `GET` | | | `{ enabled }` | |
| `/chat/conversations` | `POST` | | | | |
| `/chat/conversations` | `GET` | | | | |
| `/chat/conversations/{id}/messages` | `POST` | | | `202 { runId }` | |
| `/chat/conversations/{id}/messages` | `GET` | | | | |
| `/chat/conversations/{id}` | `DELETE` | | | `204` | |

### Chat Streaming

- Transport: SSE, WebSocket, polling fallback, or provider stream
- Endpoint:
- Event name(s):
- Envelope fields:
- Reconnect and replay policy:
- Heartbeat policy:
- Ordering and deduplication:

### MCP Transport

- Transport: stdio, Streamable HTTP, in-process/custom, legacy SSE
- Server URL or launch command:
- Supported methods:
- Required headers:
- Session policy:
- Authentication:
- CORS:
- Timeouts and request limits:

## 4. Conversation And Run Lifecycle

1. Conversation creation or selection:
2. Message submission:
3. Run creation:
4. Model request:
5. Tool discovery:
6. Tool execution:
7. Tool result handling:
8. Final answer:
9. Streamed UI/domain events:
10. Persistence:
11. Completion, failure, cancellation:

State machine:

```text
idle -> submitting -> running -> completed
                         |-> failed
                         |-> cancelled
```

## 5. MCP Client Lifecycle

- Session scope: per request, per run, per user, per tenant, or pooled
- Initialization:
- Capability discovery:
- Tool registry strategy:
- Progressive discovery threshold:
- Tool name collision policy:
- Resource and prompt usage:
- Server notifications:
- Cancellation:
- Close/cleanup:
- Retry/reconnect:

## 6. Capability Mapping

### Tools

| MCP server | Tool name | User intent | Input schema | Output shape | Auth | Side effects | Confirmation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |

### Resources

| MCP server | URI/template | Purpose | MIME type | Auth | Cache/subscription |
| --- | --- | --- | --- | --- | --- |
| | | | | | |

### Prompts

| MCP server | Prompt | Purpose | Arguments | Use in chatbot |
| --- | --- | --- | --- | --- |
| | | | | |

## 7. Frontend State And UX Contract

- Composer disabled states:
- Optimistic user message behavior:
- Assistant message insertion:
- Run progress labels:
- Error display and retry:
- Chat history paging:
- Conversation switch behavior:
- Stream event filtering:
- UI command handling:
- Domain refresh behavior:
- Accessibility requirements:
- Privacy/consent notices:

## 8. Backend Orchestration

- Controller/module boundary:
- Chat service boundary:
- LLM provider abstraction:
- MCP client manager:
- Tool router:
- Persistence model:
- Transaction boundaries:
- Idempotency:
- Background execution:
- Timeout and cancellation:
- Partial side-effect policy:

## 9. Security, Privacy, And Safety

- Authentication:
- Authorization:
- MCP credential ownership:
- Origin/Host validation:
- CORS and exposed headers:
- Human confirmation policy:
- Prompt/tool output injection defenses:
- Secret redaction:
- Audit trail:
- Rate limits:
- Retention/export/delete:
- Analytics opt-out:

## 10. Observability And Operations

- Logs:
- Metrics:
- Traces:
- Run step trace:
- Alerting:
- Feature flags:
- Health/readiness:
- Backpressure:
- Cost tracking:

## 11. Tests And Acceptance Criteria

Tests:

- Frontend component tests for composer, messages, run status, and errors.
- Frontend stream tests for ordering, deduplication, malformed events, and
  conversation switches.
- Backend unit tests for run lifecycle and tool routing.
- MCP client tests for initialize, discovery, tool call, tool error, and close.
- Security tests for missing auth, invalid user, invalid origin, and forbidden
  tools.
- End-to-end tests for one read-only tool and one mutation tool.

Acceptance criteria:

- A user can create or open a conversation and send a message.
- The backend returns a run id without blocking on the full model/tool loop.
- The frontend receives ordered run progress and final answer events.
- The MCP client initializes, discovers tools, invokes at least one tool, and
  closes or reuses the session according to the spec.
- Tool calls enforce authorization and schema validation.
- Failed model calls, transport errors, and MCP tool errors are visible and
  recoverable.
- No secrets or unauthorized data appear in frontend payloads, logs, or exports.

## 12. Rollout And Compatibility

- Feature flag:
- Environment variables:
- Migration steps:
- Backward compatibility:
- Legacy SSE support:
- Fallback mode when MCP is unavailable:
- Operational runbook:
- Decommission plan:
