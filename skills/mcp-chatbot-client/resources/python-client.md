# Python MCP Client And Chatbot Reference

Use this reference when the chatbot or MCP client is implemented in Python, or
when a backend worker uses Python to connect to MCP servers.

Official Python SDK: <https://github.com/modelcontextprotocol/python-sdk>

The examples below show transport and orchestration shape. Verify installed SDK
versions before committing exact imports.

## Streamable HTTP Client

Use Streamable HTTP for remote MCP servers.

```python
import asyncio
from collections.abc import Mapping
from typing import Any

from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client


async def list_remote_tools(mcp_url: str) -> list[str]:
    async with streamable_http_client(mcp_url) as (read_stream, write_stream, _):
        async with ClientSession(read_stream, write_stream) as session:
            await session.initialize()
            tools = await session.list_tools()
            return [tool.name for tool in tools.tools]


async def call_remote_tool(
    mcp_url: str,
    name: str,
    arguments: Mapping[str, Any],
) -> str:
    async with streamable_http_client(mcp_url) as (read_stream, write_stream, _):
        async with ClientSession(read_stream, write_stream) as session:
            await session.initialize()
            result = await session.call_tool(name, arguments=dict(arguments))
            return "\n".join(
                getattr(part, "text", "")
                for part in result.content
                if getattr(part, "type", None) == "text"
            ).strip()


if __name__ == "__main__":
    print(asyncio.run(list_remote_tools("http://localhost:8000/mcp")))
```

Spec implications:

- Document MCP URL, auth headers, session behavior, and timeout policy.
- Initialize before discovery or invocation.
- Normalize tool content and structured output before returning it to the model.
- Close the session after each run unless pooling is explicitly specified.

## stdio Client

Use stdio when the chatbot host launches a local MCP server process.

```python
import asyncio

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def run_local_server(server_script: str) -> list[str]:
    params = StdioServerParameters(
        command="python" if server_script.endswith(".py") else "node",
        args=[server_script],
        env=None,
    )
    async with stdio_client(params) as (read_stream, write_stream):
        async with ClientSession(read_stream, write_stream) as session:
            await session.initialize()
            tools = await session.list_tools()
            return [tool.name for tool in tools.tools]


if __name__ == "__main__":
    print(asyncio.run(run_local_server("server.py")))
```

Spec implications:

- stdout is reserved for JSON-RPC protocol messages in the server process.
- Server logs must go to stderr or another log sink.
- Specify launch command, working directory, environment, and shutdown behavior.

## Chatbot Loop Shape

Keep the model provider behind a small interface so the MCP client remains
provider-agnostic.

```python
from dataclasses import dataclass
from typing import Any, Protocol


@dataclass(frozen=True)
class ToolDefinition:
    name: str
    description: str
    input_schema: dict[str, Any]


@dataclass(frozen=True)
class ToolCall:
    id: str
    name: str
    arguments: dict[str, Any]


class ModelProvider(Protocol):
    async def plan(
        self,
        messages: list[dict[str, Any]],
        tools: list[ToolDefinition],
    ) -> list[ToolCall] | str:
        ...

    async def finalize(
        self,
        messages: list[dict[str, Any]],
    ) -> str:
        ...
```

Run flow:

1. Load conversation history and submit context.
2. Connect MCP client session.
3. Call `list_tools`.
4. Convert MCP tools to provider tool definitions.
5. Ask model for a final answer or tool calls.
6. Call MCP tools through the session.
7. Append tool results to the conversation.
8. Ask model for final answer.
9. Persist messages and publish lifecycle events.
10. Close the MCP session.

## Tool Result Normalization

```python
def extract_text(result: Any) -> str:
    parts: list[str] = []
    for item in getattr(result, "content", []) or []:
        if getattr(item, "type", None) == "text":
            text = getattr(item, "text", "")
            if text:
                parts.append(str(text))
    structured = getattr(result, "structuredContent", None)
    if structured is not None:
        parts.append(str(structured))
    return "\n".join(parts).strip()
```

Guardrails:

- Treat `isError` tool results as tool-level failures, not transport failures.
- Validate model-provided tool arguments before invoking tools if the SDK does
  not enforce the schema locally.
- Truncate or summarize large tool outputs before returning them to the model.
- Record side effects and partial failures in run traces.

## Backend Worker Pattern

For a web app, a Python worker can run the model/MCP loop while the HTTP backend
owns auth and persistence.

```text
Frontend -> Backend REST -> Queue/worker -> Python chatbot loop -> MCP server
Frontend <- Backend SSE  <- Queue/events <- Python chatbot loop <- MCP result
```

Specify:

- Job payload fields: user id, conversation id, run id, client request id.
- Worker auth to MCP servers.
- Event publication path back to the backend stream.
- Idempotency on retry.
- Run timeout and cancellation.
