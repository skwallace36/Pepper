"""Debug tool definitions for Pepper MCP.

Standalone tool: app_console. Other debug tools moved to app_debug grouped tool.
"""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_CONSOLE


def register_debug_tools(mcp, resolve_and_send):
    """Register standalone debug tools (console only).

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str (JSON)
    """

    @mcp.tool(name="app_console")
    async def console(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: start, stop, log"),
        filter_text: str | None = Field(default=None, description="Filter log lines (for log action)"),
        hide_noise: bool | None = Field(
            default=None,
            description="Hide known system framework noise — CFNetwork, Metal, AutoLayout, CoreData, etc. (default: true). Set false to see all.",
        ),
        exclude: str | None = Field(
            default=None,
            description="Comma-separated substrings to exclude from log (e.g. 'CoreData,Metal')",
        ),
        limit: int | None = Field(default=None, description="Max lines to return (for log action, default: 20)"),
        offset: int | None = Field(default=None, description="Skip this many recent lines for pagination (for log action, default: 0)"),
    ) -> list:
        """Capture and read app console output — both print() (stdout) and os_log/NSLog (stderr). Start, then log to read. System framework noise is filtered by default. Tip: use `timeline(last_seconds=30)` to see console events correlated with network and screen transitions."""
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
        return await resolve_and_send(simulator, CMD_CONSOLE, params)
