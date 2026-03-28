"""SwiftUI render tracking tool definitions for Pepper MCP.

Tool definitions for: renders
"""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_RENDERS


def register_renders_tools(mcp, resolve_and_send):
    """Register SwiftUI render tracking tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> dict
    """

    @mcp.tool()
    async def renders(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(
            description="Action: start | stop | status | log | clear | counts | snapshot | diff | reset | ag_probe | ag_server | ag_dump | signpost | why"
        ),
        limit: int | None = Field(default=None, description="Max events to return (for log action, default 100)"),
        since_ms: int | None = Field(
            default=None,
            description="Only return events after this Unix timestamp in ms (for log action)",
        ),
        filter: str | None = Field(
            default=None,
            description="Filter events by view controller type or address (for log action)",
        ),
        name: str | None = Field(default=None, description="Snapshot name (for ag_dump action)"),
        sub: str | None = Field(
            default=None,
            description="Sub-action for signpost: install or drain",
        ),
    ) -> str:
        """Track SwiftUI re-renders and diagnose excessive view body evaluations. Start tracking, interact, then log to see results."""
        params: dict = {"action": action}
        if limit is not None:
            params["limit"] = limit
        if since_ms is not None:
            params["since_ms"] = since_ms
        if filter is not None:
            params["filter"] = filter
        if name is not None:
            params["name"] = name
        if sub is not None:
            params["sub"] = sub
        return await resolve_and_send(simulator, CMD_RENDERS, params)
