"""Accessibility tool definitions for Pepper MCP.

Tool definitions for: accessibility_audit, accessibility_action, accessibility_events.
"""
from __future__ import annotations

from pepper_commands import CMD_ACCESSIBILITY_ACTION, CMD_ACCESSIBILITY_AUDIT, CMD_ACCESSIBILITY_EVENTS
from pydantic import Field


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
        """Use this to check for accessibility violations on the current screen.

        Checks for: missing labels on interactive elements, invalid/missing traits,
        insufficient color contrast (WCAG 2.1 AA), fixed fonts without Dynamic Type,
        tap targets smaller than 44x44pt, and conflicting trait combinations.

        Returns a list of issues sorted by severity with element details and frames.

        Example: `accessibility_audit` → review reported issues → fix in code → re-audit to verify."""
        params: dict = {}
        if checks is not None:
            params["checks"] = checks
        if severity is not None:
            params["severity"] = severity
        return await resolve_and_send(simulator, CMD_ACCESSIBILITY_AUDIT, params, timeout=15)

    @mcp.tool()
    async def accessibility_action(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        action: str = Field(
            description="Action to perform: list, invoke, escape, magic_tap, increment, decrement"
        ),
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
        """Use this to test VoiceOver interactions without enabling VoiceOver.

        Actions:
        - list: List custom accessibility actions on an element.
        - invoke: Invoke a custom action by name or index.
        - escape: Trigger accessibilityPerformEscape() (two-finger Z gesture equivalent).
        - magic_tap: Trigger accessibilityPerformMagicTap() (two-finger double-tap equivalent).
        - increment: Call accessibilityIncrement() on adjustable elements (sliders, steppers).
        - decrement: Call accessibilityDecrement() on adjustable elements.

        For escape/magic_tap, element is optional — walks the responder chain from the current context.

        Example: `accessibility_action action=list element=slider1` → `accessibility_action action=increment element=slider1`."""
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
        since_ms: int | None = Field(default=None, description="Only events after this epoch-ms timestamp (for 'events' action)"),
    ) -> str:
        """Use this to detect screen changes instantly via UIAccessibility notifications.

        Unlike polling, accessibility notifications fire immediately when the screen updates.
        When the observer is active, wait_for uses these signals to wake up early instead of
        sleeping the full poll interval — making transitions near-instant to detect.

        Event types captured:
        - screen_changed: major screen transition (view controller push/pop, modal)
        - layout_changed: partial layout update within current screen
        - announcement: VoiceOver announcement finished (includes text)

        Actions:
        - start: begin observing (registers for UIAccessibility notifications)
        - stop: stop observing
        - status: check if active and current event counts
        - events: drain the ring buffer (newest last, up to 500 events retained)
        - clear: empty the ring buffer without stopping

        Example: `accessibility_events action=start` → interact with app → `accessibility_events action=events` → `accessibility_events action=stop`."""
        params: dict = {"action": action}
        if limit is not None:
            params["limit"] = limit
        if since_ms is not None:
            params["since_ms"] = since_ms
        return await resolve_and_send(simulator, CMD_ACCESSIBILITY_EVENTS, params)
