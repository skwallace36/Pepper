"""Grouped UI query tool — find, tree, verify, read, pepper_assert as subcommands.

Replaces 5 individual tools with one `ui_query` tool using a `command` parameter.
"""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_ASSERT, CMD_FIND, CMD_READ, CMD_TREE, CMD_VERIFY


def register_ui_query_tools(mcp, resolve_and_send):
    """Register the ui_query grouped tool on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str (JSON)
    """

    @mcp.tool(name="ui_query")
    async def ui_query(
        command: str = Field(
            description="Subcommand: find | tree | verify | read | assert"
        ),
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        # find params
        predicate: str | None = Field(
            default=None,
            description="[find/assert] NSPredicate format string. Properties: label, type, className, interactive, enabled, hitReachable, visible, heuristic, iconName, traits, x/y/width/height/centerX/centerY, viewController, presentationContext",
        ),
        action: str | None = Field(default=None, description="[find] Action: list (default), first, count"),
        limit: int | None = Field(default=None, description="[find] Max results to return (default: 50)"),
        # tree params
        depth: int | None = Field(default=None, description="[tree] Max tree depth (default: 10 summary, 50 full; max: 50)"),
        detail: str | None = Field(default=None, description="[tree] Detail level: 'summary' (default) or 'full'"),
        # read params
        element: str | None = Field(default=None, description="[read/verify/assert/tree] Accessibility ID of element"),
        # verify params
        text: str | None = Field(default=None, description="[verify/assert] Assert this text is visible on screen"),
        screen: str | None = Field(default=None, description="[verify] Assert current screen matches this name"),
        visible: bool | None = Field(default=None, description="[verify] Assert element is visible"),
        enabled: bool | None = Field(default=None, description="[verify] Assert element is enabled"),
        value: str | None = Field(default=None, description="[verify/assert] Assert element has this value"),
        contains: str | None = Field(default=None, description="[verify] Assert screen contains this text"),
        exact: bool | None = Field(default=None, description="[verify] Require exact text match"),
        assertions: list[dict] | None = Field(default=None, description="[verify] Batch: list of assertion objects"),
        # assert params
        state: str | None = Field(default=None, description="[assert] State: exists, not_exists, visible, enabled, disabled, selected, has_value"),
        expected: int | None = Field(default=None, description="[assert] Expected count (use with predicate)"),
        compare: str | None = Field(default=None, description="[assert] Count comparison: eq, gte, lte, gt, lt"),
    ) -> str:
        """Query and inspect UI elements. Subcommands:
        - find: Query elements using NSPredicate (e.g. "label CONTAINS 'Save' AND type == 'button'")
        - tree: Dump UIView hierarchy (summary or full detail)
        - read: Read element's value, type, and state by accessibility ID
        - verify: Run pass/fail assertions on screen state
        - assert: Assert element state, text presence, or element count"""

        if command == "find":
            if not predicate:
                return "Error: predicate required for find"
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
                return "Error: element required for read"
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

        return f"Unknown command '{command}'. Use: find, tree, verify, read, assert"
