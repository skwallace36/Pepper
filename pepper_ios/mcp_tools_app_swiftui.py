"""Grouped SwiftUI tool — renders, swiftui_body as subcommands."""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_RENDERS


def register_app_swiftui_tools(mcp, resolve_and_send):
    """Register the app_swiftui grouped tool.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str (JSON)
    """

    @mcp.tool(name="app_swiftui")
    async def app_swiftui(
        command: str = Field(
            description="Subcommand: renders | body"
        ),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        # renders params
        action: str | None = Field(default=None, description="[renders] start/stop/status/log/clear/counts/snapshot/diff/reset/ag_probe/ag_server/ag_dump/signpost/why"),
        limit: int | None = Field(default=None, description="[renders] Max events to return"),
        since_ms: int | None = Field(default=None, description="[renders] Only events after this epoch-ms"),
        filter_text: str | None = Field(default=None, description="[renders] Filter by view name"),
        name: str | None = Field(default=None, description="[renders] Snapshot name for ag_dump"),
        sub: str | None = Field(default=None, description="[renders] Sub-action for signpost: install or drain"),
        # body params
        element: str | None = Field(default=None, description="[body] Accessibility ID of a SwiftUI view"),
        text: str | None = Field(default=None, description="[body] Text label of a SwiftUI view"),
    ) -> str:
        """SwiftUI debugging tools. Subcommands:
        - renders: Track SwiftUI re-renders, diagnose excessive view body evaluations
        - body: Inspect the SwiftUI body expression tree for a view"""

        if command == "renders":
            if not action:
                return "Error: action required for renders (start, stop, status, log, clear, counts, snapshot, diff, reset, ag_probe, ag_server, ag_dump, signpost, why)"
            params: dict = {"action": action}
            if limit is not None:
                params["limit"] = limit
            if since_ms is not None:
                params["since_ms"] = since_ms
            if filter_text is not None:
                params["filter"] = filter_text
            if name is not None:
                params["name"] = name
            if sub is not None:
                params["sub"] = sub
            return await resolve_and_send(simulator, CMD_RENDERS, params)

        elif command == "body":
            params = {}
            if element:
                params["element"] = element
            if text:
                params["text"] = text
            return await resolve_and_send(simulator, "swiftui_body", params)

        return f"Unknown command '{command}'. Use: renders, body"
