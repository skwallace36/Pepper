"""Grouped accessibility tool — audit, action, events as subcommands."""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_ACCESSIBILITY_ACTION, CMD_ACCESSIBILITY_AUDIT, CMD_ACCESSIBILITY_EVENTS


def register_ui_accessibility_tools(mcp, resolve_and_send):
    """Register the ui_accessibility grouped tool.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str (JSON)
    """

    @mcp.tool(name="ui_accessibility")
    async def ui_accessibility(
        command: str = Field(
            description="Subcommand: audit | action | events"
        ),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        # audit params
        checks: str | None = Field(default=None, description="[audit] Comma-separated checks: missing_label, missing_trait, contrast, dynamic_type, touch_target, redundant_trait"),
        severity: str | None = Field(default=None, description="[audit] Minimum severity: error, warning (default), info"),
        # action params
        action: str | None = Field(default=None, description="[action/events] For action: list/invoke/escape/magic_tap/increment/decrement. For events: start/stop/status/events/clear"),
        element: str | None = Field(default=None, description="[action] Accessibility ID of target element"),
        text: str | None = Field(default=None, description="[action] Text/label of target element"),
        name: str | None = Field(default=None, description="[action] Custom action name to invoke"),
        index: int | None = Field(default=None, description="[action] Custom action index to invoke"),
        # events params
        limit: int | None = Field(default=None, description="[events] Max events to return"),
        since_ms: int | None = Field(default=None, description="[events] Only events after this epoch-ms"),
    ) -> str:
        """Accessibility testing tools. Subcommands:
        - audit: Audit screen for accessibility violations (missing labels, contrast, small tap targets)
        - action: Test VoiceOver interactions (list/invoke custom actions, escape, magic_tap)
        - events: Detect screen changes via UIAccessibility notifications"""

        if command == "audit":
            params: dict = {}
            if checks is not None:
                params["checks"] = checks
            if severity is not None:
                params["severity"] = severity
            return await resolve_and_send(simulator, CMD_ACCESSIBILITY_AUDIT, params, timeout=15)

        elif command == "action":
            if not action:
                return "Error: action required (list, invoke, escape, magic_tap, increment, decrement)"
            params = {"action": action}
            if element is not None:
                params["element"] = element
            if text is not None:
                params["text"] = text
            if name is not None:
                params["name"] = name
            if index is not None:
                params["index"] = index
            return await resolve_and_send(simulator, CMD_ACCESSIBILITY_ACTION, params)

        elif command == "events":
            if not action:
                return "Error: action required (start, stop, status, events, clear)"
            params = {"action": action}
            if limit is not None:
                params["limit"] = limit
            if since_ms is not None:
                params["since_ms"] = since_ms
            return await resolve_and_send(simulator, CMD_ACCESSIBILITY_EVENTS, params)

        return f"Unknown command '{command}'. Use: audit, action, events"
