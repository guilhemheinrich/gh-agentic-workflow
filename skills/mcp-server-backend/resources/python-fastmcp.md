# Python FastMCP Reference

Use this reference when the existing backend is Python or when the MCP server can
run as a sidecar process next to a Python backend. Keep the production spec
focused on transport and capability contracts; treat code here as a framework
example.

Official SDK: <https://github.com/modelcontextprotocol/python-sdk>

## Standalone stdio Server

Use stdio when the MCP host launches the process locally.

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("orders-backend")


@mcp.tool()
def get_order_status(order_id: str) -> dict[str, str]:
    """Return the current status for one order."""
    # Replace with an application service call.
    return {"orderId": order_id, "status": "processing"}


if __name__ == "__main__":
    # stdout is reserved for MCP protocol messages.
    # Send logs to stderr or a file.
    mcp.run(transport="stdio")
```

Spec implications:

- Document the launch command and environment variables.
- State that stdout is protocol-only.
- Use process-level credentials or local config for auth when the host is local.

## Embedded Streamable HTTP App

Use Streamable HTTP when exposing MCP from an existing ASGI backend. The example
below mounts the MCP ASGI app under `/mcp`.

```python
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from mcp.server.fastmcp import FastMCP

mcp = FastMCP(
    "orders-backend",
    streamable_http_path="/",
    stateless_http=True,
    json_response=True,
)


@mcp.tool()
async def search_orders(customer_id: str, limit: int = 20) -> dict[str, object]:
    """Search recent orders for a customer."""
    # Replace with an injected application service call.
    return {"customerId": customer_id, "orders": [], "limit": limit}


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with mcp.session_manager.run():
        yield


app = FastAPI(lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://trusted-host.example"],
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["Authorization", "Content-Type", "MCP-Protocol-Version", "MCP-Session-Id"],
    expose_headers=["MCP-Session-Id"],
)

app.mount("/mcp", mcp.streamable_http_app())
```

Spec implications:

- Document whether the server is stateless or session-based.
- Document auth middleware before the MCP app if the endpoint is remote.
- Expose `MCP-Session-Id` only when stateful sessions are used.
- Add health and readiness endpoints outside the MCP app.

## Capability Registration Pattern

Keep MCP handlers as adapters over existing services:

```python
class OrderService:
    async def search_orders(self, customer_id: str, limit: int) -> list[dict[str, str]]:
        ...


def register_order_tools(mcp: FastMCP, orders: OrderService) -> None:
    @mcp.tool()
    async def search_orders(customer_id: str, limit: int = 20) -> list[dict[str, str]]:
        return await orders.search_orders(customer_id=customer_id, limit=limit)
```

Avoid placing business rules inside the decorator function. Keep validation,
authorization, and use-case execution explicit in the application layer.

## Test Focus

- Test `initialize` and `tools/list` with an MCP client or SDK test client.
- Test each tool handler with mocked application services.
- Test auth middleware on `POST /mcp` before the transport handler receives the
  request.
- Test that invalid inputs return structured tool or JSON-RPC errors.
