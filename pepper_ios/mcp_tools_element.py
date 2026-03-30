"""Element inspection and control tool definitions for Pepper MCP.

Tool definitions for: toggle, read_element, tree, find, verify, pepper_assert.
"""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_ASSERT, CMD_FIND, CMD_READ, CMD_TOGGLE, CMD_TREE, CMD_VERIFY


def register_element_tools(mcp, resolve_and_send, act_and_look):
    """Register element inspection/control tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> dict
        act_and_look: async (simulator, cmd, params?, timeout?) -> str
    """

    @mcp.tool()
    async def toggle(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        element: str = Field(description="Accessibility ID of the switch/segment to toggle"),
        value: int | None = Field(default=None, description="Target segment index (for segmented controls)"),
    ) -> str:
        """Flip a switch or change a segmented control by accessibility ID. Prefer over tap for switches. Shows screen state after."""
        params: dict = {"element": element}
        if value is not None:
            params["value"] = value
        return await act_and_look(simulator, CMD_TOGGLE, params)

    @mcp.tool()
    async def read_element(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        element: str = Field(description="Accessibility ID of the element to read"),
    ) -> str:
        """Read an element's current value, type, and state by accessibility ID.
        Returns detailed info: text content, enabled/disabled, selected state, frame, etc."""
        return await resolve_and_send(simulator, CMD_READ, {"element": element})

    @mcp.tool()
    async def tree(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        depth: int | None = Field(default=None, description="Max tree depth (default: 3 in summary, 50 in full mode; max: 50)"),
        element: str | None = Field(default=None, description="Scope to subtree of this accessibility ID"),
        detail: str = Field(
            default="summary",
            description="Detail level: 'summary' (default) shows 3 levels deep with class/id/label only. 'full' shows everything with frames and interactive info.",
        ),
    ) -> str:
        """Dump UIView hierarchy. Default summary mode shows 3 levels; use detail='full' for complete tree with frames."""
        params: dict = {}
        if depth is not None:
            params["depth"] = depth
        if element:
            params["element"] = element
        if detail == "full":
            params["detail"] = "full"
        return await resolve_and_send(simulator, CMD_TREE, params)

    @mcp.tool()
    async def find(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        predicate: str = Field(
            description="NSPredicate format string. Properties: label, type (button/toggle/text/searchField/tab), className, interactive, enabled, hitReachable, visible, heuristic, iconName, traits, x/y/width/height/centerX/centerY, viewController, presentationContext"
        ),
        action: str = Field(default="list", description="Action: list (default), first, count"),
        limit: int | None = Field(default=None, description="Max results to return (default: 50)"),
    ) -> str:
        """Query on-screen elements using NSPredicate expressions (e.g. "label CONTAINS 'Save' AND type == 'button'")."""
        params: dict = {"predicate": predicate, "action": action}
        if limit is not None:
            params["limit"] = limit
        return await resolve_and_send(simulator, CMD_FIND, params)

    @mcp.tool()
    async def verify(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        text: str | None = Field(
            default=None,
            description="Assert this text is visible on screen",
        ),
        element: str | None = Field(
            default=None,
            description="Accessibility ID of element to assert on",
        ),
        screen: str | None = Field(
            default=None,
            description="Assert current screen matches this name",
        ),
        visible: bool | None = Field(
            default=None,
            description="Assert element is visible (use with element param)",
        ),
        enabled: bool | None = Field(
            default=None,
            description="Assert element is enabled (use with element param)",
        ),
        value: str | None = Field(
            default=None,
            description="Assert element has this value (use with element param)",
        ),
        contains: str | None = Field(
            default=None,
            description="Assert screen contains this text (use with screen param)",
        ),
        exact: bool | None = Field(
            default=None,
            description="Require exact text match for text param (default: substring match)",
        ),
        assertions: list[dict] | None = Field(
            default=None,
            description="Batch mode: list of assertion objects. Each can have text, element, screen, visible, enabled, value, contains, exact.",
        ),
    ) -> str:
        """Run explicit pass/fail assertions on screen state. Returns structured results instead of requiring manual parsing of look output.

        Single assertion: provide text, element, or screen param.
        Batch: provide assertions list for multiple checks in one call."""
        params: dict = {}
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

    @mcp.tool()
    async def pepper_assert(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        element: str | None = Field(
            default=None,
            description="Accessibility ID to assert on",
        ),
        text: str | None = Field(
            default=None,
            description="Assert this text is visible on screen",
        ),
        predicate: str | None = Field(
            default=None,
            description="NSPredicate for count assertions (use with expected param)",
        ),
        state: str = Field(
            default="exists",
            description="State to check: exists, not_exists, visible, enabled, disabled, selected, has_value",
        ),
        value: str | None = Field(
            default=None,
            description="Expected value (use with state=has_value)",
        ),
        expected: int | None = Field(
            default=None,
            description="Expected count (use with predicate param)",
        ),
        compare: str | None = Field(
            default=None,
            description="Count comparison: eq (default), gte, lte, gt, lt",
        ),
    ) -> str:
        """Assert element state, text presence, or element count. Returns {passed: true/false} for CI-readable results.

        Element: pepper_assert element="Save" state=exists
        Text: pepper_assert text="Welcome"
        Count: pepper_assert predicate="type == 'button'" expected=3"""
        params: dict = {}
        if element is not None:
            params["element"] = element
            params["state"] = state
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
