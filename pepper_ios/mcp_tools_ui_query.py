"""Grouped UI query tool — find, tree, verify, read, assert as subcommands."""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_ASSERT, CMD_FIND, CMD_READ, CMD_TREE, CMD_VERIFY


def register_ui_query_tools(mcp, resolve_and_send):
    """Register the ui_query grouped tool."""

    @mcp.tool(name="ui_query")
    async def ui_query(
        command: str = Field(description="Subcommand: find | tree | verify | read | assert"),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        predicate: str | None = Field(default=None, description="NSPredicate format string (find/assert). Properties: label, identifier, type, className, interactive, enabled, visible, heuristic, iconName"),
        action: str | None = Field(default=None, description="find: list (default), first, count"),
        limit: int | None = Field(default=None, description="Max results (find, default 50)"),
        depth: int | None = Field(default=None, description="Max tree depth (tree, default 10 summary / 50 full)"),
        detail: str | None = Field(default=None, description="tree: 'summary' (default) or 'full'"),
        element: str | None = Field(default=None, description="Accessibility ID (read/verify/assert/tree)"),
        text: str | None = Field(default=None, description="Assert text visible on screen (verify/assert)"),
        screen: str | None = Field(default=None, description="Assert current screen matches (verify)"),
        visible: bool | None = Field(default=None, description="Assert element is visible (verify)"),
        enabled: bool | None = Field(default=None, description="Assert element is enabled (verify)"),
        value: str | None = Field(default=None, description="Assert element has this value (verify/assert)"),
        contains: str | None = Field(default=None, description="Assert screen contains text (verify)"),
        exact: bool | None = Field(default=None, description="Require exact text match (verify)"),
        assertions: list[dict] | None = Field(default=None, description="Batch assertions list (verify)"),
        state: str | None = Field(default=None, description="assert: exists, not_exists, visible, enabled, disabled, selected, has_value"),
        expected: int | None = Field(default=None, description="Expected count for predicate (assert)"),
        compare: str | None = Field(default=None, description="Count comparison: eq, gte, lte, gt, lt (assert)"),
    ) -> str:
        """Query and inspect UI elements.

Subcommands:
- find: Query elements using NSPredicate (e.g. "label CONTAINS 'Save' AND type == 'button'")
- tree: Dump UIView hierarchy (summary or full detail)
- read: Read element value, type, and state by accessibility ID
- verify: Run pass/fail assertions on screen state
- assert: Assert element state, text presence, or element count"""

        if command == "find":
            if not predicate:
                return "Error: predicate required. Use: ui_query command=find predicate=\"type == 'button'\""
            params: dict = {"predicate": predicate, "action": action or "list"}
            if limit is not None:
                params["limit"] = limit
            return await resolve_and_send(simulator, CMD_FIND, params)

        elif command == "tree":
            params = {}
            if depth is not None:
                params["depth"] = depth
            if element:
                params["element"] = element
            if detail == "full":
                params["detail"] = "full"
            return await resolve_and_send(simulator, CMD_TREE, params)

        elif command == "read":
            if not element:
                return "Error: element required. Use: ui_query command=read element='my_element_id'"
            return await resolve_and_send(simulator, CMD_READ, {"element": element})

        elif command == "verify":
            params = {}
            if assertions is not None:
                params["assertions"] = assertions
            else:
                if text is not None:
                    params["text"] = text
                if element is not None:
                    params["element"] = element
                if screen is not None:
                    params["screen"] = screen
                if visible is not None:
                    params["visible"] = visible
                if enabled is not None:
                    params["enabled"] = enabled
                if value is not None:
                    params["value"] = value
                if contains is not None:
                    params["contains"] = contains
                if exact is not None:
                    params["exact"] = exact
            return await resolve_and_send(simulator, CMD_VERIFY, params)

        elif command == "assert":
            params = {}
            if element is not None:
                params["element"] = element
                params["state"] = state or "exists"
            if text is not None:
                params["text"] = text
            if predicate is not None:
                params["predicate"] = predicate
            if value is not None:
                params["value"] = value
            if expected is not None:
                params["expected"] = expected
            if compare is not None:
                params["compare"] = compare
            return await resolve_and_send(simulator, CMD_ASSERT, params)

        return f"Error: unknown command '{command}'. Use: find, tree, verify, read, assert"
