# TypeScript And NestJS Reference

Use this reference when the existing backend is TypeScript/NestJS. Keep the
specification agnostic first; use this file only to anchor implementation
examples.

Official SDK: <https://github.com/modelcontextprotocol/typescript-sdk>

SDK package names and helper APIs have changed across MCP SDK versions. Current
v2-style documentation uses split packages such as `@modelcontextprotocol/server`,
`@modelcontextprotocol/node`, and `@modelcontextprotocol/express`. Older examples
may use `@modelcontextprotocol/sdk/...`. Verify the installed SDK version before
committing exact imports.

## NestJS Integration Shape

Recommended module boundary:

```text
src/mcp/
|-- mcp.module.ts
|-- mcp.controller.ts        # Transport endpoint: GET/POST/DELETE /mcp
|-- mcp-server.factory.ts    # Builds the MCP server and registers capabilities
`-- capabilities/
    |-- order.tools.ts
    |-- customer.resources.ts
    `-- support.prompts.ts
```

Keep the NestJS controller transport-only. Put capability registration in small
files that call application services.

## Server Factory Sketch

```ts
import { Injectable } from "@nestjs/common";
import { McpServer } from "@modelcontextprotocol/server";
import * as z from "zod/v4";
import { OrdersService } from "../orders/orders.service";

@Injectable()
export class McpServerFactory {
  readonly server: McpServer;

  constructor(private readonly orders: OrdersService) {
    this.server = new McpServer({
      name: "orders-backend",
      version: "1.0.0",
    });

    this.server.registerTool(
      "search_orders",
      {
        title: "Search orders",
        description: "Search recent orders for a customer.",
        inputSchema: z.object({
          customerId: z.string(),
          limit: z.number().int().min(1).max(100).default(20),
        }),
      },
      async ({ customerId, limit }) => {
        const orders = await this.orders.searchRecent(customerId, limit);
        const output = { customerId, orders };

        return {
          content: [
            {
              type: "text",
              text: JSON.stringify(output),
            },
          ],
          structuredContent: output,
        };
      },
    );
  }
}
```

Spec implications:

- Each tool needs a stable name, description, input schema, output shape, and
  authorization rule.
- Convert domain errors into documented tool errors.
- Avoid direct repository/database access from MCP handlers.

## Streamable HTTP Controller Sketch

This sketch targets the NestJS Express adapter. For Fastify, either adapt raw
request/response handling carefully or mount a small Express sub-application for
the MCP endpoint.

```ts
import { All, Controller, OnModuleInit, Req, Res, UseGuards } from "@nestjs/common";
import type { Request, Response } from "express";
import { NodeStreamableHTTPServerTransport } from "@modelcontextprotocol/node";
import { McpServerFactory } from "./mcp-server.factory";
import { McpAuthGuard } from "./mcp-auth.guard";

@Controller("mcp")
@UseGuards(McpAuthGuard)
export class McpController implements OnModuleInit {
  private readonly transport = new NodeStreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
    enableJsonResponse: true,
  });

  constructor(private readonly factory: McpServerFactory) {}

  async onModuleInit(): Promise<void> {
    await this.factory.server.connect(this.transport);
  }

  @All()
  async handle(@Req() req: Request, @Res() res: Response): Promise<void> {
    await this.transport.handleRequest(req, res, req.body);
  }
}
```

Spec implications:

- The controller path is the MCP endpoint, not a REST resource collection.
- The auth guard runs before the MCP transport handler.
- Request body parsing must support JSON-RPC bodies.
- If stateful sessions are needed, document session id generation, storage,
  termination, and horizontal scaling behavior.

## NestJS Operational Notes

- Validate `Origin` and `Host` in middleware or guard for remote deployments.
- Configure CORS for `GET`, `POST`, and optional `DELETE`.
- Add request size limits before the MCP handler.
- Log method name, tool/resource/prompt name, authenticated subject, duration,
  status, and session id.
- Use interceptors or middleware for metrics; keep payload logging off by default.
- Expose `/health` and `/ready` outside the MCP controller.

## Compatibility Note

When the SDK version only exposes the older monolithic package, keep the same
module shape and transport contract, but replace imports and transport class
names with the SDK version in use. The generated specification should remain
stable even if SDK helper names differ.
