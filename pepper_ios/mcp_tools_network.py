"""Network monitoring tool definitions for Pepper MCP.

Standalone tool: app_network. Other network tools moved to net_tools grouped tool.
"""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_NETWORK


def register_network_tools(mcp, resolve_and_send):
    """Register standalone network tools (network only).

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str (JSON)
    """

    @mcp.tool(name="app_network")
    async def network(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(
            description="Action: start, stop, log, status, clear, tasks, stream_log"
        ),
        task_state: str | None = Field(
            default=None,
            description="Filter tasks by state: running, suspended, canceling, completed (for tasks action)",
        ),
        filter_text: str | None = Field(default=None, description="Filter by URL pattern (for log/tasks action)"),
        hide_noise: bool | None = Field(
            default=None,
            description="Hide known Apple/system telemetry traffic (default: true). Set false to see all requests.",
        ),
        exclude: str | None = Field(
            default=None,
            description="Comma-separated URL patterns to exclude from log (e.g. 'analytics.example.com,tracker.io')",
        ),
        limit: int | None = Field(default=None, description="Max entries to return (for log action, default: 10)"),
        offset: int | None = Field(default=None, description="Skip this many recent entries for pagination (for log action, default: 0)"),
        full_urls: bool | None = Field(
            default=None,
            description="Show full URLs with query strings (default: false — strips query params for compact output)",
        ),
        include_headers: bool | None = Field(
            default=None,
            description="Include request/response headers in log output (default: false)",
        ),
        include_body: bool | None = Field(
            default=None,
            description="Include request/response bodies in log output (default: false, enables max_body=4096)",
        ),
        max_body: int | None = Field(
            default=None,
            description="Max chars per body when include_body is true (default: 4096). Overrides include_body.",
        ),
        transaction_id: str | None = Field(
            default=None,
            description="Transaction ID of a streaming request (for stream_log action — get SSE/streaming chunks)",
        ),
    ) -> str:
        """Monitor HTTP traffic. Start interception, then query the log for captured requests.

Recipes:
  action="start"                                          → begin capturing
  action="log"                                            → last 10 requests
  action="log", filter_text="api.example.com", limit=50  → filter by URL
  action="log", include_headers=True, include_body=True   → full details
  action="tasks"                                          → active URLSession tasks
  action="stream_log", transaction_id="<id>"              → SSE/streaming chunks
  action="status"                                         → interception state
  action="clear"                                          → clear captured log
  action="stop"                                           → stop interception

Use net_tools mock for API mocking. Use net_tools simulate for latency/failures."""
        params: dict = {"action": action}
        if filter_text:
            params["filter"] = filter_text
        if hide_noise is not None:
            params["hide_noise"] = hide_noise
        if exclude:
            params["exclude"] = exclude
        if limit is not None:
            params["limit"] = limit
        if offset is not None:
            params["offset"] = offset
        if full_urls is not None:
            params["full_urls"] = full_urls
        if include_headers is not None:
            params["include_headers"] = include_headers
        if include_body is not None:
            params["include_body"] = include_body
        if max_body is not None:
            params["max_body"] = max_body
        if task_state:
            params["state"] = task_state
        if transaction_id:
            params["id"] = transaction_id
        return await resolve_and_send(simulator, CMD_NETWORK, params)
