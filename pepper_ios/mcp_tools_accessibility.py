"""Accessibility tool definitions for Pepper MCP.

Tool definitions for: accessibility_audit, accessibility_action, accessibility_events.
"""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_ACCESSIBILITY_ACTION, CMD_ACCESSIBILITY_AUDIT, CMD_ACCESSIBILITY_EVENTS


def register_accessibility_tools(mcp, resolve_and_send):
    """Register accessibility tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> dict
    """

    @mcp.tool()
    async def accessibility_audit(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        checks: str | None = Field(
            default=None,
            description="Comma-separated checks to run (default: all). "
            "Options: missing_label, missing_trait, contrast, dynamic_type, touch_target, redundant_trait",
        ),
        severity: str | None = Field(
            default=None,
            description="Minimum severity to include: error, warning (default), info",
        ),
    ) -> str:
        """Audit the current screen for accessibility violations — missing labels, contrast, small tap targets, Dynamic Type."""
        params: dict = {}
        if checks is not None:
            params["checks"] = checks
        if severity is not None:
            params["severity"] = severity
        return await resolve_and_send(simulator, CMD_ACCESSIBILITY_AUDIT, params, timeout=15)

    @mcp.tool()
    async def accessibility_action(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action to perform: list, invoke, escape, magic_tap, increment, decrement"),
        element: str | None = Field(
            default=None,
            description="Accessibility ID of the target element",
        ),
        text: str | None = Field(
            default=None,
            description="Text/label of the target element (alternative to element)",
        ),
        name: str | None = Field(
            default=None,
            description="Name of the custom action to invoke (for invoke action)",
        ),
        index: int | None = Field(
            default=None,
            description="Index of the custom action to invoke (for invoke action, alternative to name)",
        ),
    ) -> str:
        """Test VoiceOver interactions without enabling VoiceOver — list/invoke custom actions, escape, magic_tap, increment, decrement."""
        params: dict = {"action": action}
        if element is not None:
            params["element"] = element
        if text is not None:
            params["text"] = text
        if name is not None:
            params["name"] = name
        if index is not None:
            params["index"] = index
        return await resolve_and_send(simulator, CMD_ACCESSIBILITY_ACTION, params)

    @mcp.tool()
    async def accessibility_events(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(description="Action: start, stop, status, events, clear"),
        limit: int | None = Field(default=None, description="Max events to return (for 'events' action, default 100)"),
        since_ms: int | None = Field(
            default=None, description="Only events after this epoch-ms timestamp (for 'events' action)"
        ),
    ) -> str:
        """Detect screen changes instantly via UIAccessibility notifications (screen_changed, layout_changed, announcement)."""
        params: dict = {"action": action}
        if limit is not None:
            params["limit"] = limit
        if since_ms is not None:
            params["since_ms"] = since_ms
        return await resolve_and_send(simulator, CMD_ACCESSIBILITY_EVENTS, params)
