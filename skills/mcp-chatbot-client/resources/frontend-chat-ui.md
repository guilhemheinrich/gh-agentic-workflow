# Frontend Chat UI Reference

Use this reference when specifying the browser or app frontend for an
MCP-powered chatbot. Keep the frontend transport about product chat UX, not MCP
protocol details, unless the browser is intentionally the MCP host.

## Recommended Boundary

Default for web apps:

- Frontend owns chat UI, local view state, optimistic user messages, and stream
  consumption.
- Backend owns LLM calls, MCP clients, credentials, authorization, run state,
  persistence, and event publication.
- Frontend submits messages to product chat endpoints and receives product
  events over SSE/WebSocket.

Direct browser MCP clients are an exception. Specify them only when:

- The MCP server supports browser-safe Streamable HTTP.
- CORS allows the frontend origin and exposes session headers.
- User-scoped OAuth or equivalent auth exists.
- No server or model secret is shipped to the browser.
- Tool permissions and confirmation prompts are enforceable in the host UI.

## Frontend Endpoint Contract

```text
GET    /chat/status
POST   /chat/conversations
GET    /chat/conversations?page=1&limit=20
POST   /chat/conversations/:id/messages
GET    /chat/conversations/:id/messages?cursor=...&limit=50
DELETE /chat/conversations/:id
GET    /notifications/stream
```

Submit response should be asynchronous:

```json
{
  "runId": "run_123",
  "conversationId": "conv_123",
  "clientRequestId": "client_123"
}
```

## UI State Model

```ts
export type ChatRunStatus = "idle" | "submitting" | "running" | "completed" | "failed";

export type ChatState = {
  conversationId: string | null;
  messages: ChatMessage[];
  activeRunId: string | null;
  runStatus: ChatRunStatus;
  lastError: { code: string; message: string } | null;
  runStepLabels: string[];
};
```

Reducer actions to specify:

- `ASSIGN_CONVERSATION_ID`
- `NEW_CONVERSATION`
- `ADD_USER_MESSAGE`
- `SUBMIT_ACCEPTED`
- `RUN_STARTED`
- `RUN_STEP`
- `RUN_COMPLETED`
- `RUN_FAILED`
- `LOAD_MESSAGES`
- `RESET_RUN_UI`

## SSE Event Handling

Use an event envelope with `runId`, `conversationId`, `clientRequestId`, and a
per-run `sequence`. Buffer out-of-order events and ignore duplicates.

```ts
type SequenceTrackerEntry = {
  lastApplied: number;
  buffer: Map<number, ChatEventEnvelope>;
};

function acceptOrdered(
  byRun: Map<string, SequenceTrackerEntry>,
  event: ChatEventEnvelope,
  apply: (event: ChatEventEnvelope) => void,
): void {
  const state = byRun.get(event.runId) ?? { lastApplied: 0, buffer: new Map() };
  byRun.set(event.runId, state);

  if (event.sequence <= state.lastApplied || state.buffer.has(event.sequence)) {
    return;
  }

  state.buffer.set(event.sequence, event);

  while (state.buffer.has(state.lastApplied + 1)) {
    state.lastApplied += 1;
    const next = state.buffer.get(state.lastApplied);
    if (next) {
      state.buffer.delete(state.lastApplied);
      apply(next);
    }
  }
}
```

Filtering rules:

- Ignore events for another active conversation.
- Apply UI commands only when `runId` or `clientRequestId` matches the active
  run/request.
- Apply domain refresh events only after authorization has already happened
  backend-side.
- Treat malformed payloads as telemetry warnings, not fatal UI crashes.

## Event Types

| Kind | Type examples | UI behavior |
| --- | --- | --- |
| `lifecycle` | `run.started`, `run.step`, `run.completed`, `run.failed` | Update active run, progress, final answer, or error. |
| `ui` | `ui.navigate`, `ui.focus`, `ui.highlight`, `ui.open_details` | Dispatch safe commands to the current app view. |
| `domain` | `calendar.event.created`, `record.updated` | Refresh relevant queries or invalidate cache. |

## Frontend Components

| Component | Responsibility |
| --- | --- |
| Chat panel/shell | Open/close, layout, conversation switch, consent notices. |
| Conversation list | Paginated summaries and selection. |
| Message list | Role-aware rendering, tool-call summaries, auto-scroll. |
| Composer | Submit text, keyboard behavior, disabled states. |
| Run status | Progress labels, spinner, failure alert, retry/reset. |
| Event bridge | Applies UI/domain events to the surrounding application. |

## UX Guardrails

- Disable submission while a run is active unless concurrent runs are specified.
- Generate a `clientRequestId` before submitting and render the user message
  optimistically.
- Reconcile optimistic messages with history after reconnect or conversation
  switch.
- Show tool activity as summaries, not raw internal payloads.
- Never render untrusted tool output as HTML.
- Surface recoverable errors: rate limit, run in progress, auth expired,
  transport disconnected, malformed event, and run failed.
- Include privacy notice/consent when prompts, chat history, or analytics are
  retained.

## Direct Browser MCP Variant

If the browser is the MCP host, add these requirements to the spec:

- Use user-scoped OAuth or equivalent auth provider.
- Configure Streamable HTTP CORS for `GET`, `POST`, and optional `DELETE`.
- Expose `MCP-Session-Id` and protocol headers only to trusted origins.
- Store tokens according to the app security model.
- Implement permission prompts before destructive tool calls.
- Close or terminate MCP sessions when the user leaves the chatbot.
- Document how model-provider calls are made without exposing server secrets.
