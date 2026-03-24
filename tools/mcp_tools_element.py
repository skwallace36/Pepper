"""Element inspection and control tool definitions for Pepper MCP.

Tool definitions for: toggle, read_element, tree, find.
"""
from __future__ import annotations

from pydantic import Field


def register_element_tools(mcp, resolve_and_send, act_and_look):
    """Register element inspection/control tools on the given MCP server.

    Args:
        mcp: FastMCP server instance.
        resolve_and_send: async (simulator, cmd, params?, timeout?) -> str
        act_and_look: async (simulator, cmd, params?, timeout?) -> str
    """

    @mcp.tool()
    async def toggle(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        element: str = Field(description="Accessibility ID of the switch/segment to toggle"),
        value: int | None = Field(default=None, description="Target segment index (for segmented controls)"),
    ) -> str:
        """Toggle a UISwitch or UISegmentedControl by accessibility ID.
        For switches: flips on/off. For segments: advances to next or jumps to specified index.
        Shows screen state after toggling."""
        params: dict = {"element": element}
        if value is not None:
            params["value"] = value
        return await act_and_look(simulator, "toggle", params)

    @mcp.tool()
    async def read_element(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        element: str = Field(description="Accessibility ID of the element to read"),
    ) -> str:
        """Read an element's current value, type, and state by accessibility ID.
        Returns detailed info: text content, enabled/disabled, selected state, frame, etc."""
        return await resolve_and_send(simulator, "read", {"element": element})

    @mcp.tool()
    async def tree(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        depth: int | None = Field(default=None, description="Max tree depth (default: 50, max: 50)"),
        element: str | None = Field(default=None, description="Scope to subtree of this accessibility ID"),
    ) -> str:
        """Dump UIView hierarchy for deep debugging. Full view tree with class, frame, accessibility info.
        Warning: view tree can be large — use depth limit or scope to a subtree."""
        params: dict = {}
        if depth is not None:
            params["depth"] = depth
        if element:
            params["element"] = element
        return await resolve_and_send(simulator, "tree", params)

    @mcp.tool()
    async def find(
        simulator: str | None = Field(default=None, description="Simulator UDID"),
        predicate: str = Field(
            description="NSPredicate format string (e.g. \"label CONTAINS 'Save' AND type == 'button'\")"
        ),
        action: str = Field(default="list", description="Action: list (default), first, count"),
        limit: int | None = Field(default=None, description="Max results to return (default: 50)"),
    ) -> str:
        """Query on-screen elements using NSPredicate expressions. Native iOS predicate syntax.

        Available properties:
          label (String), type (String: button/toggle/text/searchField/tab/etc),
          className (String), interactive (Bool), enabled (Bool), hitReachable (Bool),
          visible (Float), heuristic (String), iconName (String), traits ([String]),
          x/y/width/height/centerX/centerY (Double), viewController (String),
          presentationContext (String: root/sheet/modal/navigation)

        Examples:
          "label CONTAINS 'Save'"
          "type == 'button' AND hitReachable == true"
          "'selected' IN traits"
          "label LIKE '*Settings*' AND interactive == true"
          "centerY > 400 AND type == 'toggle'"
          "viewController == 'ProfileViewController'"
        """
        params: dict = {"predicate": predicate, "action": action}
        if limit is not None:
            params["limit"] = limit
        return await resolve_and_send(simulator, "find", params)
