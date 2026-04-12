"""Grouped SwiftUI tool — renders, body as subcommands."""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_RENDERS


def register_app_swiftui_tools(mcp, resolve_and_send):
    """Register the app_swiftui grouped tool."""

    @mcp.tool(name="app_swiftui")
    async def app_swiftui(
        command: str = Field(description="Subcommand: renders | body"),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str | None = Field(default=None, description="renders: start/stop/status/log/clear/counts/snapshot/diff/reset/why"),
        limit: int | None = Field(default=None, description="Max events to return (renders log)"),
        since_ms: int | None = Field(default=None, description="Only events after this epoch-ms (renders log)"),
        filter_text: str | None = Field(default=None, description="Filter by view name (renders log)"),
        name: str | None = Field(default=None, description="Snapshot name for ag_dump (renders)"),
        sub: str | None = Field(default=None, description="Sub-action for signpost: install or drain (renders)"),
        element: str | None = Field(default=None, description="Accessibility ID of a SwiftUI view (body)"),
        text: str | None = Field(default=None, description="Text label of a SwiftUI view (body)"),
    ) -> str:
        """SwiftUI debugging tools.

Subcommands:
- renders: Track re-renders and diagnose excessive body evaluations. Actions: start, stop, status, log, clear, counts, snapshot, diff, reset, why
- body: Inspect the SwiftUI body expression tree for a view"""

        if command == "renders":
            if not action:
                return "Error: action required. Use: start, stop, status, log, clear, counts, snapshot, diff, reset, why"
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

        return f"Error: unknown command '{command}'. Use: renders, body"
