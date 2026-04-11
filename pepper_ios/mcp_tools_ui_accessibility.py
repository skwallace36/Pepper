"""Grouped accessibility tool — audit, action, events as subcommands."""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_ACCESSIBILITY_ACTION, CMD_ACCESSIBILITY_AUDIT, CMD_ACCESSIBILITY_EVENTS


def register_ui_accessibility_tools(mcp, resolve_and_send):
    """Register the ui_accessibility grouped tool."""

    @mcp.tool(name="ui_accessibility")
    async def ui_accessibility(
        command: str = Field(description="Subcommand: audit | action | events"),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        checks: str | None = Field(default=None, description="Comma-separated checks (audit): missing_label, missing_trait, contrast, dynamic_type, touch_target, redundant_trait"),
        severity: str | None = Field(default=None, description="Min severity (audit): error, warning, info"),
        action: str | None = Field(default=None, description="action: list/invoke/escape/magic_tap/increment/decrement. events: start/stop/status/events/clear"),
        element: str | None = Field(default=None, description="Accessibility ID of target element (action)"),
        text: str | None = Field(default=None, description="Text label of target element (action)"),
        name: str | None = Field(default=None, description="Custom action name to invoke (action)"),
        index: int | None = Field(default=None, description="Custom action index to invoke (action)"),
        limit: int | None = Field(default=None, description="Max events to return (events)"),
        since_ms: int | None = Field(default=None, description="Only events after this epoch-ms (events)"),
    ) -> str:
        """Accessibility testing tools.

Subcommands:
- audit: Audit screen for violations (missing labels, contrast, small tap targets)
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
                return "Error: action required. Use: list, invoke, escape, magic_tap, increment, decrement"
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
                return "Error: action required. Use: start, stop, status, events, clear"
            params = {"action": action}
            if limit is not None:
                params["limit"] = limit
            if since_ms is not None:
                params["since_ms"] = since_ms
            return await resolve_and_send(simulator, CMD_ACCESSIBILITY_EVENTS, params)

        return f"Error: unknown command '{command}'. Use: audit, action, events"
