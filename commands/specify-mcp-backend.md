---
name: specify-mcp-backend
description: >-
  Generic prompt for /speckit.specify to create a backend MCP server
  specification. Covers transport choice, endpoint contract, JSON-RPC
  lifecycle, capability modeling, security, observability, testing, and rollout.
tags:
  - architecture
  - backend
  - documentation
  - security
  - spec-kit
---

# `/specify-mcp-backend` - Generic prompt for backend MCP server

This command provides a reusable prompt to pass to `/speckit.specify` when a
project needs to add a **backend MCP server**. It does not request direct
implementation: it requests an executable, clear, and complete Spec Kit
specification.

## Usage

```text
/specify-mcp-backend Add an MCP server to expose our order management actions to IDE assistants
/specify-mcp-backend Create a remote MCP backend for the billing API with read-only tools first
/specify-mcp-backend Specify an internal stdio MCP server for local developer workflows
```

## Expected behavior

When this command is invoked, the agent must:

1. Reframe the user need as a `/speckit.specify` request.
2. Read and apply the skill `skills/mcp-server-backend/SKILL.md`.
3. Use `skills/mcp-server-backend/resources/spec-template.md` if a detailed
   structure is needed.
4. Produce a behavior-oriented specification, not an implementation.
5. Keep the MCP layer thin: transport, validation, authorization, and mapping
   to existing application services.
6. Do not model tools as individual REST routes: tools, resources, and prompts
   are JSON-RPC methods carried by the MCP transport.

## Standard prompt for `/speckit.specify`

Use the prompt below as-is or complete it with the project context provided by
the user.

```text
Create a complete Spec Kit feature specification for adding a Model Context
Protocol (MCP) server to an existing backend application.

Original request:
[PASTE THE USER REQUEST HERE]

Known project context:
- Backend runtime/framework: [unknown unless provided]
- Deployment target: [local process, container, Kubernetes, serverless, etc.]
- Existing authentication model: [unknown unless provided]
- Existing domain/application services to expose: [unknown unless provided]
- Intended MCP hosts/clients: [IDE, assistant app, internal chatbot, CLI, etc.]
- Required transport, if already known: [stdio, Streamable HTTP, legacy HTTP+SSE]

Reference material:
- Read and apply `skills/mcp-server-backend/SKILL.md`.
- Use `skills/mcp-server-backend/resources/spec-template.md` for the target
  section structure.
- Use `skills/mcp-server-backend/resources/protocol-transport.md` for endpoint,
  header, lifecycle, and security requirements.

Specification goal:
Define the backend-side MCP server behavior so implementation agents can add it
without ambiguity. The spec must describe the MCP transport boundary, JSON-RPC
lifecycle, exposed capabilities, security model, observability, tests, and
rollout. It must remain technology-agnostic unless the project context already
identifies a concrete runtime.

Default decisions when the request is underspecified:
- Prefer Streamable HTTP for remote or embedded backend services.
- Prefer `stdio` only for local process-based servers launched by an MCP host.
- Use a single MCP transport path such as `/mcp` for HTTP transport; do not
  create one HTTP endpoint per tool.
- Support `POST /mcp` as the required HTTP method.
- Specify whether `GET /mcp` and `DELETE /mcp` are supported or return
  `405 Method Not Allowed`.
- Require authentication for remotely reachable MCP endpoints unless the user
  explicitly scopes the server to a private trusted network.
- Validate `Origin` and `Host` for HTTP transport.
- Keep business logic in existing application services; the MCP layer adapts
  protocol requests to use cases.
- Treat every tool input as untrusted and validate it with an explicit schema.
- Expose mutations through tools, and expose predictable read-only context
  through resources.
- Do not leak secrets, raw credentials, internal tokens, unrestricted file
  access, or privileged system access.

The generated specification must include these sections:
1. Context and goals
2. Non-goals and assumptions
3. Participants and responsibilities:
   - MCP host
   - MCP client
   - Backend MCP server
   - Existing application services
   - Identity provider or authorization authority
4. Transport decision and endpoint contract:
   - stdio command contract when applicable
   - Streamable HTTP contract when applicable
   - path, methods, headers, response modes, session behavior, CORS, auth,
     request limits, timeouts, and health/readiness endpoints
5. JSON-RPC lifecycle:
   - `initialize`
   - `notifications/initialized`
   - capability discovery
   - capability invocation
   - progress, cancellation, and session close behavior
6. Capability model:
   - tools for user-intent actions
   - resources for readable context
   - prompts for reusable interaction templates
   - optional client features only when justified
7. Security and permissions:
   - authentication
   - per-capability authorization
   - MCP-specific scopes or roles
   - Origin/Host validation
   - secret redaction
   - data exposure rules
   - rate limits and abuse controls
8. Error, cancellation, progress, and streaming behavior:
   - JSON-RPC errors
   - tool-level `isError` results
   - validation errors
   - domain errors
   - timeout and retry policy
   - cancellation semantics
9. Observability and operations:
   - logs
   - metrics
   - traces
   - correlation/session ids
   - audit trail
   - alerts
10. Test strategy and acceptance criteria
11. Rollout, compatibility, migration, and operational runbook

User stories to cover at minimum:
- P1: An MCP client can initialize a session and discover the backend's declared
  tools, resources, and prompts.
- P1: An authorized client can invoke a declared tool and receive a structured
  success or tool-level error result.
- P1: An unauthorized or malformed request is rejected without executing domain
  logic and without leaking sensitive details.
- P2: Long-running capability calls expose documented timeout, cancellation,
  and progress behavior.
- P2: Operators can observe capability usage, failures, latency, and security
  denials.
- P3: The server can be rolled out behind a feature flag or environment switch
  and can be disabled without breaking the existing backend API.

Functional requirements must be explicit and testable:
- The system MUST define the selected MCP transport and all supported methods.
- The system MUST implement the MCP initialization and discovery lifecycle.
- The system MUST define every exposed capability with name, intent, input
  schema, output shape, authorization rule, side effects, and error behavior.
- The system MUST validate inputs before calling application services.
- The system MUST enforce per-capability authorization.
- The system MUST return documented JSON-RPC and tool-level errors.
- The system MUST log and measure capability name, subject, correlation id,
  duration, and outcome without logging secrets.
- The system MUST include tests for initialization, discovery, at least one
  successful capability call, validation failure, authorization failure, and
  transport error behavior.

If domain-specific tools/resources/prompts are not provided in the request, do
not invent business capabilities. Instead, specify the MCP server foundation and
include requirements for registering project-specific capabilities later.

Produce the complete `spec.md` content directly according to the repository's
Spec Kit template and conventions. Do not output implementation code, task
lists, or planning artifacts.
```

## Short variant

```text
Create a complete Spec Kit `spec.md` for adding a backend MCP server.

Apply `skills/mcp-server-backend/SKILL.md`.

The spec must define: transport choice, `/mcp` or stdio contract, JSON-RPC
lifecycle, tools/resources/prompts model, per-capability authorization, input
schemas, errors, progress/cancellation, observability, tests, and rollout.

Default to Streamable HTTP for remote backends and stdio only for local
process-based servers. Keep the MCP adapter thin and route all business logic
through existing application services. Do not invent domain-specific tools if
the user has not provided the domain.

Produce the full `spec.md` only.
```
