"""Element inspection and control tool definitions for Pepper MCP.

Tool definitions for: toggle, read_element, tree, find, verify.
"""

from __future__ import annotations

from pydantic import Field

from .pepper_commands import CMD_FIND, CMD_READ, CMD_TOGGLE, CMD_TREE, CMD_VERIFY


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
        depth: int | None = Field(default=None, description="Max tree depth (default: 2 in summary, 50 in full mode; max: 50)"),
        element: str | None = Field(default=None, description="Scope to subtree of this accessibility ID"),
        detail: str = Field(
            default="summary",
            description="Detail level: 'summary' (default) shows 2 levels deep with class/id/label only. 'full' shows everything with frames and interactive info.",
        ),
    ) -> str:
        """Dump UIView hierarchy. Default summary mode shows 2 levels; use detail='full' for complete tree with frames."""
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
