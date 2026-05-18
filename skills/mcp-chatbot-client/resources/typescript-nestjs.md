# TypeScript And NestJS Reference

Use this reference for a TypeScript/NestJS backend that hosts the chatbot,
owns MCP clients, and exposes product chat endpoints to a frontend.

Official TypeScript SDK: <https://github.com/modelcontextprotocol/typescript-sdk>

SDK package names have changed across major versions. Current documentation
shows split packages such as `@modelcontextprotocol/client`,
`@modelcontextprotocol/server`, and runtime adapters such as
`@modelcontextprotocol/node`. Older projects may still use
`@modelcontextprotocol/sdk/...`. Verify installed package versions before
committing exact imports.

## Module Shape

```text
src/chat/
|-- chat.module.ts
|-- controllers/
|   `-- chat.controller.ts
|-- dto/
|   |-- create-conversation.dto.ts
|   `-- submit-message.dto.ts
|-- services/
|   |-- chat-orchestration.service.ts
|   |-- chat-run-executor.service.ts
|   |-- chat-sse-publisher.service.ts
|   |-- mcp-chat-bridge.service.ts
|   `-- chat-trace-writer.service.ts
|-- providers/
|   `-- llm-provider.interface.ts
`-- tools/
    `-- tool-definition-mapper.ts

src/mcp-client/
|-- mcp-client.module.ts
|-- mcp-client-manager.service.ts
|-- transports/
|   `-- in-process-transport.ts
`-- types.ts
```

Keep controllers product-oriented. Keep MCP client code in a bridge or manager
that the orchestration layer can call.

## Chat Controller Sketch

```ts
@Controller("chat")
export class ChatController {
  constructor(private readonly orchestration: ChatOrchestrationService) {}

  @Get("status")
  getStatus() {
    return { enabled: true };
  }

  @Post("conversations")
  @HttpCode(HttpStatus.CREATED)
  createConversation(@CurrentUser() user: AuthUser, @Body() dto: CreateConversationDto) {
    return this.orchestration.createConversation(user.id, dto);
  }

  @Post("conversations/:id/messages")
  @HttpCode(HttpStatus.ACCEPTED)
  @UseGuards(ChatEnabledGuard, ChatRateLimitGuard)
  submitMessage(
    @CurrentUser() user: AuthUser,
    @Param("id") conversationId: string,
    @Body() dto: SubmitMessageDto,
  ) {
    return this.orchestration.submitMessage(user.id, conversationId, dto);
  }

  @Get("conversations/:id/messages")
  listMessages(
    @CurrentUser() user: AuthUser,
    @Param("id") conversationId: string,
    @Query() query: ListMessagesQueryDto,
  ) {
    return this.orchestration.listMessages(user.id, conversationId, query);
  }
}
```

Spec implications:

- `submitMessage` should return quickly with `202 Accepted` and a run id.
- A background run owns the model/tool loop.
- Guards must run before any model or MCP call.
- Use `clientRequestId` for idempotency and stream correlation.

## SSE Publisher Sketch

```ts
export type ChatEventKind = "lifecycle" | "ui" | "domain";

export type ChatEventEnvelope = {
  v: 1;
  eventId: string;
  runId: string;
  conversationId: string;
  clientRequestId: string;
  sequence: number;
  kind: ChatEventKind;
  type: string;
  timestamp: string;
  payload: Record<string, unknown>;
};

@Injectable()
export class ChatSsePublisherService {
  constructor(private readonly stream: SseConnectionManagerService) {}

  publish(userId: string, envelope: Omit<ChatEventEnvelope, "v" | "eventId" | "timestamp">) {
    this.stream.pushToUser(
      userId,
      {
        v: 1,
        eventId: randomUUID(),
        timestamp: new Date().toISOString(),
        ...envelope,
      },
      { eventName: "chat" },
    );
  }
}
```

Spec implications:

- Keep event publication centralized.
- Include a monotonically increasing sequence per run.
- Log dropped stream deliveries if offline users need replay.

## MCP Client Bridge Interface

```ts
export type ChatToolDefinition = {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
};

export type McpToolCallResult = {
  isError: boolean;
  textContent: string;
  structuredContent?: unknown;
};

export interface McpChatBridgeSession {
  listTools(): Promise<ChatToolDefinition[]>;
  callTool(name: string, args: Record<string, unknown>): Promise<McpToolCallResult>;
  dispose(): Promise<void>;
}
```

## Streamable HTTP MCP Client Sketch

```ts
import { Client } from "@modelcontextprotocol/client";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/client";

export async function connectRemoteMcpServer(params: {
  url: string;
  token: string;
}): Promise<McpChatBridgeSession> {
  const client = new Client({ name: "chat-orchestrator", version: "1.0.0" });
  const transport = new StreamableHTTPClientTransport(new URL(params.url), {
    authProvider: {
      token: async () => params.token,
    },
  });

  await client.connect(transport);

  return {
    listTools: async () => {
      const result = await client.listTools();
      return result.tools.map((tool) => ({
        name: tool.name,
        description: tool.description ?? "",
        parameters: (tool.inputSchema as Record<string, unknown>) ?? {
          type: "object",
          properties: {},
        },
      }));
    },
    callTool: async (name, args) => {
      const result = await client.callTool({ name, arguments: args });
      return {
        isError: result.isError === true,
        textContent: extractToolText(result),
        structuredContent: result.structuredContent,
      };
    },
    dispose: async () => {
      await transport.terminateSession?.();
      await client.close();
    },
  };
}
```

If the SDK version does not expose the same package names, keep the same
session interface and adapt imports/classes to the installed version.

## In-Process MCP Variant

Use an in-process transport when a NestJS backend wants the chatbot to call an
internal MCP server without an HTTP round trip. This is useful when the same app
already exposes MCP externally but chat runs should stay local.

```ts
export function createInProcessTransportPair(): [Transport, Transport] {
  const clientEndpoint = new InProcessTransportEndpoint();
  const serverEndpoint = new InProcessTransportEndpoint();
  clientEndpoint.link(serverEndpoint);
  serverEndpoint.link(clientEndpoint);
  return [clientEndpoint, serverEndpoint];
}
```

Spec implications:

- In-process transport is still MCP JSON-RPC, only the framing changes.
- Auth context must be injected when building the per-user MCP server.
- Dispose both client and server sides after a per-run session.

## Orchestration Loop

```ts
async function executeRun(run: ChatRunContext): Promise<void> {
  const mcp = await mcpBridge.createSession(run.user, "chat");
  try {
    publisher.publish(run.user.id, run.lifecycle("run.started", {}));

    const tools = await mcp.listTools();
    const modelResult = await llm.execute({
      messages: await history.load(run.conversationId),
      tools,
      context: run.submitContext,
      abortSignal: run.abortSignal,
    });

    for (const call of modelResult.toolCalls) {
      publisher.publish(run.user.id, run.step(`Calling ${call.name}`));
      const toolResult = await mcp.callTool(call.name, call.arguments);
      await history.addToolResult(run, call, toolResult);
    }

    const final = await llm.finalize(run);
    await history.addAssistantMessage(run, final.message);
    publisher.publish(run.user.id, run.lifecycle("run.completed", {
      assistantMessage: final.message,
    }));
  } catch (error) {
    publisher.publish(run.user.id, run.lifecycle("run.failed", normalizeError(error)));
  } finally {
    await mcp.dispose();
  }
}
```

## Test Focus

- Controller: auth, feature flag, rate limit, `202 Accepted`, validation.
- Orchestration: active run conflict, idempotency, timeout, cancellation.
- MCP bridge: list tools, call tool, tool `isError`, dispose on failure.
- Stream: event envelope shape, sequence order, malformed payload handling.
- Authorization: forbidden tool/resource never reaches MCP server execution.
- E2E: user asks for a domain action, stream shows progress, domain state
  changes, and final assistant message appears.
